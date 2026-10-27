---
title: 添加 provider
description: 如何声明 AIGateway Provider：DSL 语法、编译产物、配置项、模型能力、prepare 函数与插件注册机制。
section: Developer guide
order: 115
---

Ankole 通过 AIGateway Provider 与各类上游 AI 服务（大语言模型、向量嵌入模型、网页搜索接口等）通信。本页建立在 [AIGateway](../ai-gateway/) 架构概念之上，面向代码贡献者完整说明*如何新增一个 Provider*，依次介绍 Provider DSL、编译生成的 `ProviderDefinition`、配置项与模型能力声明，以及负责组装请求的 `prepare` 函数。

先明确最关键的职责边界：Elixir 侧的 Provider 模块只负责组装请求参数；底层的网络传输、协议编码与响应归一化全部由 Rust 侧的 `UniversalAIClient` 承担。编译后的定义仅记录静态元数据、配置项，以及哪项模型能力由哪个 `prepare` 函数负责。换言之，Provider 并不是一套完整的 HTTP 客户端，而只是一份声明外加一个请求组装函数。

## provider DSL

Provider 模块通过 `use Ankole.AIGateway.ProviderDSL` 引入一套精简的块状 DSL 来完成声明。这套 DSL 只登记元数据与能力映射，刻意不涉及具体的请求体字段——请求体的构造直接由同一模块内的普通 Elixir `prepare` 函数实现。

```elixir
defmodule Ankole.AIGateway.Providers.MyProvider do
  use Ankole.AIGateway.ProviderDSL

  provider :my_provider do
    label(%{"default" => "My Provider"})
    base_url("https://api.example.com/v1")

    setting(:api_key, encrypted: true, scope: :credential)

    language_model do
      api_resolver(:openai_responses)
      prepare(:prepare_language_model)
      supports_parallel_tool_calls()
    end
  end

  def prepare_language_model(context) do
    # 普通 Elixir 代码：根据 context 组装待发送的请求
  end
end
```

编译时，`provider` 块会展开为一个 `ProviderDefinition` 结构体，供 AIGateway 注册表在运行时读取。

## 编译后的定义

`ProviderDefinition` 包含以下字段：

| 字段 | 含义 |
|---|---|
| `provider_kind` | 数据库中保存的 Provider 记录与模型绑定所使用的稳定标识 |
| `label` | 在 Console 中展示的本地化显示名称 |
| `module` | Provider 所在的 Elixir 模块 |
| `base_url` | 默认上游服务地址（管理员可在配置时覆盖） |
| `settings` | 声明的 `Setting` 配置项列表 |
| `capabilities` | 声明的 `Capability` 能力列表 |

运行时，注册表先按 `provider_kind` 找到对应的 Provider，再按所需能力类型匹配对应的 `Capability`，调用其指定的 `prepare` 函数组装出请求结构体，最后交由 `UniversalAIClient` 发送。

## 设置

每条 `Setting` 用于声明一项管理员连接参数或模型请求选项：

```elixir
setting(:api_key, encrypted: true, scope: :credential)
setting(:organization, advanced: true)
setting(:reasoningEffort, type: :select, default: "high",
       options: ["minimal", "low", "medium", "high", "xhigh"], scope: :request)
```

| 字段 | 含义 |
|---|---|
| `key` | 配置项键名（atom） |
| `type` | `:string`、`:select`、`:boolean`、`:map` 或 `nil` |
| `default` | 默认值 |
| `options` | `:select` 类型的可选值列表 |
| `required?` | 管理员是否必填 |
| `encrypted?` | 存储元数据，标记该凭据值是否需要静态加密落盘 |
| `advanced?` | Console 表单展示标记，仅影响界面呈现，不改变参数校验或运行时行为 |
| `scope` | 作用域：`:credential`（按凭据池成员）、`:connection`（按 Provider 记录）或 `:request`（按模型档案） |

每条 Provider 记录都配有一个凭据池（哪怕池中只有一个成员）。调用 `prepare` 函数前，解析器会先从池中选出一个健康的凭据成员，并解密其 `:credential` 作用域的配置；端点地址、自定义请求头等 `:connection` 配置由整条 Provider 记录共用；`:request` 配置则取自具体的模型档案（Model Profile）。这三类配置会合并进同一个 `settings` 映射传给 `prepare` 函数，因此 `prepare` 函数只需直接按键读取，无需自行实现凭据池调度。

`advanced?` 仅控制界面呈现，用于在 Console 表单中将该字段收纳进「高级设置」折叠区，不影响校验规则或运行时逻辑。

## 能力

每条 `Capability` 将一项用户可见的模型能力绑定到对应的 `prepare` 函数与底层传输形态：

```elixir
language_model do
  api_resolver(:openai_responses)
  prepare(:prepare_language_model)
  supports_parallel_tool_calls()
  supports_native_image_generation()
end
```

| 字段 | 含义 |
|---|---|
| `kind` | 能力种类，取值为 `:language_model`、`:embedding_model`、`:rerank_model`、`:web_search`、`:web_fetch`、`:image_generate` 之一 |
| `upstream` | 上游传输形态，由 `kind` 自动决定：`:language_model` 为 `:sse`，其余种类均为 `:json` |
| `api_resolver` | Rust 侧负责协议编码与网络传输的解析器标识（atom，如 `:openai_responses`） |
| `prepare` | 负责组装请求的 Elixir 函数名 |
| `timeout_ms` | 可选的单能力超时时间（毫秒） |
| `supports_parallel_tool_calls?` | 该 Provider 是否支持并行工具调用 |
| `supports_native_image_generation?` | 未单独配置托管 `image_generate` 档案时，该大语言模型能否直接执行通用图像生成工具 |

上述六种能力在运行时分别映射为以下外部名称：`language_model` → `"llm"`、`embedding_model` → `"embedding"`、`rerank_model` → `"rerank"`，其余三种网页与图像能力名称保持不变。仅提供大语言模型的 Provider 只需声明 `language_model`；同时提供大语言模型和向量嵌入服务的 Provider 则将两者一并声明。

## prepare 函数

`prepare` 函数是编写在 Provider 模块中的普通 Elixir 函数，函数名由 `Capability` 的 `prepare` 字段指定。该函数接收 `PrepareContext`（内含解析合并后的配置项、模型请求参数及 Agent 上下文），返回组装完毕的 `UniversalAIRequest`，交由 `UniversalAIClient` 执行网络发送：

```elixir
def prepare_language_model(%PrepareContext{} = context) do
  %UniversalAIRequest{}
  |> put_url(context.settings.base_url, "/responses")
  |> put_auth("Bearer", context.settings.api_key)
  |> put_body(context.request)
end
```

不同上游厂商的接口差异全部收敛在这里处理，包括 URL 拼接、鉴权请求头、请求体格式转换以及特定上游 API 的兼容规则。可以说，`prepare` 函数承担了 Provider 的实质工作，而 DSL 声明则决定了这套逻辑如何被系统发现和路由。另外，凭据故障切换不在 `prepare` 函数内处理：一旦传输失败，控制面可以从凭据池中改选其他成员，重新调用 `prepare` 组装请求，再让 Rust 内核发起一次新的传输尝试。

## 注册 provider

官方内置的第一方 Provider 直接随发布包编译，由注册表自动发现。对于通过插件扩展的 Provider，可在 Control Plane Plugin 的 `adapter_declarations/0` 中按 `ai_gateway.provider` 契约声明，注册表会从中自动读取并完成注册——这套机制与信号适配器（Signal Adapter）采用同一模型，仅契约 ID 不同。

插件的详细注册方式请参阅 [开发 Skill 与 Control Plane Plugin](../writing-a-skill/)；Provider 的契约标识为 `ai_gateway.provider`，其 `provider_kind` 必须匹配正则表达式 `~r/\A[a-z][a-z0-9_]{0,62}\z/`。

## 本指南不是什么

本页不是 HTTP 客户端编写教程——`prepare` 函数只负责组装请求参数，真正的 HTTP 收发由 Rust 客户端完成。同时，Provider 也不能绕过内核传输层自行实现网络通信：`api_resolver` 与 `upstream` 传输形态均由 Rust 侧的 `UniversalAIClient` 统一提供，新增 Provider 时应从现有解析器中选用，而非另造传输通道。最后，本文档不能替代阅读现有源码：`lib/ankole/ai_gateway/providers/` 目录下的内置实现才是最权威的参考，建议从结构最简单的 OpenAI 或 `openai_compatible` 模块读起。

## 下一步

- 了解 AIGateway 的路由、解析与统一网关边界，请参阅 [AIGateway](../ai-gateway/)。
- 了解插件注册方式，请参阅 [开发 Skill 与 Control Plane Plugin](../writing-a-skill/)。
- 首次在控制台中配置模型提供商，请参阅 [快速开始](../quickstart/#3-添加模型提供商并创建-agent)。
