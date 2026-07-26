---
title: Provider 路由
description: 模型选择符如何解析到 provider——两种选择符形态、解析路径、路由失败时查什么。
section: User guide
order: 46
---

每次模型调用带一个选择符——请求的 `model` 字段，说调用方想要哪个模型。解析器把该选择符变成具体的 provider、模型和到达它的运行时设置。本页是路由如何工作的运维者视角，让你能推理绑定 profile 后调用如何落在对的 provider 上——或没有。

先把决定性的性质说清楚：路由是**选择符→profile→provider**，profile 是运维者控制的中间层。你不把 agent 指向 provider；你把 profile 槽绑到 provider 上的选择符，解析器在调用时从选择符走到 profile 再到 provider。错误的绑定在解析时以 `422` 出现，不是悄悄用了错的模型。

## 两种选择符形态

解析器接受两种选择符形态，取决于能力：

| 能力 | 选择符形态 | 如何解析 |
|---|---|---|
| LLM（`llm`） | 具名别名：`primary`、`light`、`heavy`、`coding`、`vision_fallback` | 通过 agent 的 model profile 解析 |
| 非 LLM（`embedding`、`rerank`、`web_search`、`web_fetch`、`image_generate`） | `default`、`<capability>.default`、或显式 `provider_id/model` | 通过 profile 解析，或显式时直接到 provider |

LLM 别名是运维者通过 model profile 绑定的五个名字。非 LLM 能力接受 `default` 关键词（映射到 agent 的 `embedding`/`rerank`/`web_search`/`web_fetch`/`image_generate` profile）、显式默认绑定如 `embedding.default`、或完全显式的 `provider_id/model` 选择符（绕过 profile 直接到 provider）。

## 解析路径

一个回合调用模型时，解析器走：

1. **读选择符**——从请求的 `model` 字段。
2. **分类能力**——是 LLM 别名，还是非 LLM 能力？
3. **通过 profile 解析**（LLM 别名和 `default` 非 LLM 选择符）——查 agent 该具名槽的 model profile，它指向一个 provider 和一个选择符。
4. **或直接解析**（显式 `provider_id/model` 选择符）——按 id 查 provider 并用具名模型，跳过 profile。
5. **构建运行时 map**——provider id、provider kind、上游模型名、解析后设置。这是 provider 模块的 prepare 函数收到的。

解析器是唯一咨询 agent 身份和 model profile 的地方。provider 模块永远看不到选择符或主体——它收到解析后的运行时 map 并从中准备请求。

## 运维者控制什么

运维者的杠杆是 **model profile 绑定**，不是路由规则。没有路由表可编辑；有 profile 槽可绑：

- **LLM 槽**——`primary`、`light`、`heavy`（必需）、`coding`、`vision_fallback`（可选）。每个槽映射到 provider 行上的一个选择符。见 [Provider 与模型](../providers-and-models/)。
- **非 LLM 槽**——`embedding`、`rerank`、`web_search`、`web_fetch`、`image_generate`（均可选）。同样的映射方式。

发 `primary` 的调用方得到 agent 的 `primary` profile 绑到的任何东西。发 `provider_id/model` 的调用方绕过 profile、直接打 provider——这是外部 API 调用方（通过 AIGateway 的 `/responses` 端点）能在没有 agent profile 的情况下定向到特定模型的方式。

## 路由失败时

路由在解析时失败，在联系 provider 之前：

| 错误 | 含义 | 修复 |
|---|---|---|
| `422 unknown_model_selector` | 该选择符未为这个 agent 绑定 | 绑 profile 槽，或用一个已绑的选择符 |
| `422 model_binding_not_configured` | profile 指向的 provider 不完整 | 修 provider 行的凭证或设置 |
| `422 unsupported_capability` | provider 不提供该能力 | 把槽绑到声明该能力的 provider |

这些是配置错误，不是临时故障。不改配置直接重试产出同样的错误。排查顺序见 [FAQ](../faq/)。

## 本指南不是什么

它不是 provider 编写指南——DSL 和 prepare 函数见[添加 provider](../adding-a-provider/)。它不是解析器内部深入——三阶段路径见 [Provider 运行时](../provider-runtime/)。它不是负载均衡或故障转移指南——Ankole 按 profile 绑定路由，不按健康检查同一槽的多个 provider。

## 下一步

- 如何绑定 profile 槽，读 [Provider 与模型](../providers-and-models/)。
- 解析器内部，读 [Provider 运行时](../provider-runtime/)。
- 错误信封，读 [AIGateway](../ai-gateway/)。
- 各槽的成本杠杆，读[成本管理](../cost-management/)。
