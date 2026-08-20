---
title: 上下文压缩与 compaction
description: Ankole 如何让长会话保持在模型上下文内——AIGateway 自动历史 compaction 与逐字用户原文保留。
section: Developer guide
order: 116
---

一个跑得长的会话最终会超出模型的上下文窗口。AIGateway 压缩一个回合看到的会话历史，让会话能越过这个上限继续。本页对照 `ai_gateway/compaction*.ex` 里的真实代码说明这一机制。

先说明最关键的一点：compaction *刻意有损，但不沉默*。一次 compaction 用摘要替换旧回合、逐字保留近期回合、并把自身记为会话指向的持久产物。原始回合从模型上下文中消失；摘要成为新的参考状态。compaction 不是你可以还原到原文的缓存。

## AIGateway 历史 compaction

AIGateway 为其有状态 Responses 会话拥有自动历史 compaction。触发、摘要、什么存活，全在 `Ankole.AIGateway.Compaction`。

### 触发

当会话的 token 使用量越过阈值时，compaction 触发。决定使用可见历史中最新一条 provider 返回的用量——每个用量值是累积快照，不是要加上的量。AIGateway 不从内容估算 token 计数；它信任 provider 的用量数。

阈值通过 `ai_gateway.compaction` AppConfigure 键配置：

| 设置 | 默认 | 含义 |
|---|---|---|
| `threshold` | 0.50 | 触发 compaction 的模型输入上下文占比 |
| `max_threshold_tokens` | 120,000 | 对计算后触发阈值的绝对上限，让极大上下文不必等太久 |
| `tail_rows` | 2 | 摘要旁边逐字保留的近期回合数 |
| `user_message_budget_tokens` | 20,000 | 逐字重放用户原文的 token 预算 |

默认按 256k 上下文长度计算。`max_threshold_tokens` 上限存在，让极大上下文的模型不积累太长的历史以致 compaction 本身变贵。小上下文模型通过 `small_context_trigger_ratio`（0.85）更早触发。

### 摘要器做什么

阈值越过时，AIGateway 调一个摘要器模型，为旧回合产出结构化摘要。compaction prompt 把摘要定位为**参考状态而非指令**："不要继续会话。不要回答任何问题。只输出结构化摘要。"摘要捕获意图、决策、错误与修复，并逐字保留文件路径、函数名、错误消息、命令行和 ID——因为被改写的路径或错误是失效的引用。

摘要是会话中最新的旧记录。模型把它看作状态，而不是要继续的回合。

### 什么逐字存活

摘要旁边有两样东西留下：

- **近期回合**（`tail_rows`，默认 2）——最后几个回合完整保留，让模型有所需的即时上下文。
- **逐字用户原文**——`CompactionRetention` 从被压缩的区段里选用户消息，在 `user_message_budget_tokens` 内，逐字重放。这就是模型在被压缩的 assistant 回合后仍能看到"用户要求了 X"的原因。

组合——旧 assistant 工作的摘要 + 逐字近期回合 + 逐字用户原文——让会话继续而不漂移。

### compaction 产物

每次 compaction 产出一个持久的 `CompactionArtifact`，由 AIGateway 存储。会话的历史指向最近的 compaction 作为锚点；后续回合从那里继续。

## 调优

- **抬 `threshold`** 如果你的 agent 工作于短会话、compaction 触发过于频繁。默认（0.50）保守。
- **抬 `tail_rows`** 如果 compaction 后模型丢失即时上下文——更多逐字近期回合，代价是摘要空间更少。
- **抬 `user_message_budget_tokens`** 如果被压缩区段里的用户消息被丢弃、模型丢失所问。

三者都是 AppConfigure 键，通过 Console 改，在下次 compaction 时生效——不在当前回合。

## 本指南不是什么

它不是 prompt 缓存指南——AIGateway 不在此实现 provider 侧 prompt 缓存；那是 provider 的事，支持的 provider 上的 `promptCacheKey` 设置是杠杆。它不是无损历史——compaction 刻意有损，原始回合从模型上下文消失。它也不是更短会话的替代；compaction 让会话越过上下文限制继续，但每隔几个回合就 compaction 的会话，值得拆成 session 或委派给后台任务。

## 下一步

- AIGateway 概念页，读 [AIGateway](../ai-gateway/)。
