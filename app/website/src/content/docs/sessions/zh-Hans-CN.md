---
title: Sessions
description: Agent 执行会话、共享对话历史读取、单写者栅栏与故障恢复机制。
section: Developer guide
order: 103
---

Session 是单个 Agent 的基本执行单元，以 `{agent_uid, session_id}` 作为标识键。同一个 Agent 名下的多个执行会话可以并行运行，每个执行会话均由 `Ankole.Sessions` 中的独立 Driver 进程负责推进。

共享的多方聊天消息保存在 Conversation 中；参与同一场对话的各个 Agent 分别持有各自独立的 Session，而执行会话所需的模型上下文历史则由 AIGateway 负责存储。此外，通用业务 Signal 也可以不关联任何 Conversation，直接投递至目标 Session。

## 单写者

`DynamicSupervisor` 会按需拉起临时的 `:gen_statem` Driver 进程，并通过 `:global` 在整个 Erlang 集群范围内为每个 Session 标识键注册唯一名称。持久化工作区记录上的 `epoch` 字段充当单写者隔离栅栏：每次新准入都会递增 `epoch`，而 Driver 在提交事务时会持有该行锁并核对 `epoch`——一旦发生网络分区（脑裂），滞后的旧 Driver 将因栅栏失效而无法提交任何写入。

## 持久输入与模型历史

Signal 充当执行会话的持久化收件箱，AIGateway 的 Response 链则忠实记录模型输出与工具执行结果。调用控制面工具时，业务副作用与执行回执会在同一事务中原子落库；待整轮推理收尾时，Driver 再于同一事务内将本轮完整结果追加至 Response 链并清理回执。若中途发生故障切换，接替的新 Driver 可直接依据这些持久化事实精确重建执行进度。

每当跨越模型请求边界时，`Sessions` 会读取所属 Conversation 中的最新 Message，并将读取水位线写入本次实际模型请求的元数据中；当前回合的主触发消息（main）与运行中引导消息（steer）不会在背景历史片段中重复拼入。需要注意，共享对话历史仅用于补充推理上下文，绝不赋予 Agent 冒用历史发言者身份行事的权限——每次操作准入仍严格核查当前请求发起人的权限。

Signal 的完结状态会随最终对外回复意图一并原子提交。即便经历内部修订，回复归属者身份也保持不变；消息撤回或重试后，已产生的工具调用结果依然可供读取。在共享群聊中，普通 Agent 回复不会唤醒其他 Agent；跨 Agent 显式协作通过 `send_to_agent` 发起隔离的 `agent_peer` 会话，由 `personal_assistant` 在所属人类的冻结 `WorkAccess` 授权下委托 `ai_colleague` 执行任务——同事发出的 `Clarify` 追问或 `ActionCard` 审批卡会零跳（zero-hop）直投至原对话，人类作答后直接唤醒该同事，待同事提交最终回复后再向原助理 Session 投递一条持久化输入 Signal。诸如 `/compress` 之类的斜杠管理命令则通过状态反馈与检查点（Checkpoint）直接完结，无需生成常规的最终模型回复。

## 冷唤醒模型对话轮转

在对话信号准入时（`Ankole.Sessions.WakeRecycle`，由 `sessions.wake_recycle` 配置），只要前序模型对话已完成至少一次 Response，且满足（a）静置时长达到 `min_cold_gap_seconds`（默认 `3,600` 秒）同时累计输入上下文达到 `min_context_tokens`（默认 `128,000` Token），或（b）外部 IM 会话连续静置达到 `im_max_idle_seconds`（默认 `259,200` 秒 / 72 小时），Ankole 便会在准入事务内自动终结旧 AIGateway 模型对话并切换至后继分支。

轮转逻辑会跳过显式重置（`command.new`）、交互卡片回调与作答、后台任务回调信号（`background_agent_job.*` 与 `workflow.run.*`）、仍存在活跃或等待态 `BackgroundAgentJob` / `Workflow.Run` 或其他运行中 Signal 的 Session，以及崩溃重试（`last_attempt_at != nil`）。切换时会自动继承未决的 `InteractionState` 与 `ActionCard` 检查点，保持公开的 `conversation_messages` 原封不动，并在后继分支发起首次模型请求前由 `Sessions.WakeBriefing` 注入上限为 `8,000` `o200k_base` Token 的确定性 `<wake-briefing>` 摘要块（涵盖 `<brain-memory>`、`<recent-messages>`、`<recent-actions>` 与 `<objects-in-play>`）。

## Worker 与操作标识

Agent 创建时会在后台请求初次启动 Worker。执行 Session 时，环境工具或 Codex 任务需要电脑才会请求 Worker；普通问答不会重新唤醒空闲回收后的 Worker。常规环境工具调用采用按 Agent、Session 与 Signal 三元组划定的 `RunRef` 标识；Codex 任务则采用额外包含 Job 与 Attempt 维度的 `JobTurnRef` 标识。由于每项远端操作都具备独立的幂等标识，即使控制面发生 Driver 切换，新 Driver 也能无缝接管 Worker 上仍在运行的在途任务。

RuntimeFabric 为每个活跃 Worker 维护一条专属的 Phoenix Channel，并借助 Phoenix Tracker 实现跨集群节点寻址。连接握手时，系统会校验 Worker 的代数（generation）与实例化身号（incarnation）以拦截陈旧路由；每个 Worker 实例始终严格绑定唯一的 Agent。

## 恢复

`Signals` 在接纳事件的同一数据库事务内插入持久化的 Oban 唤醒任务，与调用方的领域状态写入原子提交。后台 Reconciler 会定期扫描所有到期的未完结输入（包括此前已启动但中途中断的尝试）：若目标 Session 的 Driver 仍在运行则直接唤醒，否则重新拉起新 Driver 接管；同时还会通知 Workflow 模块修复因节点异常而丢失的 `RunServer` 进程及清理任务。重试频率与上限由持久化的 `last_attempt_at` 时间戳和失败预算共同约束。

无论是原生聊天、外部即时通讯渠道、定时计划任务还是通用业务事件，底层统一遵循上述执行与恢复契约。关联模块的设计细节请参阅 [Signals](../signals/)、[Agent loop](../agent-loop/) 与 [Agent Computer Worker](../agent-computer-worker/)。
