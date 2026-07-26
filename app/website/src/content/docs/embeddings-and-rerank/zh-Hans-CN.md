---
title: Embedding 与 rerank
description: embedding 和 rerank 如何工作——两个可选 profile 槽、服务它们的 provider、AIGateway 端点、Brain 召回如何内部使用 embedding。
section: User guide
order: 40
---

Embedding 和 rerank 是 AIGateway 统一边界上与 LLM 并存的两项 AI 能力。它们不是 agent 在回合中直接调用的工具；它们是 AIGateway 通过 API 端点服务的能力，其中 embedding 被 Brain 召回内部使用以查找相关知识。本页是两者的运维者视角。

先把决定性的性质说清楚：embedding 和 rerank 是 **AIGateway API 能力，不是 worker 工具**。它们通过 model profile 槽绑定、通过 `/embeddings` 和 `/rerank` 端点服务、由系统使用（Brain 召回、hosted-tool 准备），而非被模型作为函数调用。

## profile 槽

`embedding` 和 `rerank` 是十个 model profile 槽中的两个，均为可选。只有 `primary`、`light`、`heavy` 必需。部署需要向量搜索时绑 `embedding`（Brain 召回用它）；调用者需要按相关性重排候选文档时绑 `rerank`。不需要就不绑——Brain 召回在 embedding 缺席时优雅降级，只用关键词候选。

如何绑定槽见 [Provider 与模型](../providers-and-models/)。

## 哪些 provider 服务它们

不是每个 provider 都服务 embedding 或 rerank。声明这些能力的 provider：

| Provider | Embedding | Rerank |
|---|---|---|
| Google AI Studio | 是 | — |
| Jina | 是 | 是 |
| OpenRouter | 是 | 是 |

选服务所需能力的 provider，把槽绑到它。不声明该能力的 provider 会以 `unsupported_capability` 拒绝请求。

## AIGateway 端点

两项能力通过 `/api/v1/ai-gateway` 下的专用端点服务：

- **`POST /embeddings`**——接受文本、token 数组或输入块。产出向量 embedding。非法输入形态以 `invalid_embedding_input` 失败。
- **`POST /rerank`**——接受非空文档数组和正整数 `top_n`。按与查询的相关性重排文档。空文档以 `invalid_documents` 失败；非正 `top_n` 以 `invalid_top_n` 失败。

这些是外部调用者通过 AIGateway API 使用的同一端点；它们不独立于统一 AI 边界。

## Brain 如何使用 embedding

Brain 召回通过两条并行候选路径读取知识条目：BM25 关键词候选（经 `pg_search`）和向量候选（经 embedding）。向量候选由调用 `embedding` profile 槽上绑定的 embedding 模型产出，与查询的 embedding 匹配。

`embedding` 槽未绑时，Brain 召回回退为仅关键词候选——它不失败，只失去向量路径。这就是 `embedding` 可选的原因：系统优雅降级，但绑上时向量召回明显更好。

完整召回模型见 [Brain](../brain/)。

## 运维者做什么

- **绑 `embedding`** 当部署使用 Brain（常见情况）。选服务 embedding 的 provider——Jina、OpenRouter 或 Google AI Studio。
- **绑 `rerank`** 仅当调用者需要通过 API 做文档重排。多数部署不需要。
- **留意成本。** Embedding 按调用计价；Brain 召回在每次知识搜索时调用。`embedding` 槽上更便宜的 embedding 模型通常够用——召回质量关乎覆盖，不靠单向量精度。

## 本指南不是什么

它不是向量搜索教程——embedding 和 rerank 端点是标准的，其 API 形态是 provider 的事。它不是 Brain 内部指南——召回模型在 [Brain](../brain/) 文档。它也不是工具参考——agent 的按回合工具集里没有 `embedding` 或 `rerank` 工具。

## 下一步

- profile 槽及如何绑定，读 [Provider 与模型](../providers-and-models/)。
- Brain 如何在召回中使用 embedding，读 [Brain](../brain/)。
- 端点，读 [Console API 参考](../console-api/)和 [AIGateway](../ai-gateway/)。
