---
title: Sessions
description: Agent 执行、共享历史读取、单写者栅栏与恢复。
section: Developer guide
order: 103
---

Session 是一个 Agent 的执行单元，键为 `{agent_uid, session_id}`。同一 Agent 的多个执行会话可以并行；每个执行会话由 `Ankole.Sessions` 中的一个 Driver 推进。

Conversation 保存共享发言。同一对话中的各 Agent 使用独立 Session，AIGateway 保存执行会话所用的模型历史。通用 Signal 也可以直接指向没有 Conversation 的 Session。

## 单写者

DynamicSupervisor 按需启动临时 `:gen_statem` Driver，`:global` 为每个 Session 键在 Erlang 集群中注册一个名称。持久工作区行的 epoch 是写入栅栏：准入推进它，Driver 事务持有行锁并检查它。网络分裂后的旧 Driver 不能提交。

## 持久输入与模型历史

Signal 是持久收件箱。AIGateway 的 Response 链记录模型输出与工具结果。控制面工具将副作用和回执一起提交；Driver 在同一事务中把整轮结果写入链并删除回执。替代 Driver 从这些事实重建进度。

在模型请求边界，Sessions 读取当前 Conversation 的 Message。读取水位保存在实际请求的 metadata 中；当前 main 和 steer 的 Message 不重复进入背景片段。共享历史提供上下文，不提供替过去作者行动的权限。准入检查当前请求人。

Signal 完成与最终回复意图一起提交。内部修订保留回复所有者，工具结果在撤回或 retry 后仍可读取。`/compress` 等命令以反馈和 checkpoint 完成，不要求普通的最终模型 Response。

## Worker 与操作标识

环境工具或 Codex 需要电脑时，才请求 Agent 的 Worker。环境工作使用按 Agent、Session、Signal 划定的 `RunRef`；Codex 使用还包含 Job 和 attempt 的 `JobTurnRef`。操作拥有独立标识，替代 Driver 可以接管在途工作。

RuntimeFabric 为每个 Worker 使用一条 Phoenix Channel，Phoenix Tracker 跨节点定位它。Worker 的 generation 与 incarnation 拒绝旧路由；每个 Worker 只绑定一个 Agent。

## 恢复

Signals 在接纳事务中插入持久 Oban 唤醒任务，并与调用方的领域写入一起提交。Reconciler 扫描到期的开放输入，包括已经开始的尝试；存在 Driver 就唤醒，否则重建。它也请 Workflow 所有者修复丢失的 RunServer 和清理任务。持久 `last_attempt_at` 与失败预算控制重复尝试。

原生聊天、外部聊天、定时工作和业务事件使用这些执行规则。相邻职责见 [Signals](../signals/)、[Agent loop](../agent-loop/) 与 [Agent Computer Worker](../agent-computer-worker/)。
