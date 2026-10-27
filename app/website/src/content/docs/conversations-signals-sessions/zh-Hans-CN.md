---
title: 对话、信号与执行会话
description: Ankole 的核心架构取舍与工程代价，以及基于源码逐项核对的 deepseek-harness、pi durable 和 qm 横向对比。
section: Developer guide
order: 100.5
---

Ankole 面向企业组织运行 Agent：驱动 Agent 开展工作的触发源既可能是群聊发言，也可能是定时计划、外部系统事件或后台子任务完工通知；每一次执行都必须有明确的责任主体，并且能够在进程重启后无缝恢复推进。

为此，我们将三类核心运行事实交由三个彼此独立的模块分别掌管：**对话（Conversations）**负责保存参与者的公开发言，**信号（Signals）**负责接纳并触发工作，**执行会话（Sessions）**负责驱动并恢复具体执行；与此同时，模型侧的推理上下文由 AIGateway 统一托管，向外部聊天平台发消息的意图与回执则由投递模块（Delivery）独立记录。

## 四个设计选择

### 对话发言与工作分开记录

对话表只记录对参与者公开可见的发言，而执行日志则单独记录模型推理调用与工具执行结果。在同一场多方对话中，每个参与的 Agent 都拥有自己独立的执行会话与模型上下文状态，其产出的回复对全体对话参与者可见；执行会话严格限定在所属对话内部，绝不跨对话混用。

权限边界上，凡是交互式或由人类触发的回合——包括由人类发言唤醒的 `may_intervene` 群聊主动介入回合（Agent 发言绝不会唤醒其他 Agent）——一律按 **`Human ∩ Agent` 权限交集**（`%Ankole.AuthZ.Actor{principal: agent, interactive_principal: human}`）执行；而没有交互人类参与的纯自主回合（如 `cron` 定时触发、`webhook` 事件及后台服务通知）则按 Agent 自身的权限执行。简言之：消息对谁可见取决于所在对话，而当轮能调什么资源则取决于当轮绑定的 `AuthZ.Actor`。

### 所有刺激由 Signals 接纳

无论是聊天发言、定时到点、外部 Webhook 事件还是后台任务完工通知，全都统一收敛到同一个信号准入模块，走完持久化落盘、幂等去重、归因与授权绑定以及目标会话解析。

路由目标时，Signal 既可直接点名指定目标执行会话，也可由对话参与关系或信号路由规则自动推导。对话宿主类适配器同时承担发言观察与回复投递，而纯事件源适配器只需负责生成 Signal——因此，日后接入新的外部事件源时，无需另起炉灶再造一套任务入队机制。

### 定时工作使用独立执行会话

每条 Cron 定时规则都在固定独立的 `cron:<schedule_id>` 执行会话中运行，每个后台任务也各自拥有专属的执行会话。当它们需要将阶段成果发往某个聊天群时，只需向目标对话追加一条发言；目标对话在随后的轮次中只会像读普通消息一样读取这条公开发言，而不会把定时任务或后台会话内部的冗长推理与工具调用历史混入进来。

### 模型状态只有一个所有者

AIGateway 统一面向内部 Agent 与外部客户端提供有状态的 Responses 调用及托管工具（Hosted Tools）：会话运行时只管决定每轮喂入什么输入、挂载哪些工具、从哪个检查点续接以及何时发起压缩；而底层模型历史状态的持久化存储与协议执行则全权交由 AIGateway 负责。

这里所说的 AIGateway `conversation` 专指模型侧的推理会话状态，与人类和 Agent 共同参与的公开业务对话（`Ankole.Conversations`）完全分属两层。如果让会话运行时在外部自己再存一套 Agent 模型历史，系统中就会衍生出两套相互竞争的模型状态实现。

## 经过源码核对的比较

下表基于 **2026-10-14** 重新核查的各开源仓库源码整理，所有引用链接均锁定至核查当刻的具体 Commit：

| 项目 | 核对 Commit |
| --- | --- |
| deepseek-harness | [`571902028a75`](https://github.com/deepseek-ai/deepseek-harness/commit/571902028a75c64c1d767f4ae5fd099485f0ddf0) |
| pi (`packages/durable`) | [`910149912ca2`](https://github.com/earendil-works/pi/commit/910149912ca29d7ae4eaa945bb2b53eb84c68264) |
| qm | [`cf0e475f50c0`](https://github.com/yc-software/qm/commit/cf0e475f50c061e0ae00701999fb14a9272bba7d) |

| 对比维度 | deepseek-harness | pi durable | qm | Ankole |
| --- | --- | --- | --- | --- |
| 记录模型 | 仅追加的 `SessionEvent` 日志，模型上下文从中派生。[源码][D-session] | 不可变条目（entries），与任务记录及文档更新原子提交。[规范][P-spec] | PostgreSQL `session_entries` 单表；Slack 与 Web UI 展示同一份执行会话历史。[存储][Q-session]、[设计][Q-spec] | 公开对话发言与模型内部工作日志分表存储 |
| 共享上下文 | 面向单个 Agent / Session 的历史，支持插件自定义投影。[源码][D-session] | 由宿主应用定义消息类型与状态归约策略。[源码][P-guide] | 历史条目必须对当轮受众中的每一位成员均可见才允许进入上下文。[源码][Q-audience] | 对话内每个 Agent 拥有独立执行会话；对话受众共享可见发言，模型状态彼此隔离，权限按轮次实时裁决 |
| 刺激接入 | 支持直接输入与定时跟进（follow-up），另配独立的实验性 Webhook 运行时。[定时][D-schedule]、[webhook][D-webhook] | 提供 Submission 与持久化收件箱（inbox）原语。[源码][P-guide] | Cron、Webhook 与主循环各自维护独立机制（其 SPEC 文档亦指出了循环另建机制的问题）。[源码][Q-spec] | 所有内部与外部触发源共用同一套持久化 Signal 准入契约 |
| 定时与外部触发 | 持久化提醒回到原 Session；Webhook 无持久队列、无重试、无崩溃重放与内置去重。[定时][D-schedule]、[webhook][D-webhook] | 核心包提供 submission / task 接口，外部触发器由宿主自行对接。[源码][P-guide] | 每次 Cron 触发新建 `cron:<id>:fire:<hash>` 独立会话。[源码][Q-cron] | Cron 复用稳定的专属执行会话；外部 Signal 持久落库准入，产出结果按路由投递至目标对话 |
| 外部投递 | 定时提醒仅限回传至原 Session。[源码][D-schedule] | 外部消息渠道由宿主应用自行实现。[源码][P-guide] | 维护持久化投递表，超时未送达即直接作废。[源码][Q-delivery] | 统一通过对话宿主适配器投递，支持有界退避重试，且失败、过期与结果未明状态均清晰可查 |
| 存储与并发 | 本地 JSONL 文件后端；单 Session 单写者，依赖操作系统文件锁互斥。[源码][D-store] | 支持内存、SQLite、JSONL 与 Durable Object；单进程独占存储，无跨进程锁。[源码][P-guide] | 基于 PostgreSQL，当前源码统一读写 `session_entries` 表。[源码][Q-session] | PostgreSQL 作为唯一权威存储，支持多租户隔离，并在每次启动执行前核验实时权限 |
| 模型上下文 | 从 Session 事件日志动态派生。[源码][D-session] | 从已提交的不可变 entries 归约生成。[规范][P-spec] | 从按当前受众权限过滤后的历史记录实时拼装。[源码][Q-audience] | 由 AIGateway 统一持久化与跨轮续接，会话运行时负责组装当轮输入 |

注：qm 的设计文档（SPEC）中虽仍沿用“tape”一词阐述概念，但已明确记录存储层切换至 `session_entries` 并将旧表清理列为后续收尾事项；上表严格以其当前实际生效的代码路径为准，不将早期的过渡双写计为现状。[源码][Q-spec]

## 代价与接受的限制

选择这套分层解耦架构，也意味着我们主动接受了以下工程代价与边界约束：

- **领域概念与代码分层更多**：对话、信号、执行会话、外部投递与模型上下文状态各自独立建模，比单日志平铺模型理解门槛更高。
- **排障时往往需要对照两份记录**：定位复杂线上问题时，有时需要同时查阅公开对话发言记录与对应执行会话的内部模型日志。
- **群聊回合产出的结果对全群参与者可见**：当轮在合法授权下调取并写入回复的数据，会进入该群聊的共享上下文。工具调用权限（资源 `agent:<uid>:tool:<tool_name>`、动作 `invoke` 及参数 `context.request.args`）与 Pod 操作权限均基于当轮的 `AuthZ.Actor` 裁决；相比之下，qm 采用按在场受众逐条过滤历史条目的方案。[qm 源码][Q-audience]
- **基础设施与运维分量更重**：引入 PostgreSQL 强事务与独立 Elixir 控制面，相比基于本地 JSONL 文件的轻量级 Harness 带来了更高的部署门槛与事务延迟。
- **生成中途的流式半截文本不落盘**：若进程在流式输出中途崩溃，尚未收尾提交的半段文本会直接丢弃；恢复执行时可能会重发当轮模型请求、直接复用已落盘的工具结果，并对执行状态不明的外部操作停止盲目重跑（不承诺对外部系统的副作用恰好执行一次）。相比之下，pi durable 仅在每次存储提交完成后才对外发布进度。[源码][P-guide]
- **有状态上下文受底层传输格式约束**：跨轮有状态续接要求底层传输格式能够无损回放已保存的历史条目。
- **所有接入端必须遵守统一的信号准入契约**：无论是新增聊天渠道适配器还是内部触发源，都必须严格对齐同一套 Signals 准入规范。
- **长期运行的 Cron 会话会持续累积历史**：固定复用 `cron:<schedule_id>` 会话虽然保留了跨周期记忆，但也因此依赖定期历史压缩；而 qm 则采取每次定时触发都开启全新空白会话的策略。[源码][Q-cron]

## 其他方案更适合的场景

- 如果只是个人开发者在本机终端里搭配单个编程助手使用，`deepseek-harness` 或 `pi` 的本地轻量部署显然更加省心。
- 如果希望把一套支持断点恢复的 Agent 循环作为库直接嵌入自研应用中，`pi durable` 提供了更小巧紧凑的嵌入式边界。
- 如果是纯粹围绕 Slack 频道运作、且习惯直接将模型会话日志当作唯一历史账本的团队机器人，`qm` 的单表模型会更直观直接。

进一步了解 Ankole 中从一条发言演变为可恢复任务的完整数据流，请参阅[架构](../architecture/)；查阅核心领域术语对照表，请参阅[快速开始](../quickstart/#terminology)。

[D-session]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/core/session/README.md
[D-store]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/session/session-persistence-jsonl/README.md
[D-schedule]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/schedule/schedule/README.md
[D-webhook]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/experimental/webhook/README.md
[P-guide]: https://github.com/earendil-works/pi/blob/910149912ca29d7ae4eaa945bb2b53eb84c68264/packages/durable/README.md
[P-spec]: https://github.com/earendil-works/pi/blob/910149912ca29d7ae4eaa945bb2b53eb84c68264/packages/durable/docs/spec.md
[Q-session]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/sessions/postgres-session-store.ts
[Q-audience]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/resolution/context-filter.ts
[Q-cron]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/cron/scheduler.ts
[Q-delivery]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/delivery/delivery-store.ts
[Q-spec]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/docs/SPEC.md
