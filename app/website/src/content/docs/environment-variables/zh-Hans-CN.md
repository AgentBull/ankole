---
title: 部署环境变量
description: 查阅控制面和 Agent Computer Worker 在进程启动时读取的部署配置。
section: Reference
order: 202
---

本页汇总了控制面及相关组件在进程启动时读取的环境变量，涵盖 PostgreSQL 主库、Pod Base 分片数据库、`ankole-function-runtime`、部署密钥、对象存储与进程运行参数。WorkerProvider 的详细配置以 YAML 格式保存在 PostgreSQL 中，不在环境变量里声明。

支持在实例运行期间动态调整的设置见 [系统配置](../app-configuration/)；请勿将这些运行时设置写入 `.env` 或 Kubernetes Secret。

## 引导配置与部署密钥（进程启动）

以下变量必须在控制面启动前准备就绪：使用 Docker Compose 部署时写入 `.env`，使用 Helm 部署时存入 Chart 读取的 Secret。

| 变量 | 必需 | 含义 |
|---|---|---|
| `DATABASE_URL` | 是（`prod`） | 控制面（`Ankole.Repo`）使用的 PostgreSQL 18+ 连接串 |
| `BASE_DB_URLS` | 否 | 可选的分号（`;`）分隔 PostgreSQL 18+ 连接串列表，用于物理 Pod Base 分片库（`Ankole.Pod.BaseRepo`），支持查询参数 `ankole_sharding`、`ankole_pool_size`、`ankole_stock_only`；FOSS 单库部署未设置该变量时，默认将 `DATABASE_URL` 作为 `base_default` 使用；拒绝携带 `sslmode` 参数 |
| `ANKOLE_SECRET_BASE` | 是（`prod`） | 站点级主密钥（Secret Base），用于派生数据加密与签名密钥 |
| `RELEASE_COOKIE` | 是（`prod`） | Erlang 分布式节点通信 Cookie；同一部署实例下的所有控制面节点必须使用相同的值 |
| `ANKOLE_FUNCTION_RUNTIME_TOKEN` | 是（`prod`） | 控制面与 `ankole-function-runtime` 之间共享的内部 Bearer 认证密钥 |
| `ANKOLE_FUNCTION_RUNTIME_URL` | 是（`prod`） | `ankole-function-runtime` 的内部访问地址（例如 Compose 中的 `http://function-runtime:9000` 或 Kubernetes Headless Service 地址） |
| `POSTGRES_PASSWORD` | 仅内置 PostgreSQL | PostgreSQL 数据库密码（启用内置 PostgreSQL 时必填；使用外部数据库时则通过 `DATABASE_URL` 或外部 Secret 提供） |
| `ANKOLE_HOST` | Compose | 部署实例对外提供服务的公开 DNS 域名 |
| `ACME_EMAIL` | Compose | Caddy 申请与续期 Let's Encrypt 证书所用的联系邮箱 |
| `ANKOLE_DOCKER_GID` | Compose | 宿主机 Docker Socket 所属的用户组 ID；控制面以非特权用户运行，通过该用户组权限访问 Socket |

以上配置包含敏感密钥，应妥善存放在 `.env` 或 Kubernetes Secret 中，切勿提交到版本控制系统。使用 Docker Compose 部署时，可复制 `.env.example` 作为配置起点。

无需在 `.env` 或 Secret 中为 Worker 预先配置认证密钥——控制面在创建每个 Worker 时会自动签发专属凭据。

在 Helm Chart 的 `values.yaml` 中，对应的配置键路径分别为：`secrets.ankoleSecretBase`、`secrets.releaseCookie`、`secrets.functionRuntimeToken`、`secrets.databaseURL`、`secrets.baseDBURLs`、`secrets.postgresqlPassword`、`controlPlane.siteAdminConsolePath` 以及 `functionRuntime.*`。

## 运行时调优（进程环境）

以下变量在进程启动时读取，用于调整控制面或 `ankole-function-runtime` 进程的运行参数，本身不包含敏感密钥。

| 变量 | 默认 | 含义 |
|---|---|---|
| `ANKOLE_ENV` | — | 部署环境标识（如 `prod`、`dev`） |
| `ANKOLE_LOG_LEVEL` | `info` | 日志输出级别（`debug`、`info`、`warning`、`error`） |
| `POOL_SIZE` | `10` | 控制面进程直接读取的 `Ankole.Repo` 数据库连接池大小 |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | Docker Compose `.env` 中的连接池变量，由 `compose.yaml` 映射为控制面容器内的 `POOL_SIZE` |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | `300` | 内置 PostgreSQL 数据库的 `max_connections` 上限 |
| `ANKOLE_SITE_ADMIN_CONSOLE_PATH` | `/site-admin-console` | 站点管理台（Site Admin Console）的 URL 访问路径 |
| `ANKOLE_FUNCTION_RUNTIME_IMAGE` | 发布默认镜像 | Docker Compose 部署中使用的 `ankole-function-runtime` 容器镜像 |
| `ANKOLE_FUNCTION_RUNTIME_MAX_CONCURRENCY` | `32` | 单个 `ankole-function-runtime` 容器允许的最大并发执行数 |
| `ANKOLE_LIBRARY_ROOT` | Chart 默认值 | 内置 Agent Library 的目录路径（`app/library`） |
| `ANKOLE_INTERNAL_SKILLS_ROOT` | — | 内部 Skill 包的目录路径 |
| `ANKOLE_AI_GATEWAY_BASE_URL` | — | 覆盖 AIGateway 的基础 URL |

## 文件存储（进程启动）

控制面对象存储（`Ankole.ObjectStore`）通过 `ANKOLE_FILES_STORE` 配置，统一承载每个 Agent 的云盘（包括收到的附件、生成的图片、发出的文件、已安装的 Skill、Automation Job 脚本及保存的文件），以及 Pod `file` 页面、Pod 文档/Base/Chat 附件与已编译的 Applet 产物包。Worker 从不持有底层存储凭据，所有文件字节均经由控制面中转。完整的 OpenDAL 后端支持列表见[控制面云盘与对象存储配置](../drive-storage/)。

| 变量 | 必填 | 含义 |
|---|---|---|
| `ANKOLE_FILES_STORE` | 是 | `fs` 表示使用控制面持久卷上的本地目录；`s3` 表示使用 Amazon S3 或 Cloudflare R2 等 S3 兼容存储 |
| `ANKOLE_FILES_FS_ROOT` | `fs` | 本地存储目录的绝对路径；Docker Compose 默认使用挂载在 `/var/lib/ankole/files` 的 `files_data` 卷 |
| `ANKOLE_FILES_S3_BUCKET` | `s3` | S3 存储桶名称 |
| `ANKOLE_FILES_S3_REGION` | `s3` | 存储桶所在区域；Cloudflare R2 填写 `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | 否 | S3 兼容存储服务的端点地址 |
| `ANKOLE_FILES_S3_ROOT` | 否 | 存储桶内的对象键前缀 |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID`、`ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | 否 | 静态访问凭据；留空时默认走 AWS 凭据链（包括 EKS Pod Identity） |

使用 `fs` 本地存储时，控制面仅支持单副本运行；若需运行多个控制面副本，请改用 `s3` 等远程共享存储。

向 `s3` 写入大文件时采用分段上传（Multipart Upload）。若控制面在上传中途停止，已上传的分段会残留在存储桶里，因此请为存储桶配置自动中止未完成分段上传的生命周期规则。

## Worker Provider 引导配置

以下启动变量用于标识当前部署实例与目标 Worker 镜像。每个 WorkerProvider 的具体参数在 **Console → 工作节点 → Providers** 中以 YAML 配置，凭据单独加密存储。WorkerProvider 创建后，其类型、运行位置与持久存储设置不可更改；实例规格等运行参数修改后，会在 Agent 空闲时生效。

| 变量 | 含义 |
|---|---|
| `ANKOLE_AGENT_COMPUTER_IMAGE` | 与当前控制面版本配套的目标 Worker 镜像 |
| `ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT` | 默认的 RuntimeFabric WebSocket 地址 |
| `ANKOLE_WORKER_INSTALLATION` | 部署实例标识，默认为 `ankole` |
| `ANKOLE_WORKER_PROVIDERS_FILE` | 可选的 WorkerProvider 种子 YAML 文件路径；首次导入时会与存量 Agent 的提供商指派在同一事务内完成 |

本地运行 `bun dev` 时，源码与内部 Skill 目录挂载由 `config/dev.exs` 配置，正式发布版本不包含这些开发期挂载。

## 模型提供商出站代理

当访问模型提供商的流量必须经过出站代理时，可在控制面进程上设置以下标准环境变量（`https_proxy` 等小写形式同样有效）。

| 变量 | 含义 |
|---|---|
| `HTTPS_PROXY` | HTTPS 和加密 WebSocket（`wss`）模型请求使用的代理 |
| `HTTP_PROXY` | HTTP 和明文 WebSocket（`ws`）模型请求使用的代理；未设置 `HTTPS_PROXY` 和 `ALL_PROXY` 时，加密请求也会回退使用该代理 |
| `ALL_PROXY` | 未设置协议专用代理变量时，模型请求使用的兜底代理 |
| `NO_PROXY` | 必须直连的目标主机或域名后缀，多项之间以英文逗号分隔 |

代理地址支持 `http`、`https`、`socks5` 和 `socks5h` 协议；若代理要求认证，可直接在 URL 中包含凭据。匹配优先级上，`NO_PROXY` 最高；加密请求依次读取 `HTTPS_PROXY`、`ALL_PROXY`、`HTTP_PROXY`；明文请求依次读取 `HTTP_PROXY`、`ALL_PROXY`。修改代理变量后必须重启控制面。

## Worker 专属环境变量（Agent Computer Worker）

以下变量由控制面在创建 Worker 实例时自动注入，无需运维人员手动设置。Worker 启动后根据 `WORKER_ID` 识别所属 Agent；具体的会话与回合信息随每次 `turn_start` 消息下发，不通过环境变量传递。

| 变量 | 含义 |
|---|---|
| `WORKER_ID` | 目标 Agent 的 UID；该 Worker 实例仅服务于这一个 Agent |
| `ANKOLE_RUNTIME_FABRIC_ENDPOINT` | Worker 回连控制面所使用的 `ws://` 或 `wss://` RuntimeFabric 地址 |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | 当前实例代次（generation）专用的随机认证凭据；控制面仅保存其摘要及加密后的重试值 |
| `ANKOLE_WORKER_STORAGE` | 由所属 WorkerProvider 设定的存储准备模式 |

如需为 Worker 注入通用环境变量，可在 WorkerProvider YAML 的 `env` 字段或 Kubernetes `podTemplate` 中设置。其中 `ANKOLE_MAX_CONCURRENT_SLOTS` 用于限制单个 Worker 并发运行的环境工作区与 Codex 回合数，默认值为 12；普通模型推理回合不占用该槽位。修改实例设置后，控制面会在 Agent 空闲时替换 Worker。

浏览器与内置 Skill 的路径（包括 `ANKOLE_BROWSER_*` 和 `ANKOLE_BUILTIN_SKILLS_ROOT`）由 Worker 镜像内置设定，不支持管理员手动调整。

在 Agent 环境变量编辑器中，`PATH`、`HOME`、`DATABASE_URL` 与 `ANKOLE_` 前缀均受系统保留保护；这一限制并不影响在 WorkerProvider YAML 中配置受支持的实例参数。详见[环境变量](../worker-env/)。

## 修改部署环境变量

在 Docker Compose 的 `.env` 或 Helm 的 `values` 文件中修改启动变量后，需重启对应进程使其生效。WorkerProvider 的设置请在 Console 中直接修改——已导入过的种子文件不会覆盖现有记录。每当镜像或实例配置发生变化，控制面都会在 Agent 空闲时替换对应的 Worker。

## 下一步

- 为单个 Agent 配置自定义变量，请参阅 [环境变量](../worker-env/)。
- 查阅运行期间可动态调整的设置及完整 AppConfigure 配置键清单，请参阅 [系统配置](../app-configuration/)。
- 了解这些部署变量在完整安装流程中的位置，请参阅 [快速开始的部署部分](../quickstart/#deployment)。
