# Go 运行时基础镜像（go-runtime-base）构建指南

> 相关清单：
> - [dockerfile/go-runtime-base.Dockerfile](../../dockerfile/go-runtime-base.Dockerfile) —— 基础镜像构建文件
> - [basetasktemplate/build/go-build-image.yaml](../../basetasktemplate/build/go-build-image.yaml) —— 引用本基础镜像的镜像构建模板

---

## 一、它解决什么问题

go-build-image 模板原本在**构建期**用 `apk add --no-cache tzdata ca-certificates` 装包，这要从外网 `dl-cdn.alpinelinux.org` 拉取 Alpine 包。在当前集群里这一步稳定失败：

```
#6 WARNING: fetching https://dl-cdn.alpinelinux.org/alpine/v3.22/main: DNS lookup error
#6 ERROR: unable to select packages: ca-certificates (no such package) ...
```

**根因**（已实测确认，不是 Fastly 丢包）：

| 检查 | 结果 | 含义 |
| --- | --- | --- |
| `ip -6 route`（buildkitd Pod 内） | 只有 `fe80::/64` 链路本地 | Pod **没有全局 IPv6 路由**，实际是单栈 IPv4 |
| `nslookup dl-cdn.alpinelinux.org` | 成功，返回 AAAA `2a04:4e42:68::644` + IPv4 | 原始 DNS 能解，但回了一个**不可达的 IPv6** |
| `getent hosts dl-cdn.alpinelinux.org` | 退出码 2（失败） | **musl libc 解析器失败** —— apk/wget 走的就是这条路径 |

busybox `nslookup` 自己发原始 DNS 包（绕过 libc）所以看着正常；而 `apk`/`wget` 走 alpine 的 musl libc 解析器，拿到不可达的 AAAA 后直接 `bad address`。**换国内 apk 源也治不了**——任何源都会返回 AAAA，照样触发 musl 失败。

**解法（方案 A）**：把「装 tzdata/ca-certificates」从构建期前移到一个**一次性构建的基础镜像** `go-runtime-base`，推到本地 nexus3。之后 go-build-image 生成的运行时镜像直接 `FROM` 它，**构建期不再 apk add、不再需要任何外网 DNS**——贴合 [镜像构建与推送设计](../构建/镜像构建与推送设计.md)§4.2「完全不走外部源」的设计目标。

---

## 二、镜像内容

| 组件 | 来源 | 作用 |
| --- | --- | --- |
| `tzdata` | `apk add` | 时区数据库；配合 `/etc/localtime` 让容器内时间用 Asia/Shanghai |
| `ca-certificates` | `apk add` | CA 根证书（出站 HTTPS 校验）；补全 alpine 基镜自带的 `ca-certificates-bundle` |
| `/etc/localtime` | 复制 zoneinfo | 系统默认时区 = 上海（`date`、Go `time.Local` 均读它） |
| `/etc/timezone` | echo 写入 | 文档化时区名，部分工具读取 |

> 基础镜像**只装这些**；非 root 用户、`WORKDIR`、`COPY` 二进制、`ENTRYPOINT` 等应用相关内容由 go-build-image 生成的运行时 Dockerfile 负责（不在基础镜像里）。

---

## 三、前置条件

| 依赖 | 说明 |
| --- | --- |
| 一台网络正常的构建机 | 能访问 Docker Hub（拉 `alpine:3.22`）；若构建机走不了外网，可把 Dockerfile 的 `FROM` 改成 `192.168.10.134:8082/alpine:3.22`（已预推到 nexus3，见下「方式三」注） |
| docker（≥ 20.10，建议启用 buildkit） | 构建用；跨架构构建需 buildx |
| **目标架构 = linux/arm64** | 集群 buildkitd 节点是 `aarch64`（见 §4.1 确认）；镜像架构必须匹配，否则容器 `exec format error` |
| nexus3 docker-hosted 仓库 | `192.168.10.134:8082`（HTTP），已开启匿名拉取；推送需账号（学习环境 `admin/admin`，见 [nexus3搭建](../../环境搭建/制品仓库/nexus3搭建.md)） |
| 推送通道（三选一） | 方式一 skopeo（daemonless，HTTP 仓库最稳）；方式二 docker push（需配 insecure registry）；方式三 原生 arm64 机构建 |

---

## 四、构建与推送（详细步骤）

> 镜像目标 ref：`192.168.10.134:8082/go-runtime-base:alpine-3.22`（tag 把 alpine 版本编进去，便于回滚）。

### 4.1 先确认目标架构

```bash
# 集群里 buildkitd 是什么架构？—— 必须与基础镜像架构一致
kubectl -n argo exec deploy/buildkitd -- uname -m
# 预期输出：aarch64  →  对应 docker platform = linux/arm64
```

### 4.2 方式一（推荐）：buildx 构建 + skopeo 推送

**优点**：不依赖本地 docker daemon、不用配 insecure registry、`--platform` 显式锁架构、HTTP 仓库最稳。

```bash
cd /path/to/pipeline-manifests   # 进入仓库根目录（Dockerfile 上下文）

# ① 跨架构构建，直接导出为 docker 格式 tar（不落本地 daemon）
docker buildx build --platform linux/arm64 \
    -f dockerfile/go-runtime-base.Dockerfile \
    -t 192.168.10.134:8082/go-runtime-base:alpine-3.22 \
    --output type=docker,dest=/tmp/go-runtime-base-alpine-3.22.tar \
    .

# ② 用 skopeo 推到 nexus3（HTTP 仓库，关 TLS 校验；账号密码按实际填）
skopeo copy --dest-tls-verify=false \
    --dest-creds admin:admin \
    docker-archive:/tmp/go-runtime-base-alpine-3.22.tar \
    docker://192.168.10.134:8082/go-runtime-base:alpine-3.22

# ③ 验证：远端镜像架构/os 应为 arm64 / linux
skopeo inspect --tls-verify=false \
    docker://192.168.10.134:8082/go-runtime-base:alpine-3.22 \
    | grep -E '"architecture"|"os"'
# 预期：
#   "architecture": "arm64",
#   "os": "linux",
```

> skopeo 安装：构建机若无 skopeo，`brew install skopeo`（macOS）或 `apt install skopeo`（Linux）。
> buildx 跨架构（在 amd64 机器上构建 arm64）需要 binfmt：Docker Desktop 自带；Linux 服务器执行一次 `docker run --privileged --rm tonistiigi/binfmt --install arm64`。

### 4.3 方式二：docker build + docker push

**适用**：构建机已经按 [镜像构建与推送设计](../构建/镜像构建与推送设计.md)§4.2 用 `docker push` 推过 `alpine:3.22`（即 docker daemon 已配好 `192.168.10.134:8082` 的 insecure registry）。

```bash
cd /path/to/pipeline-manifests

# ① 构建（显式锁架构；arm64 原生机上是原生构建，amd64 机上靠 buildkit+binfmt 跨架构）
docker build --platform linux/arm64 \
    -f dockerfile/go-runtime-base.Dockerfile \
    -t 192.168.10.134:8082/go-runtime-base:alpine-3.22 \
    .

# ② 推送（前提：daemon.json 已配 "insecure-registries": ["192.168.10.134:8082"]）
docker push 192.168.10.134:8082/go-runtime-base:alpine-3.22
```

> 若推送报 TLS/x509 错误，说明 docker daemon 没把 `192.168.10.134:8082` 配为 insecure registry。编辑 `/etc/docker/daemon.json` 加入：
> ```json
> { "insecure-registries": ["192.168.10.134:8082"] }
> ```
> 再 `sudo systemctl restart docker`。或直接改用「方式一（skopeo）」绕开此配置。

### 4.4 方式三：arm64 原生机直接构建（无 buildx 时）

若构建机本身就是 arm64（如 Apple Silicon Mac、arm64 Linux 服务器），可省略 `--platform`，`docker build` 默认产出 arm64 镜像：

```bash
cd /path/to/pipeline-manifests
docker build -f dockerfile/go-runtime-base.Dockerfile \
    -t 192.168.10.134:8082/go-runtime-base:alpine-3.22 .
docker push 192.168.10.134:8082/go-runtime-base:alpine-3.22   # 仍需 insecure registry（同方式二）
```

> 构建机走不了外网（拉不到 Docker Hub 的 alpine）时，把 Dockerfile 第一行改成 `FROM 192.168.10.134:8082/alpine:3.22`（该镜像已预推到 nexus3，见 [镜像构建与推送设计](../构建/镜像构建与推送设计.md)§4.2），并用方式一/二推送即可完全离线构建。

---

## 五、让 go-build-image 用上它

go-build-image 模板的 `build-runtime-base-image` 入参默认值已改为本镜像，且生成的运行时 Dockerfile 已去掉 `apk add` 段。两种用法：

**① 沿用默认值**（已改好）：直接 apply 模板即可。

```bash
kubectl apply -f basetasktemplate/build/go-build-image.yaml -n argo
```

**② 调用时显式传参**（想临时切换基础镜像时）：

```yaml
templateRef: { name: go-build-image, template: entrypoint }
arguments:
  parameters:
    - name: build-runtime-base-image
      value: "192.168.10.134:8082/go-runtime-base:alpine-3.22"
```

> ⚠️ 前提：本镜像已按 §4 推到 nexus3，且 buildkitd 的 `buildkitd.toml` 已声明 `192.168.10.134:8082` 走 HTTP（已内置在 [buildkitd.yaml](../../basetasktemplate/tools/buildkitd.yaml) 的 ConfigMap）。两者缺一不可，详见 [镜像构建与推送设计](../构建/镜像构建与推送设计.md)§4.2。

---

## 六、端到端验证

跑一次 go-build-image（或上层流水线），观察日志里**自动生成的 Dockerfile**：

```
[Info] 生成的 Dockerfile：
    # 由 go-build-image 自动生成：...不再 apk add...
    FROM 192.168.10.134:8082/go-runtime-base:alpine-3.22
    RUN addgroup -S app && adduser -S -G app app
    WORKDIR /app
    COPY go-web-demo /app/go-web-demo
    USER app
    EXPOSE 9000
    ENTRYPOINT ["/app/go-web-demo"]
```

确认 **不再有 `apk add` 那段 RUN**，且构建一路走到 `导出 docker tar` 成功、写出参 `build-image-tar-path`。之前的 `bad address` / `DNS lookup error` / `exit status 170` 应全部消失。

---

## 七、后续维护

| 场景 | 操作 |
| --- | --- |
| 升级 alpine 小版本（如 3.22 → 3.23） | 改 Dockerfile `FROM alpine:3.23` → 重新构建推送为新 tag `go-runtime-base:alpine-3.23` → 把 go-build-image 的默认值（或调用入参）指向新 tag。**不要原地覆盖旧 tag**，保留旧 tag 便于回滚 |
| 只更新证书/时区数据 | 同上，重新构建推送一个新 tag |
| 想加更多公共依赖（如 `curl`、`tini`） | 在 Dockerfile 的 `RUN apk add` 里追加，重新构建推送 |

> tag 命名约定 `go-runtime-base:alpine-<版本>`：把 alpine 版本编进 tag，一眼看出基镜基于哪个 alpine，回滚/追踪都方便。

---

## 八、FAQ

**Q1：为什么不直接在 go-build-image 里把 apk 源换成国内镜像（清华/阿里）？**
A：换源治标不治本。根因是 musl libc 拿到不可达的 AAAA 记录后解析失败，**国内源同样返回 AAAA**，照样触发 `bad address`。预制基础镜像才是从根上消除构建期外网依赖。

**Q2：能不能不维护自定义基础镜像，让 Go 程序自己内嵌时区数据？**
A：可以，这是另一条路——在 Go 源码里 `import _ "time/tzdata"`（Go 1.15+）或 go-build 加 `-tags timetzdata`，二进制就自带时区库，运行时镜像连 tzdata 都不用装。但它改的是 go-build 上游（源码/编译参数），不在本基础镜像方案范围内；本方案的优势是**对上游二进制零侵入**。

**Q3：推送报 `tls: failed to verify certificate` / `x509` 错误？**
A：nexus3 docker-hosted 是 HTTP（8082），没关目的端 TLS 校验。方式一加 `--dest-tls-verify=false`；方式二/三给 docker daemon 配 `insecure-registries` 后重启 docker。

**Q4：构建成功但容器跑起来 `exec format error`？**
A：镜像架构和集群节点不一致。用 §4.1 确认节点是 `aarch64`，构建时务必带 `--platform linux/arm64`（方式三原生 arm64 机除外）。

**Q5：构建机拉 `alpine:3.22` 很慢或拉不到（外网受限）？**
A：把 Dockerfile 的 `FROM` 改成 `192.168.10.134:8082/alpine:3.22`（nexus3 里已有），用方式一/二推送，即可离线构建。

---

## 九、参考资料

- [镜像构建与推送设计.md](../构建/镜像构建与推送设计.md) —— §4.2 基础镜像走本地 nexus3、§5.4 自动生成 Dockerfile 的设计
- [nexus3搭建.md](../../环境搭建/制品仓库/nexus3搭建.md) —— nexus3 docker-hosted 仓库搭建、镜像上传拉取、insecure registry 配置
- [buildkitd.yaml](../../basetasktemplate/tools/buildkitd.yaml) —— buildkitd 部署（含 nexus3 HTTP 仓库声明）
- 清单：[go-runtime-base.Dockerfile](../../dockerfile/go-runtime-base.Dockerfile)、[go-build-image.yaml](../../basetasktemplate/build/go-build-image.yaml)
