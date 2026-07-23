# 部署 Ankole

[English](README.md)

本目录提供开源版 Ankole 的自托管部署文件。

| 部署目标 | 文件 | 数据库 |
| --- | --- | --- |
| Kubernetes | [Helm Chart](helm/ankole-agent/README.zh-Hans.md) | 内置 PostgreSQL 或外部 PostgreSQL |
| 单台 Linux 主机 | [Docker Compose](docker-compose/README.zh-Hans.md) | 内置 PostgreSQL |

两种部署都运行同一条生产路径：

- Phoenix/OTP 控制面负责持久化状态和运维 Console；
- PostgreSQL 18 保存持久化状态，并提供 `pg_search` 和 `vector`；
- 一个或多个 Agent Computer Worker 执行 Agent Turn；
- `/agents` 保存 Agent Home 文件；
- RuntimeFabric 通过私有网络连接控制面和 Worker。

默认配置从 GitHub Container Registry 拉取 `main-latest` 镜像。
RuntimeFabric 工作流验证控制面与 Worker 镜像配对成功后，才会发布这两个
tag。tag 会移动。受控生产发布应把两个 Ankole 镜像同时固定到同一组已验证
镜像的 digest。

Agent Computer 需要 `SYS_ADMIN` 和不受限的 seccomp profile，才能使用强
bubblewrap 隔离。因此 Worker 是受信任的第一方计算服务。不要把无关容器放进
Worker 的安全边界。

有 Kubernetes 和 `ReadWriteMany` 存储时使用 Helm。单机生产部署使用 Docker
Compose 和本地 named volume。
