---
title: Cron 调度
description: 调度的任务导向运维视角——创建、列出、暂停、恢复、手动运行、检查运行，附完整示例。
section: User guide
order: 48
---

调度给 agent 一个节奏。cron schedule 按 cron 表达式周期性触发 session；checkback 是 agent 在回合中设定的一次性自唤醒。本页是调度面的任务导向运维视角——路由、操作、完整示例。它以具体操作补充 [调度](../schedules/) 概念页。

先把决定性的性质说清楚：调度通过 signal binding 触发，binding 决定结果投递到哪里。没有健康 binding 的调度触发到无处。先配 binding，再配调度。

## 列出和读取

```bash
curl https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

用 `GET .../cron-schedules` 列出 session 上的调度。用 `GET .../cron-schedules/:cron_schedule_id` 读取一个。调度带着 `name`、`schedule`（cron 表达式 map）、`timezone`、`status`（`active`/`paused`/`deleted`/`failed`）、`next_fire_at`、`last_fire_at`。

## 创建

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "binding_name": "main",
    "name": "morning-briefing",
    "schedule": { "cron": "0 9 * * *", "kind": "cron" },
    "timezone": "Asia/Shanghai",
    "payload": { "task": "产出今天的简报。" }
  }'
```

三个字段容易弄错：

- **`timezone`**——cron 表达式在此求值。显式设它；没有时区的调度有歧义。
- **`binding_name`**——调度通过此 binding 触发。若被禁用或不可用，触发不产生可投递结果。
- **`payload.task`**——agent 该做什么。保持简短；人设承载风格。

## 暂停和恢复

```bash
# 暂停
curl -X POST .../cron-schedules/<id>/pause -H "Authorization: Bearer $CONSOLE_TOKEN"

# 恢复
curl -X POST .../cron-schedules/<id>/resume -H "Authorization: Bearer $CONSOLE_TOKEN"
```

暂停让调度不再触发而不删除它。状态移到 `paused`；`next_fire_at` 清空。恢复重新装上规划器并重算下次触发时间。用暂停处理假日、事故或临时静音。

## 手动运行

```bash
curl -X POST .../cron-schedules/<id>/runs -H "Authorization: Bearer $CONSOLE_TOKEN"
```

手动运行立即触发调度，跳出 cron 节奏。它不推进 cron 日历——下次自然触发不受影响。用它测试新调度或按需跑一次。

## 检查运行

```bash
curl .../cron-schedules/<id>/runs -H "Authorization: Bearer $CONSOLE_TOKEN"
```

运行列表显示每次具体触发——何时发生及结果。`failed` 状态的调度在反复触发失败后触及失败策略；恢复或重建前先读运行找原因。

## 更新和删除

```bash
# 更新（改表达式、时区或任务）
curl -X PATCH .../cron-schedules/<id> -H "..." -d '{ "schedule": { "cron": "0 8 * * *", "kind": "cron" } }'

# 删除
curl -X DELETE .../cron-schedules/<id> -H "Authorization: Bearer $CONSOLE_TOKEN"
```

更新取消其待执行的周期事件并重新装上规划器，改过的表达式干净生效。删除会删除调度——需要时重建。

## Checkback（只读）

checkback 是 agent 在回合中设定的一次性自唤醒。运维界面只读：

```bash
# 列出待执行 checkback
curl .../sessions/<session_id>/checkbacks -H "Authorization: Bearer $CONSOLE_TOKEN"

# 取消一个 checkback
curl -X DELETE .../sessions/<session_id>/checkbacks/<scheduled_event_id> -H "Authorization: Bearer $CONSOLE_TOKEN"
```

## 一个完整示例

在上海时间创建一个每天 09:00 的简报，手动测试，然后让它跑：

1. 确认 agent session 上的 `main` binding 已启用。
2. `POST .../cron-schedules`，`cron: "0 9 * * *"`、`timezone: "Asia/Shanghai"`、`binding_name: "main"`。
3. `POST .../cron-schedules/<id>/runs`——在绑定的频道观察首次输出。
4. 输出对了就留着。不对就 `PATCH` `payload.task` 或人设，再跑一次。

## 本指南不是什么

它不是概念页——调度模型、字段和失败策略见[调度](../schedules/)。它不是故障排查指南——调度不触发时读[调度故障排查](../cron-troubleshooting/)。它也不是 cron 表达式参考——表达式语法是标准 cron，`timezone` 字段才是要紧的那个。

## 下一步

- 概念页，读[调度](../schedules/)。
- 故障排查，读[调度故障排查](../cron-troubleshooting/)。
- 使用调度的自动化形态，读[自动化蓝图](../automation-blueprints/)。
