---
title: 添加 provider
description: 如何声明一个 AIGateway provider——DSL、编译后的定义、设置、能力、prepare 函数、基于 plugin 的注册。
section: Developer guide
order: 115
---

AIGateway provider 是 Ankole 与上游 AI 服务通信的方式——LLM、embedding 模型、web 搜索 API。本页是贡献者 walkthrough：provider DSL、它产出的编译后 `ProviderDefinition`、provider 声明的设置与能力、拥有请求构造的 prepare 函数。它建立在 [AIGateway](../ai-gateway/) 概念页之上；本页是*如何添加一个 provider*。

先把决定性的性质说清楚：provider 模块在 Elixir 里拥有请求准备；Rust `UniversalAIClient` 拥有线上——传输、编码、响应归一化。编译后的定义只描述稳定的元数据、设置、以及哪个 prepare 函数拥有哪种能力。provider 不是完整的 HTTP 客户端；它是一个 prepare 函数加一份声明。

## provider DSL

provider 模块 `use Ankole.AIGateway.ProviderDSL` 并用一个小型块结构 DSL 声明自己。DSL 记录元数据和能力归属；它刻意不描述请求体字段——每个 provider 的 prepare 函数是同一模块里的普通 Elixir 代码。

```elixir
defmodule Ankole.AIGateway.Providers.MyProvider do
  use Ankole.AIGateway.ProviderDSL

  provider :my_provider do
    label(%{"default" => "My Provider"})
    base_url("https://api.example.com/v1")

    setting(:api_key, encrypted: true)

    language_model do
      upstream(:sse)
      api_resolver(:openai_responses)
      prepare(:prepare_language_model)
    end
  end

  def prepare_language_model(context) do
    # 普通 Elixir——从 context 构建准备好的请求
  end
end
```

`provider` 块编译成一个 `ProviderDefinition` 结构体，运行时被 AIGateway 注册表消费。

## 编译后的定义

`ProviderDefinition` 携带：

| 字段 | 含义 |
|---|---|
| `provider_kind` | 存储的 provider 行和模型绑定使用的稳定 id |
| `label` | Console 用的本地化显示名 |
| `module` | provider 模块本身 |
| `base_url` | 默认上游 URL（运维者可覆盖） |
| `settings` | 声明的 `Setting` 列表 |
| `capabilities` | 声明的 `Capability` 列表 |

注册表按 `provider_kind` 解析 provider、查找请求能力种类对应的能力、调用能力的 `prepare` 函数、把结果交给 `UniversalAIClient`。

## 设置

`Setting` 声明一个运维者或请求选项：

```elixir
setting(:api_key, encrypted: true)
setting(:organization, advanced: true)
setting(:reasoningEffort, type: :select, default: "high",
       options: ["minimal", "low", "medium", "high", "xhigh"], scope: :request)
```

| 字段 | 含义 |
|---|---|
| `key` | 选项名（atom） |
| `type` | `:string`、`:select`、`:boolean`、`:map` 或 nil |
| `default` | 默认值 |
| `options` | `:select` 的允许值 |
| `required?` | 运维者是否必须提供 |
| `encrypted?` | 存储元数据——值静态加密；provider 代码读取解密后的值 |
| `advanced?` | Console 表单的呈现元数据；不改变校验或运行时 |
| `scope` | `:connection`（按 provider）或 `:request`（按 model profile） |

`encrypted?` 仅是存储元数据。provider 代码从同一设置 map 读解密后的值；没有单独的凭证抽象。`advanced?` 仅是呈现——它在 Console 里把字段藏到"高级"开关后；不影响校验或行为。

## 能力

`Capability` 把一个用户可见的模型能力绑定到 prepare 函数和线上形态：

```elixir
language_model do
  upstream(:sse)
  api_resolver(:openai_responses)
  prepare(:prepare_language_model)
end
```

| 字段 | 含义 |
|---|---|
| `kind` | `:language_model`、`:embedding_model`、`:rerank_model`、`:web_search`、`:web_fetch`、`:image_generate` 之一 |
| `upstream` | 线上形态：`:sse`、`:eventstream`、`:websocket_text`、`:json` |
| `api_resolver` | Rust 侧的 resolver atom（如 `:openai_responses`），拥有编码和传输 |
| `prepare` | 构建准备好的请求的 Elixir 函数 |
| `timeout_ms` | 可选的按能力超时 |

六种能力映射到运行时使用的外部名：`language_model` → `"llm"`、`embedding_model` → `"embedding"`、`rerank_model` → `"rerank"`，三种 web/image 能力名不变。只提供 LLM 的 provider 只声明 `language_model`；提供 LLM 和 embedding 的 provider 两者都声明。

## prepare 函数

prepare 函数是 provider 模块里的普通 Elixir 代码，由能力的 `prepare` 字段命名。它接收一个 `PrepareContext`（解析后的设置、模型请求、agent 的上下文）并返回一个 `UniversalAIClient` 发送的准备好的请求：

```elixir
def prepare_language_model(%PrepareContext{} = context) do
  %UniversalAIRequest{}
  |> put_url(context.settings.base_url, "/responses")
  |> put_auth("Bearer", context.settings.api_key)
  |> put_body(context.request)
end
```

provider 的差异住在这里——URL 构造、auth 头、体塑形、特定上游 API 的怪癖。prepare 函数是 provider 的实际工作；DSL 声明只是这些工作如何被发现和路由。

## 注册 provider

第一方 provider 编译进发布、被注册表发现。对于 plugin 贡献的 provider，在一个 Control Plane Plugin 的 `adapter_declarations/0` 里通过 `ai_gateway.provider` 契约声明，注册表从 plugin 的声明里捡起它——与 signal adapter 同一模型，不同契约 id。

Plugin 的注册方法见[开发 Skill 与 Control Plane Plugin](../writing-a-skill/)；Provider 契约是 `ai_gateway.provider`，kind ID 必须匹配 `~r/\A[a-z][a-z0-9_]{0,62}\z/`。

## 本指南不是什么

它不是 HTTP 客户端教程——prepare 函数构建准备好的请求，Rust 客户端做 HTTP。它不是绕过 kernel 传输的途径；`api_resolver` 和 `upstream` 线上形态是 Rust `UniversalAIClient` 拥有的东西，provider 从已有 resolver 里选，而非发明自己的传输。它也不是读已有 provider 的替代；`lib/ankole/ai_gateway/providers/` 是权威参考，最简单的一个（OpenAI 或 openai_compatible）是正确的起点。

## 下一步

- AIGateway 概念（路由、解析、统一边界），读 [AIGateway](../ai-gateway/)。
- Plugin 注册方法，读[开发 Skill 与 Control Plane Plugin](../writing-a-skill/)。
- 首次配置 Provider，读[快速开始](../quickstart/#3-添加模型提供商并创建-agent)。
