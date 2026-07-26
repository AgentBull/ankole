---
title: Provider 运行时
description: AIGateway 如何把选择符解析到 provider、构建准备好的请求、经 kernel 分发——从模型调用到 provider 响应的三阶段。
section: Developer guide
order: 119
---

一次模型调用在到达 provider 之前经历三阶段：resolver 把选择符变成 provider 运行时 map、provider 模块构建准备好的请求、kernel 的 `UniversalAIClient` 执行它。本页对照 `ai_gateway/resolver.ex`、`providers.ex` 和 `universal_ai_request.ex` 里的真实代码，文档化这条路径。它建立在 [AIGateway](../ai-gateway/) 和[添加 provider](../adding-a-provider/) 之上。

先把决定性的性质说清楚：resolver、provider 模块、kernel 各自拥有一个阶段，互不越界。resolver 拥有选择符到运行时的解析；provider 模块拥有请求准备；kernel 拥有线上。失败的错误来自捕获它的阶段，调用方看到哪个阶段失败了。

## 阶段 1：解析（Resolver）

`Ankole.AIGateway.Resolver` 把请求的 `model` 字段变成具体的 provider 运行时 map。resolver 是主体可见选择符——`primary`、`light`、`embedding.default` 或显式 `provider_id/model`——变成 provider id、provider kind、上游模型名和解析后运行时设置的地方。

LLM 别名（`primary`、`light`、`heavy`、`coding`、`vision_fallback`）通过 agent 的 model profile 解析。Embedding 和 rerank 接受 `default`、显式默认绑定（`embedding.default`）或显式选择符。provider 模块永远看不到选择符或主体——它们只接收解析后的运行时 map。resolver 是唯一咨询主体身份和 model profile 的地方。

解析可能在联系任何 provider 之前失败：

- `422 unknown_model_selector`——该选择符未为该主体绑定。
- `422 model_binding_not_configured`——能力和名称已绑但 provider 行不完整。

这些是[Provider 与模型](../providers-and-models/)告诉运维者去查的错误。

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

各自委托给 `build_prepared_request/4`，它查 provider 的 `ProviderDefinition` 上的能力、确认 provider 支持它（`supports_capability?/2`）、调用能力的 `prepare` 函数——从解析后的设置和请求构建 `UniversalAIRequest` 结构体的普通 Elixir 函数。

这是 provider 差异住的阶段：URL 构造、auth 头、体塑形、特定上游 API 的怪癖。准备好的请求是一个 `UniversalAIRequest`——一个带 path、`api_resolver` atom、头和 provider 选项的结构体——不是一次 HTTP 调用。

## 阶段 3：执行（UniversalAIRequest → kernel）

`UniversalAIRequest` 是从 AIGateway 到 kernel `UniversalAIClient` 的薄执行适配器。其模块文档："provider 模块准备 UniversalAIClient 规格。本模块只执行它，并保持 Phoenix 调用者期望的 HTTP/SSE-ready 边界。"

执行把准备好的请求交给 Rust kernel，后者：

- 把 `api_resolver` 解析到线上协议（编码、传输），
- 打开上游连接（HTTP SSE、EventStream、WebSocket 或纯 JSON，按能力的 `upstream` 声明），
- 带 provider 的 auth 和头发送请求，
- 接收响应流，
- 归一化为下游块格式。

这是 [Kernel](../kernel/) 页文档化的阶段：Rust 里的 `universal_ai_client` 模块，带其传输、需求信用和取消。provider 模块不参与执行；它交接了准备好的请求，kernel 从那里拥有线上。

## 失败如何呈现

每个阶段产出不同类别的错误：

| 阶段 | 失败形态 | 含义 |
|---|---|---|
| 解析 | `422 unknown_model_selector` / `model_binding_not_configured` | 选择符或绑定错——配置问题，非临时 |
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
- 喂给 resolver 的 model profile，读 [Provider 与模型](../providers-and-models/)。
