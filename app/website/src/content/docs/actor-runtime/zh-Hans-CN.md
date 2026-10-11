---
title: Actor Runtime
description: 对话 Driver、持久输入与 Response 日志、单写者栅栏及恢复。
section: Developer guide
order: 103
---

actor key 是 `{agent_uid, session_id}`。同一 Agent 的多个对话可以并行，一个对话由 `Ankole.Conversations` 中的一个 Driver 串行推进。

## 单写者

DynamicSupervisor 按需启动临时 `:gen_statem` Driver，`:global` 在 Erlang 集群中给每个 actor key 一个名字。持久工作区行上的 epoch 是写入栅栏：准入推进它，Driver 的事务持有行锁并检查它。网络分裂之后，旧 Driver 也不能提交。

## 撑过进程消失的事实

ActorEvent 是持久收件箱，AIGateway 的 Response 链记录模型输出与工具结果。控制面工具同一事务提交副作用与回执；Driver 同一事务把整轮结果写入链并删除回执。新 Driver 从这些事实重建进度。

输入完成与最终回复同一事务提交。最后注入且可回复的输入拥有最终回复，内部修订保留原回复 owner。副作用之后的撤回和 retry 保留工具记录。

## Worker 标识

只有环境工具或 Codex 需要电脑时才请求 Agent 的 Worker。环境工作使用按 Agent、Session 与触发输入划定的 `RunRef`；Codex 使用还包含 Job 与 attempt 的 `JobTurnRef`。结果按操作自身标识接纳，不按 Driver epoch 栅栏，新 Driver 因而可以领养在途工作。

RuntimeFabric 为每个 Worker 使用一条 Phoenix Channel。Phoenix Tracker 跨节点找到 channel，Erlang 分布式送达消息。当前 Worker generation 与 incarnation 拒绝旧路由，每个 Worker 只服务自己的 Agent。

## 恢复

输入 owner 在提交领域事实的事务里插入 Oban 唤醒。每分钟的 Reconciler 扫描全部到期的开放输入，包括已经开始的尝试；有 Driver 就唤醒，没有就重建。它还通过 Workflow owner 补回丢失的 RunServer 与终态清理。退避从持久 `last_attempt_at` 起算，失败预算限制反复崩溃。

单节点与多节点部署运行同一条路径。另见 [Agent loop](../agent-loop/)、[SignalsGateway](../signals-gateway/) 与 [Worker](../agent-computer-worker/)。
