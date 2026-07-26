---
title: 性能调优
description: 容量旋钮——并发回合、数据库连接池、Postgres 最大连接数、worker 回合上限、按 agent 任务槽——以及决定一套部署能同时做多少的它们之间的关系。
section: Guides
order: 319
---

Ankole 里的性能主要是容量：一次能跑多少回合、它们能从连接池取多少连接、一个 agent 能并行跑多少任务。本页命名旋钮、给默认值，并——要紧的部分——解释它们如何关联，因为只调一个不调其余，是你得到慢部署或失败部署的方式。

先把决定性的性质说清楚：旋钮构成一条链。并发回合需要数据库连接；数据库连接由 Postgres 限定；任务槽放大 agent 能跑的工作。只抬一个不抬其余，链在最弱环节断——回合排队、连接耗尽、或 Postgres 拒绝连接。针对你的负载形态把它们作为一组调，不是一个一个调。

## 容量链

一个回合触及控制面（用数据库连接池）、worker（跑模型循环）、Postgres（服务连接池）。关系，一句话：

```text
(并发回合) × (每回合连接数)  ≤  数据库连接池大小  ≤  Postgres max_connections
```

每个回合持有数据库工作；每个数据库连接来自 Postgres。如果你的并发回合设置意味着比连接池允许更多的连接，回合在连接池上排队。如果连接池大小意味着比 Postgres 允许更多的连接，连接被拒。默认值让单台小主机可用；扩展意味着一起抬它们。

## 旋钮

| 旋钮 | 默认 | 限制什么 |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_TURNS` | 9 | worker 将接受的并发 actor 回合 |
| `ANKOLE_DATABASE_POOL_SIZE` | 10 | 控制面数据库连接池 |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | 300 | Postgres `max_connections`（内置服务器） |
| `agent_computer.background_agent_job.max_turns_per_worker` | 可配置 | 后台任务每个 worker 的回合上限 |
| `max_running_per_agent` | 3 | 每个 agent 最多三个运行中后台任务 |

默认（9 回合、10 连接池、300 Postgres）保守，适合单台小主机。调优问题是当部署比那更忙时抬哪个、抬多少。

## 按症状调

不同症状指向不同旋钮。动任何东西之前先读症状。

### "回合启动慢"（排队）

worker 池满时回合排队——`ANKOLE_MAX_CONCURRENT_TURNS` 是 worker 接受的并发回合上限。若[可观测性](../observability/)界面显示回合在等槽，抬上限。但只抬到链的其余允许的程度：更多并发回合意味着更多数据库工作，若连接池已近上限，抬回合上限只是把队列从 worker 移到连接池。

### "回合一旦跑起来就慢"（数据库饱和）

持有数据库连接的回合在连接池耗尽时等待。抬 `ANKOLE_DATABASE_POOL_SIZE`——但只到 Postgres 允许的范围。内置 Postgres 默认 300 连接；外部服务器有自己的 `max_connections`。若连接池大小接近 Postgres 上限，先抬 Postgres 上限（或让内置服务器的 `ANKOLE_POSTGRES_MAX_CONNECTIONS` 增长），再抬连接池。

### "后台任务排队"（agent 槽饱和）

每个 agent 最多并发跑 `max_running_per_agent`（3）个任务。若一个 agent 有三个 `running`、更多在 `queued`，上限是限制——不是 worker、不是连接池。要么接受队列，要么把工作摊到更多 agent（各有自己的三个槽）。抬 `max_running_per_agent` 很少是对的动作；按 worker 回合上限（`max_turns_per_worker`）和全局回合上限反正挡着它。

### "provider 调用是瓶颈"（不是 Ankole 旋钮）

若 `/ai-gateway/conversations` 显示模型调用占回合大部分时间，瓶颈是 provider，不是 Ankole。没有容量旋钮修这个——见[成本管理](../cost-management/)的模型侧杠杆（更便宜的 `primary`、更低 `reasoning_effort`），它们也让回合更快。

## 一个完整容量示例

一个更忙的部署，比如 5 个活跃 agent，各跑 1–2 个任务并在频道回答：

- **并发回合**——抬 `ANKOLE_MAX_CONCURRENT_TURNS` 匹配现实峰值（15–20），不是理论最大。
- **数据库连接池**——抬 `ANKOLE_DATABASE_POOL_SIZE`，让连接池不是排队点（此负载 20–30）。
- **Postgres**——确认 `ANKOLE_POSTGRES_MAX_CONNECTIONS`（300）舒适地超过连接池加 worker 自己的连接加余量；通常够，但外部服务器可能需要抬自己的 `max_connections`。
- **按 agent 任务槽**——留在 3；把更多工作摊到 agent，而不是抬它。

数字不是魔法——它们是"在峰值时处理你的负载、在任何环节不排队的最小集合"，你通过每次改动后观察[可观测性](../observability/)界面找到它们。

## 不只是 worker 容量，还有 worker 数量

Kubernetes 上，worker 是一个可水平扩展的 Deployment——更多 worker pod，各有自己的 `ANKOLE_MAX_CONCURRENT_TURNS`。容量算术是 `worker pod × 每 worker 回合`，仍受数据库连接池和 Postgres 约束。Compose（单主机）上，你有一个 worker；扩展意味着抬它的回合上限，抬到主机和数据库允许的范围。

单 worker 的主机是限制时，水平 worker 扩展是更干净的路径；数据库是限制且主机有余量时，垂直（抬单个 worker 上限）更干净。

## 性能调优不是什么

它不是"把一切调到最大"。把上限抬到下层允许范围之外，移动瓶颈，不移除它，每个旋钮拉满的设置通常比正确大小慢。它不是读症状的替代——[可观测性](../observability/)界面告诉你哪个环节是排队点，不读就调是猜。它也不是免费的；更多并发意味着更多 provider token 以及更多连接，所以把它与[成本管理](../cost-management/)杠杆配对。

## 下一步

- 作为环境变量的旋钮，读[环境变量](../environment-variables/)。
- 显示症状的界面，读[可观测性](../observability/)。
- 也影响速度的模型侧杠杆，读[成本管理](../cost-management/)。
- 跑回合的 worker，读 [Agent Computer](../agent-computer/)。
