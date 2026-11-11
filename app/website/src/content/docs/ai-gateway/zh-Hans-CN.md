---
title: AIGateway API
description: 兼容 OpenResponses 的统一 AI 网关边界：HTTP、SSE 与 WebSocket 端点、无状态与有状态调用模式，以及 Provider 路由机制。
section: Developer guide
order: 101
---

AIGateway 是 Ankole 实例统一的 AI 调用边界。外部应用、企业业务系统与各类 SDK 可通过这套兼容 OpenResponses 规范的接口发起请求，实例内部的 Agent 同样通过这一入口执行模型推理回合。每次调用到达后，网关都会将请求中的模型选择符解析为管理员配置的 Provider 绑定，上游厂商凭证始终保留在控制面内部。

本页梳理各端点的真实路由、请求格式，以及无状态与有状态调用之间的职责边界。权威实现以控制面路由器和 `Ankole.AIGateway` 模块源码为准，本文作为架构与接口导览。

## 它在哪里

在系统链路中，AIGateway 位于调用方与上游 Provider 之间。外部集成、通过 OIDC 登录的人类用户以及 Worker 侧 Agent 模型循环通过 HTTP、SSE 或 WebSocket 携带 Bearer Token 发起请求；控制面内部子系统（如 `Ankole.Brain` 与 `Function Runtime`）则以内置 `system` 主体（`ankole_brain` 与 `system`）在进程内直接调用 `Ankole.AIGateway`。每次请求到达后，AIGateway 解析模型选择符、组装上游请求并转发至绑定的 Provider，随后返回单个 JSON 响应或事件流。大语言模型、向量嵌入（Embedding）、重排序（Rerank）、网页搜索与网页抓取全部经过这同一道网关边界。当某轮响应启用了 `programmatic_tool_calling` 时，AIGateway 还会通过 `Ankole.FunctionRuntime.ProgramRunner`，在 `ankole-function-runtime` 服务的无状态隔离实例（isolate）中执行每次 `programmatic_tool_call` 提交的 TypeScript 程序。

核心原则始终一致：控制面集中掌管上游密钥凭据与路由策略，调用方永远接触不到上游 Provider 凭证，只需提供自身的主体身份与模型选择符。

## 鉴权

`/api/v1/ai-gateway` 下的所有 HTTP 与 WebSocket 端点均经过 `:ai_gateway_api` 管线与 `RequireAIGatewayAccessToken` 插件校验。网络请求必须在 `Authorization` 请求头中携带 Bearer Token，插件仅接受以下两类令牌：

- **Agent Token**：为某个已启用 Agent 主体签发的 AIGateway API Key。调用范围严格限定在该 Agent 生效的模型档案与选择符内，`subject_type = "agent"`。
- **OIDC 人类令牌**：由声明了 `ai_gateway.write` 作用域的 OIDC 客户端为活跃人类用户（Human）签发。请求只能使用该客户端公开的模型别名，`subject_type = "oidc_human"`。

控制面第一方服务（承载企业大脑任务的 `ankole_brain`，以及承载无状态 Pod Applet `ctx.ai` 调用的 `system`）则在 BEAM 进程内直接调用 `Ankole.AIGateway`，无需签发外部 Bearer Token，用量分别记入对应的 `system` 主体 UID 名下。

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
| `POST` | `/decisions` | HTTP | 针对一份状态回答带类型的问题，并给出概率 |
| `POST` | `/images` | HTTP | 生成或编辑一张图片 |
| `POST` | `/audio/speech` | HTTP | 把文本合成为语音 |
| `POST` | `/audio/transcriptions` | HTTP | 把音频转写为文本 |
| `POST` | `/ocr` | HTTP | 把 PDF 或文档图片识别为 Markdown |
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

在发起任何上游请求之前，AIGateway 会通过三层稀疏**模型档案（Model Profile）**继承链（`Site -> Pod -> Agent/System`，在 **Console → Model Profiles** 中配置）将模型选择符解析到真实的 Provider 绑定：

- **站点（Site）、Pod 与 `system` 主体（`ankole_brain`、`system`）**提供十三个固定槽位：五个语言模型槽位（`primary`、`light`、`heavy`、`coding`、`vision_fallback`）与八个独立能力槽位（`web_search`、`web_fetch`、`image_generate`、`rerank`、`decision`、`speech`、`transcription`、`ocr`）。
- **Agent** 提供除 `rerank`、`decision`、`speech`、`transcription` 与 `ocr` 外的八个内置槽位，并支持配置自定义语言模型别名；未单独覆盖的槽位会自动继承 Pod 与站点默认值。
- **跨槽位回退链**按 `coding -> heavy -> primary` 与 `light -> primary` 解析，因此只需在站点或 Pod 层配置好 `primary`，Agent 与企业大脑即可直接运行，再按需为特定 Pod、Agent 或 `system` 主体单独指定模型覆盖。

在权限允许的场景下，管理员与显式内部调用也可直接传入 `provider_id/model` 选择符。调用 `GET /models` 可列出当前主体能够解析的全部模型，并支持可选的 OpenRouter 风格筛选参数（`q`、`context`、`min_price`、`max_price`、`sort` 及模态过滤）。

每条 Provider 记录内部都拥有一个凭据池。Provider 类型（`provider_kind`）、基础 URL、请求头、连接参数与能力声明由池内全体成员共享；模型档案只指向 Provider 记录本身，从不直接绑定某个具体凭据成员。请求发出前，AIGateway 会按照该 Provider 记录配置的调度策略（`fill_first`、`round_robin`、`least_used` 或 `random`）挑选健康成员——Console 会根据当前界面语言展示本地化策略名，而 API 与底层存储统一使用规范英文键名。对于同一个有状态线程（thread），AIGateway 会尽量固定复用同一个池成员。

遇到可归因于具体凭据的 `429`、`5xx` 或网络传输错误时，系统只会将当次实际发起请求的那把凭据置入冷却状态，随即从池中改选其他成员、重建上游请求，并按带抖动的指数退避策略执行有界重试（Rust 内核每次调用只执行单次网络收发）。如果当前池内已无可用凭据，AIGateway 不会自动切换到其他 Provider。

`chatgpt_subscription` 同样作为一种常规 Provider 类型接入：其 OAuth 凭据保留在控制面内，令牌刷新在 Provider 行锁保护下执行，Agent Computer Worker 与外部调用方都不会接触到这些令牌。

`agentbull_cloud`（**AgentBull Cloud**，默认基础 URL 为 `https://cloudapis.agentbull.com`）是内置的聚合上游 Provider 类型，仅凭一把 API Key 即可同时提供语言模型、向量嵌入、重排序、`web_search`、`web_fetch` 与 `image_generate` 能力。其凭据同样托管在控制面内；外部平台连接、成员个人 OAuth 令牌以及 Skill 声明的远程 MCP 鉴权头则由控制面的 `Ankole.Connectors` MCP 网关统一托管在 PostgreSQL 中（`WorkerEnv` 仅供 Agent Computer 内的自定义脚本与 CLI 读取环境变量）。

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

`POST /embeddings` 接受纯文本、Token 数组或结构化输入分块，并要求显式传入 `provider_id/model` 选择符——例如 `Ankole.Brain` 在生成向量嵌入时会读取 [AppConfigure](../app-configuration/) 中站点级的 `brain.embedding_model`。`POST /rerank` 接收非空文档数组与正整数 `top_n` 并对文档重排，既支持显式传入 `provider_id/model`，也支持传入 `default` 或 `rerank.default`（`ankole_brain` 会解析其自身生效的 `rerank` 模型档案，Agent 与人类调用则解析当前 Pod/站点的 `rerank` 档案；完整的知识检索机制见 [Brain](../brain/)）。与此同时，Pod Applet 的 `ctx.ai` 调用以内置 `system` 主体身份通过 `Ankole.AIGateway` 无状态执行，解析 Pod/站点生效的语言模型档案（`primary`、`light`、`heavy`、`coding`、`vision_fallback`），不会占用任何前台 Agent 的 Token 配额。

`POST /web_search` 接收不超过 1,024 个字符的 `query` 和可选的 `limit`（1 到 100，默认 5），返回 `items` 与 `metadata`。每个结果包含 `url`、`title` 和 `description`，Provider 提供时还带有 `published_at` 与 `score`；`metadata` 给出 `query`、网关侧耗时 `latency_ms` 和 HTTP 请求的 `request_id`。`POST /decisions` 针对一份 `state` 回答带类型的问题：一次请求携带 1 到 64 个 `questions`，每个问题是 `noul`（是或否）、`choice`（从 2 到 255 个具名选项中选一个）或 `score`（在 2 到 10 个有序等级上打分），还可以附带最多四张图片，每张不超过 4 MiB。响应为每个问题返回带概率的答案，并给出作答的 `model` 与 token `usage`。`default` / `decision.default` 选择符解析 Pod/Site 的 `decision` 档案；未配置该档案时，改由调用方的 `light` 语言模型作答。语言模型给出的是自述置信度，因此这些概率未经校准；由语言模型作答时，一次请求的选项与等级合计不能超过 500 个。

`decision` 档案可以选择 TypeSafe（`typesafe`，默认地址 `https://api.typesafe.ai/v1`）、使用 Microsoft Foundry 的 Azure OpenAI（`azure_openai`）、OpenRouter（`openrouter`）、OpenAI（`openai`）或 Cloudflare（`cloudflare`）。TypeSafe 的 `base_url` 也可指向其他 SystemOne 兼容端点。Azure Foundry 使用配置的部署名请求 `<resource-root>/providers/microsoft/v1/systemone`，OpenAI 则通过 `gpt-6-luna` 请求 `/decisions`。TypeSafe、Azure Foundry 和 OpenRouter 使用 SystemOne 协议，仅接受 PNG 和 JPEG 图像资产，不接受 WebP；Microsoft-Decision-1 不接受图像。OpenAI Decisions 接受 PNG、JPEG 和 WebP。OpenAI 对任一问题返回拒答时，AIGateway 会拒绝整个请求并返回 `422 upstream_decision_refusal`，不返回残缺答案。

`POST /images` 在对话之外生成或编辑一张图片。请求携带 `model`（`image_generate.default`、`default` 或显式的 `provider_id/model`）、`prompt`、可选的参考图 `images` 与 `mask`，以及 `size`、`quality`、`output_format` 等 `image_generation` 工具选项。请求直接发往所选的图片 Provider：OpenRouter 和 AgentBull Cloud 提供各自目录中的图片模型，Cloudflare 提供 FLUX.1 [schnell] 和 Black Forest Labs 系列模型。响应返回 `created`、`data`（其中一项以 `b64_json` 给出图片并附带 `media_type`）以及 Provider 的 `usage`。AIGateway 会把每次生成的图片和每次决策模型调用记入用量台账；Agent 的 token 配额和 Console 的模型用量页面只统计语言模型轮次。

`POST /audio/speech` 把 `input` 中的文本合成为语音。请求携带 `model`（`speech.default`、`default` 或显式的 `provider_id/model`），还可以指定 `voice`、`response_format`（`mp3` 或 `pcm`，默认 `mp3`）、`speed` 以及描述语气的 `instructions`。响应体就是音频本身，内容类型取 provider 给出的音频类型；provider 没有给出时，`mp3` 对应 `audio/mpeg`，`pcm` 对应 `audio/pcm`。OpenRouter 提供其目录中的语音合成模型；Cloudflare 提供 Deepgram Aura 系列模型，这些模型只返回 MP3，不接受 `pcm`、`speed` 和 `instructions`。`POST /audio/transcriptions` 把音频转写为文本。请求携带 `model`（`transcription.default`、`default` 或显式的 `provider_id/model`）和 `input_audio`，后者包含 base64 编码的 `data`（解码后不超过 25 MiB）与 `format`；还可以附带 `language`、`vad_filter` 开关和 `response_format`（`json` 或 `verbose_json`，默认 `json`）。响应返回 `model`、`text` 和 `usage`，其中 `usage` 给出音频的 `seconds`；选择 `verbose_json` 时，响应还会带上 `language`、`duration` 和带时间戳的 `segments`。OpenRouter 提供其目录中的语音转写模型；Cloudflare 提供接收 base64 音频的 Workers AI 模型，例如 `@cf/openai/whisper-large-v3-turbo`。这两个端点都没有回退：对应档案绑定之前，请求会以 `model_profile_not_configured` 失败。AIGateway 在用量台账中为每次语音合成记录字符数，为每次转写记录音频秒数。

`POST /ocr` 把 PDF 或文档图片逐页识别为 Markdown。请求携带一个 `document`：一份 PDF，或一张 PNG、JPEG、WebP 图片，写成 base64 data URL，或写成带 `content_type` 与 `base64` 的对象。AIGateway 接受不超过 50 MiB 的 PDF 和不超过 20 MiB 的图片，都按解码后的大小计算；OCR 模型自身能接受的范围可能更小。对于 PDF，可以用 `pages` 列出 1 到 100 个互不重复的页码（从 0 开始）；请求省略 `pages` 时，AIGateway 不向 OCR 模型发送页码。响应返回 `model`、`pages` 和 `usage`，`usage` 给出识别的 `pages` 数。`pages` 中的每一项包含 provider 报告的 `index` 与该页的 `markdown`，没有文字的页 `markdown` 为空；AIGateway 按 `index` 升序排列这些页。`default` / `ocr.default` 选择符解析 Pod/Site 的 `ocr` 档案，由 Mistral provider 的 OCR 模型提供服务。未配置该档案时，改由一个支持图片输入的语言模型来读：优先使用调用方的 `vision_fallback` 档案，未配置时使用 `primary`。语言模型只能读一张图片，所以这时传 PDF 会以 `unsupported_value` 失败，请求也按普通语言模型请求计量。AIGateway 在用量台账中为每次 OCR 模型调用记录页数。

文件管理同样作为一等公民提供：`POST /files` 上传文件、`GET /files` 列出文件、`GET /files/:id` 与 `GET /files/:id/content` 读取元数据与文件内容字节、`DELETE /files/:id` 删除文件。所有文件操作均严格按调用主体隔离范围。

## AIGateway 不是什么

AIGateway 不是公开免鉴权的转发代理，也不是供客户端上传厂商 API Key 的透传通道——所有上游凭证都安全保存在控制面内。同时，它也不是异步作业队列或长任务调度器；长时间运行的 Agent 工作归 Sessions 和后台 Agent 任务管理。AIGateway 只守好请求与响应边界：一次请求进入，一个响应或事件流返回，在网关内完成选择符解析，把凭证严密留在控制面内部。

## 下一步

- 了解 AIGateway 在整体架构中的位置，请参阅 [架构概览](../architecture/)。
- 部署运行承载这些路由的服务，请参阅 [快速开始的部署部分](../quickstart/#deployment)。
- 首次配置 Provider 与模型档案，请参阅 [快速开始](../quickstart/#3-添加模型提供商并创建-agent)。
