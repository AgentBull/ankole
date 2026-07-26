---
title: Console 运维操作
description: 运维者的任务索引——先通过 bearer 门登录，再按 provider、agent、binding、secret、plugin 和实时可观测性各自的路径推进。
section: User guide
order: 11
---

Console 是运维者把一套运行中的 Ankole 部署变成可用部署的地方。React 外壳背后是无状态 REST API，本页是它的任务索引——门是什么，以及每一项运维工作该走哪条路径。完整的路由表和 OpenAPI 形态在开发者侧的 [Console API 参考](../console-api/)；本页只讲你做什么，不逐字段展开。

先把决定性的性质说清楚：Console API 是无状态、bearer 鉴权的，并且它在每一次请求上重新确认调用方仍然是一个活跃管理员。没有 session cookie 替你扛这件事，一个被禁用的管理员立即失效，而不是下一次登录才失效。

## 登录：bearer 门

每一次 Console 请求都经过 `:console_api` 管线和 `RequireConsoleAccessToken` 插件。每次调用跑三项彼此独立的检查，缺一不可：

1. 一个格式正确的 `Authorization: Bearer` 头；
2. 一个能通过验证的 console JWT；
3. JWT 所指的那个主体仍然是一个活跃管理员。

任何一项失败都以 `401` 中止。没有第二条更弱的进入路径——没有 session 兜底，没有延续的 cookie。登录意味着拿到一个 console JWT，并在每次请求上都带上它。

## 任务路径

Console 按“正在配置什么”组织，而不是按控制器组织。选一件工作；具体字段看对应的话题页。

### 接上模型

一个 agent 需要背后有一个模型。配置 AI provider，再把一个 model profile 绑到 agent 上。

- **新增或替换一个 provider**——`PUT /ai-gateway/providers/:provider_id`。provider 凭证留在控制面；永远不要放进 agent 的环境。
- **把一个 model profile 绑到 agent 上**——`PUT /agents/:agent_uid/model-profiles/:profile`。一个 profile 把 agent 绑到一个选择符上；AIGateway 在调用时把选择符解析到 provider。

### 创建和配置 agent

agent 是其它一切配置所围绕的单位。

- **创建一个 agent**——`POST /agents`。
- **设定它的人设文档**——`PUT /agents/:agent_uid/library-documents/:document_kind`，`document_kind` 取 `mission`、`soul` 或 `design`。这些是 agent 每个回合都会读到的运行时文档。
- **启用或覆盖它的能力**——默认再覆盖的模型见 [Agent Library](../agent-library/)；运维界面是 `/agents/:agent_uid/library-capabilities/*`。

### 连接共享工作：signal binding

一个 signal binding 把一个 provider adapter 绑到一个 agent，让聊天、webhook 和事件能到达它。各 provider 的前置条件（app id、token、webhook URL、事件订阅）见用户指南下各 adapter 的专页。

- **列出可用 adapter**——`GET /signal-adapters`。
- **创建或替换一个 binding**——`PUT /agents/:agent_uid/signal-bindings/:adapter_id/:binding_name`。
- **禁用而不删除**——`PATCH` binding 的 `enabled` 标志。禁用会停止新信号唤醒 agent，但不删除 binding。

### 管理 worker 所需的 secret

WorkerEnv 是加密的 shell 环境存储。secret 放在这里，不放明文配置，并且只在回合开始时到达 worker。

- **新增或轮换一个全局 secret**——`PUT /worker-envs/:name`。
- **把一个 secret 挂到一个 agent 上**——`PUT /agents/:agent_uid/worker-envs/:name`。
- **揭示一个 secret**——`POST /worker-envs/:name/decryptions`。这是一项单独授权的动作；浏览列表永远看不到明文。
- 合并模型、加密和“下一个回合，不是这一个回合”的规则，读 [WorkerEnv secret](../worker-env/)。

### 启用第一方 plugin

Control Plane Plugin 通过一份全局清单启用，在下一次进程启动时生效。

- **查看已激活与已排定**——`GET /control-plane-plugins`。
- **为下一次启动排定一个 plugin**——`PUT /control-plane-plugins`。改动不会立即生效；重启 Ankole 来落实。
- 为什么激活是启动时的事，读 [Control Plane Plugins](../control-plane-plugins/)。

### 配置管理员登录

运维者通过 identity provider 联合管理员身份。

- **列出支持的 IdP adapter**——`GET /identity-provider-adapters`。
- **配置一个 IdP**——`PUT /identity-providers/:provider_id`。
- **同步 directory group**——`POST /identity-providers/:provider_id/sync-runs`。

## 观察运行中的部署

Console 也是系统其余部分的可读界面：

- **进行中的 agent**——`/agents/:agent_uid/sessions`，每个 session 的 cron schedule 和 checkback。
- **worker**——`/agent-computer-workers`，按 worker 上传、移动、列出文件。
- **后台任务**——`/background-agent-jobs`（列出、读取、取消）。
- **AI 活动**——`/ai-gateway/conversations`，按会话读取消息。
- **记忆**——完整的 `/brain/*` 界面：条目、source、审计日志、dreaming 运行与 fitness、还原。
- **Principal 与 AuthZ**——`/principals`、`/principal-groups`、`/permission-grants`。

## 这里不包含什么

`/webhooks/*` 和 `/api/v1/ai-gateway/*` 路由刻意不放在 `console_api` 下。webhook 入口鉴权的是 provider，不是管理员；AIGateway 运行时 API 鉴权的是用于实时 AI 调用的 agent 或 admin token。Console 是运维者的配置界面，也是唯一一个信任管理员 bearer token 去改变部署行为的界面。

## 下一步

- 完整的路由表和策略动作，读 [Console API 参考](../console-api/)。
- 各 adapter 的专门设置页，浏览用户指南这一节。
- 这些路由所配置的子系统，从[架构概览](../architecture/)开始。
