---
title: Console API 参考
description: Console 使用的 /api/v1 与 /api/v2 接口参考，包括认证、资源路由和授权操作。
section: Reference
order: 203
---

Console REST API 使用浏览器会话 cookie。`RequireSiteAdminSession` 每次请求都检查 Console 上下文、Human 撤销状态和当前站点管理员成员资格，认证失败返回 `401`。GET 和 HEAD 以外的请求必须携带外壳中的 `x-csrf-token`；CSRF 凭据缺失或无效返回 `403`。

表中给出每条路由的完整路径。Console API 有两个版本：

- `/api/v2` 路由使用 JSON:API（`application/vnd.api+json`）。列表路由用 `page[limit]` 与 `page[after]` 做 keyset 分页。字段错误返回 `400`；记录不存在返回 `404`，错误为 `not_found`；与当前状态冲突返回 `409`，其他领域拒绝返回 `422`。错误 `code` 是理由名。
- `/api/v1` 路由使用 `application/json`，提供聚合视图、密文、协议操作、文件传输和流。

站点管理路由位于 `/api/v2/site` 与 `/api/v1/site`，使用 `:session_api` + `:site_admin` 管线。租户数据路由位于 `/api/v2` 与 `/api/v1`，使用 `:session_api` + `:site_admin` + `:data_context` 管线和 `PutDataContext`。调用租户路由时，`x-ankole-tenant: <租户 UUID>` 指定数据租户；不传该请求头时使用调用方所属租户。无效、不可用或正在删除的租户返回 `404`，错误为 `data_tenant_unavailable`。请求头不会改变调用方身份或站点管理权限，也不为站点路由选择作用域。

公开的 `/api/v1/openapi.json` 描述 v1 路由；`/api/v2/openapi.json` 与 `/api/v2/site/openapi.json` 描述 v2 路由，需要与这些路由相同的认证。运行时 AI 调用与 webhook 使用各自的鉴权规则。

## 配置界面

配置按“正在配置什么”组织，而不是按控制器组织。运维者实际驱动的界面：

### provider 与模型访问

一个运行中的 agent 需要背后有一个模型。运维者通过 AIGateway 的 provider 界面和 agent 的 model profile 把它接上：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v1/site/ai-gateway/provider-kinds` | 列出本实例可以配置的 Provider 类型 |
| `GET` | `/api/v1/site/ai-gateway/models` | 列出带能力类型的 provider 模型供控制台配置 |
| `GET` | `/api/v2/site/ai-gateway/providers` | 列出已配置的 provider |
| `GET` | `/api/v2/site/ai-gateway/providers/:provider_id` | 读取一个 Provider 及其凭据池状态 |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id` | 创建或替换一个 provider |
| `DELETE` | `/api/v2/site/ai-gateway/providers/:provider_id` | 移除一个 provider |
| `POST` | `/api/v1/site/ai-gateway/providers/:provider_id/credentials` | 添加一个凭据池成员 |
| `PUT` | `/api/v1/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | 更新或重新认证池成员 |
| `DELETE` | `/api/v1/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | 删除池成员 |
| `PUT` | `/api/v1/site/ai-gateway/providers/:provider_id/credential-pool/strategy` | 设置凭据池选择策略 |
| `POST` | `/api/v1/site/ai-gateway/providers/:provider_id/chatgpt-login` | 开始一次 ChatGPT 设备码或浏览器登录 |
| `POST` | `/api/v1/site/ai-gateway/providers/:provider_id/chatgpt-login/poll` | 轮询一次设备码登录 |
| `POST` | `/api/v1/site/ai-gateway/providers/:provider_id/chatgpt-login/browser-callback` | 完成浏览器粘贴回退 |
| `POST` | `/api/v1/site/ai-gateway/providers/:provider_id/chatgpt-enterprise-credentials` | 添加 Enterprise access token |
| `GET` | `/api/v1/agents/:agent_uid/model-profiles` | 列出一个 agent 的 model profile |
| `PUT` | `/api/v1/agents/:agent_uid/model-profiles/:profile` | 创建或替换一个 profile |
| `DELETE` | `/api/v1/agents/:agent_uid/model-profiles/:profile` | 移除一个 profile |

Provider 凭证以加密池成员的形式保存在控制面，绝不放进 Agent 环境。model profile 把 Agent 绑定到一个 Provider 和模型；AIGateway 在该 Provider 内选择健康成员。API 投影只返回脱敏的账号事实、健康状态、限额数据和用量。

### agent 及其能力

agent 是核心单位，运维者的其它配置都围绕它展开：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/agents` | 列出 agent |
| `POST` | `/api/v2/agents` | 创建一个 agent |
| `GET` | `/api/v2/agents/:agent_uid` | 读取一个 agent |
| `PATCH` | `/api/v2/agents/:agent_uid` | 更新一个 agent |
| `POST` | `/api/v2/agents/:agent_uid/enable` | 重新启用一个已停用的 agent |
| `DELETE` | `/api/v2/agents/:agent_uid` | 停用一个运行中的 agent；对已停用的 agent 执行则永久删除 |

### Worker provider

每个 Agent 在创建时选择一个 Worker provider，之后不能更换。Provider 的 YAML 配置与加密凭据分开保存。生命周期与存储契约见 [Worker 管理](../worker-management/)。

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v1/site/worker-provider-kinds` | 列出 provider 类型、YAML 示例与凭据要求 |
| `GET` | `/api/v2/site/worker-providers` | 列出已配置的 Worker provider |
| `POST` | `/api/v2/site/worker-providers` | 创建 Worker provider |
| `PATCH` | `/api/v2/site/worker-providers/:provider_id` | 更新配置或凭据 |
| `GET` | `/api/v1/site/worker-providers/:provider_id/check` | 检查连接与权限 |
| `DELETE` | `/api/v2/site/worker-providers/:provider_id` | 删除没有 Agent 使用的 provider |
| `PUT` | `/api/v2/agents/:agent_uid/worker-provider` | 为迁移后尚未指派 provider 的 Agent 完成指派 |

### 信号路由规则

信号路由规则（API Schema 中名为 Signal Binding）把一个 Provider 适配器连接到一个 Agent，让共享工作可以到达它：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v1/signal-adapters` | 列出本实例声明的适配器 |
| `GET` | `/api/v1/signal-bindings` | 列出路由规则；`?agent=` 可筛选到单个 Agent |
| `PUT` | `/api/v1/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | 创建或替换路由规则 |
| `PATCH` | `/api/v1/agents/:agent_uid/signal-bindings/:binding_name` | 更新路由规则 |
| `DELETE` | `/api/v2/agents/:agent_uid/signal-bindings/:binding_name` | 禁用路由规则 |
| `GET` | `/api/v1/conversations/:conversation_id/standing-orders` | 读取一个 Conversation 的常驻指令 |
| `PUT` | `/api/v1/conversations/:conversation_id/standing-orders` | 替换一个 Conversation 的常驻指令 |

禁用一个 binding 会停止新信号唤醒它的 agent，而不删除这个 binding。

### Agent Library 能力

Library 默认值属于所选租户；Agent 覆盖也在该租户内生效。

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v1/agent-library/capabilities` | 列出全局 library 能力 |
| `PUT` | `/api/v1/agent-library/agent-plugins/:id` | 设定一个 plugin 的租户默认状态 |
| `PUT` | `/api/v1/agent-library/skills/:id` | 设定一个 skill 的租户默认状态 |
| `GET` | `/api/v1/agents/:agent_uid/library-capabilities` | 列出一个 agent 的有效能力 |
| `PUT` | `/api/v1/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 为某一个 agent 覆盖一个 plugin |
| `PUT` | `/api/v1/agents/:agent_uid/library-capabilities/skills/:id` | 为某一个 agent 覆盖一个 skill |
| `GET` | `/api/v1/agents/:agent_uid/library-documents` | 列出某个 agent 的 library 文档 |
| `PUT` | `/api/v1/agents/:agent_uid/library-documents/:document_kind` | 设定一份 library 文档 |
| `GET` | `/api/v2/agents/:agent_uid/skill-lessons` | 列出生效和已退场的技能教训 |
| `POST` | `/api/v2/agents/:agent_uid/skill-lessons` | 为已启用的 Skill 新增人工教训 |
| `POST` | `/api/v2/agents/:agent_uid/skill-lessons/:lesson_id/retire` | 让一条技能教训退场 |

一项能力先在租户内启用，再按 Agent 收窄或放宽。技能教训为单个 Agent 提供附加的过程指引，不改动 Skill 来源。列表会保留证据和退场历史。已退场的教训不再投递；人工撤销的内容会留在 Dreaming 的禁止再学习清单中。生命周期与限制见[技能教训](../skill-lessons/)。

### 环境变量（WorkerEnv）

WorkerEnv 有站点默认值、租户覆盖和 Agent 挂载。下列路由返回元数据；明文需要通过独立、可审计的解密操作获取。

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v1/site/worker-envs` | 列出站点默认值 |
| `PUT` | `/api/v1/site/worker-envs/:name` | 设置站点默认值 |
| `DELETE` | `/api/v1/site/worker-envs/:name` | 删除站点默认值 |
| `POST` | `/api/v1/site/worker-envs/:name/decryptions` | 解密站点值 |
| `GET` | `/api/v1/worker-envs` | 列出租户值 |
| `PUT` | `/api/v1/worker-envs/:name` | 设置租户值 |
| `DELETE` | `/api/v1/worker-envs/:name` | 删除租户值 |
| `POST` | `/api/v1/worker-envs/:name/decryptions` | 解密租户值 |
| `GET` | `/api/v1/agents/:agent_uid/worker-envs` | 列出 Agent 挂载 |
| `PUT` | `/api/v1/agents/:agent_uid/worker-envs/:name` | 为 Agent 挂载或覆盖值 |
| `DELETE` | `/api/v1/agents/:agent_uid/worker-envs/:name` | 移除 Agent 挂载 |
| `POST` | `/api/v1/agents/:agent_uid/worker-envs/:name/decryptions` | 解密 Agent 值 |

Agent 挂载可使用专用值，也可依次继承租户值和站点默认值。Worker 工作开始时解析环境值；已有工作区保持创建时的环境。

### Control Plane Plugin

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v1/site/control-plane-plugins` | 列出 Control Plane Plugin 及其状态 |
| `PUT` | `/api/v1/site/control-plane-plugins` | 启用或禁用 plugin |

Control Plane Plugin 是改变控制面自身行为的第一方扩展，例如 signals adapter。

### 身份源提供商与 AppConfiguration

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v1/identity-provider-adapters` | 列出本实例支持的 IdP 适配器 |
| `GET` | `/api/v1/identity-providers` | 列出已配置的身份源提供商 |
| `PUT` | `/api/v1/identity-providers/:provider_id` | 创建或替换一个 IdP |
| `POST` | `/api/v1/identity-providers/:provider_id/sync-runs` | 从一个 IdP 同步 directory group |
| `GET` | `/api/v1/site/app-configurations` | 列出站点配置键 |
| `PUT` | `/api/v1/site/app-configurations/:key` | 设置站点值 |
| `POST` | `/api/v1/site/app-configurations/:key/decryptions` | 解密站点 secret |
| `GET` | `/api/v1/app-configurations` | 列出运维者管理的配置键 |
| `PUT` | `/api/v1/app-configurations/:key` | 设定一个配置值 |
| `POST` | `/api/v1/app-configurations/:key/decryptions` | 解密一个 secret 配置值 |

`AppConfiguration` 按站点或租户作用域存储声明的运维设置。`/api/v1/site/app-configurations` 管理站点键，`/api/v1/app-configurations` 管理租户键。两者均支持列表、读取单个键、设置、删除覆盖与可审计的解密。启动凭据与启动事实仍放在环境变量或 secret mount 中。

### 租户管理

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/tenants` | 列出租户 |
| `POST` | `/api/v2/site/tenants` | 创建租户 |
| `PATCH` | `/api/v2/site/tenants/:tenant_id` | 更新租户 |
| `DELETE` | `/api/v2/site/tenants/:tenant_id` | 请求删除租户 |
| `POST` | `/api/v2/site/tenants/:tenant_id/suspension` | 暂停租户 |
| `DELETE` | `/api/v2/site/tenants/:tenant_id/suspension` | 恢复租户 |
| `GET` | `/api/v2/site/privileged-tenant` | 读取特权租户 |
| `PATCH` | `/api/v2/site/privileged-tenant` | 将站点管理转移到另一个租户 |

## 读取界面

除了配置，Console 也是系统其余部分的可观测路径——每一个已经实现的子系统，在这里都有它的读取界面：

- **进行中的 agent**：`/api/v1/agents/:agent_uid/sessions`，每个 agent 的 cron schedule 与 checkback 管理；列表端点为租户级，接受 `agent` 筛选。
- **Worker**：`/api/v2/agent-workers` 列出每个 Agent 的 Worker 状态。
- **Agent 网盘**：`/api/v1/agents/:agent_uid/files` 列出、上传、删除文件，`/api/v1/agents/:agent_uid/files/content` 下载文件，`/api/v1/agents/:agent_uid/file-moves` 移动文件。这些文件由控制面管理。
- **任务**：`/api/v2/background-agent-jobs`（列出、读取、取消）。
- **AI 活动**：`/api/v2/ai-gateway/conversations`，按会话读取消息。
- **主体与 AuthZ**：`/api/v2/principals`、`/api/v2/principal-groups`、`/api/v2/permission-grants`。权限模型见 [主体与 AuthZ](../principal-authz/)。

## 关于这里不包含什么

`/webhooks/*` 验证 provider。运行时 `/api/v1/ai-gateway/*` 调用使用 AIGateway 鉴权。Console 配置路由使用本页所述的会话与 CSRF 检查。

## 下一步

- Console 所配置的那些运行时界面，读 [AIGateway API](../ai-gateway/)、[Signals](../signals/)、[Sessions](../sessions/)。
- Console 使用的权限模型，见 [主体与 AuthZ](../principal-authz/)。
- 如果还没有运行中的实例，请先阅读 [快速开始的部署部分](../quickstart/#deployment)。
