---
title: Background Agent Jobs
description: 跨越 Worker 故障的持久化可恢复长任务：Job 状态机、等待用户输入、唤醒归属会话，以及与 Sessions 的职责边界。
section: Developer guide
order: 105
---

后台 Agent 任务（Background Agent Job）专用于承载生命周期远超单个 Worker 实例的长时工作。面对耗时长、步骤繁多或需要独立工作区隔离而无法在当前对话回合内当场跑完的任务，主 Agent 可以派发一个后台任务去异步推进：后台任务按自己的节奏执行、暂停等待人工确认、报错或顺利完工；与此同时，发起任务的主 Agent 依然保持空闲，随时响应用户的日常对话。本页对照 `Ankole.BackgroundAgentJobs` 的实际代码实现，梳理这条完整的生命周期。

先明确最核心的设计前提：后台任务是一项**持久化工作单元**，绝非内存中的临时子进程。它的权威状态保存在 PostgreSQL 中，每一次状态流转都受并发栅栏保护并留有审计记录；每当任务进入需要通知发起方的关键状态时，系统都会向归属会话（Owner Session）投递一条标准唤醒信号——与日常聊天消息共用同一套 Signal 队列。

## 与 Sessions 的边界

实时对话回合与后台长任务属于两种截然不同的工作形态，运行时在架构上将二者明确解耦：`Sessions` 负责驱动实时的、受纪元栅栏保护的交互回合（唤醒会话、运行模型推理循环、提交可见回复）；而 `BackgroundAgentJobs` 则负责托管由某个回合委派出去的持久化可恢复工作。两者之间的交接链路完全显式可查：每条任务记录都保存着 `owner_session_id`、`source_signal_id` 和 `source_tool_call_id`，因此从“哪个回合发起了任务”到“任务如何回报结果”的完整因果链随时可以重建。

执行时，后台任务在同一个 Agent 名下独立的 `job:<id>` 专用 Session 中运转，并在关键节点向 `owner_session_id` 回报进展，拥有独立的状态机、重试预算与通知规则。

## 任务状态机

每个后台任务在六个固定状态之间流转，所有状态迁移均受严格的状态转换表约束：

```text
queued → running → waiting_on_user → running → … → succeeded | failed | stopped
```

- **`queued`**：任务已接纳入库，尚未占用该 Agent 的并发运行槽位。
- **`running`**：正在执行，占用该 Agent 的一个并发运行槽位（默认每个 Agent 最多同时运行 3 个后台任务）。
- **`waiting_on_user`**：暂停执行以等待用户或主 Agent 补充信息。此时会主动释放占用的运行槽位，待收到答复后再恢复运行。
- **`succeeded`**、**`failed`**、**`stopped`**：终态。进入终态的任务不再有任何活跃执行过程。

`Ankole.BackgroundAgentJobs.Schemas.Job` 的 Ash 状态机定义允许的状态转换。Worker 只能提交 `running` 任务的完成结果；管理员的 `external_complete` 操作可以完成 `queued`、`running` 或 `waiting_on_user` 任务。进入终态的任务不能再转换到其他状态。

## 唤醒：向 owner 回报

每当后台任务进入需要归属会话知晓的状态时，生命周期管理模块都会在提交状态变更的同一个数据库事务内，向 `owner_session_id` 追加一条唤醒事件。以下三种状态会触发唤醒：

| 任务状态 | 唤醒事件类型 |
|---|---|
| `succeeded` | `background_agent_job.completed` |
| `failed` | `background_agent_job.failed` |
| `waiting_on_user` | `background_agent_job.waiting` |

这条唤醒事件本质上就是一条标准的 Signal——经过相同的队列、相同的并发栅栏与相同的会话驱动器——投递给 `owner_session_id`，并附带任务创建时记录的 `reply_route`（渠道绑定、频道与线程标识）。归属会话无需轮询任务状态，只有在确实需要处理进展或汇报结果时才会被唤醒；而转入 `queued` 或 `running` 属于正常的内部调度过程，无需归属会话采取行动，因此不会触发唤醒。

唤醒事件的 `source_id` 同时编码了任务 ID、目标状态与尝试序号（attempt），确保任务暂停恢复后再次触发的唤醒不会与早先的唤醒事件去重混淆。

完工唤醒信号中仅内联附带一段有长度上限的结果摘要。当持久化保存的完整最终报告超出摘要长度上限时，主 Agent 可调用 `show_background_job_details` 工具并从 `result_offset: 0` 开始读取，随后将每次返回的 `result.next_offset` 传入下一次调用，循环读取直至 `next_offset` 为 `null`。按顺序拼接这些保证 UTF-8 字符边界安全的分片，即可逐字还原完整交付物——既控制了单次唤醒信号与工具响应的体积，又能无损读取任意长度的最终产出。

## 恢复与等待输入

`waiting_on_user` 是一种“任务上下文保持存活、但不白占执行槽位”的挂起状态。当后台任务遇到必须由人工拍板的分歧时，会将状态切换为 `waiting_on_user`：最新状态投影记录为 `interrupted`（错误码 `request_user_input`），并保留待决的工具调用（tool call）上下文，从而为主会话随后的答复留出精准的续接锚点。一旦收到答复，任务便重新切回 `running` 沿着原线程继续推进。若处于 `waiting_on_user` 的任务已暂停满 `10` 分钟，且最近一次模型调用报告的总 Token 数达到 `128,000` 及以上，`CodexJobSession` 恢复执行时会跳过已冷却的超大上下文窗口，直接基于受限的工作区重建信息（`job.task`、持久工作区文件、有界尝试历史及前序任务说明/报告）开启新线程，并在每次开启新线程或完成压缩后同步轮转运行时 CLI 的 `contextId`。

除在同一次任务内暂停恢复外，新任务还可以基于前序已结束的任务接力续跑：数据库通过 `continued_from_job_id` 与 `workspace_owner_job_id` 记录这条继承链，使多阶段长任务得以一路向下传递，既不丢失前序脉络，也能直接复用已有工作区文件。

## 跨 worker 故障的恢复

Worker 失效后，PostgreSQL 保留任务状态，持久 Home 保留工作区和 Codex 线程。每个任务最多允许 5 次执行失败、25 次槽位认领，以及连续 5 次回合失败。认领新槽位时递增 `attempts`；接管仍在运行的尝试不递增。基础设施中断后，可重试任务回到 `queued`，不消耗执行失败预算，但已认领的次数仍然保留。

调度器通过两条事务认领路径处理启动与续跑：

- **`claim_attempt_in_tx`** 为 `queued` 任务认领新的执行尝试。
- **`claim_continuation_in_tx`** 为收到输入的任务认领续跑尝试。

两条路径都先锁定 Agent 的容量，再锁定任务行。耗尽重试预算的任务进入 `failed`；管理员取消任务时进入 `stopped`。

`Ankole.Sessions.TurnErrorClassifier` 决定重试间隔。基础设施中断依次等待 15、30、60、120、300 秒，不消耗执行失败预算；可重试的执行失败与 Provider 容量不足依次等待 60、600、1,800、3,600、7,200 秒，并消耗执行失败预算。不可重试的拒绝立即使任务失败。

AIGateway 返回凭据池耗尽及明确的未来恢复时间时，任务退回 `queued`，释放 Worker 绑定，并预约该时间重新派发，不消耗执行失败预算。已认领的当次仍计入 25 次认领上限。恢复时间缺失或已过时，则使用常规执行重试间隔，并消耗一次执行失败预算。

## 派发与 agent 的插件

创建后台任务时可指定一套可选的工作区初始化模板。任务首次获准进入执行（Execution Admission）时，系统会在同一个事务内固化当时生效的 Provider 与模型绑定，以及当前选中的 Agent Plugin 和 Skill 列表。后续发生故障重试或暂停续接时，都会沿用这份初始快照，但会与该 Agent 当前的最新启用状态取交集：若某项已选能力在中途被管理员关闭，执行时会立即剔除；若重新开启则恢复可用；但首次准入时未选中的新增能力不会中途混入。上游访问密钥与可更新的 Skill 文件内容则始终在运行时读取最新值。

在底层接入上，`Sessions.CodexJob` 从内核 Signal 准入每次任务尝试，并将运行中引导（steer）事件与常规会话消息分道处理，防止发往主会话的普通消息误干扰后台任务。任务内的每一轮模型调用均经由 AIGateway 按已锁定的模型绑定发出；若目标 Provider 配有多把密钥，凭据挑选、会话亲和、令牌刷新与故障切换均由 AIGateway 统一托管。

后台任务与主 Agent 共用基于 `Ankole.AIAgent.Library` 的动态 `skill_view` 加载器。每次运行前，Worker 会将任务冻结的 Skill 快照与该 Agent 当前在 `Ankole.AIAgent.Library` 中已启用的 Skill 集合及 `ankole-runtime` 过滤条件取交集，并将允许使用的完整技能包（含随附文件、脚本与 MCP 声明）物化至 `/workspace/.ankole/turn-skills/<signal-id>/<skill-name>/`。每次调用 `skill_view` 时，控制面都会实时核验当前启用状态，从 `Ankole.AIAgent.Library` 读取 Skill 清单或包内相对路径文件，并附带该 Agent 当前生效的技能教训（Skill Lesson）。

每个 Turn 启动或续跑前，Worker 都会将由 `Ankole.AIAgent.Library.Contracts` 合成的完整 Agent 有效契约刷新到 `$CODEX_HOME/AGENTS.md` 和 `~/AGENTS.md`，将视觉规范刷新到 `~/DESIGN.md`。项目内的指令由工作区模板或代码仓库维护。任务上下文和技能目录通过开发者指令传入。Codex 原生子 Agent 的最短等待时间为 1 分钟，默认等待时间为 10 分钟。

## 运维界面

`/api/v2` 下的 Console API 路由提供任务查询、回合轨迹、健康检查与生命周期干预能力：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/background-agent-jobs` | 分页列出后台任务 |
| `GET` | `/api/v2/background-agent-jobs/:id` | 查看单个任务的详细状态与执行记录 |
| `GET` | `/api/v2/background-agent-jobs/health` | 查询后台任务子系统健康状态 |
| `GET` | `/api/v2/background-agent-jobs/:job_id/turns` | 列出指定任务的回合（Turn）轨迹 |
| `POST` | `/api/v2/background-agent-jobs/:id/cancel` | 取消指定后台任务 |
| `POST` | `/api/v2/background-agent-jobs/:id/complete` | 手动标记指定后台任务完成 |

发起取消会将数据库中的 Job 状态更新为 `stopped`，并向 Worker 发送实时中断指令；后续任何迟到的 Worker 执行结果能否入库提交，均由 PostgreSQL 中的 Job 状态、attempt 标识与回合版本号（Turn revision）共同裁决。

## Background Agent Jobs 不是什么

后台任务绝不是脱离管控的自由后台守护进程：它受控于固定的状态迁移表、有界的重试预算以及唯一的汇报归属会话（`owner_session_id`）。它也不是绕过权限边界的后门——后台任务以所属 Agent 的身份运行，严格受同一套权限、插件与 Skill 开关约束。此外，它也不替代 `Sessions`：二者虽然底层共享 Signal 队列与并发隔离原语，但后台任务专注于承载可跨故障恢复的长时委派工作，而 `Sessions` 专注于驱动实时对话回合。这一职责边界是刻意设计的，任何跨层协作都必须走显式定义的状态流转与信号交接，而不能直接穿透读写对方的内部状态。

## 下一步

- 了解派生后台任务并接收其汇报的实时会话机制，请参阅 [Sessions](../sessions/)。
- 了解后台任务执行期间调用的统一模型网关，请参阅 [AIGateway API](../ai-gateway/)。
- 了解任务唤醒事件如何作为标准信号送达归属会话，请参阅 [Signals](../signals/)。
