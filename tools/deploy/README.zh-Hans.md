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
- 控制面的文件服务保存每个 Agent 的云盘，放在本地 volume 或 S3 兼容存储中；
- 控制面为每个需要 Worker 的 Agent 创建一个 Agent Computer Worker 容器，
  Agent Home 与缓存分开，实例删除后保留 Agent Home；
- RuntimeFabric 通过私有网络连接控制面和 Worker。

默认配置从 GitHub Container Registry 拉取 `main-latest` 镜像。
RuntimeFabric 工作流验证控制面与 Worker 镜像配对成功后，才会发布这两个
tag。tag 会移动。受控生产发布应把 Ankole 镜像固定到同一组已验证镜像的
digest。

Worker 容器是一个 Agent 的电脑，也是它唯一的隔离边界：它不需要额外的内核
权限，Agent 之间不共用 Worker。控制面需要创建 Worker 容器的权限：Compose
用 Docker socket，Kubernetes 用命名空间内的 Role。

有 Kubernetes 时使用 Helm。单机生产部署使用 Docker Compose 和本地 named
volume。

Worker 也可以经 [Cloudflare 适配器](cloudflare/agent-workers/README.zh-Hans.md)
运行在 Cloudflare Containers 上。Helm Chart 可以把 Cloudflare provider 写入种子，
Compose 默认提供 Docker provider 种子。首次导入后，在 Console 增加 provider，
创建 Agent 时选择。Cloudflare provider 的端点使用能从 Cloudflare 访问的公网地址。
