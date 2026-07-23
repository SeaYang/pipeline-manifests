# go-runtime-base：Go 静态二进制运行时基础镜像
#
# 作用：预装 tzdata + ca-certificates + 上海时区，供 go-build-image 模板生成的运行时镜像直接 FROM。
#       把「装包」这件事从『集群内构建期（buildkitd Pod 里）』前移到『一次性本地构建』，
#       使最终镜像构建不再需要 apk add、不再依赖外网 DNS —— 规避 buildkitd Pod 无全局 IPv6 路由时，
#       alpine/musl 解析 dl-cdn.alpinelinux.org 失败（apk 报 bad address / DNS lookup error）的问题。
#
# 目标架构：linux/arm64（与集群 buildkitd 节点 aarch64 一致；构建时务必用 --platform linux/arm64，
#           否则跨架构构建机会得到 amd64 镜像，跑在 arm64 集群里报 exec format error）。
#
# 构建/推送的详细可执行步骤见：docs/工具/go运行时基础镜像构建.md
FROM alpine:3.22

# tzdata：时区数据（配合下面的 /etc/localtime，让容器内时间用 Asia/Shanghai）。
# ca-certificates：CA 根证书（出站 HTTPS 校验；alpine 基镜已含 ca-certificates-bundle，这里补全 update-ca-certificates 工具链）。
# 装包 + 设时区为上海（复制 zoneinfo 到 /etc/localtime，并写 /etc/timezone）。
# 这一步只在本镜像「一次性构建」时执行（在网络正常的构建机上），最终镜像构建期不再重复。
RUN apk add --no-cache tzdata ca-certificates && \
    cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone
