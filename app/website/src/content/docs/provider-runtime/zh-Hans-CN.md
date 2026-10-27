---
title: Provider 运行时
description: AIGateway 如何将模型选择符解析为提供商运行时配置、构造请求并经由 Rust Kernel 分发——详解从模型调用到上游响应的三阶段流水线。
section: Developer guide
order: 119
---

在 Ankole 中，一次模型调用从发起到触达上游提供商，会依次经历三个阶段：首先由 Resolver 将模型选择符解析为提供商运行时映射（Map），接着由对应的提供商模块组装就绪请求，最后交由 Rust Kernel 中的 `UniversalAIClient` 完成网络传输。本文结合 `ai_gateway/resolver.ex`、`providers.ex` 与 `universal_ai_request.ex` 的源码实现，梳理这条执行链路。阅读前建议先了解 [AIGateway](../ai-gateway/) 与 [添加 provider](../adding-a-provider/)。

Resolver、提供商模块与 Rust Kernel 各司其职，分别掌控其中一个阶段：Resolver 负责选择符解析、凭据池调度与 OAuth 令牌刷新；提供商模块负责构造特定厂商的请求载荷；Rust Kernel 则只负责执行单次网络收发。遇到可重试故障时，控制面的重试协调器（Attempt Owner）可以换用其他凭据并重新构造请求，但 Kernel 自身既不挑选凭据，也不发起重试。

## 阶段 1：解析（Resolver）

`Ankole.AIGateway.Resolver` 负责将调用方传入的 `model` 字段解析为具体的提供商运行时 Map——将主体可见的逻辑选择符（如 `primary`、`web_search.default` 或显式的 `provider_id/model`）转换为确定的提供商 ID、提供商类型（kind）、上游模型名称以及合并后的运行时参数。

每个 Agent 都拥有八个内置模型档案：`primary`、`light`、`heavy`、`coding`、`vision_fallback`、`web_search`、`web_fetch` 与 `image_generate`（其中 `coding` 是控制台界面中“后台 Agent 任务”档案在 API 与存储层对应的字段名）。前五个档案绑定语言模型，后三个档案则分别对应网页搜索、网页抓取与图像生成能力。

向量嵌入（Embedding）与重排（Rerank）不属于 Agent 级档案；直接通过 AIGateway 调用这两项能力时，必须传入显式的 `provider_id/model` 选择符。Brain 则分别从 [AppConfigure](../app-configuration/) 的 `brain.embedding_model` 读取站点级嵌入模型、从 `brain.rerank_model` 读取租户级重排模型，具体检索机制见 [Brain](../brain/)。

锁定目标提供商记录后，Resolver 会从凭据池中挑选一份可用凭据。若当前对话线程已建立凭据亲和（Thread Affinity），则优先沿用原凭据；否则按该提供商配置的 `fill_first`、`round_robin`、`least_used` 或 `random` 策略选取。生成的运行时 Map 会携带精确的凭据 ID，贯穿后续每一条错误处理路径。对于采用 ChatGPT 订阅 OAuth 登录的凭据池成员，若令牌临近过期或距上次刷新过久，Resolver 会在提供商行级锁的保护下先行刷新令牌：一旦遭遇不可恢复的永久刷新失败，便将该成员标记为 `dead`；若是暂时性失败则标记为 `exhausted`，两种情况下都会继续顺延挑选池内下一个健康成员。

如果绑定关系缺失或配置不完整，请求在解析阶段就会提前中止，不会发起任何外部网络请求：

- `422 unknown_model_selector`：当前主体名下未绑定该模型选择符；
- `422 model_binding_not_configured`：能力与档案名称虽已绑定，但关联的提供商记录配置不完整。

上述错误通常意味着模型档案未配置、目标提供商不可用或参数漏填。

若提供商配置无误，但凭据池中所有成员均不可用，则会触发另一类错误：返回 `credential_pool_exhausted` 及各成员当前的脱敏状态；仅当池中存在处于冷却期且恢复时间已知的成员时，响应中才会附带 `retry_at` 字段。

## 阶段 2：准备（Provider 模块 + Providers）

拿到解析后的运行时 Map 后，`Ankole.AIGateway.Providers` 会按所调用的能力类型分发至对应提供商模块的请求构造函数：

```elixir
build_response_request(runtime, request)    # :language_model
build_embeddings_request(runtime, request)  # :embedding_model
build_rerank_request(runtime, request)      # :rerank_model
build_web_search_request(runtime, request)  # :web_search
build_web_fetch_request(runtime, request)   # :web_fetch
build_image_generate_request(runtime, request) # :image_generate
```

这六个入口内部统一委托给 `build_prepared_request/4`：先查阅该提供商 `ProviderDefinition` 上的能力声明，调用 `supports_capability?/2` 确认支持该能力，再执行对应的 `prepare` 纯 Elixir 函数，根据解析后的配置与调用入参组装出 `UniversalAIRequest` 结构体。此时生成的请求对象还会附带一份仅对控制面可见的重建上下文（内含本次选中的凭据 ID），并在跨越 NIF 边界传入 Rust 之前将其剥离。

不同上游厂商的协议差异全部收敛在这一阶段处理，包括请求 URL 拼接、认证请求头注入、请求体构造以及特定上游 API 的兼容适配。需要注意，此阶段产出的 `UniversalAIRequest` 只是包含请求路径、`api_resolver` 原子（atom）、请求头与提供商选项的纯数据结构，尚未真正发起任何网络调用。

## 阶段 3：执行（UniversalAIRequest → kernel）

`UniversalAIRequest` 充当了从 Elixir AIGateway 通往底层 Rust Kernel `UniversalAIClient` 的轻量级执行适配层：提供商模块负责定义请求规格，适配层则将其移交底层执行，并向上游 Phoenix 调用方维持可直接用于 HTTP/SSE 流式输出的边界。

进入执行阶段后，就绪请求被传入 Rust Kernel，由后者依次完成：

- 将 `api_resolver` 映射为具体的传输协议与编解码格式；
- 按能力声明中的 `upstream` 类型建立上游连接（支持 HTTP SSE、EventStream、WebSocket 或普通 JSON 响应）；
- 携带组装好的提供商认证信息与请求头发出请求；
- 流式接收上游返回数据；
- 将异构上游响应统一归一化为标准的下游数据块（Chunk）格式。

无论请求成功还是失败，Kernel 都会向控制面回传经过严格白名单裁剪的响应头子集——仅保留 `x-codex-*` 限流头系列与 `cf-mitigated`，彻底剥离凭据、Cookie 及其他提供商私有响应头。控制面依靠这组安全子集计算凭据冷却窗口、推算剩余配额并识别 Cloudflare 质询拦截。

每次 Kernel 调用外层都由 `CredentialAttempts` 协调器包裹。一旦发生可明确归因于某份凭据的 `429`、`5xx` 或传输层故障，协调器只会精准标记本次实际发起请求的凭据，随后从池中另选一个健康成员，重新构造认证信息与提供商请求头，经过带随机抖动的指数退避等待后交由 Kernel 发起新一轮尝试；若池中仅剩唯一可用成员，则对该凭据额外重试一次。对于不含凭据 ID 的故障，系统不会误标任何成员，并在轮询完一圈后终止重试。倘若池内所有成员均已不可用，协调器便直接返回 `credential_pool_exhausted`，绝不会擅自跨提供商回退到其他厂商。

这一阶段的底层实现即 [Kernel](../kernel/) 文档介绍的 Rust `universal_ai_client` 模块（涵盖网络传输、按需拉取背压控制与请求取消），Elixir 侧的提供商模块全程不介入网络收发。

## 失败如何呈现

流水线的各个阶段会映射为语义分明的 HTTP 错误类别：

| 所属阶段 | 错误形态 | 含义与处置方式 |
|---|---|---|
| 解析阶段 | `422 unknown_model_selector` / `model_binding_not_configured` | 选择符未绑定或提供商配置残缺——属于确定性配置错误，重试无效，需修正配置 |
| 凭据池调度 | `429 credential_pool_exhausted` | 池内所有凭据均已停用、失效或处于冷却期；若带有 `retry_at` 可按提示等待，否则需排查并补充凭据 |
| 准备阶段 | `422 unsupported_capability` / 提供商专属参数校验错误 | 目标提供商不支持所请求的能力，或传入了非法的请求参数 |
| 执行阶段 | `502 upstream_response_failed` / `504 upstream_timeout` | 上游提供商返回服务端错误或响应超时——通常属于暂时性故障 |

调用方只需观察错误状态码即可决定下一步动作：收到 `422` 应检查并修复配置或入参，收到 `502`/`504` 可退避等待后重试，收到 `429` 则核查凭据池配额。完整的错误响应信封格式见 [AIGateway](../ai-gateway/)。

## 注册表与 plugin 贡献的 provider

`Providers` 模块维护着一份保存编译后 `ProviderDefinition` 结构体的内存注册表：内置的第一方提供商随代码直接编译载入；由插件扩展提供的提供商则通过 `ai_gateway.provider` 契约接入，由 `refresh_from_adapter_declarations/1` 合并写入注册表。所有提供商的 `kind` 标识均须匹配正则表达式 `~r/\A[a-z][a-z0-9_]{0,62}\z/`。注册表会缓存合并后的完整集合，避免每次解析模型请求时重复扫描插件列表。

## 本指南不是什么

- **不是提供商开发教程**：如需了解声明式 DSL、能力定义与 `prepare` 函数的具体写法，请参阅 [添加 provider](../adding-a-provider/)。
- **不是底层网络协议规范**：传输层细节归属 Rust Kernel，详见 [Kernel](../kernel/)。
- **不替代直接阅读源码**：本文旨在串联 `resolver.ex`、`providers.ex` 与 `universal_ai_request.ex` 之间的调用脉络，具体细节仍以源码为准。

## 下一步

- 了解如何编写自定义提供商模块，请参阅 [添加 provider](../adding-a-provider/)。
- 查看 AIGateway 的公开端点与错误信封规范，请参阅 [AIGateway](../ai-gateway/)。
- 了解负责实际网络传输的 Rust 模块，请参阅 [Kernel](../kernel/)。
- 首次为 Agent 配置模型档案，请参阅 [快速开始](../quickstart/#3-添加模型提供商并创建-agent)。
