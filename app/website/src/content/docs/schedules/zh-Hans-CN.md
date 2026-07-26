---
title: 调度
description: 如何给 agent 一个周期性节奏——session 上的 cron schedule、暂停与恢复、手动运行，以及 checkback 自唤醒模式。
section: User guide
order: 21
---

调度让 agent 能按时间醒来，而不是只在收到消息时才醒。Ankole 有两种：**cron schedule** 按 cron 表达式周期性地唤醒 session，**checkback** 是 agent 在回合里设定的延迟自唤醒。本页是两者的运维视角。

先把决定性的性质说清楚：调度只拥有时间语义。哪些该触发、是否已触发、是否已取消，这些持久正确性住在领域表和 actor 事件幂等性里，不在调度器进程里。一行写着“09:00 触发”的 schedule 产生一次唤醒边；之后发生什么由 actor 运行时决定。

## 调度住在哪里

一个 cron schedule 属于某一个 agent session，并带着一个 binding 名——触发应当通过哪个 signal binding 走。所以 schedule 的范围是 `(agent_uid, session_id, binding_name)`。session 是被唤醒的 actor；binding 是唤醒事件走的路由，它决定 agent 响应所用的 channel 和回复模式。

## cron schedule 字段

一个 cron schedule 带着你预期的字段，加上几个值得知道的：

| 字段 | 含义 |
|---|---|
| `name` | 这条 schedule 的标签 |
| `schedule` | cron 表达式 map（normalizer 接受的结构化形态） |
| `timezone` | cron 表达式求值所用的时区 |
| `payload` | schedule 触发时投递给 agent 的内容 |
| `status` | `active`、`paused` 或已删除 |
| `next_fire_at` / `last_fire_at` | 规划器视角的下次与上次触发时间 |
| `failure_policy` | 某次触发失败时怎么办 |
| `idempotency_key` | 防止重复创建 schedule |

`timezone` 是运维者容易踩的字段：没有时区的 cron 表达式有歧义，Ankole 按你设的时区求值表达式。即使部署只在一个时区运行，也显式设它——这让 schedule 在不同部署之间可移植。

## 创建、读取、更新

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "binding_name": "...", "name": "morning-briefing", "schedule": { ... }, "timezone": "Asia/Shanghai", "payload": { ... } }'
```

用 `GET /agents/:agent_uid/sessions/:session_id/cron-schedules` 列出 session 上的 schedule，用 `GET .../cron-schedules/:cron_schedule_id` 读取一个，用 `PATCH .../cron-schedules/:cron_schedule_id` 更新一个。更新会取消其待执行的周期事件并重新装上规划器，于是改过的表达式干净地生效，而不是和旧的赛跑。

## 暂停、恢复、手动运行

三个操作覆盖运维生命周期：

- **暂停**——`POST .../cron-schedules/:cron_schedule_id/pause`。让 schedule 不再触发而不删除它。状态移到 `paused`；`next_fire_at` 清空。
- **恢复**——`POST .../cron-schedules/:cron_schedule_id/resume`。重新装上已暂停的 schedule 并重算 `next_fire_at`。
- **手动运行**——`POST .../cron-schedules/:cron_schedule_id/runs`。立即触发 schedule，跳出它的 cron 节奏。用来测试一条 schedule 或按需跑一次；它不会推进 cron 日历。

手动运行产生一次具体触发事件，和自然触发一样被记录，所以你可以在运行列表（`GET .../cron-schedules/:cron_schedule_id/runs`）里把它和自然触发的放在一起查看。

## checkback：自唤醒

checkback 是另一种形态的调度：agent 在回合里设定的延迟自唤醒，用于“一小时后再看一眼”。它是一次性的，不是周期性的。agent 通过自己的工具创建它；运维界面只读：

- `GET /agents/:agent_uid/sessions/:session_id/checkbacks`——列出 session 的待执行 checkback。
- `DELETE /agents/:agent_uid/sessions/:session_id/checkbacks/:scheduled_event_id`——取消一个 checkback。

替换一个待执行的 checkback 会把被取消的事件保留为审计历史，所以你能看到 agent 推迟了什么、何时被取消。

## 出问题的时候

- **某条 schedule 没触发**——检查 `status` 是 `active`、`next_fire_at` 在未来、该 session 的 signal binding 已启用。binding 被禁用的 schedule 不会产生可投递的唤醒事件。
- **在错误的时间触发了**——检查 `timezone`。在错误时区求值的 cron 表达式，会在错的时区里看起来像对的时间触发。
- **手动运行没有效果**——在运行列表里看这次运行；产生了 0 个 actor 事件的触发，通常意味着 session 无法接受它（agent Principal 被禁用，或 binding 不可用）。
- **出现了重复 schedule**——`idempotency_key` 就是为防止这件事而存在；在重试同一次创建时复用它。

## 下一步

- 路由，读 [Console API 参考](../console-api/)。
- schedule 所唤醒的 session，读 [Actor Runtime](../actor-runtime/) 开发者页。
- 触发所走的 binding，读 [Signal binding](../signal-bindings/)。
