---
title: Console API 参考
description: Console 使用的 /api/v1 REST 接口参考，包括认证、资源路由和授权操作。
section: Reference
order: 203
---

本页是 Console API 的 REST 参考：鉴权入口、`/api/v1` 下的路由，以及每条路由所执行的权限动作。

先说明最关键的一点：Console API 是无状态、bearer 鉴权的，并且它在每一次请求上重新确认调用方仍然是一个活跃管理员。没有 session cookie 替你扛这件事，一个被禁用的管理员立即失效，而不是下一次登录才失效。

## 门

`/api/v1` 下的每一条路由都经过 `:console_api` 管线和 `RequireConsoleAccessToken` 插件。插件跑三项彼此独立的检查，缺一不可：

1. 一个格式正确的 `Authorization: Bearer` 头；
2. 一个能通过验证的 Console JWT；
3. JWT 所指的那个主体仍然是一个活跃管理员。

成功时，它把主体和 claims 存进 conn assigns，供下游的策略检查使用；任何一项失败都以 `401` 中止。浏览器界面靠 session 与 CSRF 做到的事，这里以逐请求、无 cookie 的方式等价实现。不存在第二条更弱的进入这些路由的路径。

## 配置界面

配置按“正在配置什么”组织，而不是按控制器组织。运维者实际驱动的界面：

### provider 与模型访问

一个运行中的 agent 需要背后有一个模型。运维者通过 AIGateway 的 provider 界面和 agent 的 model profile 把它接上：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/ai-gateway/provider-kinds` | 列出本实例可以配置的 Provider 类型 |
| `GET` | `/ai-gateway/providers` | 列出已配置的 provider |
| `GET` | `/ai-gateway/providers/:provider_id` | 读取一个 Provider 及其凭据池状态 |
| `PUT` | `/ai-gateway/providers/:provider_id` | 创建或替换一个 provider |
| `DELETE` | `/ai-gateway/providers/:provider_id` | 移除一个 provider |
| `POST` | `/ai-gateway/providers/:provider_id/credentials` | 添加一个凭据池成员 |
| `PUT` | `/ai-gateway/providers/:provider_id/credentials/:credential_id` | 更新或重新认证池成员 |
| `DELETE` | `/ai-gateway/providers/:provider_id/credentials/:credential_id` | 删除池成员 |
| `PUT` | `/ai-gateway/providers/:provider_id/credential-pool/strategy` | 设置凭据池选择策略 |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-login` | 开始一次 ChatGPT 设备码或浏览器登录 |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-login/poll` | 轮询一次设备码登录 |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-login/browser-callback` | 完成浏览器粘贴回退 |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-enterprise-credentials` | 添加 Enterprise access token |
| `GET` | `/agents/:agent_uid/model-profiles` | 列出一个 agent 的 model profile |
| `PUT` | `/agents/:agent_uid/model-profiles/:profile` | 创建或替换一个 profile |
| `DELETE` | `/agents/:agent_uid/model-profiles/:profile` | 移除一个 profile |

Provider 凭证以加密池成员的形式保存在控制面，绝不放进 Agent 环境。model profile 把 Agent 绑定到一个 Provider 和模型；AIGateway 在该 Provider 内选择健康成员。API 投影只返回脱敏的账号事实、健康状态、限额数据和用量。

### agent 及其能力

agent 是核心单位，运维者的其它配置都围绕它展开：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/agents` | 列出 agent |
| `POST` | `/agents` | 创建一个 agent |
| `GET` | `/agents/:agent_uid` | 读取一个 agent |
| `PATCH` | `/agents/:agent_uid` | 更新一个 agent |
| `DELETE` | `/agents/:agent_uid` | 移除一个 agent |

### 信号路由规则

信号路由规则（API Schema 中名为 Signal Binding）把一个 Provider 适配器连接到一个 Agent，让共享工作可以到达它：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/signal-adapters` | 列出本实例声明的适配器 |
| `GET` | `/agents/:agent_uid/signal-bindings` | 列出一个 Agent 的路由规则 |
| `PUT` | `/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | 创建或替换路由规则 |
| `PATCH` | `/agents/:agent_uid/signal-bindings/:binding_name` | 更新路由规则 |
| `DELETE` | `/agents/:agent_uid/signal-bindings/:binding_name` | 移除路由规则 |
| `GET` | `/signal-channels/:channel_id/standing-orders` | 读取一个频道的常驻指令 |
| `PUT` | `/signal-channels/:channel_id/standing-orders` | 替换一个频道的常驻指令 |

禁用一个 binding 会停止新信号唤醒它的 agent，而不删除这个 binding。

### Agent Library 能力

Agent Library 是一个 agent 能做什么——它的 plugin 和 skill。Console 暴露两层范围：一层全局默认值，一层按 agent 的覆盖：

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

### 环境变量（WorkerEnv）

Agent Computer Worker 运行时可能需要 API key、token 等环境变量。Console 将这项功能称为“环境变量”；API 中仍使用 `WorkerEnv` 作为资源名：

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

解密是一项独立的、受审计的操作。列出和读取返回的是元数据，不是 secret 值。worker 只在一个回合开始时收到它的环境；改动在下一个回合生效，不会在已经开始执行的回合上生效。

### Control Plane Plugin

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/control-plane-plugins` | 列出 Control Plane Plugin 及其状态 |
| `PUT` | `/control-plane-plugins` | 启用或禁用 plugin |

Control Plane Plugin 是改变控制面自身行为的第一方扩展，例如 signals adapter 或 Brain source connector。

### 身份源提供商与 AppConfiguration

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/identity-provider-adapters` | 列出本实例支持的 IdP 适配器 |
| `GET` | `/identity-providers` | 列出已配置的身份源提供商 |
| `PUT` | `/identity-providers/:provider_id` | 创建或替换一个 IdP |
| `POST` | `/identity-providers/:provider_id/sync-runs` | 从一个 IdP 同步 directory group |
| `GET` | `/app-configurations` | 列出运维者管理的配置键 |
| `PUT` | `/app-configurations/:key` | 设定一个配置值 |
| `POST` | `/app-configurations/:key/decryptions` | 解密一个 secret 配置值 |

`AppConfiguration` 面向运维者管理的设置——那些声明过的 `Ankole.AppConfigure` 键。引导配置（进程启动事实与凭证）按项目边界的要求，留在环境变量或 secret 挂载里，不进这里。

## 读取界面

除了配置，Console 也是系统其余部分的可观测路径——每一个已经实现的子系统，在这里都有它的读取界面：

- **进行中的 agent**：`/agents/:agent_uid/sessions`，每个 agent 的 cron schedule 和 checkback。
- **worker**：`/agent-computer-workers`，按 worker 上传、移动、列出文件。
- **任务**：`/background-agent-jobs`（列出、读取、取消）。
- **AI 活动**：`/ai-gateway/conversations`，按会话读取消息。
- **记忆**：完整的 `/brain/*` 界面——条目、source、审计日志、dreaming 运行与 fitness、还原。
- **主体与 AuthZ**：`/principals`、`/principal-groups`、`/permission-grants`。权限模型见 [主体与 AuthZ](../principal-authz/)。

## 关于这里不包含什么

`/webhooks/*` 和 `/api/v1/ai-gateway/*` 路由刻意不放在 `console_api` 下。webhook 入口鉴权的是 provider，不是管理员；AIGateway 运行时 API 验证的是用于实时 AI 调用的 agent 或 admin token。Console 是运维者的配置界面，也是唯一一个信任管理员 bearer token 去改变部署行为的界面。

## 下一步

- Console 所配置的那些运行时界面，读 [AIGateway API](../ai-gateway/)、[SignalsGateway](../signals-gateway/)、[Actor Runtime](../actor-runtime/)。
- Console 使用的权限模型，见 [主体与 AuthZ](../principal-authz/)。
- 如果还没有运行中的实例，请先阅读 [快速开始的部署部分](../quickstart/#deployment)。
