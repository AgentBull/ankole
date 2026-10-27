---
title: AIGateway API
description: 兼容 OpenResponses 的统一 AI 网关边界：HTTP、SSE 与 WebSocket 端点、无状态与有状态调用模式，以及 Provider 路由机制。
section: Developer guide
order: 101
---

AIGateway 是 Ankole 实例统一的 AI 调用边界。外部应用、企业业务系统与各类 SDK 可通过这套兼容 OpenResponses 规范的接口发起请求，实例内部的 Agent 同样通过这一入口执行模型推理回合。每次调用到达后，网关都会将请求中的模型选择符解析为管理员配置的 Provider 绑定，上游厂商凭证始终保留在控制面内部。

本页梳理各端点的真实路由、请求格式，以及无状态与有状态调用之间的职责边界。权威实现以控制面路由器和 `Ankole.AIGateway` 模块源码为准，本文作为架构与接口导览。

## 它在哪里

在系统链路中，AIGateway 位于调用方与上游 Provider 之间。调用方（Agent 的模型循环、通过 OIDC 登录的人类用户或外部集成服务）在请求头中携带 Bearer Token，按 OpenResponses 格式发出请求；AIGateway 解析模型选择符、组装上游请求并转发至绑定的 Provider，随后返回单个 JSON 响应或事件流。大语言模型、向量嵌入（Embedding）、重排序（Rerank）、网页搜索与网页抓取全部经过这同一道网关边界。当某轮响应启用了 `programmatic_tool_calling` 时，AIGateway 还会通过 `Ankole.FunctionRuntime.ProgramRunner`，在 `ankole-function-runtime` 服务的无状态隔离实例（isolate）中执行每次 `programmatic_tool_call` 提交的 TypeScript 程序。

最核心的安全原则是：调用方永远接触不到上游 Provider 凭证。控制面集中掌管密钥凭据与路由策略，调用方只需持有自身的访问令牌与模型选择符。

## 鉴权

`/api/v1/ai-gateway` 下的所有端点均经过 `:ai_gateway_api` 管线与 `RequireAIGatewayAccessToken` 插件校验。请求必须在 `Authorization` 请求头中携带 Bearer Token，插件仅接受以下两类令牌：

- **Agent Token**：为某个已启用 Agent 主体签发的 AIGateway API Key。调用范围严格限定在该 Agent 自身的模型绑定与选择符内，`subject_type = "agent"`。
- **OIDC 人类令牌**：由声明了 `ai_gateway.write` 作用域的 OIDC 客户端为活跃人类用户（Human）签发。请求只能使用该客户端公开的模型别名，`subject_type = "oidc_human"`。

获取 OIDC 人类令牌的流程：先在控制台中创建带有 `ai_gateway.write` 作用域的 OIDC 客户端，配置允许访问的权限组与模型别名，再通过授权码加 PKCE 流程完成登录；若需长期调用，可申请 `offline_access` 并配合轮换式 Refresh Token 使用。发起调用的人类用户必须属于客户端允许的权限组，且只能使用客户端配置的模型别名，不得直接传入原始的 `provider_id/model` 选择符。

缺失令牌或令牌验证失败时，接口统一返回 `401`（`code: "invalid_token"`），不提供匿名访问路径。

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"总结当前未关闭的告警。"}'
```

## 端点

所有路由均挂载在 `/api/v1/ai-gateway` 前缀下。每个端点采用哪种传输协议属于硬性接口契约，不可混用：

| 方法 | 路径 | 传输 | 用途 |
|---|---|---|---|
| `GET` | `/models` | HTTP | 列出当前主体可见的模型选择符 |
| `POST` | `/responses` | HTTP 或 SSE | 创建响应；传入 `"stream": true` 时切换为流式输出 |
| `GET` | `/responses` | WebSocket | 有状态的流式响应连接 |
| `GET` | `/responses/:response_id` | HTTP | 读取已保存的有状态响应（`resp_{uuid}`） |
| `POST` | `/embeddings` | HTTP | 生成向量嵌入（Embedding） |
| `POST` | `/rerank` | HTTP | 对文档列表重新排序 |
| `POST` | `/web_search` | HTTP | 搜索公开网页 |
| `POST` | `/web_fetch` | HTTP | 抓取网页正文 |
| `GET/POST/DELETE` | `/files`、`/files/:id`、`/files/:id/content` | HTTP | 上传、读取与删除文件 |

`POST /responses` 是整个网关的核心端点，负责承载模型推理回合，也是唯一会按传输方式与状态持久性分流的路由。

## HTTP 与 SSE 上的无状态响应

无状态调用遵循“一次请求、一次响应”模式：调用方提交完整输入，AIGateway 解析选择符并调用上游 Provider，随后一次性返回完整响应体。若在请求体中设置 `"stream": true`，同一端点会切换为 Server-Sent Events（SSE）：AIGateway 建立事件流，按 `event: <type>\ndata: <json>\n\n` 格式逐条写出带类型的事件，并在结束时输出 `data: [DONE]`。

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"起草一份发布说明。","stream":true}'
```

无状态 HTTP 与 SSE 共守一条硬性规则：一律拒绝 `previous_response_id`、`conversation` 和 `store` 等有状态字段。凡是需要跨回合续接上下文的请求，都必须改走 WebSocket。若在普通 HTTP 或 SSE 请求中携带上述有状态字段，接口会返回 `400`（`code: "stateful_responses_require_websocket"`），并在错误消息中指明具体违规字段。

## WebSocket 上的有状态响应

有状态响应通过向 `GET /responses` 发起 WebSocket 协议升级建立。升级完成后，连接交由 `AIGatewayResponsesSocket` 处理，绑定当前主体身份，并启用消息压缩、30 分钟空闲超时以及 128 MiB 单帧大小上限。由于客户端在等待模型输出期间不会向服务端发送帧，这 30 分钟空闲超时同时也是单次响应的最大允许耗时，与上游模型的首字节及流空闲超时预算保持一致。只有在这条 WebSocket 通道上，调用方才能设置 `store: true`，并通过 `previous_response_id` 或 `conversation` 续接已有对话。

有状态会话的完整持久化生命周期全部由控制面托管：每条已保存的响应都会分配一个形如 `resp_{uuid}` 的 ID，后续回合可通过 `previous_response_id` 续接引用，持久化会话则通过 `conversation` 引用。续接校验、持久化历史、上下文压缩、响应投影与异常恢复均由控制面统一负责，无需调用方自行维护。

落盘后的响应可随时通过无状态纯 HTTP 请求取回：

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses/resp_4f3c... \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN"
```

当已保存的对话历史过长时，上下文压缩是在不丢失关键脉络的前提下缩减历史长度的唯一机制。压缩不设独立端点：只需向 `/responses` 发送输入中带有 `{"type": "compaction_trigger"}` 条目的请求，AIGateway 便会返回一条 `compaction` 类型的输出条目。三种传输方式均支持该操作——普通 `POST /responses` 直接返回响应体，附带 `"stream": true` 时以 SSE 事件流返回，WebSocket 连接同样返回对应事件。若仅发送触发条目，网关会压缩由 `previous_response_id` 或 `conversation` 指定的已存储会话，并在回包中携带可供后续续接的检查点 ID；若连同内联历史记录一并发送，网关则直接压缩请求中传入的内容。

## provider 路由

在发起任何上游请求之前，AIGateway 会先将模型选择符解析到真实的 Provider 绑定。每个 Agent 默认拥有八个内置模型档案：`primary`、`light`、`heavy`、`coding`、`vision_fallback`、`web_search`、`web_fetch` 和 `image_generate`（前五个对应语言模型，后三个对应独立能力），此外还可配置自定义语言模型档案；管理员调用则可使用显式的 Provider 条目。`GET /models` 会列出当前主体能够解析的全部模型，并支持可选的 OpenRouter 风格筛选参数（`q`、`context`、`min_price`、`max_price`、`sort` 及模态过滤）。

每条 Provider 记录内部都拥有一个凭据池。Provider 类型（`provider_kind`）、基础 URL、请求头、连接参数与能力声明由池内全体成员共享；模型档案只指向 Provider 记录本身，从不直接绑定某个具体凭据成员。请求发出前，AIGateway 会按照该 Provider 记录配置的调度策略（`fill_first`、`round_robin`、`least_used` 或 `random`）挑选健康成员——Console 会根据当前界面语言展示本地化策略名，而 API 与底层存储统一使用规范英文键名。对于同一个有状态线程（thread），AIGateway 会尽量固定复用同一个池成员。

遇到可归因于具体凭据的 `429`、`5xx` 或网络传输错误时，系统只会将当次实际发起请求的那把凭据置入冷却状态，随即从池中改选其他成员、重建上游请求，并按带抖动的指数退避策略执行有界重试（Rust 内核每次调用只执行单次网络收发）。如果当前池内已无可用凭据，AIGateway 不会自动切换到其他 Provider。

`chatgpt_subscription` 同样作为一种常规 Provider 类型接入：其 OAuth 凭据保留在控制面内，令牌刷新在 Provider 行锁保护下执行，Agent Computer Worker 与外部调用方都不会接触到这些令牌。

`agentbull_cloud`（**AgentBull Cloud**，默认基础 URL 为 `https://cloudapis.agentbull.com`）是内置的聚合上游 Provider 类型，仅凭一把 API Key 即可同时提供语言模型、向量嵌入、重排序、`web_search`、`web_fetch` 与 `image_generate` 能力。其凭据同样托管在控制面内；至于 Worker 侧 MCP 技能直接读取的外部服务凭据，仍通过 `WorkerEnv` 独立配置。

选择符解析可能因两类配置缺失而失败，调用方应做好处理：

- `422 unknown_model_selector`：当前主体名下未绑定该选择符。
- `422 model_binding_not_configured`：能力与档案名已存在，但 Provider 绑定配置不完整。

此外，若绑定的 Provider 不支持所请求的能力，接口返回 `422 unsupported_capability`；若目标 Provider 已被管理员停用，则返回 `422 provider_disabled`。以上均属于静态配置问题而非瞬时故障，不修改配置直接重试不会生效。

## 错误形态

错误响应统一采用兼容 OpenAI 的 JSON 信封结构 `{"error": {"code", "message"}}`，HTTP 状态码与故障类别一一对应。调用方建议提前针对以下状态码做好处理：

- `400`：请求体校验失败，例如缺少 `model` 或 `input`、`limit` / `top_n` 取值不合法、在普通 HTTP 请求中传入有状态字段，或压缩输入格式有误；`code` 字段会指明具体原因。
- `401`：Bearer Token 缺失或验证未通过。
- `429`：所选 Provider 的凭据池已全部耗尽冷却，错误码为 `credential_pool_exhausted`；若 AIGateway 已知最早恢复时间，响应中会附带 `retry_at`。
- `404`：在当前主体权限范围内找不到指定的已存储响应、会话、Agent 或文件。
- `422`：请求语法合法，但控制面无法提供服务（未知选择符、未完成的绑定、不支持的能力或已停用的 Provider）。
- `502` / `504`：上游 Provider 请求失败。其中 `502` 涵盖网络传输失败与非法上游响应（`upstream_transport_failed`、`invalid_upstream_response`、`ai_gateway_request_failed`），`504` 对应上游超时（`upstream_timeout`）；上游返回的客户端 `4xx` 错误会按其原始状态码透传。

只要上游返回了 `error.message`，AIGateway 就会原样转发该错误说明；否则直接报告上游返回的 HTTP 状态码。

## 编程式工具调用与图像生成

当 `/responses` 请求声明启用 `programmatic_tool_calling` 工具时，AIGateway 会根据当前可用工具描述符自动生成 `program` 工具。每次执行 `programmatic_tool_call` 时，网关都会通过 `Ankole.FunctionRuntime.ProgramRunner` 在 `ankole-function-runtime` 的无状态隔离实例中运行确定性的 TypeScript 程序，并在嵌套工具调用边界处暂停，由 AIGateway 统一维护对话历史、执行顺序与取消操作。

`image_generation` 是公共 Responses 工具，具备两条执行路径：当调用主体配置了 `image_generate` 档案时，AIGateway 使用该档案绑定的独立 Provider 与模型执行生图；未配置该档案时，只有当前主语言模型的 Provider 声明支持原生图像生成，AIGateway 才会将该工具透传给主模型。若两条路径均不具备，请求会在准备阶段直接失败，不会模拟伪造工具。两条路径使用完全一致的公共流式事件与图像持久化逻辑，模型推理用量与生图用量则分别记入实际产出对应内容的凭据名下。

## web 工具、文件，以及其他能力

同一套主体身份与访问令牌也可调用周边能力端点。`POST /web_search` 接收带长度上限的查询词 `query`，返回由 Provider 提供的网页搜索结果；`POST /web_fetch` 接收 1 至 5 个公网 HTTPS URL，返回提取后的网页内容。这两类调用支持传入 `web_search.default` 与 `web_fetch.default`，由 AIGateway 自动解析当前 Agent 对应的模型档案。

`POST /embeddings` 接受纯文本、Token 数组或输入分块；`POST /rerank` 接收非空文档数组与正整数 `top_n` 并对文档重排。这两个端点要求显式传入 `provider_id/model` 选择符，不解析 Agent 档案名。Brain 调用这两项能力时，分别读取 [AppConfigure](../app-configuration/) 中站点级的 `brain.embedding_model` 与租户级的 `brain.rerank_model`。Pod Applet 的 `ctx.ai` 调用则通过 AIGateway 无状态路由执行，复用创建该 Applet 的 Agent 的语言模型档案与配额，并将用量归入该 Agent 名下（该 Agent 必须处于启用状态）。完整的知识检索机制见 [Brain](../brain/)。

文件管理同样作为一等公民提供：`POST /files` 上传文件、`GET /files` 列出文件、`GET /files/:id` 与 `GET /files/:id/content` 读取元数据与文件内容字节、`DELETE /files/:id` 删除文件。所有文件操作均严格按调用主体隔离范围。

## AIGateway 不是什么

AIGateway 不是公开免鉴权的转发代理，也不是供客户端上传厂商 API Key 的透传通道——所有上游凭证都安全保存在控制面内。同时，它也不是异步作业队列或长任务调度器；长时间运行的 Agent 工作归 Sessions 和后台 Agent 任务管理。AIGateway 只守好请求与响应边界：一次请求进入，一个响应或事件流返回，在网关内完成选择符解析，把凭证严密留在控制面内部。

## 下一步

- 了解 AIGateway 在整体架构中的位置，请参阅 [架构概览](../architecture/)。
- 部署运行承载这些路由的服务，请参阅 [快速开始的部署部分](../quickstart/#deployment)。
- 首次配置 Provider 与模型档案，请参阅 [快速开始](../quickstart/#3-添加模型提供商并创建-agent)。
