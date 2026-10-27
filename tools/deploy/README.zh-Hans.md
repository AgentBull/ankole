# 部署 Ankole

[English](README.md)

本目录提供开源版 Ankole 的自托管部署配置。

| 部署目标 | 部署文件 | 数据库 |
| --- | --- | --- |
| Kubernetes | [Helm Chart](helm/ankole-agent/README.zh-Hans.md) | 内置 PostgreSQL 或外部 PostgreSQL 服务 |
| 单台 Linux 主机 | [Docker Compose](docker-compose/README.zh-Hans.md) | 内置 PostgreSQL |

两种部署方案运行同一套生产架构：

- Phoenix/OTP 控制面负责维护持久化状态并提供运维控制台（Console）；
- PostgreSQL 18 承载持久化数据，并提供 `pg_search` 与 `vector` 扩展；
- 控制面文件服务将每个 Agent 的云盘保存在本地卷或 S3 兼容对象存储中；
- 控制面按需为每个 Agent 创建独立的 Agent Computer Worker 容器，其中 Agent Home 与可重建缓存分开存放，删除容器实例后仍保留 Agent Home；
- RuntimeFabric 在私有网络中连接控制面与各 Worker。

默认配置固定使用预发布版控制面 `2.0.0-alpha.24`（控制面镜像内置配套的 Worker 镜像引用）以及固定的 PostgreSQL 镜像摘要（digest）。部署时请确保配置文件与镜像来自同一发布版本：`main-latest` 跟踪正式版及候选发布版，`canary` 跟踪 alpha 与 beta 预发布版，因此浮动标签指向的版本可能早于 `main` 分支上的部署文件。

每个 Worker 容器是单个 Agent 专属的运行环境，也是其唯一的隔离边界：容器无需额外内核特权，且不同 Agent 之间绝不共用 Worker。为按需拉起这些容器，控制面需要具备创建容器的权限——在 Docker Compose 下挂载 Docker 套接字（socket），在 Kubernetes 下绑定命名空间内的 `Role`。

若有 Kubernetes 集群，请优先使用 Helm 部署；若在单台生产主机上结合本地命名卷部署，请使用 Docker Compose。

Worker 也可通过 [Cloudflare 适配器](cloudflare/agent-workers/README.zh-Hans.md)运行在 Cloudflare Containers 上。Docker Compose 默认预置本地 Docker 运行方（Worker Provider）种子，Helm Chart 则可直接预置 Cloudflare 运行方种子；首次导入完成后，还可在控制台新增其他运行方，并在创建 Agent 时按需选用。配置 Cloudflare 运行方时，各端点必须填写可从 Cloudflare 公网访问的地址。
