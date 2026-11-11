# 部署 Ankole

[English](README.md)

本目录提供开源版 Ankole 的自托管部署配置。

| 部署目标 | 部署文件 | 数据库 |
| --- | --- | --- |
| Kubernetes | [Helm Chart](helm/ankole-agent/README.zh-Hans.md) | 内置 PostgreSQL 或外部 PostgreSQL 服务 |
| 单台 Linux 主机 | [Docker Compose](docker-compose/README.zh-Hans.md) | 内置 PostgreSQL |

两种部署方案运行同一套生产架构：

- Phoenix/OTP 控制面维护持久化状态，对外提供 Pod 工作空间与运维控制台（Console）；
- PostgreSQL 18 承载控制面持久化数据并提供 `pg_search` 与 `vector` 扩展，同时通过主库的租户 Schema 或 `BASE_DB_URLS` 配置的独立 PostgreSQL 分片库存放物理 Base 数据表；
- 统一云盘（Drive）存储将 Pod 文件、Applet 产物包与云盘对象保存在本地存储卷或 S3 兼容等远程对象存储中；
- 函数运行时（`ankole-function-runtime`）在不接触数据库凭据的前提下，运行无状态 Applet 后端路由、已发布的 Applet Action 以及确定性 `PTC` 与 `Workflow` 程序；
- 控制面按需为每个 Agent 创建独立的 Agent Computer Worker 容器，其中持久化 Agent Home 与可重建缓存分开存放，删除容器实例后仍保留 Agent Home；
- RuntimeFabric 在私有网络中连接控制面与各 Worker。

默认配置将控制面与 Function Runtime 镜像固定为预发布版 `2.0.0-alpha.24`。控制面镜像内置配套的 Worker 镜像引用，PostgreSQL 则通过镜像摘要（digest）固定。部署时请确保配置文件与镜像来自同一发布版本：`main-latest` 跟踪正式版及候选发布版，`canary` 跟踪 alpha 与 beta 预发布版，因此浮动标签指向的版本可能早于 `main` 分支上的部署文件。

每个 Worker 容器是单个 Agent 专属的运行环境，也是其唯一的隔离边界，不同 Agent 之间绝不共用 Worker。启用 `/drive` FUSE 挂载时（Docker 下配置 `/dev/fuse` 与 `SYS_ADMIN`，Kubernetes 下配置 `smarter-devices/fuse` 与 `SYS_ADMIN` 并由 Chart 的 `ValidatingAdmissionPolicy` 严格约束），仅容器内的 `root` 监管进程在私有挂载命名空间内持有挂载权限，随后会将业务子进程（`uid 1000`）降权至空的 Linux 能力集（capability set）。为按需创建和销毁这些容器，控制面需要具备容器编排权限——在 Docker Compose 下挂载 Docker 套接字（socket），在 Kubernetes 下绑定命名空间内的 `Role`。

若有 Kubernetes 集群，请优先使用 Helm 部署；若在单台生产主机上结合本地命名卷部署，请使用 Docker Compose。

Worker 也可通过 [Cloudflare 适配器](cloudflare/agent-workers/README.zh-Hans.md)运行在 Cloudflare Containers 上。Docker Compose 默认预置本地 Docker 运行方（Worker Provider）种子，Helm Chart 则可直接预置 Cloudflare 运行方种子；首次导入完成后，还可在控制台新增其他运行方，并在创建 Agent 时按需选用。配置 Cloudflare 运行方时，各端点必须填写可从 Cloudflare 公网访问的地址。
