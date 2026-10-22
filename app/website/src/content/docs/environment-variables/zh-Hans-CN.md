---
title: 部署环境变量
description: 查阅控制面和 Agent Computer Worker 在进程启动时读取的部署配置。
section: Reference
order: 202
---

本页列出 PostgreSQL、部署密钥、文件存储与进程设置的启动变量。Worker provider 的设置以 YAML 保存在 PostgreSQL 中。

可以在实例运行期间修改的运行时设置见 [系统配置](../app-configuration/)。不要把这些运行时设置写入 `.env` 或 Kubernetes Secret。

## 引导与 secret（进程启动）

这些必须在控制面启动前存在。Docker Compose 放 `.env`，Helm 放 chart 读取的 Secret。

| 变量 | 必需 | 含义 |
|---|---|---|
| `DATABASE_URL` | 是 | 控制面所用的 PostgreSQL 连接串 |
| `ANKOLE_SECRET_BASE` | 是 | 实例级 Secret Base，用于派生其他密钥 |
| `RELEASE_COOKIE` | 是 | Erlang distribution cookie；同一部署的每个控制面节点使用同一个值 |
| `POSTGRES_PASSWORD` | 仅内置 PostgreSQL | PostgreSQL 密码（启用内置 PostgreSQL 时必需；外部则由外部 Secret 提供） |
| `ANKOLE_HOST` | Compose | 部署所服务的 DNS 名 |
| `ACME_EMAIL` | Compose | Caddy 用于 Let's Encrypt 的邮箱 |
| `ANKOLE_DOCKER_GID` | Compose | Docker socket 所属组的 ID；控制面以非特权用户运行，通过这个组访问 socket |

这些值应放在 `.env` 或 Secret 中，绝不能提交到版本控制。Docker Compose 的 `.env.example` 是配置起点。

Worker 不需要在 `.env` 或 Secret 中配置 key：控制面会为每个 Worker 发放它自己的凭据。

Helm chart 的 `values.yaml` 列出了 Kubernetes 中对应的 `ankoleSecretBase`、`releaseCookie`、`databaseURL` 和 `postgresqlPassword`。

## 运行时调优（进程环境）

启动时读取，调优一个运行中的进程。它们不是 secret。

| 变量 | 默认 | 含义 |
|---|---|---|
| `ANKOLE_ENV` | — | 部署环境标签（如 `prod`、`dev`） |
| `ANKOLE_LOG_LEVEL` | `info` | 日志级别（`debug`、`info`、`warning`、`error`） |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | 控制面数据库连接池大小 |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | `300` | 内置 PostgreSQL 服务器的 `max_connections` |
| `ANKOLE_LIBRARY_ROOT` | chart 默认 | 自带 Agent Library 的路径（`app/library`） |
| `ANKOLE_INTERNAL_SKILLS_ROOT` | — | 内部 skill bundle 的路径 |
| `ANKOLE_AI_GATEWAY_BASE_URL` | — | 覆盖 AIGateway 基 URL（很少需要） |

## 文件存储（进程启动）

控制面把每个 Agent 的云盘放在文件存储中：附件、生成的图片、发出的文件、已安装的 Skill、Automation Job 脚本，以及 Agent 保存的文件。Worker 从不持有存储凭据；文件字节经控制面中转。

| 变量 | 必填 | 含义 |
|---|---|---|
| `ANKOLE_FILES_STORE` | 是 | `fs` 表示控制面持久卷上的一个目录，`s3` 表示 Amazon S3 或 Cloudflare R2 等 S3 兼容存储 |
| `ANKOLE_FILES_FS_ROOT` | `fs` | 存储目录的绝对路径；Docker Compose 使用挂载在 `/var/lib/ankole/files` 的 `files_data` 卷 |
| `ANKOLE_FILES_S3_BUCKET` | `s3` | 桶 |
| `ANKOLE_FILES_S3_REGION` | `s3` | 区域；Cloudflare R2 使用 `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | 否 | S3 兼容存储的端点 |
| `ANKOLE_FILES_S3_ROOT` | 否 | 桶内的键前缀 |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID`、`ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | 否 | 静态凭据；不设置时使用默认 AWS 凭据链，包括 EKS Pod Identity |

`fs` 存储只允许一个控制面副本。运行多个控制面副本时使用 `s3`。

`s3` 上的大文件以分段上传（multipart upload）写入。如果控制面在上传中途停止，已上传的分段会留在存储桶里，所以请给存储桶配置一条中止未完成分段上传的生命周期规则。

## Worker Provider 引导配置

以下启动值标识部署与目标 Worker 镜像。每个 provider 在 **Console → 工作节点 → Providers** 中用 YAML 配置，凭据另行加密保存。类型、位置与持久存储创建后不能修改；实例设置在 Agent 空闲时生效。

| 变量 | 含义 |
|---|---|
| `ANKOLE_AGENT_COMPUTER_IMAGE` | 控制面版本对应的目标 Worker 镜像 |
| `ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT` | 默认 RuntimeFabric WebSocket 地址 |
| `ANKOLE_WORKER_INSTALLATION` | 部署标签，默认 `ankole` |
| `ANKOLE_WORKER_PROVIDERS_FILE` | 可选的 provider 种子 YAML 文件；首次导入与旧 Agent 指派在同一事务内 |

`bun dev` 的源码与内部 Skill 挂载来自 `config/dev.exs`，发布版本没有这些开发挂载。

## 模型提供商出站代理

模型提供商流量必须经过出站代理时，在控制面进程上设置这些标准环境变量。
`https_proxy` 等小写形式同样有效。

| 变量 | 含义 |
|---|---|
| `HTTPS_PROXY` | HTTPS 和安全 WebSocket（`wss`）模型请求使用的代理 |
| `HTTP_PROXY` | HTTP 和 WebSocket（`ws`）模型请求使用的代理；未设置 `HTTPS_PROXY` 和 `ALL_PROXY` 时，安全请求也会使用它 |
| `ALL_PROXY` | 未设置协议专用变量时，模型请求使用的后备代理 |
| `NO_PROXY` | 必须直连的主机或域名后缀，以英文逗号分隔 |

代理 URL 支持 `http`、`https`、`socks5` 和 `socks5h`；代理需要认证时，
URL 可以包含凭证。`NO_PROXY` 的优先级最高。安全请求依次使用
`HTTPS_PROXY`、`ALL_PROXY`、`HTTP_PROXY`；普通请求依次使用
`HTTP_PROXY`、`ALL_PROXY`。修改这些变量后必须重启控制面。

## 仅 worker 的环境（Agent Computer Worker）

控制面创建 Worker 时设置这些变量，不由运维者设置。Worker 从 `WORKER_ID` 得知自己的 Agent；会话和回合通过每个 `turn_start` 到达，不在环境里。

| 变量 | 含义 |
|---|---|
| `WORKER_ID` | Agent UID；Worker 只为这个 Agent 服务 |
| `ANKOLE_RUNTIME_FABRIC_ENDPOINT` | Worker 连接的 `ws://` 或 `wss://` RuntimeFabric URL |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | 本代随机凭据；控制面保存摘要和加密的重试值 |
| `ANKOLE_WORKER_STORAGE` | 由 provider 设置的存储准备模式 |

Worker 环境变量在 provider YAML 的 `env` 或 Kubernetes `podTemplate` 中设置。`ANKOLE_MAX_CONCURRENT_SLOTS` 限制单个 Worker 的环境工作区和 Codex 回合，默认值为 12。模型回合不占 Worker 槽位。修改实例设置后，在空闲时替换 Worker。

Worker 镜像负责设置浏览器和 Skill 路径，包括 `ANKOLE_BROWSER_*` 和 `ANKOLE_BUILTIN_SKILLS_ROOT`。这些路径不能由管理员调整。

`PATH`、`HOME`、`DATABASE_URL` 与 `ANKOLE_` 前缀在 Agent 环境变量编辑器中保留；这个限制不禁止 provider YAML 支持的实例设置。参见[环境变量](../worker-env/)。

## 修改部署环境变量

在 Compose `.env` 或 Helm values 中修改启动变量后，重启对应进程。provider 设置在 Console 中修改；已导入的种子文件不会覆盖现有 provider。镜像或实例设置变化后，在 Agent 空闲时替换 Worker。

## 下一步

- Agent 使用的自定义变量，读 [环境变量](../worker-env/)。
- 运行期间可调整的设置和完整 AppConfigure 键清单，读 [系统配置](../app-configuration/)。
- 部署变量在上下文中的位置，读 [快速开始的部署部分](../quickstart/#deployment)。
