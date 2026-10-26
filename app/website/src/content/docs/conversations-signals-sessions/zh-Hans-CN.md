---
title: 对话、信号与执行会话
description: Ankole 的设计选择与代价，以及经过源码核对的 deepseek-harness、pi durable 和 qm 比较。
section: Developer guide
order: 100.5
---

Ankole 为组织运行 Agent。工作可以来自发言、时间、外部事件或任务完成，需要明确负责的主体，并能在进程重启后继续。

三种事实分别由不同的组件拥有：**对话**保存参与者的发言，**信号**触发工作，**执行会话**执行工作。AIGateway 保存模型会话状态，Delivery 记录向外部平台发言的意图和结果。

## 四个设计选择

### 对话发言与工作分开记录

对话记录保存参与者可见的发言，工作日志保存模型调用和工具结果。每个 Agent 在对话中拥有自己的执行会话和模型状态，各执行会话的工作对全体参与者可见。执行会话不跨对话。

交互式与由人类触发的轮次（包括由人类发言唤醒的 `may_intervene` 介入轮次；Agent 发言绝不会唤醒其他 Agent）按 **`Human ∩ Agent` 权限交集**（`%Ankole.AuthZ.Actor{principal: agent, interactive_principal: human}`）执行；无交互人类的自主非人类轮次（`cron`、`webhook` 及后台服务触发）按 Agent 自身的权限执行。可见范围取决于对话，执行权限取决于当轮的 `AuthZ.Actor`。

### 所有刺激由 Signals 接纳

发言、时间、外部事件和任务完成共用一个接纳所有者：持久化、去重、归因与授权、目标解析。

signal 可以直接指定执行会话，否则由对话参与关系或信号路由规则选择目标。对话宿主适配器观察发言并执行投递，事件源适配器只产生 signal。新增来源不需要另建接纳机制。

### 定时工作使用独立执行会话

cron 规则使用稳定的 `cron:<schedule_id>` 执行会话，后台任务也有自己的执行会话。它们可以向某个对话发言。对话的下一轮读取这条发言，不引入其他执行会话的模型调用和工具结果。

### 模型状态只有一个所有者

AIGateway 为内部 Agent 和外部客户端提供有状态的 Responses 调用与 hosted tools。运行时决定输入、工具、续接和压缩，平台负责保存模型状态并执行这些机制。

AIGateway conversation 指模型会话状态，与参与者共享的公开对话分开。把 Agent 历史移到运行时，会出现第二套模型状态实现。

## 经过源码核对的比较

下表基于 **2026-10-14** 重新检查的仓库快照。链接固定到本次核对的 commit。

| 项目 | 核对 commit |
| --- | --- |
| deepseek-harness | [`571902028a75`](https://github.com/deepseek-ai/deepseek-harness/commit/571902028a75c64c1d767f4ae5fd099485f0ddf0) |
| pi (`packages/durable`) | [`910149912ca2`](https://github.com/earendil-works/pi/commit/910149912ca29d7ae4eaa945bb2b53eb84c68264) |
| qm | [`cf0e475f50c0`](https://github.com/yc-software/qm/commit/cf0e475f50c061e0ae00701999fb14a9272bba7d) |

| 方面 | deepseek-harness | pi durable | qm | Ankole |
| --- | --- | --- | --- | --- |
| 记录模型 | 只追加的 `SessionEvent` 日志，模型历史从中派生。[源码][D-session] | 不可变 entries，与 task 记录、文档更新原子提交。[规范][P-spec] | PostgreSQL `session_entries`；Slack 和 Web UI 展示同一执行会话历史。[存储][Q-session]、[设计][Q-spec] | 对话发言与模型工作日志分开 |
| 共享上下文 | 面向 Agent / Session 的历史，可由插件定义投影。[源码][D-session] | 宿主定义消息类型与应用策略。[源码][P-guide] | 历史必须对本轮受众中的每个成员可见。[源码][Q-audience] | 每个 Agent 在对话中有自己的执行会话；受众共享，模型状态独立，授权按轮次 |
| 刺激接入 | Agent 输入和定时 follow-up；另有 webhook 运行时。[定时][D-schedule]、[webhook][D-webhook] | Submission 与持久 inbox。[源码][P-guide] | cron、webhook、loop 各自有机制；SPEC 批评 loop 单独建立机制。[源码][Q-spec] | 所有来源共用持久 signal 接纳契约 |
| 定时与外部触发 | 持久提醒回到原 Session；webhook 没有队列、重试、崩溃重放或内置去重。[定时][D-schedule]、[webhook][D-webhook] | 包提供 submission / task API，外部触发由宿主接入。[源码][P-guide] | 每次 cron 触发使用 `cron:<id>:fire:<hash>`。[源码][Q-cron] | cron 使用稳定执行会话；外部 signal 持久接纳，结果发到目标对话 |
| 外部投递 | 定时投递限于原 Session。[源码][D-schedule] | 外部渠道由宿主应用提供。[源码][P-guide] | 持久投递记录，过期即作废。[源码][Q-delivery] | 对话宿主适配器；有界重试；失败、过期、结果不明状态可见 |
| 存储与并发 | 本地 JSONL 后端；每个 Session 一个写者，由操作系统锁保护。[源码][D-store] | Memory、SQLite、JSONL、Durable Object；一个进程拥有存储，无跨进程锁。[源码][P-guide] | PostgreSQL；当前代码只读写 `session_entries`。[源码][Q-session] | PostgreSQL 为权威；租户隔离；每次开始执行时检查授权 |
| 模型上下文 | 从 Session 日志派生。[源码][D-session] | 从已提交 entries 归约。[规范][P-spec] | 从按受众过滤的历史组装。[源码][Q-audience] | AIGateway 保存与续接，运行时决定输入 |

qm 的 SPEC 仍用「tape」描述设计，但已记录切换到 `session_entries`，并将旧表清理安排在之后。这里按当前代码比较，不把早先的双写方案当作现状。[源码][Q-spec]

## 代价与接受的限制

- **概念和代码更多。** 对话、信号、执行会话、投递和模型状态需要各自的所有者。
- **排查需要两份记录。** 对话发言和执行会话的工作日志可能需要同时查看。
- **群内工作会向全体参与者披露结果。** 当轮授权取得的数据会进入对话的共享上下文。工具调用权限（资源 `agent:<uid>:tool:<tool_name>`、动作 `invoke` 及 `context.request.args`）与 Pod 操作均基于当轮的 `AuthZ.Actor` 进行评估；qm 则按受众过滤历史。[qm 源码][Q-audience]
- **部署更重。** PostgreSQL 事务与控制面，相比本地文件 harness 增加延迟和运维成本。
- **半段文本不持久。** 崩溃会丢失未完成的文本；恢复可能重做模型调用，复用已记录的工具结果，不盲目重复结果不明的操作。外部副作用不承诺恰好一次。pi durable 只在存储提交后发布进度。[源码][P-guide]
- **上下文受平台约束。** 有状态请求需要能无损重放存储条目的 wire。
- **统一接纳契约。** 所有生产者和适配器都必须遵循同一套 Signals 接纳契约。
- **cron 历史会积累。** 稳定执行会话保留上下文，需要压缩；qm 每次触发都新建执行会话。[源码][Q-cron]

## 其他方案更适合的场景

- 个人开发者在本机与一个 Agent 工作时，deepseek-harness 或 pi 的部署更简单。
- 将可恢复的 Agent loop 嵌入应用时，pi durable 提供更小的运行时边界。
- 以 Slack 为中心、以模型会话历史为记录依据的团队助手，qm 的结构更直接。

发言到工作的流程见[架构](../architecture/)，统一术语见[快速开始](../quickstart/#terminology)。

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
