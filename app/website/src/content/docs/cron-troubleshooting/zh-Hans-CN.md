---
title: 调度故障排查
description: 当 cron schedule 不触发、在错的时间触发、或触发了却没发帖时——按顺序走这些检查，对照真实的状态、binding 和 model profile 边界。
section: Guides
order: 310
---

行为异常的 schedule 落入四类之一：不触发、在错的时间触发、触发了却没发帖、进了 `failed`。本页按最快找到原因的顺序处理它们。多数 schedule 问题是配置，不是代码。

要记住的决定性性质：schedule 只拥有*时间*。它在 cron 表达式所指的那一刻、按它所带的时区，产生一次唤醒边。之后的一切——binding 是否投递、agent 是否跑、模型是否解析——是别的子系统的边界，修复几乎从不在 schedule 自身上。

## 症状：没触发

### 检查 1：确认 schedule 存在且为 `active`

```bash
curl https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

找到该 schedule，确认它的 `status`。状态词汇是 `active`、`paused`、`deleted`、`failed`：

- **`paused`**——有人暂停了它。用 `POST .../cron-schedules/:id/resume` 恢复。
- **`deleted`**——被移除了；重建。
- **`failed`**——schedule 触及其失败策略。读运行列表（`GET .../cron-schedules/:id/runs`）找原因；修底层问题，再按策略允许重建或恢复。
- **`active`** 但 `next_fire_at` 在过去——调度器没捡起它，或控制面在触发窗口期间停了。

只有 `active` 的 schedule 会触发。这是第一项检查，因为它是最常见的安静失败。

### 检查 2：确认 `next_fire_at` 已设且在未来

`next_fire_at` 为 null 的 `active` schedule 已装上但没有下次触发计划——通常因为刚恢复、规划器还没重算，或因为表达式无法被归一化。`PATCH` 该 schedule（`PATCH .../cron-schedules/:id`）重新触发归一化；若 `next_fire_at` 仍为 null，schedule 表达式非法，归一化已悄悄拒绝。

### 检查 3：触发时控制面在运行吗？

调度器是一个控制面进程。控制面停了、在重启、或在应当触发时跨窗口迁移，那次触发就丢了——Ankole 不为停机窗口补触发。若节奏跨宕机要紧，围绕它规划；一个在 09:00–09:05 重启期间错过的每日 09:00 schedule，明天才触发，不在 09:06。

## 症状：在错的时间触发

### 检查 4：时区

cron 表达式在 schedule 的 `timezone` 里求值。"错的时间"最常见的原因是时区不匹配——团队在 `Asia/Shanghai`、却在 UTC 里求值的 09:00 schedule 会早五小时触发。确认 `timezone` 匹配团队所在地。`next_fire_at` 在该时区里计算；拿同时区的钟和它比。

### 检查 5：cron 表达式本身

格式错的表达式要么在归一化时被拒（`next_fire_at` 保持 null——见检查 2），要么被归一化成你本意以外的东西。手动触发 schedule（`POST .../cron-schedules/:id/runs`）确认*任务*管用；然后单独修表达式。手动运行不校验 cron 时序——它校验的是下游一切。

## 症状：触发了却没发帖

schedule 触发了；问题在下游。此时故障排查不再是关于 schedule。

### 检查 6：schedule 触发所走的 binding

schedule 通过它的 `binding_name` 触发，它决定频道和回复模式。若该 binding 被禁用、不可用（记有 `unavailable_reason`）、或指向 agent 不能发帖的频道，触发产生了一个无处可去的事件。通过 `GET /agents/:agent_uid/signal-bindings` 确认 binding 已启用且健康。

### 检查 7：agent 的 model profile

定时回合是一次真实回合——它需要和手驱动回合同样的 model profile。若 `primary`/`light`/`heavy` 未绑或解析到凭证过期的 provider，定时回合会像会话回合一样失败，只是没人看着所以安静。通过 `/agents/:agent_uid/model-profiles` 和 provider 行确认。

### 检查 8：worker

定时回合需要一个就绪的 worker。繁忙的部署上，schedule 触发时 worker 池可能已满；回合排队但要等槽空才跑。检查 `/background-agent-jobs` 和触发窗口的 worker 日志。"有时管用、有时不管用"的 schedule 通常是容量问题，不是 schedule 问题。

## 症状：进了 `failed`

### 检查 9：读运行，再修底层原因

`failed` 中的 schedule 在反复触发失败后触及其失败策略。运行列表（`GET .../cron-schedules/:id/runs`）记录每次触发及其结果——读最近几次失败的成因。成因几乎总是检查 6–8 之一（binding、model profile、worker），不是 schedule 自身。先修下游问题再恢复或重建，否则 schedule 会再次失败。

不要在不读运行的情况下删除 `failed` 的 schedule 来"重置"——你会丢掉告诉你修什么的失败历史。

## 最快路径：一次手动运行

若不确定问题是时序还是下游，先手动运行 schedule：

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules/<cron_schedule_id>/runs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

手动运行产生一次具体触发事件，记录在运行列表。若手动运行发帖了，问题是时序（检查 4–5）或调度器（检查 1–3）。若手动运行也不发帖，问题在下游（检查 6–8），cron 时序从来不是问题。

## 本页不是什么

它不是 schedule 设计指南——schedule 的形态和字段读[调度](../schedules/)。它也不是让 schedule 补触发的方式；停机期间错过的触发按设计保持错过。schedule 子系统刻意很薄：它拥有时间，把其余交给别的。排查它主要是排查它交出去的东西。

## 下一步

- 调度界面，读[调度](../schedules/)。
- 使用 schedule 的自动化形态，读[自动化蓝图](../automation-blueprints/)。
- schedule 触发所走的 binding，读 [Signal binding](../signal-bindings/)。
