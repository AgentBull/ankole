---
title: 性能调优
description: Worker 槽位、模型并发、数据库连接池、Job 上限与空闲回收。
section: Guides
order: 319
---

主对话与 Workflow 的模型调用在控制面运行，纯问答不启动 Worker。Worker 容量只计算打开的环境工作区与运行中的 Codex 回合，不能把槽位数当成所有对话的并发上限。

## 容量的 owner

Driver 等待模型或工具时释放数据库连接。模型并发、provider 配额、Worker 槽位和数据库查询并发是分别管理的上限。各控制面副本上的 `Ankole.Repo` 与 `Ankole.Pod.BaseRepo` 连接池总量须低于对应 PostgreSQL 服务器的连接预算，并为管理操作和维护连接留出余量。在未设置 `BASE_DB_URLS` 的单库部署中，`Ankole.Pod.BaseRepo` 会在 `Ankole.Repo` 的 10 连接池之外向 `DATABASE_URL` 额外打开一个独立的 10 连接池（每个副本共 `20` 个连接池连接）。当 `BASE_DB_URLS` 指向独立的分片数据库时，按 `副本数 × ankole_pool_size` 规划每个分片实例的 `max_connections`。先观察连接池 checkout 等待，再调整连接池大小。

| 旋钮 | 默认 | 限制什么 |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_SLOTS` | 部署种子中为 12（未设置时为 9） | 单个 Agent 打开的环境工作区与运行中的 Codex 回合 |
| `POOL_SIZE`（Compose/Helm 中为 `ANKOLE_DATABASE_POOL_SIZE`） | 10 | 每个副本的 `Ankole.Repo` 控制面数据库连接池 |
| `BASE_DB_URLS`（`ankole_pool_size`） | 每分片 10（dev/test 中为 `2`） | 每个副本上各 `Ankole.Pod.BaseRepo` Base 分片的数据库连接池 |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | 300 | Postgres `max_connections`（内置服务器） |
| `agent_computer.background_agent_job.max_running_per_agent` | 3 | 每个 Agent 并发运行的 Background Agent Job 上限（租户级） |
| `idleReleaseAfter` | 全部六种提供方默认均为 `15m`（设为 `never` 可禁用空闲停止） | Worker 空闲多久后停止并释放 CPU 和内存 |

## 调整真正等待的边界

- 模型请求等待 provider 容量时，检查 provider 配额与凭据。
- 电脑工具等待 `no_worker_capacity` 时，需要空 Worker 槽位；提高上限前先检查保留工作区中的在途命令。
- 后台 Job 排队可能受每 Agent 的 Job 上限或 Worker 容量限制。提高 Worker 槽位不会改变 Job 上限。
- 数据库 checkout 延迟需要检查全部副本与各 Base 分片上的 `Ankole.Repo`、`Ankole.Pod.BaseRepo` 连接池及 PostgreSQL 容量。

provider YAML 修改在控制面替换空闲 Worker 时生效，既有 generation 保留已保存的设置。`idleReleaseAfter` 控制空闲资源回收，持久 Home 仍由 provider 存储保留。

另见 [工作节点](../worker-management/)、[后台任务](../background-agent-jobs/) 与 [成本管理](../cost-management/)。
