---
title: 自动化蓝图
description: 把触发器与 Agent session、automation job、后台任务和信号路由规则组合成自动化。
section: Guides
order: 309
---

Ankole 的自动化由三种触发器之一与两种消费者之一组合。Agent session 处理需要判断、记忆或对话的工作；automation job 用确定性脚本处理机械工作。本页给出常见形态、可以直接套用的蓝图。

Ankole 不增加工作流语言或步骤图。Automation job 是 Agent Home 内普通的 Bun `main.ts`。触发器 owner 继续负责时间或入口，所选消费者处理不变的事件。只有脚本发出事件或失败策略要求唤醒时，Agent 才返回。

## 三种触发器

每个蓝图用三种触发器之一。挑蓝图之前先知道自己需要哪种。

| 触发器 | 如何触发 | 载体 | 用什么建 |
|---|---|---|---|
| **调度** | 按 cron 节奏（每小时、每天、每周） | cron schedule 上的一个 `task` | [调度](../schedules/) |
| **自延迟（checkback）** | Agent 在回合里设置一个延迟触发器 | Agent 的 `check_back_later` 工具 | [调度](../schedules/) |
| **事件驱动（webhook）** | 外部系统 POST 到 capability URL | 一个 `webhook.received` 事件 | [Webhook 委托](../webhook-delegations/) |

三种触发器无论唤醒 Agent 还是运行脚本，都产生同一个 CloudEvents 信封。消费者选择只改变收件人，不改变触发事实。直接唤醒与脚本发出的事件都通过归属 session 的路由规则返回。

## 选择消费者

| 消费者 | 适用情况 | 触发结果 |
|---|---|---|
| **Agent session** | 每次 delivery 都需要判断、记忆、运行时选择工具或面向用户回复 | 触发器写入 ActorEvent 并唤醒会话 |
| **Automation job** | 处理只是确定性的获取、比较、解析或预定动作 | 触发器创建持久脚本 run；脚本可以静默结束，也可以向归属 session 发出事件 |

处理方式还不清楚时，先直接唤醒 Agent。只有已经证明是机械工作的部分才移入 automation job。这样脚本保持小巧，模型也不会进入空转轮询。

## 蓝图：每日摘要（调度）

计划任务每天触发一次，Agent 根据任务说明收集和整理信息，再把结果发到绑定的聊天渠道。先按 [计划任务](../schedules/) 创建并手动验证，再设置每天运行的 Cron 表达式。

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "owner_session_id": "<session_id>",
    "binding_name": "main",
    "name": "daily-digest",
    "schedule": { "cron": "0 9 * * *", "kind": "cron" },
    "timezone": "Asia/Shanghai",
    "delivery": { "targets": [{ "binding_name": "main", "signal_channel_id": "<signal_channel_id>" }] },
    "payload": { "task": "产出今天 mission 里那些话题的摘要。" },
    "idempotency_key": "daily-digest-1"
  }'
```

可调部分：cron 表达式（节奏）、`timezone`（“9 点”是哪里的）、`task`（做什么）、人设（怎么做）。依赖该 schedule 之前，先手动运行验证。

## 蓝图：确定性哨兵（调度 + Automation Job）

Schedule 频繁触发、检查过程机械且通常无结果时，使用 automation job。Agent 写入并注册脚本，再把 cron schedule 绑定到它的 `automation_job_id`。

```json
{ "cron": "0 * * * *", "kind": "cron" }
```

条件不成立时，脚本读取来源后直接结束，不调用 `emitEvent`；条件成立时，脚本把有界来源事实发到归属 session，再由 Agent 复核并决定行动。注册前手工验证不调用 SDK 的分支，注册后用真实测试触发器验证每个调用 `context()` 或 `emitEvent` 的分支。

每次运行都需要语义判断时，继续使用直接唤醒 Agent 的 schedule。Automation Job 合同见 [Worker CLI 能力](../cli-capabilities/)。

## 蓝图：延迟跟进（checkback）

agent 在回合里被问某事，决定稍后再回来。不是固定 cron，agent 自己用 `check_back_later` 设一次性唤醒。agent 那一侧的形态是"一小时后再看"——agent 调工具；运维界面只读。

适合没有固定节奏的工作：”一小时后看部署完成没”、”站会后再读这个 thread”。agent 掌握时机；你通过 `GET /agents/:agent_uid/checkbacks` 查看待执行的 checkback，可用 `DELETE` 取消。

## 蓝图：研究并报告（调度 + 后台任务）

计划任务触发一个回合。若工作需要长时间搜索和交叉验证，Agent 会把它交给 [Deep Research 后台任务](../deep-research-job/)，而不是让当前回合一直等待。

1. cron schedule 触发它的 `task`。
2. agent 判断工作很长，调 `create_background_job`。
3. schedule 的回合结束；任务自己跑。
4. 任务向拥有它的 session 发回 `background_agent_job.completed`，由 binding 投递。

这就是如何得到一个"每周深度研究"，而 schedule 的回合不必跑一小时。schedule 负责启动；任务负责执行。

## 蓝图：事件驱动（webhook）

外部系统，例如源代码仓库或 CI provider，调用一条短期有效的 Ankole capability URL。Endpoint 接受 delivery 后，先持久提交所选消费者记录，再返回成功。

Agent 必须检查外部对象当前状态并判断事件时，使用默认的直接消费者。当确定性脚本可以预先过滤或对账回执时，把 endpoint 绑定到 automation job。两条路径都把回执视为不可信输入，有后果的事实仍以外部权威来源为准。Capability 的安全与生命周期规则见 [Webhook 委托](../webhook-delegations/)。

## 蓝图：观察并升级（binding 策略 + schedule）

一个观察频道的团队助理，加一个定期总结它所观察内容的 schedule。binding 策略（`may_intervene` 或 `record_only`）决定 agent 实时看到什么；schedule 决定它何时综合。

- binding：`unaddressed_group_message_policy: record_only`——agent 看到一切、什么不说、构建上下文。
- schedule：每天或每周的"这个频道发生了什么"摘要。
- agent 通过 binding 发帖，借助 session 近期上下文。

这把观察（持续、安静）与综合（定时、发声）分开。适合实时回复会是噪声、但定期摘要有价值的频道。

## 选一个蓝图

- **想让它按钟点跑？** 调度。按"每次都发"还是"仅当某事要紧"选摘要或哨兵形态。
- **想让它中途回来某事？** checkback。agent 掌握时机。
- **想让长工作被钟点踢一脚？** 调度 + 后台任务。
- **想做频繁机械检查但不启动模型？** 调度或 Checkback + automation job。
- **想让外部系统继续工作？** Webhook 委托，消费者选择直接 Agent 或 automation job。
- **想要安静观察加定期综合？** binding 策略 + schedule。

## Ankole 里的自动化不是什么

它不是工作流语言，没有 YAML 步骤、平台 DAG、隐藏游标或通用事件总线。Automation job 可以运行小脚本，但脚本自行拥有状态并保证重复执行安全。投递仍使用归属 session 的路由规则，自动化也不能绕过权限。判断交给 Agent，只有机械部分交给脚本。

## 下一步

- 调度界面，读 [调度](../schedules/)。
- 确定性脚本消费者，读 [Automation Job](../automation-jobs/)。
- 后台执行与协作方式，读 [后台 Agent 任务](../background-jobs/)。
- 外部事件 capability，读 [Webhook 委托](../webhook-delegations/)。
