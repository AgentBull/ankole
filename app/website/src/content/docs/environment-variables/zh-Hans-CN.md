---
title: 部署环境变量
description: 查阅控制面和 Agent Computer Worker 在进程启动时读取的部署配置。
section: Reference
order: 202
---

本页只列进程启动时读取的部署环境变量。它们用于连接 PostgreSQL、建立实例密钥、启动 RuntimeFabric，以及调整控制面和 Worker 进程。

可以在实例运行期间修改的 AppConfigure 键已经迁入[系统配置](../app-configuration/)。不要把这些运行时设置写入 `.env` 或 Kubernetes Secret。

## 引导与 secret（进程启动）

这些必须在控制面启动前存在。Docker Compose 放 `.env`，Helm 放 chart 读取的 Secret。

| 变量 | 必需 | 含义 |
|---|---|---|
| `DATABASE_URL` | 是 | 控制面所用的 PostgreSQL 连接串 |
| `ANKOLE_SECRET_BASE` | 是 | 实例级 Secret Base，用于派生其他密钥 |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | 是 | worker 向 RuntimeFabric 出示的认证 key |
| `POSTGRES_PASSWORD` | 仅内置 PostgreSQL | PostgreSQL 密码（启用内置 PostgreSQL 时必需；外部则由外部 Secret 提供） |
| `ANKOLE_HOST` | Compose | 部署所服务的 DNS 名 |
| `ACME_EMAIL` | Compose | Caddy 用于 Let's Encrypt 的邮箱 |

这些值应放在 `.env` 或 Secret 中，绝不能提交到版本控制。Docker Compose 的 `.env.example` 是配置起点。

Helm chart 的 `values.yaml` 列出了 Kubernetes 中对应的 `ankoleSecretBase`、`workerAuthKey` 和 `postgresqlPassword`。

## 运行时调优（进程环境）

启动时读取，调优一个运行中的进程。它们不是 secret。

| 变量 | 默认 | 含义 |
|---|---|---|
| `ANKOLE_ENV` | — | 部署环境标签（如 `prod`、`dev`） |
| `ANKOLE_LOG_LEVEL` | `info` | 日志级别（`debug`、`info`、`warning`、`error`） |
| `ANKOLE_LOG_FORMAT` | `json` | 日志行格式（`json` 供摄入，`pretty` 供本地阅读） |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | 控制面数据库连接池大小 |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | `300` | 内置 PostgreSQL 服务器的 `max_connections` |
| `ANKOLE_MAX_CONCURRENT_TURNS` | `9` | 并发 actor 回合上限 |
| `ANKOLE_LIBRARY_ROOT` | chart 默认 | 自带 Agent Library 的路径（`app/library`） |
| `ANKOLE_INTERNAL_SKILLS_ROOT` | — | 内部 skill bundle 的路径 |
| `ANKOLE_AI_GATEWAY_BASE_URL` | — | 覆盖 AIGateway 基 URL（很少需要） |
| `ANKOLE_RUNTIME_FABRIC_BIND_ENDPOINT` | — | RuntimeFabric 绑定端点 |

## 仅 worker 的环境（Agent Computer Worker）

worker 读取一个固定的小集合。actor 身份**不在**其中——它通过 `turn_start` 到达，不在环境里。这些由受管 worker 引导设置，不由运维者设置。

| 变量 | 含义 |
|---|---|
| `WORKER_ID` | worker 身份（如 `worker-local-1`） |
| `RUNTIME_FABRIC_URL` | RuntimeFabric URL，带着 worker 认证 key |
| `ANKOLE_AGENTS_ROOT` | 共享 `/agents` 工作空间挂载的根 |
| `ANKOLE_AGENT_COMPUTER_IMAGE` | worker 所跑的 Agent Computer Worker 镜像 |
| `ANKOLE_VERSION` | Ankole 版本标签 |

Worker 镜像负责设置浏览器、Bubblewrap、Codex 和 Skill 路径，包括 `ANKOLE_BROWSER_*`、`ANKOLE_BWRAP_PATH`、`ANKOLE_CODEX_BINARY` 和 `ANKOLE_BUILTIN_SKILLS_ROOT`。这些路径不能由管理员调整。

`PATH`、`HOME`、`DATABASE_URL` 以及以 `ANKOLE_` 开头的名称属于保留名称，不能通过 Console 覆盖。Agent 使用的自定义值见[环境变量](../worker-env/)。

## 修改部署环境变量

- 使用 Docker Compose 时，修改 `.env`，再重启受影响的容器。
- 使用 Kubernetes 时，修改 Helm values 或对应的 Secret，再重启受影响的工作负载。

环境变量只在进程启动时读取。仅修改文件或 Secret，不重启进程，不会改变当前运行状态。

## 下一步

- Agent 使用的自定义变量，读[环境变量](../worker-env/)。
- 运行期间可调整的设置和完整 AppConfigure 键清单，读[系统配置](../app-configuration/)。
- 部署变量在上下文中的位置，读[快速开始的部署部分](../quickstart/#deployment)。
