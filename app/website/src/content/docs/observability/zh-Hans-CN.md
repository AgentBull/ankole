---
title: 可观测性
description: 运行 Ankole 时观察什么——Console 读取界面映射到它们回答的运维问题，加上如何读结构化日志。
section: Guides
order: 311
---

Ankole 里的可观测性不是一个仪表盘，而是 Console API 上一组读取界面，各自回答不同问题。本页把运维者实际问的问题映射到回答它的路由，并展示如何读位于其下的结构化日志。

先把决定性的性质说清楚：持久读取界面（session、会话、任务、审计）是 PostgreSQL 状态，不是临时指标。出问题时，产生它的进程已逝，记录仍在。日志告诉你进程在做什么；Console 界面告诉你系统*决定了*什么。

## 运维者的问题与回答之处

| 运维者问题 | Console 路由 | 读到什么 |
|---|---|---|
| "这个 agent 现在在做什么？" | `GET /agents/:agent_uid/sessions` | agent 的活跃 session |
| "一个回合实际调了什么？" | `GET /ai-gateway/conversations` 和 `.../conversations/:id/messages` | 近期回合的模型调用和消息 |
| "后台任务卡住了吗？" | `GET /background-agent-jobs` 和 `.../:job_id` | 任务状态（`queued`/`running`/`waiting_on_user`/`succeeded`/`failed`/`stopped`）、尝试、result/error |
| "worker 健康吗？" | `GET /agent-computer-workers` | worker 状态和指派 |
| "schedule 触发了吗？" | `GET .../cron-schedules/:id/runs` | 具体触发及其结果 |
| "agent 记住了什么，谁改的？" | `GET /brain/audit-log` 和 `.../entries/:id/audit-log` | 追加式的 Brain 知识历史 |
| "dreaming 具备运行条件吗？" | `GET /brain/dreaming-fitness` | dreaming 前置条件和近期状态 |
| "session 有哪些待执行的唤醒？" | `GET .../sessions/:id/checkbacks` | agent 设的待执行 checkback |
| "Brain 整体健康吗？" | `GET /brain/status` | Brain 配置与健康 |

每一行都是无状态、bearer 鉴权的 Console 读取——与 [Console 运维操作](../console-operations/)按任务索引的是同一界面。

## 如何读其下的日志

控制面输出结构化日志，形态稳定：事件名、人类消息、结构化字段，严重级别从 `debug` 到 `notice`/`warning`/`error`。两个 `ANKOLE_LOG_*` 旋钮控制你看到什么：

- **`ANKOLE_LOG_LEVEL`**——`debug | info | warning | error`。默认 `info`。为某次复现降到 `debug`，处理完调回去。留在 `debug` 的部署又吵又慢，非法值启动时拒绝。
- **`ANKOLE_LOG_FORMAT`**——`json`（默认，供摄入）或 `pretty`（本地经 `kit logs pretty` 阅读）。

生产里，格式留 `json`，让日志摄入器处理。事件名是连接键——先按事件名搜，再按字段收窄。完整旋钮集见[环境变量](../environment-variables/)。

## 三种常出现的模式

### "机器人不回复"

从模型向外查，不从 schedule 向内查。[FAQ](../faq/) 顺序适用：

1. `/ai-gateway/conversations` 看回合——到底有没有模型调用？
2. `/agents/:agent_uid/sessions`——session 醒了吗？
3. `agent-computer-workers`——worker 就绪了吗？
4. signal binding——启用且健康吗？

会话路由通常是最快的判据：一次有模型调用但返回错误的回合指向 provider；一次没有模型调用的回合指向 binding 或 worker。

### "后台任务行为异常"

`GET /background-agent-jobs/:job_id` 带 `status`、`attempts`、`result`、`error`。状态词汇告诉你形态：`waiting_on_user` 是暂停等人，不是卡住；五次尝试后的 `failed` 是真实失败，不是临时故障。决定是否重试前先读 `error`——配置错误重试到同样的失败。完整词汇见[后台任务（运维视角）](../background-jobs-ops/)。

### "agent 的记忆里有东西变了吗？"

Brain 的审计日志是追加式的，还原本身也被审计。`GET /brain/audit-log` 显示 agent 相信过什么、谁改过它的历史；`GET /brain/entries/:id/audit-log` 收窄到一个条目。这是"agent 为什么这么想？"的界面——答案在审计轨迹里，不在模型当前输出里。

## 可观测性不是什么

它不是指标管线。Ankole 不输出 Prometheus 计数器或内置 Grafana 仪表盘；读取界面是你通过 Console 查询的 PostgreSQL 状态，日志是你用已有工具摄入的结构化事件。想要仪表盘，在日志和 Console 读取之上自建——数据在那里，呈现是你的选择。

它也不是对一次回合每个工具调用的实时追踪。要那种粒度，会话的消息和 worker 日志是来源；Console 界面用于决定和持久状态，不是逐步。

## 下一步

- 完整读取界面，读 [Console 运维操作](../console-operations/)和 [Console API 参考](../console-api/)。
- 日志旋钮，读[环境变量](../environment-variables/)。
- 任务状态词汇，读[后台任务（运维视角）](../background-jobs-ops/)。
