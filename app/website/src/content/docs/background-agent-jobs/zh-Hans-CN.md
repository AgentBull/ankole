---
title: Background Agent Jobs
description: 跨越 worker 故障的持久、可恢复工作——job 状态机、等待输入、唤醒 owner，以及与 Actor Runtime 的边界。
section: Developer guide
order: 105
---

一个后台 Agent 任务是一项注定要比单个 worker 活得更久的工作。agent 派出一个任务去做那些太长、步骤太多，或者隔离要求太高、没法在自己回合里就地跑的事——然后这个任务按自己的节奏运行、暂停等输入、失败或完成，而发起它的 agent 仍然有空跟它的 owner 说话。本页对照 `Ankole.BackgroundAgentJobs` 里的真实代码，画出这条生命周期。

先说明最关键的一点：一个任务是持久工作，不是子进程。它的状态在 PostgreSQL 里，每一次状态迁移都有隔离栏和审计，当任务进入 owner 应当知晓的状态时，它会向 owner 的 session 追加一条唤醒事件——走的是和普通信号同一个 actor 事件队列。

## 与 Actor Runtime 的边界

一次 session 回合和一个后台任务，是两种不同形态的工作，运行时把它们分开。Actor Runtime 拥有的是实时的、带隔离栏的回合——唤醒 session、跑一个模型循环、提交。一个后台 Agent 任务拥有的，是被某个回合委派出去的持久、可恢复工作。交接是显式的：一个任务带着 `owner_session_id`、`source_actor_event_id` 和 `source_tool_call_id`，所以从发起回合到任务、再回来的链路，始终可以重建。

实际意味着什么：一个任务既不是第二个 session，也不是对 agent 的一个争夺式占用。它是 owner session 请求的工作，有自己的状态机、自己的重试预算、自己的回报方式。

## 任务状态机

一个任务在六个状态间流转，迁移受一张固定的表约束：

```text
queued → running → waiting_on_user → running → … → succeeded | failed | stopped
```

- **`queued`**——已接受，尚未占用 agent 的运行槽。
- **`running`**——占用 agent 的一个运行槽（每个 agent 最多三个）。
- **`waiting_on_user`**——暂停以等待人类输入。释放其运行槽；之后的回合会恢复它。
- **`succeeded`**、**`failed`**、**`stopped`**——终态。一个终态任务没有实时执行。

每一次迁移都经过 `transition_allowed?/2`，所以一个 `queued` 的任务不经过 `running` 就跳不到 `succeeded`，一个终态任务根本动不了。这张表就是契约，应用代码里的任何东西都不得绕开它。

## 唤醒：向 owner 回报

当一个任务进入 owner 应当知晓的状态时，lifecycle 会在同一个事务里提交这次迁移，并向 owner 的 session 追加一条唤醒事件。三个状态会产生唤醒：

| 任务状态 | 唤醒事件类型 |
|---|---|
| `succeeded` | `background_agent_job.completed` |
| `failed` | `background_agent_job.failed` |
| `waiting_on_user` | `background_agent_job.waiting` |

这条唤醒是一条普通的 actor 事件——同样的队列、同样的隔离栏、同样的 session 控制器，和任何别的信号一样——发往 `owner_session_id`，并按任务的 `reply_route`（它的绑定、channel、thread）路由。owner session 不做轮询；只有在真有事情要报告时，它才被唤醒。进入 `queued` 或 `running` 的迁移不产生唤醒，因为这两件事 owner 不必采取行动。

唤醒事件的 source id 编码了任务、状态和尝试序号，所以一个被恢复的任务后续的唤醒，不会和早先那一次混淆。

完成唤醒只携带有界的结果摘要。持久化的最终回复超过摘要上限时，owner Agent 调用 `show_background_job_details` 并传入 `result_offset: 0`，随后把每次返回的 `result.next_offset` 传给下一次调用，直到它为 `null`。按顺序拼接这些 UTF-8 安全的片段，可以逐字还原最终回复。这样既能限制唤醒和每次读取的大小，也无需增加另一种任务操作，同时不会失去对持久结果的访问。

## 恢复与等待输入

`waiting_on_user` 是那种让任务保持存活、又不占槽的暂停。当任务需要人类决策时，它迁移到 `waiting_on_user`；最新状态投影记下 `interrupted`，错误码 `request_user_input`，并带一个待处理 tool call，这样 owner 的下一回合就有一个精确的续接点。人类回答后，任务迁移回 `running` 并继续。

一个任务也可以从上一个任务续接，而不是从自己的暂停处续接：`continued_from_job_id` 和 `workspace_owner_job_id` 记下这条链。长任务就这样向前传递，既不丢线索，也不丢工作空间。

## 跨 worker 故障的恢复

任务状态是持久的，所以 worker 丢失是一个可恢复事件，而不是数据丢失事件。运行时给一个任务一份有界的重试预算——最多五次执行尝试，最多五次连续回合失败——而当某次尝试没能正常启动时，`requeue_unstarted_attempt` 会把尝试计数减一，并把任务放回 `queued`，在第一次尝试时清掉 `started_at`，让它表现为一次全新开始。

两条 claim 路径覆盖两种恢复形态：

- **`claim_attempt_in_tx`**——为一次新的执行尝试 claim 一个任务。
- **`claim_continuation_in_tx`**——在一次暂停之后 claim 一个任务以续接。

两者都按固定顺序拿 agent 的槽锁，再在 `FOR UPDATE` 下拿任务行。同一个 agent 上并发的 dispatcher 因此每次都以同样的方式决出结果。一次重试尝试若超出预算，就落入 `failed`；一个被取消的任务落入 `stopped`。两次尝试之间的重试延迟限定在 30 秒，所以一个短暂失败的任务不会频繁冲击 Provider。

AIGateway 配额耗尽且池有已知的未来恢复时间时，生命周期会把任务放回 `queued`，释放 Worker 分配关系，并按该时间安排下一次派发。已经取得的 attempt 仍然计入五次预算，所以反复发生的配额失败也有上限。恢复时间已过期或缺失时，任务走普通的有界重试路径，不会立即再次派发。

## 派发与 agent 的插件

一个任务保留一个可选的工作空间模板，但每一次执行用的是 agent *当前* 启用的 Agent Plugins 和兼容 Skills——不是 spawn 时冻结的快照。派发路径（`BackgroundAgentJobDispatch.process`）从 actor 事件解析出任务，交给回合运行时，并把 steer 事件单独处理，以免一次发往 session 的实时交付被误当成对任务的 steer。每个模型回合都通过 AIGateway，并使用任务创建时保存的 Provider 绑定。若该 Provider 有多个凭据，选择、亲和、刷新和重试都由 AIGateway 管理；任务没有账号字段或账号并发槽。

任务第一次初始化工作空间时，runner 组装项目 `AGENTS.md`：可选的工作空间模板在最前，随后追加渲染出的任务上下文——agent 的 SOUL 与 MISSION、持久 Brain 上下文和执行事实。共享模板 `app/library/templates/AGENT_JOB.md` 仍作为扩展点，但随产品交付的文件为空，因此 runner 不生成 Job Guidance 一节。Codex 项目配置把原生子 agent 等待的最小值设为 1 分钟，默认值设为 2 分钟；不设置最大值，因此沿用 Codex 默认值。这样可以减少空等待超时后模型重复进入，相关问题见 [openai/codex#35259](https://github.com/openai/codex/issues/35259)。续接既有线程的任务保留原有 `AGENTS.md`。

## 运维界面

三条 console 范围的路由覆盖运维者的需要：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/background-agent-jobs` | 列出任务 |
| `GET` | `/background-agent-jobs/:job_id` | 读取一个任务 |
| `POST` | `/background-agent-jobs/:job_id/cancel` | 取消一个任务 |

取消把任务推到 `stopped`；它不会从正在运行的回合底下突然抽走 worker。回合自行结束或失败，受每一次 worker 写入都要经过的同一套 activation 和 revision 校验约束。

## Background Agent Jobs 不是什么

一个任务不是一个自由形态的后台进程。它是一个带有固定迁移表、有界重试预算、以及单一回报 owner session 的状态机。它不是在权限边界之外跑工作的途径——任务作为它的 agent 运行，受同样的插件和技能约束。它也不是 Actor Runtime 的替代品；两者共享 actor 事件队列和隔离机制，但任务拥有可恢复工作，运行时拥有实时回合。这条边界是刻意的，越过它要走一次文档化的迁移，而不是直接触碰另一层的内部。

## 下一步

- 任务从中派生、并向其回报的实时回合，读 [Actor Runtime](../actor-runtime/)。
- 任务执行跑的模型回合，读 [AIGateway API](../ai-gateway/)。
- 任务的唤醒如何作为一条普通信号到达 owner，读 [SignalsGateway](../signals-gateway/)。
