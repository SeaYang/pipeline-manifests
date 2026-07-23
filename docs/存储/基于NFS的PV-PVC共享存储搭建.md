# 基于 NFS 的 PV/PVC 共享存储搭建

在已有的 k8s 集群（参考 [k8s环境搭建](../../环境搭建/k8s/v1.23.3.md)）基础上，搭建一套基于 NFS 的共享存储，供多个 Pod 之间读写同一份数据。

NFS Server 部署在 worker 节点（硬盘 150G，容量充足），所有 Pod（目前都在 worker 上）都挂载这个共享目录。

## 环境信息

| 角色 | 主机名 | IP | 说明 |
| --- | --- | --- | --- |
| k8s master | k8s-master | 192.168.10.130 | 控制面，默认不跑业务 Pod（NoSchedule 污点） |
| k8s worker | k8s-worker | 192.168.10.131 | 跑业务 Pod，**同时也是 NFS Server** |
| 子网 | - | 192.168.10.0/24 | 虚拟机自定义网络 vmnet2 |

- NFS Server 共享目录：`/data/pipeline/shared-data`
- k8s 版本：v1.23.3
- 容器运行时：docker（参考 [docker安装](../../环境搭建/docker/docker_v28.2.2.md)）

## 整体架构与原理

```
+-----------------------------+        NFS (TCP 2049)
|  k8s-worker (NFS Server)    |<-------------------------------+
|  /data/pipeline/shared-data |                                |
|  nfs-kernel-server          |                                |
+-----------------------------+                                |
                                                               |
              Pod A (writer) ---挂载 PVC---> 同一个 NFS 目录    |
              Pod B (reader) ---挂载 PVC---> 同一个 NFS 目录 ----+
```

关键点先记住，后面会展开：

1. NFS Server 在 worker 上导出 `/data/pipeline/shared-data`。
2. **每个会运行「挂载该 PV 的 Pod」的节点，都必须安装 NFS 客户端（`nfs-common`）**。因为真正执行 `mount -t nfs` 的是节点上的 kubelet，不是 Pod 内部。这点很容易被忽略。
3. k8s 里用 `ReadWriteMany`（RWX）访问模式的 PV/PVC，让多个 Pod 同时读写——这正是 NFS 相比本地 `hostPath`/`emptyDir` 的核心价值。
4. 本方案是「静态供给」（手工建好 PV，PVC 去绑定）。后面也给出了「动态供给」（nfs-subdir-external-provisioner，每个 PVC 自动分一个子目录）的进阶做法。

---

## 一、NFS Server 端安装与配置（在 worker 节点 192.168.10.131 操作）

以下命令在 `k8s-worker` 上以 root（或加 sudo）执行。

### 1.1 先确认磁盘容量落点

worker 一共 150G，要确认 `/data` 落在有空间的分区上，而不是某个很小的分区：

```shell
df -h /data
```

如果 `/data` 不存在或落在空间不够的分区，先把目录建在容量充足的分区下。本例假设整个 150G 是一个挂载在 `/` 的大分区，`/data` 直接在根下即可。

### 1.2 安装 nfs-kernel-server

```shell
sudo apt update
sudo apt install -y nfs-kernel-server
```

安装后会自动带上 `rpcbind`（NFS 依赖它做端口映射）。

### 1.3 创建共享目录

```shell
sudo mkdir -p /data/pipeline/shared-data
```

目录默认属主是 `root:root`，权限 `755`。关于权限和「squash」的细节见 [5.1 权限与 squash（头号坑）](#51-权限与-squash头号坑)，这里先用默认值。

### 1.4 配置导出（编辑 /etc/exports）

```shell
sudo vim /etc/exports
```

在文件末尾追加一行：

```text
/data/pipeline/shared-data 192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash)
```

各参数含义：

| 参数 | 含义 |
| --- | --- |
| `192.168.10.0/24` | 只允许这个子网的机器挂载（限定来源，比写 `*` 安全） |
| `rw` | 可读可写 |
| `sync` | 写操作同步落盘，数据更安全（代价是略慢；追求性能可换 `async`） |
| `no_subtree_check` | 不做子树检查，性能更好，且能避免一些跨目录重命名导致的报错 |
| `no_root_squash` | **关键**：客户端的 root 不被映射成 nobody，这样 Pod 以 root 运行时能正常写。详见后文 |

> 安全提示：`no_root_squash` 意味着客户端的 root 对该目录拥有「真 root」权限。在内网学习环境可接受；生产环境应改用 `all_squash + anonuid/anongid` 映射到专用账号（见 [5.9](#59-安全限制导出网段no_root_squash-的风险)）。

### 1.5 让导出生效并设置开机自启

```shell
# 重新加载导出配置
sudo exportfs -ra

# 查看当前导出列表（验证配置是否正确）
sudo exportfs -v

# 启动并设置开机自启
sudo systemctl enable --now nfs-server
sudo systemctl enable --now rpcbind
```

`exportfs -v` 正常会输出类似：

```shell
root@k8s-worker:/home/seayang# exportfs -v
/data/pipeline/shared-data
		192.168.10.0/24(sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash)
```

### 1.6 防火墙（如启用了 ufw）

Ubuntu Desktop 默认 ufw 是关闭的，可以先确认：

```shell
sudo ufw status
```

- 如果是 `Status: inactive`，**跳过本步**，无需放行端口。
- 如果是 `active`，需要放行 NFS 相关端口。最简单的是限定子网放行：

  ```shell
  sudo ufw allow from 192.168.10.0/24 to any port 2049 proto tcp   # nfs
  sudo ufw allow from 192.168.10.0/24 to any port 111  proto tcp   # rpcbind
  sudo ufw allow from 192.168.10.0/24 to any port 111  proto udp
  ```

  > NFSv4 其实只需要 2049；但 `rpcbind`(111) 和 mountd 在 NFSv3/混合模式下会被用到，一起放开省心。

### 1.7 验证 NFS Server

在 worker 本机检查导出列表：

```shell
showmount -e localhost
```

期望输出：

```shell
Export list for localhost:
/data/pipeline/shared-data 192.168.10.0/24
```

再确认服务状态：

```shell
sudo systemctl status nfs-server --no-pager
```

看到 `Active: active (exited)` 且 `status=0/SUCCESS` 即正常。

> 注意：`nfs-server` 是 `Type=oneshot` 类型的服务——它启动时执行一次 `exportfs`、把 NFS 内核守护进程（kernel nfsd）拉起来，之后用户态服务进程就「退出」了，真正的文件服务由内核线程承担。所以状态是 `active (exited)` 而不是 `active (running)`，这是正常的，不用担心。
>
> 如果日志里出现 `exportfs: can't open /etc/exports for reading`，说明**服务启动那一刻**没有读到导出配置（通常是「先启动服务、后写 `/etc/exports`」导致的，比如装包时服务被自动拉起）。只要事后执行过 `exportfs -ra`，当前状态就是好的，用下面的 `exportfs -v` / `showmount -e` 验证即可。

---

## 二、NFS Client 端安装与验证（master 和 worker 都要装）

**重点**：master 和 worker 都要装 `nfs-common`。原因见开头的「关键点 2」——kubelet 在哪个节点跑 Pod，就在哪个节点执行真正的 NFS 挂载。即便现在 Pod 只在 worker 跑，将来想在 master 上跑（去掉污点后）或做手动测试，都需要客户端工具。

### 2.1 安装 nfs-common

**在 master（192.168.10.130）和 worker（192.168.10.131）上都执行：**

```shell
sudo apt update
sudo apt install -y nfs-common
```

### 2.2 手动挂载测试（在 master 上验证连通性）

在 master 上挂一下 worker 导出的目录，确认网络、权限都通：

```shell
# 临时挂载点
sudo mkdir -p /mnt/nfs-test

# 挂载（worker IP = 192.168.10.131）
sudo mount -t nfs -o nfsvers=4.1 192.168.10.131:/data/pipeline/shared-data /mnt/nfs-test

# 看看是否挂上
df -h /mnt/nfs-test
mount | grep nfs-test
```

写一个测试文件：

```shell
echo "hello from master $(date)" | sudo tee /mnt/nfs-test/hello.txt
cat /mnt/nfs-test/hello.txt
```

然后**到 worker 上**确认文件真的写到了 server 端：

```shell
cat /data/pipeline/shared-data/hello.txt
```

能看到同样内容，说明 NFS Server/Client 完全正常。

> 注意：k8s 挂载 PV 时不需要把目录写进 `/etc/fstab`，kubelet 会按需挂载。这里只是手动验证连通性，验证完可以卸载：
>
> ```shell
> sudo umount /mnt/nfs-test
> ```

---

## 三、k8s PV/PVC 创建（在 master 上用 kubectl 操作）

下面把上面的命令写成 yaml 保存到仓库的 `pvc/` 目录，也方便版本管理。

### 3.1 创建 PV（静态供给）

详细看：[nfs-pv.yaml](../../pvc/nfs-pv.yaml)

创建并查看：

```shell
kubectl apply -f pvc/nfs-pv.yaml
kubectl get pv nfs-pv
```

PV 状态应为 `AVAILABLE`：

```shell
NAME     CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS   REASON   AGE
nfs-pv   80Gi      RWX            Retain           Available                                   8s
```

### 3.2 创建 PVC

详细看：[nfs-pvc.yaml](../../pvc/nfs-pvc.yaml)

创建并查看：

```shell
kubectl apply -f pvc/nfs-pvc.yaml
kubectl get pvc nfs-pvc
kubectl get pv nfs-pv
```

绑定成功后：

```shell
NAME      STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
nfs-pvc   Bound    nfs-pv   80Gi      RWX                           13s
```

同时 PV 的 `STATUS` 会变成 `Bound`，`CLAIM` 列显示 `default/nfs-pvc`。

### 3.3 创建测试 Pod（写入）

`pvc/nfs-writer.yaml`：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nfs-writer
spec:
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["/bin/sh", "-c"]
      args:
        - |
          echo "writer 写入数据，时间戳：$(date)" > /data/shared/log.txt
          echo "写入完成，保持运行以便观察"
          sleep 120
      volumeMounts:
        - name: nfs-vol
          mountPath: /data/shared
  volumes:
    - name: nfs-vol
      persistentVolumeClaim:
        claimName: nfs-pvc
  restartPolicy: OnFailure
```

> 镜像提示：`busybox:1.36` 体积小。如果 worker 拉不到镜像，参考 [镜像加速.md](../../环境搭建/镜像加速.md) 先在 worker 上 `docker pull` 好再 tag。

```shell
kubectl apply -f pvc/nfs-writer.yaml
kubectl get pod nfs-writer -w
```

等 Pod 进入 `Running` 后，验证写入：

```shell
kubectl exec nfs-writer -- cat /data/shared/log.txt
```

同时到 worker 的 server 目录确认：

```shell
sudo cat /data/pipeline/shared-data/log.txt
```

### 3.4 验证 Pod 间数据共享

再起一个 reader Pod，挂载**同一个 PVC**，读 writer 写的文件，证明数据共享成立。

`pvc/nfs-reader.yaml`：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nfs-reader
spec:
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["/bin/sh", "-c", "sleep 120"]
      volumeMounts:
        - name: nfs-vol
          mountPath: /data/shared
  volumes:
    - name: nfs-vol
      persistentVolumeClaim:
        claimName: nfs-pvc
  restartPolicy: OnFailure
```

```shell
kubectl apply -f pvc/nfs-reader.yaml

# reader 读到了 writer 写的文件 = 共享成功
kubectl exec nfs-reader -- cat /data/shared/log.txt
```

进一步：让 reader 也写一笔，再在 writer 里读：

```shell
kubectl exec nfs-reader -- sh -c 'echo "reader 回写：$(date)" >> /data/shared/log.txt'
kubectl exec nfs-writer -- cat /data/shared/log.txt
```

两个 Pod 互相能看到对方的写入，说明基于 NFS 的 RWX 共享存储已经跑通。

---

## 四、动态供给（可选进阶）

上面的静态供给是「一个 PV 对应整个共享目录，多个 Pod 共用」。如果你将来希望**每个 PVC 自动分到一个独立子目录**（互相隔离、用完自动回收），可以用 `nfs-subdir-external-provisioner`。

它的工作方式：你只要建 PVC，provisioner 就会在 NFS 共享目录下自动创建 `${namespace}-${pvcName}-${pvcUid}` 这样的子目录并挂给 Pod。

### 4.1 部署 provisioner

`pvc/nfs-provisioner.yaml`（包含 RBAC + Deployment + StorageClass，一次 apply）：

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-client-provisioner
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nfs-client-provisioner-runner
rules:
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: run-nfs-client-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    namespace: kube-system
roleRef:
  kind: ClusterRole
  name: nfs-client-provisioner-runner
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: leader-locking-nfs-client-provisioner
  namespace: kube-system
rules:
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: leader-locking-nfs-client-provisioner
  namespace: kube-system
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    namespace: kube-system
roleRef:
  kind: Role
  name: leader-locking-nfs-client-provisioner
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-client-provisioner
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nfs-client-provisioner
  template:
    metadata:
      labels:
        app: nfs-client-provisioner
    spec:
      serviceAccountName: nfs-client-provisioner
      containers:
        - name: nfs-client-provisioner
          image: registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2
          volumeMounts:
            - name: nfs-client-root
              mountPath: /persistentvolumes
          env:
            - name: PROVISIONER_NAME
              value: k8s-sigs.io/nfs-subdir
            - name: NFS_SERVER
              value: 192.168.10.131
            - name: NFS_PATH
              value: /data/pipeline/shared-data
      volumes:
        - name: nfs-client-root
          nfs:
            server: 192.168.10.131
            path: /data/pipeline/shared-data
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
provisioner: k8s-sigs.io/nfs-subdir
parameters:
  archiveOnDelete: "false"     # 删 PVC 时是否归档子目录；false=直接删
  pathPattern: "${.PVC.namespace}-${.PVC.name}"
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
```

> 镜像提示：`registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2` 可能拉不下来，参考 [镜像加速.md](../../环境搭建/镜像加速.md) 在 worker 上先 pull 并 tag。

```shell
kubectl apply -f pvc/nfs-provisioner.yaml
kubectl -n kube-system get pod -l app=nfs-client-provisioner
```

### 4.2 用动态 StorageClass 建 PVC

```yaml
# pvc/nfs-dynamic-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-dynamic-pvc
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: nfs-client     # 指向上面建的 StorageClass
  resources:
    requests:
      storage: 5Gi
```

```shell
kubectl apply -f pvc/nfs-dynamic-pvc.yaml
kubectl get pvc nfs-dynamic-pvc
```

建好后到 worker 上看，`/data/pipeline/shared-data/` 下会多出一个 `default-nfs-dynamic-pvc-<uid>` 子目录——这就是动态供给的效果。

> 注意区别：动态供给是「每 PVC 一个隔离子目录」，并不能让多个 Pod 跨 PVC 共享数据。如果你要的就是「多 Pod 共享同一份数据」，请用第三章的静态供给 + 同一个 PVC。

---

## 五、你可能没考虑到的（重要）

### 5.1 权限与 squash（头号坑）

这是 NFS + k8s 最常见的坑，必须理解。

**NFS 默认开启 `root_squash`**：客户端的 root 用户会被映射成 `nobody:nogroup`（uid 65534）。我们 1.4 里特意用了 `no_root_squash` 关掉它，原因如下：

- 大部分 Pod 默认以 **root** 运行（busybox、很多镜像都是）。
- 共享目录 `shared-data` 属主是 root，权限 `755`（只有属主能写）。
- 如果保持默认 `root_squash`，Pod 的 root 写文件 → 被映射成 nobody → 对 755 的 root 目录 **没有写权限** → 报 `Permission denied`，Pod 起不来或写文件失败。

**几种处理方式，按场景选：**

| 场景 | 做法 |
| --- | --- |
| Pod 以 root 运行（学习环境） | 导出加 `no_root_squash`（本方案）。简单直接 |
| Pod 以非 root 运行（如 runAsUser=1000） | 方案A：`chmod 777` 目录（粗暴）；方案B：导出加 `all_squash,anonuid=1000,anongid=1000`，把所有访问映射到 1000 |
| 生产环境，多租户隔离 | 建专用 uid/gid，`all_squash,anonuid=<uid>,anongid=<gid>`，目录 chown 给该 uid，最安全 |

**如果遇到 `Permission denied`，先这样排查：**

```shell
# 在 worker 上看导出是否真的关了 root_squash
sudo exportfs -v | grep shared-data

# 看 Pod 写出来的文件属主是谁（在 worker server 目录看）
ls -l /data/pipeline/shared-data/
```

如果文件属主是 `nobody`/`nogroup`，说明 squash 生效了；如果是 `root`，说明 `no_root_squash` 已生效。

### 5.2 kubelet 节点必须装 nfs-common

再说一次，因为太重要：**真正执行 `mount -t nfs` 的是节点上的 kubelet，不是容器里。** 所以任何会运行「挂 NFS 的 Pod」的节点，都必须先装 `nfs-common`，否则 Pod 卡在 `ContainerCreating`，事件里报：

```
MountVolume.SetUp failed for volume "nfs-vol" : mount failed: exit status 32
Mounting command: mount
... mount.nfs: ... package nfs-common is missing
```

本环境目前只在 worker 跑 Pod，worker 已装即可；但 master 也建议装上（第二章已让两边都装）。

### 5.3 NFS 版本 v3 / v4

- Ubuntu 24.04 的 `nfs-kernel-server` 同时支持 v3 / v4 / v4.1 / v4.2。
- **推荐用 NFSv4.1**（本方案 `mountOptions: nfsvers=4.1`）：只要 2049 端口，防火墙配置简单，性能也更好。
- 如果你遇到挂载卡住或 `mount.nfs: access denied`，可临时去掉 `nfsvers=4.1` 让它自动协商，或显式 `nfsvers=3` 排查是不是 v4 的 idmap 问题。

### 5.4 AccessModes 与共享语义

- `ReadWriteMany`（RWX）：多 Pod 同时读写。**NFS 的卖点**，本方案用它。
- `ReadWriteOnce`（RWO）：只能被一个节点挂载。NFS 也能声明 RWO，但通常没必要。
- 注意：**PV 和 PVC 的 accessModes 必须一致才能绑定**，否则 PVC 一直 `Pending`。

### 5.5 mountOptions 调优

本方案用了 `hard,timeo=600,retrans=2,nfsvers=4.1`：

- `hard`：server 不可达时挂起等待，恢复后继续，**避免静默丢数据**。生产必用。
- `soft`：超时直接报错返回——快但可能丢数据，一般不推荐给写场景。
- `timeo=600`：超时 60 秒（单位 0.1 秒）。
- `retrans=2`：重传 2 次。
- 想提高吞吐可加 `rsize=1048576,wsize=1048576`（读写块大小，1MB，v4 默认上限）。

> 注意 k8s 里 `mountOptions` 写在 **PV 的 spec**（或 StorageClass）里才生效，写在 PVC 里无效。

### 5.6 reclaimPolicy 与数据保留

- `Retain`（本方案）：删 PVC 后，PV 变 `Released`，**数据保留在磁盘上**，但 PV 不会自动重新绑定，需手工清理 `claimRef` 才能复用。
- `Delete`：删 PVC 时自动删后端（静态 NFS PV 不支持真正删除目录，需动态 provisioner 配合）。

学习环境用 `Retain` 最安全——删错了 PVC 数据还在。

### 5.7 单点故障：worker 既是计算节点又是 NFS Server

把 NFS Server 放在 worker 上，意味着 **worker 一旦宕机，所有依赖该存储的 Pod 全部不可用**（计算和数据一起挂）。

- 学习环境：完全没问题，知道这个前提即可。
- 生产环境：NFS Server 应该是**独立于 k8s 节点的专用存储服务器**，避免计算与存储耦合，并做 RAID/冗余。

### 5.8 磁盘容量与监控

**NFS 不会按 PV 的 `capacity` 真正限制空间**——`80Gi` 只是个声明，实际能写多少取决于 worker 磁盘真实剩余空间（150G 里还剩多少）。所以：

```shell
# 定期在 worker 上看真实占用
df -h /data
du -sh /data/pipeline/shared-data/*
```

如果担心某个 Pod 把磁盘写爆，可以在 NFS 上层用 `quota`，或限制 Pod 写入逻辑，NFS 本身不直接做 per-PVC 配额。

### 5.9 安全：限制导出网段、no_root_squash 的风险

- 导出范围尽量收窄（本方案用 `192.168.10.0/24` 而非 `*`）。
- `no_root_squash` 让客户端 root = 服务端 root，内网学习可接受，公网/多用户机器绝不要用。
- 更安全的写法（假设应用以 uid=1000 运行）：
  ```
  /data/pipeline/shared-data 192.168.10.0/24(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)
  ```
  然后 `chown -R 1000:1000 /data/pipeline/shared-data`。

### 5.10 开机自启与持久化

- NFS Server：已用 `systemctl enable nfs-server rpcbind`，重启自动起来。
- **导出配置**：写在 `/etc/exports` 里，重启后自动生效（不要只 `exportfs` 不改文件）。
- k8s 端的 PV/PVC：存在 etcd 里，master 重启不丢。

### 5.11 备份

`/data/pipeline/shared-data` 里的数据，定期备份。最简单：

```shell
# 在 worker 上打包备份到另一路径或外部存储
sudo tar -czf /backup/shared-data-$(date +%F).tar.gz -C /data/pipeline shared-data
```

重要数据建议再 rsync 到 Mac 本地或 NAS，避免虚拟机损坏导致数据丢失。

### 5.12 AppArmor（Ubuntu 默认安全模块）

Ubuntu 24.04 默认开启 AppArmor，一般不影响 NFS 挂载。如果遇到奇怪的挂载失败且排除了网络/权限问题，可以 `dmesg | grep -i apparmor` 看看是不是被拦了（学习环境基本不会遇到）。

---

## 六、常见问题排查

| 现象 | 可能原因 | 排查/解决 |
| --- | --- | --- |
| Pod 卡 `ContainerCreating`，事件报 `mount.nfs: access denied` | 导出网段不含该节点 IP，或 `root_squash` 拦了 | `exportfs -v` 检查网段；按 5.1 处理权限 |
| Pod 报 `package nfs-common is missing` | 节点没装客户端 | 在该节点 `apt install nfs-common`（见 5.2） |
| 写文件 `Permission denied` | squash 把 root 映射成 nobody | 用 `no_root_squash` 或 `chmod`/`anonuid`（见 5.1） |
| `showmount -e` 卡住/超时 | 防火墙或 rpcbind 没起 | `systemctl status rpcbind`；放行 111/2049（见 1.6） |
| PVC 一直 `Pending` | accessModes 不匹配、capacity 超过 PV、storageClassName 写错 | `kubectl get pv`、`kubectl describe pvc` 看事件 |
| 挂载后文件属主显示 `nobody`/`4294967294` | NFSv4 idmap 问题 | 临时用 `nfsvers=3`，或配置 `/etc/idmapd.conf` 的 Domain |
| `Stale file handle` | server 端目录被删/重建，旧的挂载句柄失效 | 客户端 `umount` 后重新 `mount`，或重启 Pod |

常用排查命令速查：

```shell
# 看 Pod 为什么起不来
kubectl describe pod <pod-name>
kubectl get events --sort-by=.metadata.creationTimestamp

# 看 PV/PVC 绑定状态
kubectl get pv,pvc

# 在节点上手动复现挂载（绕过 k8s，定位是 NFS 问题还是 k8s 问题）
sudo mount -t nfs -v -o nfsvers=4.1 192.168.10.131:/data/pipeline/shared-data /mnt/nfs-test
```

---

## 清理（如需回退）

```shell
kubectl delete -f pvc/nfs-reader.yaml
kubectl delete -f pvc/nfs-writer.yaml
kubectl delete -f pvc/nfs-pvc.yaml
kubectl delete -f pvc/nfs-pv.yaml
# 动态供给相关
kubectl delete -f pvc/nfs-dynamic-pvc.yaml
kubectl delete -f pvc/nfs-provisioner.yaml
```

PV 用了 `Retain`，删 PVC 后数据还在 `/data/pipeline/shared-data/`，需要的话手工清理。

## 参考资料

- [k8s环境搭建](../../环境搭建/k8s/v1.23.3.md)
- [docker安装](../../环境搭建/docker/docker_v28.2.2.md)
- [镜像加速](../../环境搭建/镜像加速.md)
- NFS 官方手册：https://help.ubuntu.com/community/SettingUpNFSHowTo
- k8s NFS PV 文档：https://kubernetes.io/docs/concepts/storage/volumes/#nfs
- nfs-subdir-external-provisioner：https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner
