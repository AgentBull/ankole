---
title: Session 管理
description: 如何观察和管理 agent session——列出 session、检查调度和 checkback、理解 actor 模型中的 session。
section: User guide
order: 53
---

一个 session 是一个长时 actor——单位 `{agent_uid, session_id}`，持有会话的上下文、工作空间状态和已调度工作。运维者不直接创建或删除 session；它们在信号到达或调度触发时创建，并作为持久状态存在。本页是 session 面的运维者视角：如何列出、什么挂在 session 上、需要关注时怎么办。

先把决定性的性质说清楚：session 是**持久 PostgreSQL 状态，不是 live 进程**。session 控制器进程是临时的——它按需启动、串行化 session 的调度、可能崩溃并重启。session 本身——其 actor 事件、调度、checkback——在数据库中存活。你观察持久状态，不是进程。

## 列出 session

```bash
curl https://ankole.example.com/api/v1/agents/<agent_uid>/sessions \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /agents/:agent_uid/sessions` 列出一个 agent 的 session。每个 session 由其 `session_id`（base64url 编码字符串）标识，与 `agent_uid` 配对构成 actor key。

## 什么挂在 session 上

一个 session 携带：

- **Actor 事件**——持久收件箱。到达的信号、跑过的回合、发出的命令（steer、stop、retry）。它们排队、按 `queue_sequence` 排序、一次处理一个。
- **Cron 调度**——触发该 session 的周期性调度。运维面见 [Cron 调度](../cron-schedules-ops/)。
- **Checkback**——agent 设定的一次性自唤醒。概念见[调度](../schedules/)。
- **Activation**——回合运行时拥有该 session 的 live 租约。隔离模型见 [Actor Runtime](../actor-runtime/)。

## 检查调度和 checkback

```bash
# session 上的调度
curl https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

# session 上的 checkback
curl https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/checkbacks \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

这些是调度和 checkback 面的 session 范围视图。一个有卡住调度或一堆待处理 checkback 的 session 需要关注——见[调度故障排查](../cron-troubleshooting/)。

## session 需要关注时

- **调度卡住**——读运行列表；调度可能 `paused`、`failed`、或触发进禁用的 binding。见 [Cron 调度](../cron-schedules-ops/)。
- **Checkback 堆积**——agent 设了从未解决的自唤醒。用 `DELETE .../checkbacks/:id` 取消它们，或让它们触发并观察结果。
- **session 似乎无响应**——检查 agent Principal 是否活跃、binding 是否启用、worker 是否就绪。无响应的 session 通常是无响应的 binding 或 worker，不是 session 问题。
- **actor 事件在 `dead_letter`**——反复回合失败把事件推过重试预算。读事件的错误、修底层原因、让事件重试或解决。

## 运维者不做什么

- **创建 session**——session 在信号到达或调度触发时由系统创建。没有 `POST /sessions` 路由。
- **删除 session**——session 作为持久状态存在；没有 `DELETE /sessions/:id` 路由。不再需要的 session 只是停止接收事件。
- **重启 session**——session 控制器通过 OTP 监督器自行重启。运维者重启 worker，不是 session。

## 本指南不是什么

它不是 Actor Runtime 概念页——activation 隔离栏、三重隔离、恢复模型见 [Actor Runtime](../actor-runtime/)。它不是会话历史指南——转写归 AIGateway，见 [AIGateway](../ai-gateway/)。它不是调度故障排查指南——见[调度故障排查](../cron-troubleshooting/)。

## 下一步

- actor 模型与恢复，读 [Actor Runtime](../actor-runtime/)。
- 调度，读 [Cron 调度](../cron-schedules-ops/)。
- 故障排查，读[调度故障排查](../cron-troubleshooting/)。
- Console 路由，读 [Console API 参考](../console-api/)。
