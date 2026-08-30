---
title: AIGateway API
description: OpenResponses 兼容的 AI 边界——HTTP、SSE、WebSocket 端点，无状态与有状态调用，以及 provider 路由。
section: Developer guide
order: 101
---

AIGateway 是 Ankole 实例统一的 AI 边界。外部应用、企业系统和 SDK 通过兼容 OpenResponses 的 API 调用它，内部 Agent 也通过同一入口发起模型回合。每次调用都会把模型选择符解析到运维者配置的 Provider 绑定，上游凭证始终留在控制面。

本页记录的是真实的路由、请求形态，以及无状态与有状态调用之间的边界。事实来源是控制面的路由器和 `Ankole.AIGateway` 模块；本页是地图，不是契约。

## 它在哪里

AIGateway 夹在调用方和 provider 之间。调用方——agent 的模型循环、控制台运维者，或一个外部集成——带上 bearer token，发出一个 OpenResponses 形态的请求。AIGateway 解析选择符，准备好请求，把它分发到绑定的 provider，再返回单个 JSON 响应或一个流。LLM、embedding、rerank、web 搜索、web 抓取，全都走同一个边界。

最关键的一点：调用方永远看不到 provider 凭证。控制面掌握凭证和路由策略，调用方只掌握自己的 token 和选择符。

## 鉴权

`/api/v1/ai-gateway` 下的每个端点都经过 `:ai_gateway_api` 管线和 `RequireAIGatewayAccessToken` 插件。请求必须在 `Authorization` 头里带上 bearer token，插件只接受两类：

- **Agent Token**——以某个已启用 Agent 主体签发的 AIGateway API Key；调用范围只包含该 Agent 的模型绑定和选择符，`subject_type = "agent"`。
- **admin token**——某个活跃人类管理员的控制台 token；调用范围限定在运维者能看到的 provider 视图内，`subject_type = "admin_human"`。

缺失或无法验证的 token 返回 `401`，`code: "invalid_token"`。没有匿名路径。

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"总结当前未关闭的告警。"}'
```

## 端点

所有路由都在 `/api/v1/ai-gateway` 下。一个端点用哪种传输方式，是契约的一部分，不是偏好。

| 方法 | 路径 | 传输 | 用途 |
|---|---|---|---|
| `GET` | `/models` | HTTP | 列出该主体可见的模型选择符 |
| `POST` | `/responses` | HTTP 或 SSE | 创建响应；`"stream": true` 时走流式 |
| `GET` | `/responses` | WebSocket | 有状态的流式响应 |
| `GET` | `/responses/:response_id` | HTTP | 取回一个已存储的有状态响应（`resp_{uuid}`） |
| `POST` | `/embeddings` | HTTP | 生成 embedding |
| `POST` | `/rerank` | HTTP | 对文档重排 |
| `POST` | `/web_search` | HTTP | 搜索网页 |
| `POST` | `/web_fetch` | HTTP | 抓取网页 |
| `GET/POST/DELETE` | `/files`、`/files/:id`、`/files/:id/content` | HTTP | 上传、读取、删除文件 |

`POST /responses` 是整个入口的中心。它承载模型回合，也是唯一会按传输方式和状态分叉的端点。

## HTTP 与 SSE 上的无状态响应

无状态调用就是一次请求、一次响应。调用方发送完整输入，AIGateway 解析选择符，调用 provider，返回完整响应体。设 `"stream": true`，同一个端点就切到 Server-Sent Events：AIGateway 开一条 SSE 流，按 `event: <type>\ndata: <json>\n\n` 写出带类型的事件，最后以 `data: [DONE]` 结束。

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"起草一份发布说明。","stream":true}'
```

无状态的 HTTP 和 SSE 共享一条硬规则：它们拒绝有状态字段 `previous_response_id`、`conversation` 和 `store`。一个请求要跨回合续接，就必须走 WebSocket。在 HTTP 或 SSE 上发送有状态字段，会得到 `400`，`code: "stateful_responses_require_websocket"`，消息里会指出哪个字段不合法。

## WebSocket 上的有状态响应

有状态响应走的是升级为 WebSocket 的 `GET /responses`。升级时把连接交给 `AIGatewayResponsesSocket`，带上主体身份、300 秒空闲超时、压缩，以及 128 MiB 的帧上限。在这条传输上，调用才可以设 `store: true`，并用 `previous_response_id` 或 `conversation` 续接一段已有的会话。

持久的生命周期就在这里。一个被存储的响应会得到形如 `resp_{uuid}` 的 ID。后续回合用 `previous_response_id` 引用它；一段被存储的会话用 `conversation` 引用。续接规则、持久历史、压缩、响应投影和恢复都归控制面管，没有一件是调用方要操心的。

之后用无状态、纯 HTTP 取回一个已存储的响应：

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses/resp_4f3c... \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN"
```

压缩是把一段很长的已存储历史换成较短的一段、又不丢线索的唯一工具。它没有自己的端点：发送输入中带 `{"type": "compaction_trigger"}` 条目的请求，AIGateway 会回一个 `compaction` 输出条目。三种传输都支持——`POST /responses` 直接返回响应体，同一个调用加 `"stream": true` 以 SSE 事件返回，WebSocket 返回同样的事件。只发触发条目时，它压缩 `previous_response_id` 或 `conversation` 指定的已存储会话，回包带着可以继续的检查点 id；连同历史一起发送时，它压缩你发来的内容。

## provider 路由

AIGateway 在任何上游调用之前，先把模型选择符解析到真实的 Provider 绑定。每个 Agent 有八个内置档案：`primary`、`light`、`heavy`、`coding`、`vision_fallback`、`web_search`、`web_fetch` 和 `image_generate`。前五个选择语言模型，后三个选择独立能力。Agent 还可以有自定义语言模型档案。管理员使用显式 Provider 条目。`GET /models` 列出当前主体能够解析的模型，并支持可选的 OpenRouter 风格过滤（`q`、`context`、`min_price`、`max_price`、`sort` 和模态过滤）。

每个 Provider 行拥有一个凭据池。Provider kind、base URL、请求头、设置和能力声明由所有池成员共享。model profile 只指向 Provider 行，从不指定池成员。AIGateway 按该行配置的 `fill_first`、`round_robin`、`least_used` 或 `random` 策略选择健康成员。Console 会根据当前界面语言翻译这些策略名称，API 值和存储值保持不变。AIGateway 会尽量让同一个有状态 thread 使用同一成员。

能归属到具体凭据的 `429`、`5xx` 或传输失败，只会冷却实际发起请求的凭据。AIGateway 改选其他成员、重建 Provider 请求，再按指数退避和抖动做有界重试。Rust kernel 每次只执行一次传输尝试。池为空时，AIGateway 不会切换到另一个 Provider。

`chatgpt_subscription` 是普通 Provider kind。它的 OAuth 凭据留在控制面，token 刷新在 Provider 行锁内执行。Agent Computer 和外部调用方都不会收到这些 token。

解析可能以两种方式失败，调用方应当处理：

- `422 unknown_model_selector`——该选择符没有为这个主体绑定。
- `422 model_binding_not_configured`——能力和名称已绑定，但 provider 绑定不完整。

绑定的 provider 不提供的能力，会以 `422 unsupported_capability` 出现。被运维者禁用的 provider，会以 `422 provider_disabled` 出现。这些都是配置问题，不是临时故障；不改配置直接重试没有用。

## 错误形态

错误使用 OpenAI 兼容的信封。响应体是 `{"error": {"code", "message"}}`，HTTP 状态码与失败类别对应。值得预先规划的几类：

- `400`——请求体验证失败：缺 `model`、缺 `input`、`limit` 或 `top_n` 不合法、HTTP 上出现有状态字段、压缩输入格式不对。`code` 会指出字段。
- `401`——bearer token 缺失或无法验证。
- `429`——所选 Provider 的凭据池已耗尽。错误码是 `credential_pool_exhausted`；若 AIGateway 知道最早恢复时间，错误会带 `retry_at`。
- `404`——对该主体而言找不到某个已存储的响应、会话、agent 或文件。
- `422`——请求格式正确，但控制面无法服务它：未知选择符、未配置的绑定、不支持的能力、被禁用的 provider。
- `502` / `504`——上游 provider 失败。`502` 涵盖传输和无效响应失败（`upstream_transport_failed`、`invalid_upstream_response`、`ai_gateway_request_failed`）；`504` 是 `upstream_timeout`。provider 返回的客户端 `4xx` 会按它自己的状态码透传。

当上游返回了 `error.message` 时，AIGateway 会转发这条消息；否则就如实报告上游的 HTTP 状态码。

## 图像生成

`image_generation` 是公共 Responses 工具，有两条执行路径。主体配置了 `image_generate` 档案时，AIGateway 使用该档案的独立 Provider 和模型执行工具；没有配置时，只有主 Provider 的能力声明支持原生图像生成，AIGateway 才把工具透传给它。两条路径都不存在时，请求准备会直接失败，不会模拟工具。

两条路径使用相同的公共流事件和图像持久化。模型用量与图像用量分别记在实际产出对应内容的凭据上。

## web 工具、文件，以及其他能力

同一个主体和 token 也驱动相邻的能力。`POST /web_search` 接收一个有长度上限的 `query`，返回 Provider 支持的搜索结果；`POST /web_fetch` 接收一到五个公网 HTTPS URL，返回页面内容。这两类调用可以使用 `web_search.default` 和 `web_fetch.default`，由 AIGateway 解析当前 Agent 档案。

`POST /embeddings` 接受文本、token 数组或输入块。`POST /rerank` 对一个非空文档数组重排，并接收一个正整数 `top_n`。这两个端点要求显式 `provider_id/model` 选择符，不会解析 Agent 档案。Brain 调用这些能力时，使用 [AppConfigure](../app-configuration/) 中实例级的 `brain.embedding_model` 和 `brain.rerank_model`。[Brain](../brain/) 说明完整检索行为。

文件是一等公民：`POST /files` 上传，`GET /files` 列出，`GET /files/:id` 和 `GET /files/:id/content` 读取元数据和字节，`DELETE /files/:id` 删除。它们都按主体限定范围。

## AIGateway 不是什么

它不是一个公开、免鉴权的代理。它不是用来发送 provider 凭证的地方——凭证在控制面里。它也不是队列或作业运行器；长时运行的 agent 工作归 Actor Runtime 和后台 Agent 任务。AIGateway 是请求/响应边界：一次调用进来，一个响应或一条流出去，选择符被解析，凭证留在里面。

## 下一步

- 要看 AIGateway 在整个系统里的位置，读 [架构概览](../architecture/)。
- 要运行承载这些路由的服务，读 [快速开始的部署部分](../quickstart/#deployment)。
- 首次配置 Provider 和模型档案，见 [快速开始](../quickstart/#3-添加模型提供商并创建-agent)。
