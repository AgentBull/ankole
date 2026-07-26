---
title: 自动化蓝图
description: 把 Cron 计划任务、Checkback、后台任务和信号路由规则组合成定时、自延迟或事件驱动的自动化。
section: Guides
order: 309
---

Ankole 里的自动化不是一个工具，而是三种触发器与 agent 判断的组合。本页给出常见形态的可直接用蓝图，每个都由其它指南覆盖的部件构成。复制形态、换上你的话题和频道，然后在几次运行里调人设。

先把决定性的性质说清楚：这里的自动化是*agent 驱动*的。触发器唤醒 agent；agent 决定做什么。没有单独的"自动化脚本"语言——schedule 带的 prompt，或 webhook 投递的事件，就是 agent 工作的依据。

## 三种触发器

每个蓝图用三种触发器之一。挑蓝图之前先知道自己需要哪种。

| 触发器 | 如何触发 | 载体 | 用什么建 |
|---|---|---|---|
| **调度** | 按 cron 节奏（每小时、每天、每周） | cron schedule 上的一个 `task` | [调度](../schedules/) |
| **自延迟（checkback）** | agent 在回合里设一个延迟自唤醒 | agent 的 `check_back_later` 工具 | [调度](../schedules/) |
| **事件驱动（webhook）** | 外部系统 POST 到 webhook 正门 | 一个 `signals_gateway.webhook_handler` plugin | [SignalsGateway](../signals-gateway/) |

三种模式都通过 Agent 的路由规则投递：计划任务使用一条规则，Agent 从 Webhook 事件醒来后发帖也使用一条规则。路由模型之外没有单独的“把自动化结果投递到频道”设置。

## 蓝图：每日摘要（调度）

计划任务每天触发一次，Agent 根据任务说明收集和整理信息，再把结果发到绑定的聊天渠道。先按[计划任务](../schedules/)创建并手动验证，再设置每天运行的 Cron 表达式。

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "binding_name": "main",
    "name": "daily-digest",
    "schedule": { "cron": "0 9 * * *", "kind": "cron" },
    "timezone": "Asia/Shanghai",
    "payload": { "task": "产出今天 mission 里那些话题的摘要。" }
  }'
```

可调部分：cron 表达式（节奏）、`timezone`（"9 点"是哪里的）、`task`（做什么）、人设（怎么做）。依赖 schedule 之前先手动运行验证。

## 蓝图：每小时哨兵（调度，除非触发否则安静）

一个频繁触发但通常保持安静的 schedule——agent 盯着一个来源，只有当某事要紧才发帖。秘诀是人设的"除非否则安静"规则，配上频繁的 cron。

```json
{ "cron": "0 * * * *", "kind": "cron" }
```

配一份点名阈值的 mission："仅当新的严重公告影响我们技术栈时发帖。否则保持安静。"一个每小时跑、大多数时候安静的 schedule 才是对的——哨兵的价值在罕见的发帖，不在频繁的。

## 蓝图：延迟跟进（checkback）

agent 在回合里被问某事，决定稍后再回来。不是固定 cron，agent 自己用 `check_back_later` 设一次性唤醒。agent 那一侧的形态是"一小时后再看"——agent 调工具；运维界面只读。

适合不在节奏上的工作："一小时后看部署完成没"、"站会后再读这个 thread"。agent 掌握时机；你通过 `GET /agents/:agent_uid/sessions/:session_id/checkbacks` 看待执行的 checkback，可用 `DELETE` 取消。

## 蓝图：研究并报告（调度 + 后台任务）

计划任务触发一个回合。若工作需要长时间搜索和交叉验证，Agent 会把它交给 [Deep Research 后台任务](../deep-research-job/)，而不是让当前回合一直等待。

1. cron schedule 触发它的 `task`。
2. agent 判断工作很长，调 `create_background_job`。
3. schedule 的回合结束；任务自己跑。
4. 任务向拥有它的 session 发回 `background_agent_job.completed`，由 binding 投递。

这就是如何得到一个"每周深度研究"，而 schedule 的回合不必跑一小时。schedule 踢一脚；任务干活。

## 蓝图：事件驱动（webhook）

一个外部系统——provider webhook、CI 结果、监控告警——POST 到 `/webhooks/v1/:handler_id/:instance_id/:kind`，一个声明的 `signals_gateway.webhook_handler` plugin 把它变成 actor 事件。agent 醒来、读事件、决定做什么。

这是 Microsoft 365 directory webhook（`entra-id`，kinds `directory`）以及任何 plugin 声明的自定义 webhook handler 背后的形态。蓝图是：在 plugin 里声明 handler，把外部系统指向 webhook URL，让人设决定事件意味着什么。webhook 正门鉴权的是*provider*（Bot Framework JWT、Graph `clientState`，或任何 handler 用来签名的东西），从不鉴权管理员。

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
- **想让外部系统唤醒 agent？** webhook，通过声明的 handler。
- **想要安静观察加定期综合？** binding 策略 + schedule。

## Ankole 里的自动化不是什么

它不是脚本语言，没有 YAML 步骤，也没有“如果这样则那样”的流程图。触发器只负责唤醒 Agent，由角色设定和模型决定下一步。它也不是独立的投递系统，所有结果仍通过路由规则交付；更不能绕过权限，自动化 Agent 和由人唤醒的 Agent 使用同一套 AuthZ 授权。自动化由触发器、Agent 和路由规则组成，真正作出决定的是 Agent。

## 下一步

- 调度界面，读[调度](../schedules/)。
- 后台执行与协作方式，读[后台 Agent 任务](../background-jobs/)。
- webhook 正门，读 [SignalsGateway](../signals-gateway/) 开发者页。
