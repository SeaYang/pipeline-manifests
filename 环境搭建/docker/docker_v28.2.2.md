# docker安装

linux环境下一般直接执行：sudo apt install docker.io，即可安装docker，但是这个默认安装的是比较新的版本，会和k8s 1.23.3版本下的kubelet不兼容，需要额外做一些适配，为了避免适配带来的不方便，本文直接指定安装docker的28.2.2版本，步骤如下

1、安装必要的依赖工具

```shell
sudo apt-get install -y ca-certificates curl gnupg lsb-release
```

2、添加阿里云的 Docker GPG 密钥

```shell
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
```

3、添加阿里云的 Docker CE 软件源

```shell
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

4、更新软件包列表并查看可用版本

```shell
sudo apt-get update
apt-cache madison docker-ce | grep 28.2.2 # 这里目标是安装28.2.2版本
```

5、进行安装

```shell
# 这里请替换为上面查到的真实版本号
VERSION_STRING="5:28.2.2-1~ubuntu.24.04~noble"
sudo apt-get install -y docker-ce=$VERSION_STRING docker-ce-cli=$VERSION_STRING containerd.io docker-buildx-plugin docker-compose-plugin
```

6、锁定 Docker 的版本

```shell
sudo apt-mark hold docker-ce docker-ce-cli containerd.io
```

7、启动docker

```shell
# sudo apt install docker.io #安装Docker Engine
sudo service docker start #启动docker服务
sudo usermod -aG docker ${USER} #当前用户加入docker组
```

新开一个shell终端，验证docker安装是否成功

```shell
root@k8s-master:/home/seayang# docker version
Client: Docker Engine - Community
 Version:           28.2.2
 API version:       1.50
 Go version:        go1.24.3
 Git commit:        e6534b4
 Built:             Fri May 30 12:07:29 2025
 OS/Arch:           linux/arm64
 Context:           default

Server: Docker Engine - Community
 Engine:
  Version:          28.2.2
  API version:      1.50 (minimum version 1.24)
  Go version:       go1.24.3
  Git commit:       45873be
  Built:            Fri May 30 12:07:29 2025
  OS/Arch:          linux/arm64
  Experimental:     false
 containerd:
  Version:          v2.2.3
  GitCommit:        77c84241c7cbdd9b4eca2591793e3d4f4317c590
 runc:
  Version:          1.3.5
  GitCommit:        v1.3.5-0-g488fc13e
 docker-init:
  Version:          0.19.0
  GitCommit:        de40ad0
```

### docker配置修改

把 cgroup 的驱动程序改成 systemd，然后重启docker

```shell
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

sudo systemctl enable docker
sudo systemctl daemon-reload
sudo systemctl restart docker
```