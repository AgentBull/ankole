---
title: Provider 运行时
description: AIGateway 如何把选择符解析到 provider、构建准备好的请求、经 kernel 分发——从模型调用到 provider 响应的三阶段。
section: Developer guide
order: 119
---

一次模型调用在到达 provider 之前经历三阶段：resolver 把选择符变成 provider 运行时 map、provider 模块构建准备好的请求、kernel 的 `UniversalAIClient` 执行它。本页对照 `ai_gateway/resolver.ex`、`providers.ex` 和 `universal_ai_request.ex` 里的真实代码，文档化这条路径。它建立在 [AIGateway](../ai-gateway/) 和[添加 provider](../adding-a-provider/) 之上。

Resolver、Provider 模块、kernel 各自拥有一个阶段。Resolver 拥有选择符解析、凭据池选择和 OAuth 刷新；Provider 模块拥有请求准备；kernel 拥有一次线上尝试。控制面的 attempt owner 可以改选凭据并重建请求，但 kernel 自己不选择凭据，也不重试。

## 阶段 1：解析（Resolver）

`Ankole.AIGateway.Resolver` 把请求的 `model` 字段变成具体的 provider 运行时 map。resolver 是主体可见选择符——`primary`、`light`、`embedding.default` 或显式 `provider_id/model`——变成 provider id、provider kind、上游模型名和解析后运行时设置的地方。

LLM 别名（`primary`、`light`、`heavy`、`coding`、`vision_fallback`）通过 Agent 的模型档案解析。其中 `coding` 是“后台 Agent 任务”档案沿用至今的持久化键和 API 别名。Embedding 和 rerank 接受 `default`、显式默认绑定（`embedding.default`）或显式选择符。Resolver 是唯一读取主体身份和模型档案的地方。

解析到 Provider 行后，Resolver 选择一份可用凭据。thread 亲和优先于该行的 `fill_first`、`round_robin`、`least_used` 或 `random` 策略。运行时 map 把准确的 credential ID 带到之后每个失败路径。对 ChatGPT 订阅的 OAuth 成员，Resolver 会在 Provider 行锁内刷新接近过期或过久未刷新的 token。永久刷新失败把该成员标成 `dead`，临时失败标成 `exhausted`，两者都会继续选择下一个可用成员。

解析可能在联系任何 provider 之前失败：

- `422 unknown_model_selector`——该选择符未为该主体绑定。
- `422 model_binding_not_configured`——能力和名称已绑但 provider 行不完整。

这些错误分别表示模型档案缺失、Provider 不可用或 Provider 配置不完整。

凭据池没有可用成员是另一类错误。它返回 `credential_pool_exhausted` 和当前各成员的安全状态。只有当前处于冷却的成员有已知未来恢复时间时，错误才带 `retry_at`。

## 阶段 2：准备（Provider 模块 + Providers）

运行时 map 解析好后，`Ankole.AIGateway.Providers` 分发到 provider 模块的 prepare 函数。入口按能力分型：

```elixir
build_response_request(runtime, request)    # :language_model
build_embeddings_request(runtime, request)  # :embedding_model
build_rerank_request(runtime, request)      # :rerank_model
build_web_search_request(runtime, request)  # :web_search
build_web_fetch_request(runtime, request)   # :web_fetch
build_image_generate_request(runtime, request) # :image_generate
```

各自委托给 `build_prepared_request/4`，它查 Provider 的 `ProviderDefinition` 上的能力、确认 Provider 支持它（`supports_capability?/2`）、调用能力的 `prepare` 函数——从解析后的设置和请求构建 `UniversalAIRequest` 结构体的普通 Elixir 函数。准备好的请求会保留一份仅控制面可见的重建上下文，其中带有选中的 credential ID；跨越 native 边界前会删除这份上下文。

这是 provider 差异住的阶段：URL 构造、auth 头、体塑形、特定上游 API 的怪癖。准备好的请求是一个 `UniversalAIRequest`——一个带 path、`api_resolver` atom、头和 provider 选项的结构体——不是一次 HTTP 调用。

## 阶段 3：执行（UniversalAIRequest → kernel）

`UniversalAIRequest` 是从 AIGateway 到 kernel `UniversalAIClient` 的薄执行适配器。Provider 模块准备请求规格；适配器执行它，并保持 Phoenix 调用方需要的 HTTP/SSE-ready 边界。

执行把准备好的请求交给 Rust kernel，后者：

- 把 `api_resolver` 解析到线上协议（编码、传输），
- 打开上游连接（HTTP SSE、EventStream、WebSocket 或纯 JSON，按能力的 `upstream` 声明），
- 带 provider 的 auth 和头发送请求，
- 接收响应流，
- 归一化为下游块格式。

kernel 在成功和失败两条路上返回受限的响应头子集。它包含 `x-codex-*` 限额头族和 `cf-mitigated`，但不包含凭据、cookie 或其他 Provider 请求头。控制面用这个子集计算冷却时间、投影限额并诊断 Cloudflare challenge。

`CredentialAttempts` 包住每次 kernel 尝试。一个能归属的 `429`、`5xx` 或传输失败只标记真正发起该尝试的凭据，然后选择另一个健康成员，重建认证与 Provider 请求头，按指数退避和抖动等待，再让 kernel 执行一次新尝试。只剩一个可用成员时，同一凭据额外重试一次。没有 credential ID 的失败不标记任何成员，并在轮换一圈后停止。所有成员不可用时，attempt owner 返回 `credential_pool_exhausted`，不会切换到另一个 Provider。

这是 [Kernel](../kernel/) 页文档化的阶段：Rust 里的 `universal_ai_client` 模块，带其传输、需求信用和取消。Provider 模块不参与执行。

## 失败如何呈现

每个阶段产出不同类别的错误：

| 阶段 | 失败形态 | 含义 |
|---|---|---|
| 解析 | `422 unknown_model_selector` / `model_binding_not_configured` | 选择符或绑定错——配置问题，非临时 |
| 凭据池 | `429 credential_pool_exhausted` | 所有成员都被禁用、失效或处于冷却；有 `retry_at` 时等待，否则修复凭据池 |
| 准备 | `422 unsupported_capability` / provider 专属校验 | provider 不提供该能力，或请求选项非法 |
| 执行 | `502 upstream_response_failed` / `504 upstream_timeout` | provider 返回错误或超时——可能临时 |

错误类别告诉调用方是修配置（422）、等并重试（502/504）、还是查 provider。[AIGateway](../ai-gateway/) 页文档化了完整错误信封。

## 注册表与 plugin 贡献的 provider

`Providers` 里的 provider 注册表持有编译后的 `ProviderDefinition` 结构体。第一方 provider 编译进来；plugin 贡献的 provider 通过 `ai_gateway.provider` 契约到达，`refresh_from_adapter_declarations/1` 把它们合并进注册表。provider kind 必须匹配 `~r/\A[a-z][a-z0-9_]{0,62}\z/`，注册表缓存合并后的集合，使解析不必每次调用都重扫 plugin。

## 本指南不是什么

它不是 provider 编写教程——DSL、定义和 prepare 函数见[添加 provider](../adding-a-provider/)。它不是线上协议参考——kernel 拥有线上，那是 [Kernel](../kernel/) 页。它也不是读三个模块的替代；本页是穿过它们的路径。

## 下一步

- 如何写 provider，读[添加 provider](../adding-a-provider/)。
- AIGateway 概念页（端点、错误形态），读 [AIGateway](../ai-gateway/)。
- 执行请求的 kernel，读 [Kernel](../kernel/)。
- 首次配置模型档案，读[快速开始](../quickstart/#3-添加模型提供商并创建-agent)。
