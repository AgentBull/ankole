---
title: 自动化蓝图
description: 将触发器与 Agent 会话、Automation Job、后台任务和信号路由规则组合成自动化流程，并理清与 Workflow 的边界。
section: Guides
order: 309
---

Ankole 的触发式自动化由“三类触发器”与“两类消费者”自由组合而成：需要语义判断、长期记忆或多轮对话的工作交由 Agent 会话（Session）承接；纯粹的机械检查与规则处理则交由 Automation Job 通过确定性脚本完成。本页汇总最常用的落地组合模式与可直接套用的配置蓝图。

Automation Job 并不是一套专用的工作流编排语言或可视化流程图，它只是存放在 Agent 云盘指定文件夹下的普通 Bun `main.ts` 脚本。定时计划或 Webhook 入口依旧由各自的触发器模块管理，每次触发产生的标准事件直接交由所选消费者处理；只有在脚本主动发出事件，或按失败告警策略需要介入时，系统才会唤醒 Agent。

[Workflow](../workflows/) 则属于另一类完全不同的执行机制：由主 Agent 在单次对话回合内发起一场固定结构、边界明确的子 Agent 并行编排。Workflow 不能订阅定时调度或 Webhook 触发器，也不会在后台轮询外部状态；只有当单次用户请求内部包含若干可并行开展的独立分析判断时，才适合选用 Workflow。

## 三种触发器

每套自动化蓝图都以以下三种触发器之一作为起点，选型前请先明确触发方式：

| 触发器 | 触发时机 | 事件载体 | 配置入口 |
|---|---|---|---|
| **定时调度（Schedule）** | 按固定 Cron 节奏触发（每小时、每天、每周等） | Cron 计划上的 `task` 载荷 | [计划任务](../schedules/) |
| **延迟回查（Checkback）** | Agent 在当前回合内自行设定一次性延后提醒 | Agent 调用内置的 `check_back_later` 工具 | [计划任务](../schedules/) |
| **事件驱动（Webhook）** | 外部系统向专属 Capability URL 发起 `POST` 请求 | `webhook.received` 事件 | [Webhook 委托](../webhook-delegations/) |

无论后续是直接唤醒 Agent 还是运行自动化脚本，这三种触发器都会生成格式一致的 CloudEvents 事件信封。切换消费者只会改变事件接收方，不会改变触发事件本身的内容；无论是直接唤醒产生的回复，还是脚本上报事件后触发的回复，最终都通过归属 Session 的信号路由规则向外投递。

## 选择消费者

| 消费者 | 适用场景 | 触发后的行为 |
|---|---|---|
| **Agent Session** | 每次触发都需要结合记忆推理、动态挑选工具或直接撰写面向用户的回复 | 触发器写入一条 Signal 并唤醒目标会话 |
| **Automation Job** | 处理逻辑只是确定性的数据拉取、阈值比对、格式解析或预设动作 | 触发器创建一次持久化脚本运行记录；脚本可直接静默退出，也可调用接口向归属会话上报事件 |

如果初期还不确定处理逻辑能否写成纯规则，建议先让触发器直接唤醒 Agent；等跑通几轮、确认其中某部分纯粹属于机械巡检后，再将该环节抽离为 Automation Job。这样既能让脚本保持精简，也能避免大模型空转轮询浪费 Token。

## 蓝图：每日摘要（调度）

通过定时任务每天固定触发一次，由 Agent 按任务说明搜集汇总信息，并将摘要发往绑定的聊天群或私聊。配置时建议先按 [计划任务](../schedules/) 创建任务并手动触发验证一遍，确认效果符合预期后再开启每日定时 Cron 表达式。

通过命令行调用以下 Console API 前，请先从已登录的浏览器中获取会话 Cookie 与 `x-csrf-token` 请求头的值：

```bash
curl -X POST https://ankole.example.com/api/v2/agents/<agent_uid>/cron-schedules \
  -H "Cookie: $CONSOLE_COOKIE" \
  -H "x-csrf-token: $CSRF_TOKEN" \
  -H "Content-Type: application/vnd.api+json" \
  -d '{
    "data": {
      "owner_session_id": "<session_id>",
      "binding_name": "main",
      "name": "daily-digest",
      "idempotency_key": "daily-digest-1",
      "schedule": { "kind": "cron", "expression": "0 9 * * *" },
      "timezone": "Asia/Shanghai",
      "delivery": { "targets": [{ "binding_name": "main", "conversation_id": "<conversation_uuid>" }] },
      "payload": { "task": "产出今天 mission 里那些话题的摘要。" }
    }
  }'
```

常见可调参数包括：Cron 表达式（触发频率）、`timezone`（决定“早上 9 点”按哪个时区换算）、`task`（具体汇总内容）以及 Agent 自身的长期设定（汇报语气与格式）。正式投入日常值守前，请务必先手动触发测试一次。

## 蓝图：确定性哨兵（调度 + Automation Job）

当巡检频率很高、检查逻辑固定，且绝大多数时候“一切正常无事发生”时，最适合搭配 Automation Job。可让 Agent 编写并注册巡检脚本，再将高频 Cron 计划绑定到该脚本的 `automation_job_id`：

```json
{ "kind": "cron", "expression": "0 * * * *" }
```

运行期间，只要监控指标未触发阈值，脚本拉取完外部数据便直接退出，不调用 `emitEvent`；一旦发现异常越界，脚本才将截取好的关键数据上报给归属 Session，唤醒 Agent 复核上下文并决定后续动作。在正式注册前，应先手动运行验证不依赖 SDK 的纯逻辑分支；注册完成后，再通过真实的测试触发器逐一跑通调用 `context()` 与 `emitEvent` 的分支。

反之，如果每次触发都离不开语义理解与综合判断，则无需绕道脚本，直接让定时计划唤醒 Agent 即可。Automation Job 的完整运行时契约请参阅 [Worker CLI 能力](../cli-capabilities/)。

## 蓝图：延迟跟进（checkback）

用户在对话中交代了一件事，Agent 判断现在时机未到、需要过一阵子再回来看——这类场景无需配置固定周期的 Cron，Agent 会在回合中自行调用 `check_back_later` 工具设下一次性延迟唤醒。对 Agent 而言，这就像给自己定了一个“一小时后再看一眼”的闹钟；而在 Console 运维界面上，这类待办提醒以只读列表展示。

这种模式非常适合没有固定周期的临时跟进，例如“一小时后确认发版有没有成功”或“等早会结束后再来汇总这段讨论”。跟进时机完全由 Agent 自主把握；管理员可通过 `GET /api/v2/checkbacks?agent=<agent_uid>` 查看待执行的回查项，或调用 `DELETE /api/v2/agents/:agent_uid/checkbacks/:scheduled_event_id` 取消指定提醒。

## 蓝图：研究并报告（调度 + 后台任务）

定时计划唤醒一次会话后，如果任务涉及耗时较长的全网检索与多源交叉印证，Agent 会将其转交为 [Deep Research 后台任务](../deep-research-job/)，而不会卡住当前调度回合干等：

1. Cron 计划到点触发预设的 `task`。
2. Agent 评估发现研究体量较大，调用 `create_background_job` 派发后台任务。
3. 本次调度触发的前台回合随即干净结束，后台任务在独立工作区中持续推进。
4. 研究完成后，后台任务向归属 Session 发回 `background_agent_job.completed` 信号，最终报告经由信号路由规则投递到目标群聊。

借助这一组合，就能轻松实现“每周一自动产出深度行业周报”，而无需让单次定时回合硬跑一个小时：定时计划只管准点发令，长时执行全部交给后台任务。

## 蓝图：事件驱动（webhook）

代码仓库、CI/CD 平台或告警系统等外部服务，可以直接向一条带时效限制的 Ankole Capability URL 推送事件。Webhook 端点收到请求后，会先将目标消费者的待处理记录持久化落库，确认提交成功后再向调用方返回响应。

如果每次收到事件都需要 Agent 实时查询外部系统最新状态并做综合研判，保持默认的 Agent Session 直接消费即可；如果可以先用确定性脚本做一轮签名过滤、噪音剔除或账单核对，则可将 Webhook 端点绑定到 Automation Job。无论走哪条路径，系统都会将外部推送的载荷视为不可信输入——凡涉及有业务后果的关键事实，Agent 都会先向外部权威数据源二次核实，再采取行动或对外答复。关于 Capability URL 的安全机制与生命周期规则，请参阅 [Webhook 委托](../webhook-delegations/)。

## 蓝图：观察并升级（binding 策略 + schedule）

如果你希望在团队频道里配备一名平时安静旁听、定期帮忙梳理重点的群助理，可以将信号路由的群聊观察策略与定时调度结合起来：路由策略（`may_intervene` 或 `record_only`）决定 Agent 平时能看到哪些群消息，定时调度决定它何时开口做阶段性汇总。

- **信号路由策略**：设为 `unaddressed_group_message_policy: record_only`——Agent 静默收录群内全部发言以积累上下文，平时绝不插话。
- **定时调度**：配置每日下班前或每周五的固定计划，要求汇总“本频道近期讨论的核心进展与待办”。
- **定期汇报**：到点后 Agent 结合会话近期积累的完整上下文提炼摘要，并通过同一条路由规则发回群内。

这种拆分把“平时持续静默观察”与“定期集中发声汇总”解耦开来，非常适合那些实时插话会干扰讨论、但阶段性纪要又很有价值的业务频道。

## 选一个蓝图

- **想按固定钟点定期运行？** 选**定时调度**。每次都要发报告就用“每日摘要”模式；只有出状况才需吭声就用“确定性哨兵”模式。
- **想让 Agent 过一会儿自己回来看某件事？** 选 **Checkback**，由 Agent 在对话中自主设定唤醒时间。
- **想按固定周期启动一项耗时很长的深度任务？** 选**定时调度 + 后台任务**。
- **想高频巡检外部状态，又不想每次都消耗模型调用？** 选**定时调度（或 Checkback）+ Automation Job**。
- **想在单次对话回合内并行拆解若干独立子问题？** 选 **Workflow**，并行跑完后向当前会话返回一份汇总结论。
- **想让外部系统主动推送事件来触发后续处理？** 选 **Webhook 委托**，再按需搭配直接唤醒 Agent 或 Automation Job 预筛。
- **想平时安静旁听群聊、定期输出阶段总结？** 选**信号路由观察策略 + 定时调度**。

## Ankole 里的自动化不是什么

Ankole 的触发式自动化不是重型工作流引擎：没有繁琐的 YAML 步骤编排、平台级 DAG 状态图、隐藏的隐式游标或通用消息总线。Automation Job 虽然支持运行自定义脚本，但需要由脚本自身管理业务状态并保证重跑幂等；所有对外消息依然严格遵循归属 Session 的信号路由规则，任何自动化手段都无法绕过系统的权限边界。

产品内名为 Workflow 的特性同样不承担外部触发编排职责：它仅用于在单次任务内运行固定的编排逻辑以并发扇出（fan-out）有界子 Agent，既不能订阅外部触发器，也无法挂起等待后续外部输入。简言之：开放式权衡判断交给 Agent，高频机械巡检交给 Automation Job，单回合内的有界并行核验交给 Workflow。

## 下一步

- 配置定时任务与延迟回查，请参阅 [计划任务](../schedules/)。
- 了解确定性巡检脚本的使用方式，请参阅 [Automation Job](../automation-jobs/)。
- 了解单回合内的有界子 Agent 并行编排，请参阅 [Workflow](../workflows/)。
- 了解长时后台任务的派发与交互协作，请参阅 [后台 Agent 任务](../background-jobs/)。
- 配置面向外部系统的事件接收地址，请参阅 [Webhook 委托](../webhook-delegations/)。
