---
title: Signals
description: 持久化事件接纳、信号路由规则、共享对话事实与外部消息投递机制。
section: Developer guide
order: 102
---

Signal 是驱动 Agent 执行会话处理工作的持久化事件，既可以代表一条聊天消息、一次定时唤醒、一份自动化脚本结果，也可以代表一条通用业务事件。聊天类 Signal 会关联对应的 Conversation 与 Message 记录，而纯业务事件则可直接投递，无需生成对话与发言记录。

在职责划分上，`Ankole.Signals` 负责事件接纳与信号路由规则，`Ankole.Conversations` 负责管理共享发言、外部平台事件观测与对外消息投递，`Ankole.Sessions` 则负责实际的会话执行——原始来源事实、触发信号与运行时执行状态各归其主、边界清晰。

## 对话与发言

Conversation 用于保存多方共享的对话历史。无论是平台内原生聊天还是外部 IM 渠道，底层统一采用同一套 Message 数据模型，记录发言者身份、正文内容及对话内的递增序号；外部渠道消息则额外通过 `ExternalMessageRef` 关联上游平台的消息 ID 与原始载荷。

外部对话在单个租户内通过 `provider_conversation_id` 唯一标识。多个 Agent 可以共同参与同一场外部对话、共享同一份发言时间线，同时各自维护独立的执行会话（Session）与模型推理历史；删除某个 Agent 或停用路由规则，都不会抹除已沉淀的外部对话历史。

外部平台推送事件时，先由 `Conversations.Observe` 接纳平台原始事实，再由 `Conversations.External` 落库写入 Message 与外部引用记录：收到重复推送时幂等更新同一条记录；收到表情回应（Reaction）时仅更新消息状态，不会触发新的模型推理回合；当上游平台撤回或删除某条发言时，则由发言所属领域在同一数据库事务内同步更新消息状态及依赖该消息的执行记录。

## 消息如何产生 Signal

外部请求进入系统后，先由渠道适配器完成平台签名校验，并将消息发送、表情回应、消息撤回或卡片交互统一归一化为标准结构；随后 `Observe` 解析匹配的信号路由规则，依次执行过滤条件判断、群聊策略评估以及必要的发信人身份准入检查。

通过准入的消息会落库保存为 Message；若按规则需要唤醒 Agent 处理，`Signals` 会在同一个数据库事务内为目标 Agent 的执行会话写入一条待处理 Signal。被过滤条件拦下的事件会以幂等空操作（no-op）正常返回成功，表情回应同样不会唤醒 Agent。

对于未明确点名 Agent 的群聊消息，若路由规则设为 `addressed_only`（仅处理明确提及），系统会直接跳过身份准入与 Message 落库；不过原始消息引用仍保留供按需回溯——一旦后续有人明确点名 Agent 并引用了早先那条未落库的群消息，系统便会自动按需补录被引用原消息的 Message 记录。至于开启主动介入后 Agent 如何评估未点名的群聊动态，请参阅 [群聊主动介入](../ambient-intervention/)。

## CloudEvents 与路由

控制台中的“信号路由规则”在底层存储为 Binding 记录，集中定义了目标 Agent、渠道适配器、配置引用、过滤条件及会话目标策略。运维人员可在 Console 中随时停用某条规则：停用后会立即停止接纳新事件，但不会删除此前已记录的对话历史。

除聊天渠道外，外部业务系统还可通过标准 CloudEvents 接口推送结构化 JSON 事件：

```text
POST /signals/v1/cloudevents/:token
```

事件体包含标准的 `specversion`、`id`、`source`、`type` 字段，以及可选的 `subject`、`time`、`data` 与扩展属性。命中路由规则后，系统可按配置将事件投递至固定的 Conversation 或 Session、按 `source + subject` 自动归并会话，或为每条事件单独开辟全新 Session。遇到相同事件 ID 的重复投递时，系统会做幂等去重，不会重复生成触发信号。

从外部接口传入的事件类型与数据载荷一律视为普通外部输入，无法伪造内部系统控制指令或冒充受信任的内部事件源——系统内核事件的私有来源标识仅能由控制面内部模块直接赋予。运维人员可在 Console 中创建、吊销 CloudEvents 接入端点并配置对应的路由规则。

## 平台 webhook 与回调能力

第三方平台 Webhook 统一经由以下入口接入：

```text
POST /webhooks/v1/:handler_id/:instance_id/:kind
```

控制器根据 `signals.webhook_handler` 插件契约定位对应的处理器（Handler），校验声明支持的事件类别，并交由该处理器验证上游平台签名或接入凭据；聊天信号适配器则遵循 `signals.adapter` 契约。

由 Agent 在运行期间自主创建的外部事件回调则使用专用路径 `/webhooks/v1/event-callbacks/wh_<token>`。注意，路径中的随机令牌仅用于授权触发已登记的回调路由，并不对第三方传入的请求体内容做真实性背书。`Signals` 在数据库中仅保存令牌的哈希摘要，并在收到回调时将端点状态更新与 `webhook.received` 事件（或绑定的自动化脚本运行记录）放在同一事务内提交。完整的委托生命周期与 Worker 桥接机制见 [Webhook 委托](../webhook-delegations/)。

## 投递

Agent 向外部渠道发送回复时，先由 `Conversations.Delivery` 持久化记录发送意图，解析出目标平台的真实会话标识与回复引用 ID，再调用渠道适配器的 `deliver` 接口执行外发；待上游平台确认接收后，再将生成的 Message 记录、外部消息引用与投递结果在同一事务内一并提交。

每条外发记录的状态流转为 `pending`、`sent`、`failed`、`expired` 或 `unknown`。一旦网络超时等异常导致无法确认上游是否已成功落盘，系统会将状态如实保留为可见的 `unknown`，而不会盲目自动重发造成群内刷屏；持久化的发送意图与诊断详情可供人工或后续对账流程核实。

会话执行与故障恢复机制见 [Sessions](../sessions/)，渠道接入实操见 [快速开始](../quickstart/)，三层核心模型的职责对照见 [对话、信号与执行会话](../conversations-signals-sessions/)。
