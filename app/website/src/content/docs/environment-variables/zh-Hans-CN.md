---
title: 环境变量
description: 完整参考——引导期进程环境变量（部署时）、运行时调优环境变量、仅 worker 的环境变量，以及承载运维者管理的运行时设置的 AppConfigure 键。
section: Reference
order: 202
---

Ankole 从两个地方读配置，两者的生命周期刻意不同。**进程环境变量**承载在 PostgreSQL 可达之前就必须存在的部署期事实与 secret——在 `.env`（Compose）或 Kubernetes Secret（Helm）里设一次，进程启动时读取。**AppConfigure 键**承载运维者管理的运行时设置——可在运行时通过 Console 修改，存在 PostgreSQL 里。本页是两者的参考，按应用范围分组。

先把决定性的性质说清楚：不要混淆两者。引导期环境变量不是第二个 Console，AppConfigure 键也不是第二个 `.env`。一个设置能等到 PostgreSQL 起来，就属于 AppConfigure；等不到，就属于环境变量。

## 引导与 secret（进程启动）

这些必须在控制面启动前存在。Docker Compose 放 `.env`，Helm 放 chart 读取的 Secret。

| 变量 | 必需 | 含义 |
|---|---|---|
| `DATABASE_URL` | 是 | 控制面所用的 PostgreSQL 连接串 |
| `ANKOLE_SECRET_BASE` | 是 | 部署范围的 secret 基；用于派生其它密钥 |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | 是 | worker 向 RuntimeFabric 出示的认证 key |
| `POSTGRES_PASSWORD` | 仅内置 PostgreSQL | PostgreSQL 密码（启用内置 PostgreSQL 时必需；外部则由外部 Secret 提供） |
| `ANKOLE_HOST` | Compose | 部署所服务的 DNS 名 |
| `ACME_EMAIL` | Compose | Caddy 用于 Let's Encrypt 的邮箱 |

这些放 `.env` 或 Secret，永远不要进版本控制。Docker Compose 的 `.env.example` 是规范的起点集合；Helm chart 的 `values.yaml` 文档化了 Kubernetes 侧的等价物（`ankoleSecretBase`、`workerAuthKey`、`postgresqlPassword`）。

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

## 仅 worker 的环境（Agent Computer）

worker 读取一个固定的小集合。actor 身份**不在**其中——它通过 `turn_start` 到达，不在环境里。这些由受管 worker 引导设置，不由运维者设置。

| 变量 | 含义 |
|---|---|
| `WORKER_ID` | worker 身份（如 `worker-local-1`） |
| `RUNTIME_FABRIC_URL` | RuntimeFabric URL，带着 worker 认证 key |
| `ANKOLE_AGENTS_ROOT` | 共享 `/agents` 工作空间挂载的根 |
| `ANKOLE_AGENT_COMPUTER_IMAGE` | worker 所跑的 Agent Computer 镜像 |
| `ANKOLE_VERSION` | Ankole 版本标签 |

worker 侧的浏览器、bubblewrap、Codex、skills 路径（`ANKOLE_BROWSER_*`、`ANKOLE_BWRAP_PATH`、`ANKOLE_CODEX_BINARY`、`ANKOLE_BUILTIN_SKILLS_ROOT` 等）由 worker 镜像设置，不可由运维者调优。保留的 worker-env 名字（`PATH`、`HOME`、`DATABASE_URL`，以及除上述固定集合外任何以 `ANKOLE_` 开头的）无法通过 WorkerEnv 覆盖——运维者管理的 shell 环境见 [WorkerEnv secret](../worker-env/)。

## AppConfigure 键（运行时，运维者管理）

AppConfigure 键存在 PostgreSQL 里，通过 Console 修改。每个键有声明的 key、scope、schema、默认值和加密标志。运维者实际会动到的：

### AI agent

| 键 | 含义 |
|---|---|
| `ai_agent.max_iterations` | agent 循环迭代预算 |
| `ai_agent.max_output_tokens` | 每回合输出 token 上限 |
| `ai_agent.inactivity_timeout_ms` | 一个回合可 inactive 多久后被回收 |
| `ai_agent.library.agent_plugin_defaults` | Agent Plugin 的全局默认启用 |
| `ai_agent.library.skill_defaults` | skill 的全局默认启用 |

### AI 网关与记忆

| 键 | 含义 |
|---|---|
| `ai_gateway.compaction` | AIGateway 会话压缩策略 |
| `brain.knowledge` | Brain 策展知识设置 |
| `brain.dreaming` | Brain dreaming 启用与调度 |
| `brain.embedding` | Brain embedding 模型设置 |
| `brain.search` | Brain 召回搜索设置 |
| `brain.sources` | Brain 留存 source 设置 |

### 身份、插件与系统

| 键 | 含义 |
|---|---|
| `principals.identity_providers.active` | 哪个 identity provider 用于管理员登录 |
| `principals.identity_providers.directory_full_sync_interval_hours` | 多久全量同步一次 directory group |
| `plugins.enabled_ids` | 已启用的 Control Plane Plugin 全局清单（下次启动生效） |
| `system.timezone` | 部署默认时区 |
| `i18n.default_locale` | 部署默认 locale |

### 运行时 fabric 与 worker

| 键 | 含义 |
|---|---|
| `runtime_fabric.worker_auth_key` | worker 认证 key（也可从引导环境变量派生） |
| `agent_computer.background_agent_job.max_turns_per_worker` | 后台 Agent 任务每个 worker 的回合上限 |
| `worker.rendered_fetch_idle_ttl_ms` | 渲染后的 web 抓取结果空闲 TTL |
| `security.ssrf_filter` | 为真时，模型控制的 URL 抓取拒绝私网和环回主机 |

### 设置与引导

| 键 | 含义 |
|---|---|
| `setup.bootstrap_activation_code` | 首次访问的激活码（用 `kit show bootstrap-activation-code` 读取） |
| `setup.completed` | 设置是否已完成 |

## 各类如何修改

- **引导与 secret**——编辑 `.env`（Compose）或 Secret（Helm）并重启。不要把这些放进 AppConfigure。
- **运行时调优环境变量**——编辑部署的环境并重启控制面。
- **AppConfigure 键**——通过 Console 修改（`PUT /app-configurations/:key`），或通过子系统的专用 Console 路由（provider 配置、binding 配置等）。多数立即生效；少数影响启动（尤其是 `plugins.enabled_ids`）在下次进程启动生效。

## 下一步

- 运维者的 shell 环境存储，读 [WorkerEnv secret](../worker-env/)。
- 修改 AppConfigure 的 Console 路由，读 [Console API 参考](../console-api/)。
- 部署变量在上下文中的位置，读[安装部署指南](../installation/)。
