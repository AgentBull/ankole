---
title: Console API 参考
description: Console 管理台使用的 /api/v2 接口参考，涵盖浏览器会话认证、各领域资源路由与细粒度权限校验。
section: Reference
order: 203
---

Console API 采用支持多账号切换的浏览器会话认证机制：客户端通过 `Cookie` 发送加密签名的会话 Cookie，并通过 `x-ankole-authentication` 请求头指定当前激活的登录账号。请求到达后，`RequireSiteAdminSession` 插件会解析有效的管理员会话、核验人类账号的当前访问状态，并绑定 `Ankole.AuthZ` 调用主体（`console_rest`）；随后由 `Ankole.AuthZ.Authorizer` 按照 `site_console:**` 与 `tenant_console:**` 权限规则对每一次 Ash 操作执行鉴权。未登录或会话失效返回 `401`；除 `GET` 和 `HEAD` 之外的所有写请求都必须携带前端应用壳注入的 `x-csrf-token` 请求头，若缺失 CSRF 令牌、令牌无效或操作权限不足，接口均返回 `403`。

Console 的配置管理、聚合状态视图及可审计的密钥读取操作统一挂载在 `/api/v2` 下：其中站点级管理路由使用 `/api/v2/site` 前缀，租户级路由则作用于当前选定的数据租户。下文各表均列出包含前缀的完整路径。

所有 `/api/v2` 接口均采用 `application/vnd.api+json` 媒体类型，每个操作的请求与响应结构均由对应的 OpenAPI Schema 严格定义：标准资源的创建与更新通过 `data.type` 与 `data.attributes` 传参；通用动作（generic action）则将参数直接放在 `data` 对象内，并可直接返回强类型结果对象而非标准 JSON:API 资源文档（例如 `PUT /api/v2/worker-envs/EXAMPLE` 接收 `{"data":{"value":"example","secret":false}}` 并直接返回 `worker_env` 对象）。列表接口仅在其 Schema 明确声明支持游标（keyset）分页时，才接受 `page[limit]` 与 `page[after]` 参数。

访问租户级路由时，可通过 `x-ankole-tenant: <租户 UUID>` 请求头显式指定目标数据租户；未携带该请求头时默认操作调用方自身所属的租户。若指定的租户不存在、已停用或正在删除中，接口返回 `404`（错误码 `data_tenant_unavailable`）。注意：该请求头仅切换租户级路由的数据作用域，不会改变调用方身份或站点管理员权限，也不会影响 `/api/v2/site/*` 站点级路由。

`/api/v2/openapi.json` 与 `/api/v2/site/openapi.json` 分别导出租户控制台与站点管理台的完整 OpenAPI 3.1 规范，访问它们同样需要通过上述管理员会话认证。其余面向浏览器的 JSON:API 作用域也各自发布独立的 OpenAPI 3.1 文档：`/api/v2/pod/openapi.json`（涵盖 Pod 工作区接口及面向 `pod_admin` 的 `/api/v2/pod/admin/*` 管理路由）与 `/api/v2/browser/openapi.json`（涵盖浏览器登录认证与首次初始化向导接口）。文件的二进制上传与下载使用下文列出的原生 `/api/v2` 端点；而运行时 AI 网关调用、标准 OIDC 协议端点及外部 Webhook 接收路由则各自遵循独立的接口契约。

## 配置界面

以下路由按运维人员实际管理的业务对象分组整理，而非按底层代码控制器罗列：

### provider 与模型访问

运行中的 Agent 需要绑定底层模型才能工作。管理员通过 AIGateway 的站点级 Provider 路由与 Agent 级的模型档案（Model Profile）路由完成对接：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/ai-gateway/provider-kinds` | 列出当前实例支持配置的全部 Provider 类型 |
| `GET` | `/api/v2/site/ai-gateway/models` | 列出各 Provider 下附带能力分类的可选模型供控制台表单使用 |
| `GET` | `/api/v2/site/ai-gateway/providers` | 列出已配置的全部模型 Provider |
| `GET` | `/api/v2/site/ai-gateway/providers/:provider_id` | 读取指定 Provider 及其凭据池状态 |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id` | 创建或更新指定 Provider |
| `DELETE` | `/api/v2/site/ai-gateway/providers/:provider_id` | 删除指定 Provider |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials` | 向凭据池新增一个凭据成员 |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | 更新凭据成员属性或重新完成认证 |
| `DELETE` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | 从凭据池移除指定成员 |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id/credential-pool/strategy` | 设置凭据池的成员调度策略 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login` | 发起一次 ChatGPT 设备码登录或浏览器登录会话 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login/poll` | 轮询设备码登录授权状态 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login/browser-callback` | 提交浏览器回跳链接以完成登录 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-enterprise-credentials` | 直接录入 ChatGPT Enterprise 访问令牌 |
| `GET` | `/api/v2/agents/:agent_uid/model-profiles` | 列出指定 Agent 的全部模型档案 |
| `PUT` | `/api/v2/agents/:agent_uid/model-profiles/:profile` | 创建或更新指定名称的模型档案 |
| `DELETE` | `/api/v2/agents/:agent_uid/model-profiles/:profile` | 删除指定的模型档案 |

上游 Provider 的密钥以加密池成员的形式保存在控制面内，绝不会注入 Agent 运行环境。模型档案只需将 Agent 绑定到某条 Provider 记录与模型名，运行时由 AIGateway 在该 Provider 的凭据池内自动挑选健康成员；接口响应仅返回脱敏后的账号标识、健康状态、配额窗口与用量统计。

### agent 及其能力

Agent 是系统的核心工作主体，绝大多数运维配置都围绕它展开：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/agents` | 列出当前租户下的 Agent |
| `POST` | `/api/v2/agents` | 创建新 Agent |
| `GET` | `/api/v2/agents/:agent_uid` | 读取单个 Agent 的详情 |
| `PATCH` | `/api/v2/agents/:agent_uid` | 更新 Agent 属性 |
| `POST` | `/api/v2/agents/:agent_uid/enable` | 重新启用已停用的 Agent |
| `DELETE` | `/api/v2/agents/:agent_uid` | 对启用态 Agent 执行时将其停用；对已停用 Agent 执行时将其永久删除 |

### Worker provider

每个 Agent 在创建时必须指定所属的 Worker Provider，保存后不可更改。Provider 的 YAML 规格配置与加密存储的云平台凭据分开管理，详细的实例生命周期与存储契约见 [工作节点](../worker-management/)。

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/worker-provider-kinds` | 列出支持的 Worker 平台类型、YAML 配置示例与所需凭据 |
| `GET` | `/api/v2/site/worker-providers` | 列出已配置的 Worker Provider |
| `POST` | `/api/v2/site/worker-providers` | 创建新的 Worker Provider |
| `PATCH` | `/api/v2/site/worker-providers/:provider_id` | 更新配置参数或平台凭据 |
| `GET` | `/api/v2/site/worker-providers/:provider_id/check` | 连通性与平台权限自检 |
| `DELETE` | `/api/v2/site/worker-providers/:provider_id` | 删除当前没有任何 Agent 绑定的 Worker Provider |
| `PUT` | `/api/v2/agents/:agent_uid/worker-provider` | 为历史迁移后尚未绑定 Provider 的存量 Agent 补齐指派 |

### 信号路由规则

信号路由规则（在 API Schema 中称为 `Signal Binding`）用于将外部渠道适配器与目标 Agent 连接起来，使外部消息与事件能够送达该 Agent：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/signal-adapters` | 列出当前实例已注册的信号适配器 |
| `GET` | `/api/v2/signal-bindings` | 列出信号路由规则（支持 `?agent=` 按单个 Agent 过滤） |
| `PUT` | `/api/v2/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | 创建或全量替换一条路由规则 |
| `PATCH` | `/api/v2/agents/:agent_uid/signal-bindings/:binding_name` | 局部更新路由规则配置 |
| `DELETE` | `/api/v2/agents/:agent_uid/signal-bindings/:binding_name` | 停用指定路由规则 |
| `GET` | `/api/v2/conversations/:conversation_id/standing-orders` | 读取指定 Conversation 的频道常驻指令 |
| `PUT` | `/api/v2/conversations/:conversation_id/standing-orders` | 替换指定 Conversation 的频道常驻指令 |

停用某条路由规则只会阻止后续新信号继续唤醒关联的 Agent，不会删除规则配置本身。

### Agent Library 能力

能力库的默认开关归属于当前所选租户，单个 Agent 的覆盖配置同样在该租户内生效：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/agent-library/capabilities` | 列出当前租户的能力目录与默认启用状态 |
| `PUT` | `/api/v2/agent-library/agent-plugins/:id` | 设置指定 Agent Plugin 的租户默认开关 |
| `PUT` | `/api/v2/agent-library/skills/:id` | 设置指定 Skill 的租户默认开关 |
| `GET` | `/api/v2/agents/:agent_uid/library-capabilities` | 查询指定 Agent 计算继承后的有效能力集合 |
| `PUT` | `/api/v2/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 为指定 Agent 单独覆盖某个 Plugin 的开关 |
| `PUT` | `/api/v2/agents/:agent_uid/library-capabilities/skills/:id` | 为指定 Agent 单独覆盖某个 Skill 的开关 |
| `GET` | `/api/v2/agents/:agent_uid/library-documents` | 读取指定 Agent 的四份长期设定文档 |
| `PUT` | `/api/v2/agents/:agent_uid/library-documents/:document_kind` | 更新指定类型的长期设定文档 |
| `GET` | `/api/v2/agents/:agent_uid/skill-lessons` | 列出该 Agent 当前生效及已退役的技能教训 |
| `POST` | `/api/v2/agents/:agent_uid/skill-lessons` | 为已启用的 Skill 手动新增人工技能教训 |
| `POST` | `/api/v2/agents/:agent_uid/skill-lessons/:lesson_id/retire` | 将指定技能教训标记为退役 |

能力开关通常先在租户层面设定基准默认值，再按具体 Agent 按需收紧或放行。技能教训则在不改动原始 Skill 文件的前提下，为单个 Agent 附加专属操作指引；查询接口会完整返回支撑证据与退役历史。一旦某条教训退役便不再随回合注入，且由人工手动撤销的教训会进入 Dreaming 的禁学名单以防反复重新生成。完整生命周期与数量上限请参阅[技能教训](../skill-lessons/)。

### 环境变量（WorkerEnv）

`WorkerEnv` 环境变量分为“站点默认值 → 租户覆盖值 → Agent 挂载值”三级。常规查询路由仅返回变量名与元数据；如需查看加密保存的明文值，必须单独调用带审计记录的 `decryptions` 解密接口：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/worker-envs` | 列出站点级默认环境变量 |
| `PUT` | `/api/v2/site/worker-envs/:name` | 设置站点级默认环境变量 |
| `DELETE` | `/api/v2/site/worker-envs/:name` | 删除站点级默认环境变量 |
| `POST` | `/api/v2/site/worker-envs/:name/decryptions` | 审计解密站点级变量明文 |
| `GET` | `/api/v2/worker-envs` | 列出当前租户环境变量 |
| `PUT` | `/api/v2/worker-envs/:name` | 设置租户级环境变量 |
| `DELETE` | `/api/v2/worker-envs/:name` | 删除租户级环境变量 |
| `POST` | `/api/v2/worker-envs/:name/decryptions` | 审计解密租户级变量明文 |
| `GET` | `/api/v2/agents/:agent_uid/worker-envs` | 列出指定 Agent 挂载的环境变量 |
| `PUT` | `/api/v2/agents/:agent_uid/worker-envs/:name` | 为指定 Agent 挂载变量或设置专属覆盖值 |
| `DELETE` | `/api/v2/agents/:agent_uid/worker-envs/:name` | 移除指定 Agent 的变量挂载 |
| `POST` | `/api/v2/agents/:agent_uid/worker-envs/:name/decryptions` | 审计解密 Agent 专属变量明文 |

Agent 挂载变量时既可填写该 Agent 独享的专属值，也可沿用租户级覆盖值或站点默认值。环境变量在新启动 Worker 工作时统一解析注入；已经打开的存量工作区继续保持创建时的环境快照。

### Control Plane Plugin

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/control-plane-plugins` | 列出所有 Control Plane Plugin 及其启用状态 |
| `PUT` | `/api/v2/site/control-plane-plugins` | 切换可选插件在下次启动时的启用状态 |

Control Plane Plugin 是编译进控制面发布包的第一方扩展模块，用于提供信号适配器、身份源适配器、AI Gateway Provider 以及 Worker Provider 等控制面扩展能力。声明为 `activation: :always` 的核心插件随构建常驻启用；而调用 `PUT /api/v2/site/control-plane-plugins` 则用于更新下次重启时生效的 `:optional` 可选插件列表，并会在保存前运行各子系统的 `veto_disable` 安全否决校验，防止意外关停仍被存量资源（如已配置的 Worker Provider）依赖的插件。

### 身份源提供商与 AppConfiguration

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/identity-provider-adapters` | 列出当前实例支持的身份源（IdP）适配器类型 |
| `GET` | `/api/v2/identity-providers` | 列出已配置的身份源提供商 |
| `PUT` | `/api/v2/identity-providers/:provider_id` | 创建或替换指定的身份源配置 |
| `POST` | `/api/v2/identity-providers/:provider_id/sync-runs` | 触发从指定 IdP 同步企业通讯录与组织架构组 |
| `GET` | `/api/v2/site/app-configurations` | 列出站点级 `AppConfiguration` 配置键 |
| `PUT` | `/api/v2/site/app-configurations/:key` | 设置站点级配置值 |
| `POST` | `/api/v2/site/app-configurations/:key/decryptions` | 审计解密站点级敏感配置值 |
| `GET` | `/api/v2/app-configurations` | 列出当前租户级 `AppConfiguration` 配置键 |
| `PUT` | `/api/v2/app-configurations/:key` | 设置租户级配置值 |
| `POST` | `/api/v2/app-configurations/:key/decryptions` | 审计解密租户级敏感配置值 |

`AppConfiguration` 按站点或租户两级作用域存储已声明的运行期系统配置：`/api/v2/site/app-configurations` 管理站点级键，`/api/v2/app-configurations` 管理租户级键，两者均完整支持列表查询、单键读取、写入覆盖、删除恢复默认以及带审计记录的明文解密。至于数据库与对象存储连接等进程引导期参数，则通过进程环境变量或密钥文件挂载（secret mount）注入。

### 租户管理

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/tenants` | 列出站点内的全部租户 |
| `POST` | `/api/v2/site/tenants` | 创建新租户 |
| `PATCH` | `/api/v2/site/tenants/:tenant_id` | 更新租户信息 |
| `DELETE` | `/api/v2/site/tenants/:tenant_id` | 发起租户销毁流程 |
| `POST` | `/api/v2/site/tenants/:tenant_id/suspension` | 暂停冻结指定租户 |
| `DELETE` | `/api/v2/site/tenants/:tenant_id/suspension` | 解除冻结并恢复租户运行 |
| `GET` | `/api/v2/site/privileged-tenant` | 查询当前持有站点管理权的特权租户 |
| `PATCH` | `/api/v2/site/privileged-tenant` | 将站点管理权移交至另一个租户 |

## 读取界面

除配置管理外，Console API 还承担着全系统的运行态可观测查询职责——每个核心子系统都在此暴露了对应的只读或运维视图：

- **活跃会话与定时调度**：`/api/v2/agents/:agent_uid/sessions` 查看会话列表，配合各 Agent 名下的 Cron 定时计划与 Checkback 管理路由（租户级列表端点支持传入 `agent` 参数按单个 Agent 筛选）。
- **Worker 实例状态**：`/api/v2/agent-workers` 列出各 Agent 关联的 Worker 实例就绪与运行状态。
- **Agent 云盘文件**：`/api/v2/agents/:agent_uid/files` 列出与删除云盘文件，`/api/v2/agents/:agent_uid/file-moves` 移动或重命名路径；`POST /api/v2/agents/:agent_uid/files` 通过 `multipart/form-data` 上传文件，`GET /api/v2/agents/:agent_uid/files/content` 下载原始文件字节。这两个原生二进制端点复用完全相同的浏览器会话、CSRF 校验、租户切换与文件权限控制，底层存储由控制面统一托管。
- **后台长任务**：`/api/v2/background-agent-jobs` 支持列表查询、单任务详情读取与任务取消。
- **AI 网关对话记录**：`/api/v2/ai-gateway/conversations` 支持按模型会话回溯完整消息与工具调用明细。
- **主体身份、AuthZ 权限与 OIDC 客户端**：涵盖 `/api/v2/principals`（含成员身份调整 `PATCH /api/v2/principals/:uid/membership`、账号禁用 `POST /api/v2/principals/:uid/access-disables` 与恢复访问 `POST /api/v2/principals/:uid/access-restorations`）、`/api/v2/principal-groups`、`/api/v2/permission-grants` 以及 `/api/v2/oidc-clients`。完整的权限判定规则请参阅 [主体与 AuthZ](../principal-authz/)。

## 关于这里不包含什么

以下三类路由各自采用独立的认证与协议边界，不属于 Console API 范畴：`/webhooks/*` 路由按对应外部平台的签名机制校验事件来源；`/api/v1/ai-gateway/*` 运行时模型路由使用 AIGateway Bearer Token 鉴权；只有 `/api/v2/*` 控制台路由使用本页所述的浏览器会话与 CSRF 校验。

## 下一步

- 了解受 Console 配置驱动的核心运行时模块，请参阅 [AIGateway API](../ai-gateway/)、[Signals](../signals/) 与 [Sessions](../sessions/)。
- 了解支撑 Console 细粒度操作鉴权的权限体系，请参阅 [主体与 AuthZ](../principal-authz/)。
- 若尚未启动 Ankole 实例，请先参阅 [快速开始的部署部分](../quickstart/#deployment)。
