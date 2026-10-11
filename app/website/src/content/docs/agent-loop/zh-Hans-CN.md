---
title: Agent 循环
description: 控制面 Driver、持久模型与工具步骤，以及 Worker 执行边界。
section: Developer guide
order: 117
---

主 Agent loop 在 Elixir 控制面的 `Ankole.Conversations` 中运行，每个对话由一个 `:gen_statem` Driver 推进。纯问答和控制面工具不需要 Worker；环境工具和 Codex 首次需要电脑时才启动 Agent 的 Worker。

## 一轮的持久步骤

1. 准入开放的 ActorEvent，在 PostgreSQL 中推进对话 epoch。
2. 从已存储的 Response 链重建进度，准备下一次模型请求。
3. 通过 AIGateway 的进程内 Responses API 打开持久 Response。
4. 按声明派发给控制面工具、Worker 或持久等待的 owner。
5. 在同一事务提交整轮工具结果、满足等待的输入消费和回执删除。
6. 在边界注入排队的输入，或提交最终回复与输入完成。

AIGateway 拥有转录、压缩、记忆注入与 hosted 工具。Driver 拥有迭代限制、空回复修复、重复错误提示和最终回复规则。所有对话类型共用这个 owner；Codex 在 Worker 内保留自己的 loop。

## 恢复与副作用

新 Driver 从 ActorEvent 与 Response 链重建进度。控制面工具的副作用与回执同一事务提交，已进入链的结果不再执行。Worker 用 Response ID 与 call ID 标识环境调用，新 Driver 可以领养。Worker 进程消失后，安全调用可以重试，其余无法确认的调用返回 `interrupted`。

普通输入等待下一个边界。停止与有效 retry 中断当前工作，无效的带目标 retry 保持运行。工具调用之后的撤回或裸 retry 保留工具记录，在同一链注入修订。

## 有界失败

AIGateway 负责单轮内的重试，Driver 负责跨尝试的重试。普通输入在第六次准入时进入死信。计划停机在事务成功时退还已准入的一次尝试，崩溃不退还。Workflow 与 Job 保留各自的预算 owner。

单写者规则见 [Actor Runtime](../actor-runtime/)，执行与存储见 [Agent Computer Worker](../agent-computer-worker/)，Responses 见 [AIGateway](../ai-gateway/)。
