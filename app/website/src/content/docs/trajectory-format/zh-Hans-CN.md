---
title: 轨迹与消息格式
description: Ankole 如何存储和投影会话消息与后台任务轨迹——两种存储形态、ChatML 规范形式、剥离协议细节的模型可见投影。
section: Developer guide
order: 121
---

Ankole 在两处、为两种工作记录 agent 做了什么：AIGateway 存储会话消息（有状态 Responses 会话产出的 live 转写），后台 Agent 任务存储回合轨迹（持久任务执行的按回合记录）。本页说明两种存储形态、规范 ChatML 格式、以及剥离协议细节的模型可见投影。它建立在 [AIGateway](../ai-gateway/) 和 [Background Agent Jobs](../background-agent-jobs/) 之上。

先说明最关键的一点：模型永远看不到原始存储行。两种形态都投影到一个模型可见的形式，剥离协议身份、用回合局部调用别名替换——模型看到"工具调用 1 → 工具结果 1"，而非内部 UUID 或线上协议字段。存储形式用于持久和审计；投影形式用于模型。

## AIGateway 会话消息

AIGateway 拥有实时会话转写。每条消息是 `ai_gateway_messages` 里的一行：

| 字段 | 含义 |
|---|---|
| `subject_uid` | 会话所属的主体 |
| `conversation_id` | 该消息所属的会话 |
| `type` | 消息类型（assistant、tool result 等） |
| `role` | 消息在转写中扮演的角色 |
| `status` | 生命周期状态 |
| `previous_message_id` | 自引用续接锚点——在 API 上渲染为 `previous_response_id`，让会话链接 |
| `content` | 消息内容（一个 JSON 值，不是单个字符串） |
| `metadata` | 不透明的调用者元数据加 AIGateway 拥有的响应事实（模型、provider、用量、provider 原始 ID） |

`previous_message_id` 是续接锚点：每条消息指向前一条，产生一条链。在 API 上，它渲染为 `previous_response_id`，使调用者或 compaction 可从任何锚点续接。`metadata` 携带 AIGateway 拥有的事实——使用的模型和 provider、token 用量、provider 原始响应 ID——以及不透明的调用者元数据。它不得携带第二份条目列表。

一次 compaction（见 [上下文压缩与 compaction](../context-compression-and-caching/)）用一条摘要消息替换旧消息，该摘要成为新锚点。旧消息不再在模型的可见上下文里；摘要是新起点。

## 后台 Agent 任务轨迹

后台任务把其按回合执行存为 `background_agent_job_turn_items` 里只追加的语义线程条目流。每个条目属于一个回合，有位置、修订、条目键和语义条目本身：

| 字段 | 含义 |
|---|---|
| `turn_id` | 该条目所属的任务回合 |
| `position` | 条目在回合内的顺序 |
| `revision` | 接受该条目时的回合修订 |
| `item_key` | 条目的稳定键（`client:` 键标记调用者消息） |
| `item` | 一个带类型的语义线程条目 |

这些行只追加：steer 或 nudge 追加新条目，而不改写已存条目。所有读者在读取时把每个已存条目投影成规范 ChatML 消息；投影不出消息的条目仍会保存，用于线程重放。条目流出现之前记录的回合把内容留在旧 `background_agent_job_turn_trajectory_groups` 表里，读者只对这些回合读取已存的组行。

工具结果消息的 metadata 会记录 `execution_mechanism`。模型 Provider 执行的工具使用 `provider_hosted`，Codex 调用的 Ankole 动态工具使用 `local_dynamic`。即使两个工具的展示名相同，这一稳定事实也能区分它们。

这是与 AIGateway 会话消息分开的存储形态，因为后台任务的轨迹属于任务，不属于会话。任务的回合是它们自己的线；它回报的会话收到结果，不是轨迹。

## 模型可见投影

模型看不到存储行。worker 里的 `modelVisibleTrajectory` 把轨迹投影到模型应当看到的：

- **剥离存储的协议身份**——内部消息 id、线上协议字段、任何模型不应据以行动的东西。
- **用回合局部别名替换工具调用 id**——`call_1`、`call_2` 等。模型看到哪个工具结果属于哪个工具调用（唯一有用的关系），无需用来关联的内部 UUID。
- **保留内容和角色**——实际消息、工具调用及其结果，按发生顺序。

模块文档明确："回合局部调用别名保留唯一有用的关系：哪个工具结果属于哪个工具调用。" 存储行携带的其余一切都是给系统的，不是给模型的。

## 两种形态如何关联

| | AIGateway 消息 | 后台任务轨迹 |
|---|---|---|
| 存储什么 | live 会话转写 | 按回合任务执行记录 |
| 谁拥有 | AIGateway | 后台 Agent 任务 |
| 规范格式 | AIGateway 的消息 schema | 语义条目投影为 ChatML |
| 模型如何看到 | 有状态 Responses API | `modelVisibleTrajectory` 投影 |
| Compaction | AIGateway compaction 替换旧消息 | 不压缩（任务受重试预算约束） |

两者不混合。一个会话的消息归 AIGateway；一个任务的轨迹归任务。任务通过唤醒事件（见 [Background Agent Jobs](../background-agent-jobs/)）把结果回报给拥有它的会话，而非写进会话的消息存储。

## 本指南不是什么

它不是 ChatML 规范——规范 ChatML 格式是一个标准，Ankole 的读取投影保持这一形态，不重新定义它。它不是读取轨迹的消费者面向 API——Console 路由（`/ai-gateway/conversations/:id/messages`、`/background-agent-jobs/:id`）是运维界面，见 [Console API 参考](../console-api/)。它也不是存储页的替代；本页是跨两者的格式层视图。

## 下一步

- 会话消息存储，读 [AIGateway](../ai-gateway/)。
- 任务轨迹存储，读 [Background Agent Jobs](../background-agent-jobs/)。
- compaction（替换旧消息），读 [上下文压缩与 compaction](../context-compression-and-caching/)。
- 读取这些的 Console 路由，读 [Console API 参考](../console-api/)。
