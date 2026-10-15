---
title: Signals
description: 持久事件、信号路由规则、共享对话事实与外部投递。
section: Developer guide
order: 102
---

Signal 是请求 Agent 执行会话处理工作的持久事件。它可以表示消息、定时唤醒、自动化结果或业务事件。Signal 可以关联 Conversation 和 Message；通用业务事件不必创建这两类事实。

`Ankole.Signals` 拥有事件接纳与信号路由规则，`Ankole.Conversations` 拥有共享发言、外部观察和投递，`Ankole.Sessions` 拥有执行。来源事实、刺激与执行状态分别由其所有者管理。

## 对话与发言

Conversation 保存共享历史。原生聊天和外部聊天使用同一 Message 模型，记录作者、内容以及对话内序号。`ExternalMessageRef` 把外部发言连接到平台消息标识和原始载荷。

外部 Conversation 在租户内以 `provider_conversation_id` 唯一识别。多个 Agent 可以参与同一对话、共享发言，同时保留各自的执行会话和模型历史。删除 Agent 或路由规则不会删除外部历史。

`Conversations.Observe` 接纳平台事实，`Conversations.External` 写入 Message 和外部引用。重复观察更新同一事实。表情反应更新事实，不启动模型回合。平台删除通过发言所有者执行，并在同一事务内更新依赖的执行事实。

## 消息如何产生 Signal

适配器校验平台请求，把消息、表情反应、删除或交互归一化。Observe 解析信号路由规则，应用过滤和消息策略，并在需要时执行身份准入。

被接纳的消息写成 Message。需要 Agent 工作时，Signals 在同一事务中接纳该 Agent 执行会话的 Signal。被过滤的事实是成功的空操作，表情反应不唤醒 Agent。

对于未点名 Agent 的群消息，`addressed_only` 可以跳过准入和发言记录；明确引用所需的原消息仍可供后续解析。后续回复明确引用时，可以提升所需的来源 Message。[群聊主动介入](../ambient-intervention/)说明 Agent 如何判断其他群活动。

## CloudEvents 与路由

信号路由规则（Signal Routing Rule）保存为 Binding，选择 Agent、适配器、配置引用、过滤条件和目标。运维者在 Console 管理规则。停用规则会停止新的接纳，不删除已经记录的对话事实。

CloudEvents 端点通过以下路径接收结构化 JSON：

```text
POST /signals/v1/cloudevents/:token
```

事件包含 `specversion`、`id`、`source`、`type`，以及可选的 `subject`、`time`、`data` 和扩展字段。匹配的规则可以选择固定 Conversation 或 Session、按来源与 subject 归并，或为每个事件使用独立 Session。重复投递保留事件标识，不产生第二个刺激。

外部事件的类型和数据是输入事实，不能声明内部控制命令或可信生产者。内核事件的私有来源由实际所有者赋予。Console 可以创建、取消 CloudEvents 端点并配置规则。

## 平台 webhook 与回调能力

平台 handler 使用以下入口：

```text
POST /webhooks/v1/:handler_id/:instance_id/:kind
```

被声明的 handler 校验平台签名或凭据。控制器按 `signals.webhook_handler` 契约选择 handler，并检查其声明的事件类型。信号适配器使用 `signals.adapter` 契约。

Agent 创建的原始回调使用 `/webhooks/v1/event-callbacks/wh_<token>`。该能力授权已记录的回调路由，不认证请求正文中的事实。Signals 保存 token 摘要，并将端点决定与 `webhook.received` 或绑定的自动化 run 一起提交。生命周期与 Worker bridge 见 [Webhook 委托](../webhook-delegations/)。

## 投递

`Conversations.Delivery` 保存外部发送意图，并调用适配器的 `deliver`。发送前解析真实的平台对话与消息标识。确认发送后，每个产生的 Message 和外部引用与投递结果一同提交。

投递状态为 `pending`、`sent`、`failed`、`expired`、`unknown`。无法确认的结果保留为可见的 `unknown`，不会自动重发。持久意图和诊断支持后续核对。

执行与恢复见 [Sessions](../sessions/)，配置见 [快速开始](../quickstart/)，架构比较见 [对话、信号与执行会话](../conversations-signals-sessions/)。
