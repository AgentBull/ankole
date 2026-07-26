---
title: Actor Runtime
description: 一个长时 session 如何存活、唤醒、失败与恢复——actor key、OTP 故障域、activation 隔离栏，以及 RuntimeFabric 的实时路径。
section: Developer guide
order: 103
---

Actor Runtime 让一个 session 成为长时存活的东西，而不是一次请求。一个信号到达，一个 session 被唤醒，一个 worker 跑完一个回合，回合提交或失败，session 回到等待——整个过程里，哪怕进程崩溃，PostgreSQL 里的持久转写仍然正确。本页对照 `Ankole.SignalsGateway.ActorRuntime` 里的真实代码，画出这条生命周期。

先说核心设计选择：正确性在数据库里，不在进程里。那些活着的进程是为了推理和吞吐做的优化；阻止迟到或跨 session 回复污染状态的隔离栏，只不过是对数据行的相等比较。所有进程都没了，持久转写仍然完好。

## actor key

长时工作的单位是一个 actor key：`{agent_uid, session_id}`。一个 agent 可以持有多个 session；一个 session 恰好属于一个 Agent。后面的一切——串行控制器、activation、delivery 行、Worker 指派——都以这一对为键。

session 是上下文、工作空间状态、引导、取消和恢复交汇的地方。它既不是一次请求，也不是一个队列任务，而是一个有状态的工作身份，能够跨几小时甚至几天地唤醒、等待、续接。

## 两层，两种保证

运行时刻意把两层分开，因为它们需要的保证不同：

- **AI-agent 状态**——对话、回合、消息——是*持久事实*。它住在 AIGateway 拥有的表里，扛得过任何崩溃。
- **Actor-runtime 投影**——activation、delivery、指派——是更廉价的*运行时线索*。它们为进行中的工作设隔离栏，并且可以从持久层重建。

这种分开正是 Worker 可替换的原因。Worker 跑一个回合；决定这个回合的回复还算不算数的，是那些隔离栏行。一个崩溃或被取代的 Worker 发出的迟到回复，会被隔离栏挡掉并无害丢弃。

## 串行控制器，每个 actor 一个

对每个 actor key，动态监督器按需启动一个 `SessionController` GenServer，并在 `ActorDirectory` 里以唯一名称注册。一个控制器为同一个 actor key 串行化调度，所以常规路径上绝不会有两个回合在同一 session 上竞争。

这是为了推理做的优化，不是正确性边界。控制器崩溃并重启时，actor 的状态一点不丢——真正挡着门的，始终是数据库里那些持久隔离栏。启动控制器是幂等的：同一个 actor 的两次并发唤醒争着启动它，输的一方拿到 `{:already_started, pid}`，双方都把它当成功，返回那个活着的 pid。调用方永远不必协调由谁来启动 actor。

## OTP 故障域

监督树的构造方式，让一次失败不会变成所有人的失败：

- **运行时监督器**跑 `:one_for_one`。它的子进程——传输、命名、每个 actor 的控制器——是各自独立的关注点。一个子进程崩溃不会让其余子进程的状态失效，因为持久的正确性在 PostgreSQL 里，不在这些进程里。
- **session 监督器**是一个 `DynamicSupervisor`，同样是 `:one_for_one`。每个 `SessionController` 是自己的故障单元：一个崩溃的控制器，或一个行为异常的 actor，会被隔离和重启，而不触碰任何别的 actor 的控制器。

实际效果是，某个 Agent 卡住、超时或崩溃，会被单独隔离或在自己的分支上重启，而不是演变成全部署的灾难。actor 在运行时来去，不需要一份静态的子进程清单。

## activation 隔离栏

session 被唤醒去跑一个回合时，运行时创建一个 `ActorSessionActivation`：该 actor session 的一份实时租约投影。一个 activation 带着一个 `actor_epoch`——该 actor key 的单调计数器——一个 `lease_id` 和 `lease_expires_at`、一个 `current_actor_event_id`，以及一个在对实时回合做就地引导时自增的 `revision`。

activation 状态流转 `starting → active → draining`，`stopped` 和 `failed` 是终态。每个 actor key 同一时刻只允许存在一个活跃的 activation，由一个部分唯一索引强制。租约失败后新创建的 activation 会拿到更高的 epoch，而这个 epoch 就是那个廉价的隔离栏，让来自上一个 activation 的迟到回复仅凭不相等就失败。

每一条 worker 回复都必须回显一个 `turn_ref`，其字段以相等比较的方式与数据库行核对——activation、actor epoch 和为该回合命名的 delivery 行，这三重隔离栏。这让迟到或跨 session 的 worker 回复无害地失败，而不是污染持久转写，而且做到这一点不需要任何内存中的 session 状态。唯一一处刻意留弱的地方——一个已持久启动的回合在重启时丢失了运行时隔离栏——由受影响消息行所对应的那个确切的运行时事件处理器修复。

## delivery 行与实时路径

在一条已入队的 actor 事件和 worker 接受之间，隔着一条 `ActorEventDelivery` 行。一次 worker 执行恰好处理一个 `actor_event_id`。隔离栏五元组——`activation_uid`、`actor_epoch`、`actor_event_id_fence`、`revision` 和 actor key——从 activation 复制到每条 delivery 行上，于是迟到回复的核对就是对数据库的纯相等比较，不需要内存中的 session 状态。

delivery 状态流转 `created → sent → accepted`，`send_failed` 和 `superseded` 是终态且可忽略。从控制面到 worker 的实时路径跑在 RuntimeFabric 上——建立在 ZeroMQ 之上的实时传输——解码后的流量在持有 socket 的 broker 之上被路由：worker 生命周期事件被串行化，actor 事件被转发到各自的 session 控制器，相互独立的 worker RPC 请求在一个 task 监督器下运行。任何领域回调都不在传输 broker 进程里执行。

## 租约到期与恢复

activation 只在 `now < lease_expires_at` 时有效。一个 watchdog 会把一个进行中、已过期的 activation 置为失败，好让它的 actor 事件可以重试；通常情况下，它会停止一个当前事件为空的、尚温热的 activation。一个回合出错时，该事件保持 `open` 以便重试，直到反复的 worker 失败越过溢出阈值，它才进入 `dead_letter`。重试用指数退避，限定在 5 到 120 秒之间，并且每次失败尝试的 epoch 都会抬高，使它的迟到回复无法匹配下一次重试。

一句话讲完恢复：持久事件保持 open，运行时投影被重建，一个带有更高 epoch 的新 activation 把这个事件重新接起来。actor 不会丢失自己的位置，因为它的位置从来就不在某个进程里。

## Actor Runtime 不是什么

它不是存放持久事实的地方——那些在 AI-agent 状态层和 PostgreSQL 里。它不是 worker；worker 是可替换的 Agent Computer 进程，负责跑回合。它也不是入口；信号从 [SignalsGateway](../signals-gateway/) 进来，一旦变成 actor 事件，唤醒并跑起它们就是这个运行时的事。这里的边界，是把一条持久入队的事件转换成一个有隔离栏、可恢复的实时回合，再转换回一次持久提交。

## 下一步

- 信号如何变成 actor 事件，读 [SignalsGateway](../signals-gateway/)。
- worker 被唤醒后跑的模型回合，读 [AIGateway API](../ai-gateway/)。
- 全系统视角，读[架构概览](../architecture/)。
