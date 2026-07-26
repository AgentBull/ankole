---
title: 记忆
description: Ankole agent 如何读写长期记忆——Brain 工具（memory_search、memory_open、memory_update、memory_browse、memory_health_check）、何时使用、human/agent/dreaming 写权限模式，以及运维如何通过在会话上声明 Brain scope 来启用记忆。
section: User guide
order: 33
---

记忆是 Ankole agent 把学到的东西跨回合、跨会话留下来的方式。它是一组 worker 工具，源在 `app/agent_computer/src/tools/memory/memory-tools.ts`，通过 AIGateway 读写 [Brain](../brain/) 子系统。本页是运维视角：这些工具是什么、agent 何时调用、记忆怎么定范围、你如何为一个会话开启它。

先把决定性的性质说清楚：Brain 记忆是持久真相，agent 的工作记忆——当前回合的上下文——是易失的。agent 下周还记得的东西，存在 Brain 的策展知识里，在 PostgreSQL 中，不在会话记录里。如果 agent 没把它写进 Brain，它就没记住。

## 记忆是什么

agent 没有一个通用的"记住"按钮。它有五个职责明确的工具，都定义在 `app/agent_computer/src/tools/memory/memory-tools.ts`：

- **`memory_search`**（第 231 行）——搜索 Brain 知识。agent 传一个 query 和 layer（`chat`、`knowledge` 或 `all`），拿回排序后的证据。description 告诉模型：信任空结果前先看 `status`、`result_completeness` 和 `degraded_reasons`，因为不完整的空结果并不能证明没有匹配。
- **`memory_open`**（第 263 行）——按规范名或别名打开并读取一条策展知识条目，返回永久块位置和语义关系。
- **`memory_update`**（第 290 行）——对一条策展条目施加恰好一个结构化变更。这是写路径，需要写权限。控制面从本回合打开的条目推导 owner、store、author 和并发栅栏。
- **`memory_browse`**（第 316 行）——逐页浏览精确、未受信的聊天消息或留存的外部材料，用 search 返回的 `source_N` 别名展开。
- **`memory_health_check`**（第 344 行）——读人类 Console 读的同一份状态：管道失败、embedding 积压、memo 预算、策展 lint。它是诊断索引，不是裁决，description 告诉 agent 不要自动跑它。

这些工具是 agent 触达长期记忆的唯一界面。Brain 本身——embedding、dreaming、source 留存、策展——是它们背后的子系统，见 [Brain](../brain/) 开发者页。

## agent 何时使用记忆

这些工具不是每个回合都调。agent 在当前回合上下文不足以给出答案，或者新状态、确切出处重要时才调用。具体地：

- **`memory_search`**——agent 需要一个事实、一个先前决定、一句引用到的原话，而工作上下文里没有，或者必须标明某个说法来自哪里时。
- **`memory_open`**——任何更新之前。工具 description 写着"更新前立即打开每条条目和每个块"，所以 agent 绝不盲改。
- **`memory_update`**——记录值得留的持久事实：一个决定、一个更正后的理解、一条新的自我知识。对易失状态（agent 此刻在做什么、任务中途的工具失败），会话记录就够了，写进 Brain 只会挤占持久知识。
- **`memory_browse`**——重读某条引用背后的原始消息，或扫一页 search 翻出来的原始聊天。
- **`memory_health_check`**——只在做有意的复盘时。`brain-review` skill 就是干这个的，且只在人类明确要求复盘、审计、清理、或 复盘 agent 的记忆时才跑。

关键区分：Brain 存放必须熬过这次会话的知识。工作记忆——回合上下文——服务于本回合。把每个一闪而过的念头都写进 Brain 的 agent，只会让持久库更吵，不会更聪明。

## 记忆如何定范围

每次读写都流经一个 Brain scope，而这个 scope 只从 AIGateway 会话上的声明推导——`conversation.metadata["brain"]`。任何频道事件、provider 元数据、运行时环境状态都不作为兜底。一个 scope 带 `owner_uid`、一组 `readable_store_keys`、一个 `writable_store_key` 和 `current_channel`。

这把权限边界放在会话声明上，运维看得见也改得了。公开群组的默认 store 是 `shared`；私聊默认 `dm:<uid>`；保密频道用 `channel:<id>`。agent 绝不显式传 `current`、`shared`、`dm:<uid>` 或 `channel:<id>`——控制面自己推导。agent 唯一能做的显式选择是 `self`，用于关于这个 agent、且必须跨会话生效的知识：它自己的运行规则、skill、自我认知。

## 写权限：谁能写什么

一次对策展知识的写入带一个权限模式，模式记在行上。这些模式来自 Brain Knowledge 模块：

- **`:human`**——由人写，通过 Console 或一次复盘。
- **`:agent`**——由 agent 从会话的可写 store 写。
- **`:dreaming`**——由 Brain dreaming 流程提出。dreaming 产出的是提议的知识，人类审过才成为事实。一块 `:dreaming` 还不是真相，是候选。
- **`:source_learning`**——从留存的外部材料推导而来。
- **`:mechanical`**——由自动化管道写入。

这就是为什么 `memory_update` 从本回合打开的条目推导 author 和写权限，而不是让 agent 自己挑。agent 以自己的权限写，写进 scope 允许的 store。它写不了 `:human`，也写不了 dreaming 提议进一个不接受它们的 store。

## 如何启用记忆

记忆不是你在 [Agent Library](../agent-library/) 里拨的开关。工具随 worker 出厂，Agent Computer 跑的每个回合都有，但只要会话没声明 Brain scope，它们就答不出任何东西。要 agent 真正用上记忆，两件事必须成立：

1. **会话声明了 Brain scope。** 设好 `conversation.metadata["brain"]`，控制面才能推导 `owner_uid`、可读 store 和可写 store。没有这个声明，工具跑在一个空 scope 上，返回不了有用结果。这个声明就是开关。
2. **agent 有用它的理由。** 一份让 agent 保留持久知识的人设，加上一套供人类监督的 `brain-review` 节奏，才能让记忆有用而不闲置。见 [Agents](../agents/) 看人设与能力如何拼到一起。

要周期性复盘 agent 记住了什么，启用 `brain-review` skill——一个内置 skill（`default_enabled: true`），用上面五个工具引导一次对话式事后复盘。它只在人类明确要求时跑，而人类是评判者：agent 抛出证据、执行人类的决定，不擅自裁决哪条记忆为真。

## 运维不该碰的东西

工具的 RPC 路径、embedding 管道、dreaming 调度器都在 AIGateway 背后的子系统里，不是运维可调的开关。如果记忆返回降级结果，看 `memory_health_check` 的输出（管道失败、embedding 积压、策展 lint），而不是某个 worker 环境变量。持久的修在 Brain 本身——见 [Brain](../brain/) 开发者页——不在 worker 镜像里。

## 下一步

- 这些工具背后的子系统——持久知识、dreaming、source 留存、人类复核——读 [Brain](../brain/) 开发者页。
- agent 的人设、能力，以及给记忆定范围的会话声明，读 [Agents](../agents/)。
- 引导周期性记忆复盘的 skill，读 [Agent Library](../agent-library/) 和 [Writing a skill](../writing-a-skill/)。
- 回合内跑这些工具的 worker，读 [Agent Computer](../agent-computer/) 开发者页。
