---
title: Console 运维流程
description: 管理员用来配置 provider、model profile、Agent、Signal binding、library capability、WorkerEnv secret 和 plugin 的无状态 bearer-token REST API。
section: Operations
order: 12
---

Console 是运维者把一套运行中的 Ankole 部署变成一套可用部署的工具。React 外壳背后是无状态的 REST API——`console_api` 管线——系统里的每一个配置界面都是它上面的一条路由。本页是运维者的 API 地图：门是什么、有哪些配置界面、每个界面管什么。

先把决定性的性质说清楚：Console API 是无状态的、bearer 鉴权的，并且它在每一次请求上重新确认调用方仍然是一个活跃管理员。没有 session cookie 替你扛这件事，一个被禁用的管理员立即失效，而不是下一次登录才失效。

## 门

`/api/v1` 下的每一条路由都经过 `:console_api` 管线和 `RequireConsoleAccessToken` 插件。插件跑三项彼此独立的检查，缺一不可：

1. 一个格式正确的 `Authorization: Bearer` 头；
2. 一个能通过验证的 console JWT；
3. JWT 所指的那个主体仍然是一个活跃管理员。

成功时，它把主体和 claims 存进 conn assigns，供下游的策略检查使用；任何一项失败都以 `401` 中止。这是 session 加 CSRF 为浏览器界面所做的事的逐请求、无 cookie 等价物。不存在第二条更弱的进入这些路由的路径。

## 配置界面

配置按“正在配置什么”组织，而不是按控制器组织。运维者实际驱动的界面：

### provider 与模型访问

一个运行中的 agent 需要背后有一个模型。运维者通过 AIGateway 的 provider 界面和 agent 的 model profile 把它接上：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/ai-gateway/provider-kinds` | 列出本部署能配置的 provider 种类 |
| `GET` | `/ai-gateway/providers` | 列出已配置的 provider |
| `PUT` | `/ai-gateway/providers/:provider_id` | 创建或替换一个 provider |
| `DELETE` | `/ai-gateway/providers/:provider_id` | 移除一个 provider |
| `GET` | `/agents/:agent_uid/model-profiles` | 列出一个 agent 的 model profile |
| `PUT` | `/agents/:agent_uid/model-profiles/:profile` | 创建或替换一个 profile |
| `DELETE` | `/agents/:agent_uid/model-profiles/:profile` | 移除一个 profile |

provider 凭证住在控制面里，绝不放在 agent 的环境里。一个 model profile 把一个 agent 绑到一个选择符上；AIGateway 在调用时把这个选择符解析到 provider。

### agent 及其能力

agent 是这样一个单位：运维者围绕它配置其它一切：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/agents` | 列出 agent |
| `POST` | `/agents` | 创建一个 agent |
| `GET` | `/agents/:agent_uid` | 读取一个 agent |
| `PATCH` | `/agents/:agent_uid` | 更新一个 agent |
| `DELETE` | `/agents/:agent_uid` | 移除一个 agent |

### signal binding

一个 signal binding 把一个 provider adapter 绑到一个 agent 上，让共享工作能够到达它：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/signal-adapters` | 列出本部署声明的 adapter |
| `GET` | `/agents/:agent_uid/signal-bindings` | 列出一个 agent 的 binding |
| `PUT` | `/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | 创建或替换一个 binding |
| `PATCH` | `/agents/:agent_uid/signal-bindings/:binding_name` | 更新一个 binding |
| `DELETE` | `/agents/:agent_uid/signal-bindings/:binding_name` | 移除一个 binding |

禁用一个 binding 会停止新信号唤醒它的 agent，而不删除这个 binding。

### Agent Library 能力

Agent Library 是一个 agent 能做什么——它的 plugin 和 skill。Console 暴露两层范围：一个全局默认值，一层按 agent 的覆盖：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/agent-library/capabilities` | 列出全局 library 能力 |
| `PUT` | `/agent-library/agent-plugins/:id` | 设定一个 plugin 的全局默认状态 |
| `PUT` | `/agent-library/skills/:id` | 设定一个 skill 的全局默认状态 |
| `GET` | `/agents/:agent_uid/library-capabilities` | 列出一个 agent 的有效能力 |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 为某一个 agent 覆盖一个 plugin |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | 为某一个 agent 覆盖一个 skill |
| `GET` | `/agents/:agent_uid/library-documents` | 列出某个 agent 的 library 文档 |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | 设定一份 library 文档 |
| `GET` | `/agents/:agent_uid/library-skill-overlays` | 列出 skill overlay |
| `PUT` | `/agents/:agent_uid/library-skill-overlays/:skill_name` | 设定一个 skill overlay |
| `DELETE` | `/agents/:agent_uid/library-skill-overlays/:skill_name` | 移除一个 skill overlay |

一项能力先在全局启用，再按 agent 收窄或放宽。skill overlay 让运维者为某一个 agent 定制某个 skill 的行为，而不必 fork 它。

### WorkerEnv secret

Agent Computer worker 需要 secret——API key、token——但这些 secret 不能明文躺在配置里。WorkerEnv 是那个加密存储：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/worker-envs` | 列出命名的 WorkerEnv 条目 |
| `GET` | `/worker-envs/:name` | 读取一个条目（元数据，不是明文） |
| `PUT` | `/worker-envs/:name` | 创建或更新一个条目 |
| `DELETE` | `/worker-envs/:name` | 移除一个条目 |
| `GET` | `/agents/:agent_uid/worker-envs` | 列出挂到某个 agent 上的条目 |
| `PUT` | `/agents/:agent_uid/worker-envs/:name` | 把一个条目挂到一个 agent 上 |
| `DELETE` | `/agents/:agent_uid/worker-envs/:name` | 从一个 agent 上摘下一个条目 |
| `POST` | `/worker-envs/:name/decryptions` | 解密一个条目（受审计、受特权保护） |

解密是一项独立的、受审计的操作。列出和读取返回的是元数据，不是 secret 值。worker 只在一个回合开始时收到它的环境；改动在下一个回合生效，不在一个已经在跑的回合上生效。

### Control Plane Plugin 与 Codex account

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/control-plane-plugins` | 列出 Control Plane Plugin 及其状态 |
| `PUT` | `/control-plane-plugins` | 启用或禁用 plugin |
| `GET` | `/codex-accounts` | 列出 Codex account |
| `POST` | `/codex-accounts` | 创建一个 Codex account |
| `PUT` | `/codex-accounts/:account_id` | 更新一个 account |
| `DELETE` | `/codex-accounts/:account_id` | 移除一个 account |

Control Plane Plugin 是那些改变控制面自身行为的第一方扩展（一个 signals adapter、一个 Brain source connector）。Codex account 带着后台 Agent 任务执行时所用的账户。

### identity provider 与 AppConfiguration

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/identity-provider-adapters` | 列出本部署支持的 IdP adapter |
| `GET` | `/identity-providers` | 列出已配置的 identity provider |
| `PUT` | `/identity-providers/:provider_id` | 创建或替换一个 IdP |
| `POST` | `/identity-providers/:provider_id/sync-runs` | 从一个 IdP 同步 directory group |
| `GET` | `/app-configurations` | 列出运维者管理的配置键 |
| `PUT` | `/app-configurations/:key` | 设定一个配置值 |
| `POST` | `/app-configurations/:key/decryptions` | 解密一个 secret 配置值 |

`AppConfiguration` 面向运维者管理的设置——那些声明过的 `Ankole.AppConfigure` 键。引导配置（进程启动事实与凭证）按项目边界的要求，留在环境变量或 secret 挂载里，不进这里。

## 读取界面

除了配置，Console 也是系统其余部分的可观测路径——每一个已经成文的子系统，在这里都有它的读取界面：

- **进行中的 agent**：`/agents/:agent_uid/sessions`，每个 session 的 cron schedule 和 checkback。
- **worker**：`/agent-computer-workers`，按 worker 上传、移动、列出文件。
- **任务**：`/background-agent-jobs`（列出、读取、取消）。
- **AI 活动**：`/ai-gateway/conversations`，按会话读取消息。
- **记忆**：完整的 `/brain/*` 界面——条目、source、审计日志、dreaming 运行与 fitness、还原。
- **Principal 与 AuthZ**：`/principals`、`/principal-groups`、`/permission-grants`——即 [Principal 与 AuthZ](../principal-authz/) 页里的权限模型。

## 关于这里不包含什么

`/webhooks/*` 和 `/api/v1/ai-gateway/*` 路由刻意不放在 `console_api` 下。webhook 入口鉴权的是 provider，不是管理员；AIGateway 运行时 API 鉴权的是用于实时 AI 调用的 agent 或 admin token。Console 是运维者的配置界面，也是唯一一个信任管理员 bearer token 去改变部署行为的界面。

## 下一步

- Console 所配置的那些运行时界面，读 [AIGateway API](../ai-gateway/)、[SignalsGateway](../signals-gateway/)、[Actor Runtime](../actor-runtime/)。
- Console 自身所运行的权限模型，读 [Principal 与 AuthZ](../principal-authz/)。
- 要先有一套可供配置的运行中部署，读[安装部署指南](../installation/)。
