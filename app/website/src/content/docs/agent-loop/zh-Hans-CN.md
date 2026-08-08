---
title: Agent 循环
description: 控制面回合生命周期与 worker 侧 agent 循环之间的边界——各自拥有什么、如何通信、迭代预算与重试住在哪里。
section: Developer guide
order: 117
---

一个回合是跨两个运行时的工作单位：Elixir 控制面调度并隔离它，Bun worker 在其中跑 agent 循环。本页说明两者之间的边界——控制面的 `TurnLifecycle` 拥有什么、worker 的 `runAgentLoop` 拥有什么、它们如何经 RuntimeFabric 通信。它建立在 [Actor Runtime](../actor-runtime/) 和 [Agent Computer Worker](../agent-computer-worker/) 页之上；本页补上两者之间回合级的细节。

先说明最关键的一点：控制面拥有回合的*身份与提交*；worker 拥有回合的*执行*。worker 决定循环何时结束；控制面决定回合结果是否持久。worker 报告完成的回合，在控制面提交前不持久。

## 控制面侧：TurnLifecycle

`Ankole.SignalsGateway.ActorRuntime.TurnLifecycle` 负责循环周边发生的事，不负责循环内部。其职责：

| 职责 | 做什么 |
|---|---|
| **租约管理** | activation 持有租约（`activation_progress_lease_seconds` = 2100 秒，带 120 秒宽限）；watchdog 使过期 activation 失败，让其事件可重试 |
| **回合启动** | 创建带新 epoch 的 `ActorSessionActivation`、指派 worker、经 RuntimeFabric 投递回合信封 |
| **回合错误处理** | `handle_turn_error/2` 接收 worker 的错误报告、分类、决定重试还是 dead-letter |
| **回合提交** | worker 报告成功时，将回合结局记录为持久事实 |
| **Activation 过期** | `fail_activation_if_expired/2` 捕获租约用完的卡住或崩溃回合 |

回合错误的重试预算就在这里，不在 worker：最多 5 次尝试（`@worker_turn_error_dead_letter_attempts`），指数退避在 5 到 120 秒之间（`@worker_turn_error_retry_base_seconds` 和 `@max`）。每次失败抬高 epoch，使失败尝试的迟到回复无法匹配后续重试。

控制面**不**决定模型说什么、agent 调哪些工具、循环跑多少迭代。那些是 worker 的。

## Worker 侧：runAgentLoop

`app/agent_computer/src/core/agent-loop.ts` 里的 `runAgentLoop` 是 worker 在回合中跑的四步循环：

1. **调用模型**——通过回合范围的 OpenAI Responses 适配器（AIGateway 的有状态传输）。
2. **本地执行 function call**——如果响应带 function-call 项，worker 运行工具。
3. **记录输出**——通过 AIGateway，存为 function-call-output 消息。
4. **从日志锚点继续**——直到响应不再返回 function-call 项。

worker 拥有**循环终止和本地迭代预算**。两种结局：

- **`loop_finished`**——模型返回时不再有工具调用。回合自然结束。
- **`iteration_exhausted`**——worker 触及迭代上限。模型被轻推综合一个最终答案而非继续调用工具（`MODEL_ITERATION_LIMIT_SYNTHESIS_TEXT`），回合以该综合结束。

worker 还拥有三种恢复轻推：empty-after-tools 轻推（模型执行了工具但返回空响应）、tool-error 恢复提示、迭代上限综合。这些在 worker 侧，因为它们关乎模型接下来做什么，不关乎回合是否持久。

## Worker 不拥有什么

agent 循环模块文档明确：worker **不**拥有历史扩展、compaction、续接锚点或持久响应状态。那些留在 AIGateway。worker：

- 不决定模型看到多少历史（AIGateway 的有状态 Responses 拥有它，含 compaction）；
- 不存储会话（AIGateway 的事）；
- 不决定回合副作用是否提交（控制面做）。

这是让 worker 可替换的划分：worker 跑循环，AIGateway 拥有转写，控制面拥有提交。

## 如何通信

| 方向 | 什么越过边界 |
|---|---|
| 控制面 → worker | `TurnStart` 信封（actor 身份、turn ref、要处理的事件） |
| Worker → 控制面 | 进度信封（检查点、活动摘要）、回合失败时的 `TurnError`、或回合的自然完成 |
| Worker → AIGateway | 模型调用、function-call 输出（这些不经控制面） |

每条 worker 消息带 `ActorTurnRef`（`activation_uid`、`actor_epoch`、`actor_event_id`）。控制面拿去和当前 activation 核对；ref 不再匹配的消息被当作过期拒绝。这是从回合层看到的 [Actor Runtime](../actor-runtime/) 三重隔离栏。

## 重试边界

回合失败时，控制面决定重试，不是 worker。worker 报告错误；`handle_turn_error` 分类：

- **可重试**（worker 传输失败、超时）——事件保持 `open`，epoch 抬高，运行时在退避延迟后重新投递。
- **Dead-letter**——5 次尝试（或 5 次连续回合失败）后，事件移到 `dead_letter`，回合停止重试。运维者检查并解决。

worker 不自行重试。它报告错误，控制面拥有重试决定，因为控制面才能重建 activation 隔离栏。

## 本指南不是什么

它不是模型 prompting 指南——循环形态是机械的（调用、执行、记录、继续），模型在其中的行为是人设的事。它不是传输指南——RuntimeFabric 承载信封，那是 [Kernel](../kernel/) 页的范围。它也不是 [Actor Runtime](../actor-runtime/) 页的替代；activation 隔离栏是回合生命周期运行在其中的上下文。

## 下一步

- activation 隔离栏与 actor 模型，读 [Actor Runtime](../actor-runtime/)。
- 跑循环的 worker，读 [Agent Computer Worker](../agent-computer-worker/)。
- 循环调用的有状态 Responses 传输，读 [AIGateway](../ai-gateway/)。
- compaction（worker 不拥有），读 [上下文压缩与 compaction](../context-compression-and-caching/)。
