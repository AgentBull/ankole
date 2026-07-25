---
title: SignalsGateway
description: 共享工作入口层——聊天、webhook 和 provider 事件如何变成 actor 事件，而又不把来源事实错写成执行状态。
section: Concepts
order: 7
---

SignalsGateway 是共享工作的入口。一条聊天消息、一个 webhook、一个 provider 事件，或一个定时提醒，从一边进来；一个归一化、持久的 actor 事件从另一边出去，准备好唤醒某个 session。这个网关的职责，是把各个 provider 各不相同的形态收成一种，并且让原始的 provider 事实与随后发生的执行保持分离。

本页画出的是真实的入口路径、绑定模型，以及镜像与唤醒之间的边界。事实来源是 `Ankole.SignalsGateway` 模块及其 `Ingress`、`Projection`、`Bindings` 子模块。

## 它守住的契约

不论来自哪个 provider，有两条性质始终成立，也正是这个网关作为独立一层存在的理由：

- **来源事实始终是事实。** 一个被镜像的条目，记录的是 provider 当前的样子——谁、在哪里、什么时候、说了什么。它不是执行状态。agent 的回合跑在这些事实的投影上，而不是跑在事实本身上。
- **唤醒是有条件的。** 不是每一个被接受的事实都会唤醒 actor。一个被过滤掉的信号是一次成功的空操作（`status: :filtered`），只有当一个被接受的事实确实产生了新的 actor 事件时，actor 运行时才会被启动。

这种分离之所以要紧，是因为各个 provider 的行为各不相同，会重试、会重投，还会发出一些 agent 应当看到、却不必据此行动的事件。网关把这些差异吸收掉，actor 运行时看到的就是一条干净的输入流。

## 入口管线

不论来自哪个 provider，每一条入境事实都走同一条固定管线：

1. **解析绑定。** 网关按 `agent_uid` 和 `binding_name` 查找 signal binding。没有绑定，就没有路径——事实被拒绝。
2. **构造事实。** provider 原生的载荷通过 `FactNormalizer` 归一化为一种带类型的事实——条目、表情反应、动作或生命周期。provider 各自的名称（比如“删除”或“撤回”）会坍缩成同一种面向 actor 的类型。
3. **应用绑定过滤。** 绑定的过滤规则决定这条事实是否在范围内。不匹配会返回 `{:ok, %{status: :filtered}}`，这是一次成功，不是错误。
4. **接受并镜像。** 被接受的事实会 upsert channel 镜像，并写出条目投影。provider 事实就在这里变成持久的行。
5. **在需要时交出 actor 事件。** 如果被接受的事实应当唤醒某个 actor，就向 session 队列追加一条 `ActorEvent`。表情反应是例外：它只更新镜像，永远不产生 actor 事件。

接受过程中的加锁顺序是固定的——channel、然后 session、然后 actor 事件——所以同一 channel 上并发到达的事实会以确定的方式分出胜负。

## 入境事实的几种类型

网关通过 `Ingress` 接受四种具体类型，每一种都映射到一种归一化的、面向 actor 的契约：

- **条目（entry）**——一条消息或帖子到达某个 channel。这是主要的唤醒路径。IM 条目策略决定一条未被 @ 的群消息是产生 `may_intervene` 事件（允许 agent 主动插话），还是 `addressed` 事件（agent 被直接点名）。
- **条目移除（entry removed）**——provider 的删除或撤回。面向 actor 的契约始终是 `signal.entry.removed`；provider 原生的生命周期名称只留作诊断用。
- **表情反应（reaction）**——对某个已有条目的 emoji 或投票变化。只更新镜像，永远不唤醒 actor。如果反应指向一个网关从未镜像过的条目，它会被忽略（`:ignored_unknown_entry`），而不被当成错误。
- **动作（action）**——provider 上发起的一次交互，比如卡片按钮点击。会经过回复交互去重：重复的点击返回 `:duplicate_action`，过期的返回 `:stale_action`，被接受的则变成 `signal.action.invoked` 事件。

## channel、条目与回复模式

**channel** 是条目所在的 provider 侧容器：一个 IM 单聊或群聊、一个 webhook 端点、一个 issue、一条告警流。channel 这一行是纯粹的外部事实镜像，按 provider 原生的 channel id 作主键，所以每次事件是 upsert 而非插入。它记录着 `reply_mode`——`:none`、`:channel` 或 `:entry`——出箱会读取它，以决定一条回复是作为新的 channel 帖子发出，还是作为对某个具体条目的楼中楼回复。

**条目** 是一个 channel 中的一单位内容：一条消息、一篇帖子、一个事件。条目投影才是 agent 回合读取的东西；它既不是 actor 事件，也不是源载荷的逐字副本。

## 绑定模型

一个 signal binding 把一个 provider adapter 绑到一个 agent 上，名字由运维者自取。绑定挂在 agent 名下，通过 console 范围的路由管理：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/signal-adapters` | 列出本部署声明的 adapter |
| `GET` | `/agents/:agent_uid/signal-bindings` | 列出某个 agent 的绑定 |
| `PUT` | `/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | 创建或替换一个绑定 |
| `PATCH` | `/agents/:agent_uid/signal-bindings/:binding_name` | 更新一个绑定 |
| `DELETE` | `/agents/:agent_uid/signal-bindings/:binding_name` | 删除一个绑定 |

一个绑定带着它使用的 adapter、一个配置引用、过滤规则、一条群消息策略、一个 `enabled` 开关，以及一个 `confidential_memory` 开关。禁用一个绑定会停止新事实唤醒它的 actor，但不会删除绑定本身；一个不可用的绑定会记下 `unavailable_reason`，运维者就能看到它为什么停了。

adapter 不是写死的。它们在启动时从插件注册表中按 `signals_gateway.adapter` 契约解析出来，所以可用的 provider 集合，就是本部署的插件所声明的那些。请求一个没有任何声明提供的 adapter id，会返回 `signal_adapter_not_found`。

## provider 的 webhook 入口

推送事件的 provider 通过同一扇正门进入网关：

```text
POST /webhooks/v1/:handler_id/:instance_id/:kind
```

这条路由刻意放在所有鉴权管线之外：没有 session、没有 CSRF、没有 bearer token、没有 Accept 协商，因为 provider 会发送它们自己的请求头。鉴权 provider 是被声明的 handler 的事——一个 Bot Framework 的 JWT、一个 Graph 的 `clientState`，或任何 provider 用来签名的东西。

控制器本身只负责路由。它解析被声明的 `signals_gateway.webhook_handler` 插件，强制执行该 handler 声明的 `kind` 白名单，并渲染该 handler 的响应指令。未知的 handler 或未声明的 kind 返回 `404`，且不回显载荷；handler 失败返回 `500` 和一条通用消息。真正调用 `Ingress` 并传入归一化事实的，是 handler 自身。

## 出箱：回复发回去

入境只是网关的一半。另一半是出箱，它把 agent 的回复变成 provider 侧的发送动作。出箱读取 channel 的 `reply_mode` 来选择发送方式——一条 channel 帖子，或一条楼中楼回复——并走与入境相同的 adapter 契约。agent 在一个回合中提交的副作用，通过这条路径交付，它们的持久记录与产生它们的那条 actor 事件存放在一起，而不是放在 live worker 里。

## SignalsGateway 不是什么

它不是 provider 客户端。它不为每个聊天平台维持长连接；那是 adapter 及其长连接 worker 的事。它也不是承载任意工作的队列——只承载 session 上面向 actor 的事件。agent 的执行也不在这里；一旦一条 actor 事件被追加，唤醒并跑起回合就是 Actor Runtime 的事。网关的边界，是把 provider 事实转成持久的 actor 输入，再把 actor 回复转回 provider 发送。

## 下一步

- 被唤醒的 actor 事件如何跑起来，读 [AIGateway API](../ai-gateway/) 和[架构概览](../architecture/)。
- 在一套运行中的部署里配置绑定，读[安装部署指南](../installation/)和 [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)。
