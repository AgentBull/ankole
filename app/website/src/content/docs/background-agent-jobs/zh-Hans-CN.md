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

每一次状态变更都必须通过 `transition_allowed?/2` 校验：处于 `queued` 的任务绝不可能跳过 `running` 直接变为 `succeeded`，而已进入终态的任务也无法再次流转。这张转换表就是系统的硬性契约，业务代码中的任何路径都不得绕过。

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

`waiting_on_user` 是一种“任务上下文保持存活、但不白占执行槽位”的挂起状态。当后台任务遇到必须由人工拍板的分歧时，会将状态切换为 `waiting_on_user`：最新状态投影记录为 `interrupted`（错误码 `request_user_input`），并保留待决的工具调用（tool call）上下文，从而为主会话随后的答复留出精准的续接锚点。一旦收到答复，任务便重新切回 `running` 沿着原线程继续推进。

除在同一次任务内暂停恢复外，新任务还可以基于前序已结束的任务接力续跑：数据库通过 `continued_from_job_id` 与 `workspace_owner_job_id` 记录这条继承链，使多阶段长任务得以一路向下传递，既不丢失前序脉络，也能直接复用已有工作区文件。

## 跨 worker 故障的恢复

由于任务权威状态持久保存在 PostgreSQL 中，底层 Worker 容器销毁或失联只是一次可自动自愈的运行期事件，不会造成任务丢失。运行时为每个后台任务分配了有界的容错重试预算——最多允许 5 次执行尝试（attempt）、最多容忍连续 5 个回合失败；如果某次尝试在尚未真正启动执行前就因基础设施原因中断，`requeue_unstarted_attempt` 会退还当次尝试计数并将任务放回 `queued`（若是首次尝试还会一并清空 `started_at`，使其恢复为全新待启动状态）。

调度器通过两条事务认领（claim）路径分别处理两类启动场景：

- **`claim_attempt_in_tx`**：为一次全新的执行尝试认领待运行任务。
- **`claim_continuation_in_tx`**：在暂停恢复后认领任务以续接原有进度。

两条路径都严格按照固定锁顺序先获取该 Agent 的并发槽位锁，再以 `FOR UPDATE` 锁定任务行，确保同一 Agent 下的并发调度器始终以确定性的顺序完成认领而不会死锁。一旦重试次数耗尽，任务便转入 `failed`；收到人工取消指令则转入 `stopped`。相邻两次重试之间固定间隔 30 秒退避延迟，避免瞬时故障期间密集冲击上游模型 Provider。

如果任务因 AIGateway 凭据池配额耗尽而受阻，且网关给出了明确的未来恢复时间点（`retry_at`），生命周期模块会将任务退回 `queued`、释放当前 Worker 绑定，并按该恢复时间点预约下一次派发。不过，已消耗的当次 attempt 仍会计入 5 次总预算内，防止持续配额故障导致无限重排；若网关未返回恢复时间或时间已过，则直接走常规的 30 秒有界重试路径，不会立即盲目重发。

## 派发与 agent 的插件

创建后台任务时可指定一套可选的工作区初始化模板。任务首次获准进入执行（Execution Admission）时，系统会在同一个事务内固化当时生效的 Provider 与模型绑定，以及当前选中的 Agent Plugin 和 Skill 列表。后续发生故障重试或暂停续接时，都会沿用这份初始快照，但会与该 Agent 当前的最新启用状态取交集：若某项已选能力在中途被管理员关闭，执行时会立即剔除；若重新开启则恢复可用；但首次准入时未选中的新增能力不会中途混入。上游访问密钥与可更新的 Skill 文件内容则始终在运行时读取最新值。

在底层接入上，`Sessions.CodexJob` 从内核 Signal 准入每次任务尝试，并将运行中引导（steer）事件与常规会话消息分道处理，防止发往主会话的普通消息误干扰后台任务。任务内的每一轮模型调用均经由 AIGateway 按已锁定的模型绑定发出；若目标 Provider 配有多把密钥，凭据挑选、会话亲和、令牌刷新与故障切换均由 AIGateway 统一托管。

后台任务与主 Agent 复用同一个 Ankole `skill_view` 加载器：常规兼容 Skill 会直接列入任务的 Skill 目录；声明了 `brain-recall-only: true` 的 Skill 则不在目录中列出，而是通过 Brain 按需检索发现（当调用 `get_page` 命中对应的发现记录时，会自动转发给 `skill_view` 加载）。每次实际读取 `SKILL.md` 或附属参考文件前，加载器都会向控制面实时核验当前 Agent Plugin 与 Skill 的有效启用状态，因此即便任务正在运行，也无法继续读取已被管理员紧急关闭的 Skill。

首次初始化任务工作区时，运行器会自动拼装工作区根目录下的 `AGENTS.md`：若指定了工作区模板则置于最前，随后追加渲染后的任务上下文（包含该 Agent 的 `SOUL.md`、`MISSION.md` 及本次执行参数）。同时，生成的 Codex 项目配置会将原生子 Agent 等待时间的下限设为 1 分钟、默认值设为 2 分钟（上限不额外覆盖，沿用 Codex 默认值），以减少因过短空等待超时导致的模型无效重入（背景详见 [openai/codex#35259](https://github.com/openai/codex/issues/35259)）。后续续接的线程会直接复用已生成的项目 `AGENTS.md`。

## 运维界面

Console API 提供三条核心管理路由供运维监控与干预：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/background-agent-jobs` | 分页列出后台任务 |
| `GET` | `/background-agent-jobs/:job_id` | 查看单个任务的详细状态与执行记录 |
| `POST` | `/background-agent-jobs/:job_id/cancel` | 取消指定后台任务 |

发起取消会将数据库中的 Job 状态更新为 `stopped`，并向 Worker 发送实时中断指令；后续任何迟到的 Worker 执行结果能否入库提交，均由 PostgreSQL 中的 Job 状态、attempt 标识与回合版本号（Turn revision）共同裁决。

## Background Agent Jobs 不是什么

后台任务绝不是脱离管控的自由后台守护进程：它受控于固定的状态迁移表、有界的重试预算以及唯一的汇报归属会话（`owner_session_id`）。它也不是绕过权限边界的后门——后台任务以所属 Agent 的身份运行，严格受同一套权限、插件与 Skill 开关约束。此外，它也不替代 `Sessions`：二者虽然底层共享 Signal 队列与并发隔离原语，但后台任务专注于承载可跨故障恢复的长时委派工作，而 `Sessions` 专注于驱动实时对话回合。这一职责边界是刻意设计的，任何跨层协作都必须走显式定义的状态流转与信号交接，而不能直接穿透读写对方的内部状态。

## 下一步

- 了解派生后台任务并接收其汇报的实时会话机制，请参阅 [Sessions](../sessions/)。
- 了解后台任务执行期间调用的统一模型网关，请参阅 [AIGateway API](../ai-gateway/)。
- 了解任务唤醒事件如何作为标准信号送达归属会话，请参阅 [Signals](../signals/)。
