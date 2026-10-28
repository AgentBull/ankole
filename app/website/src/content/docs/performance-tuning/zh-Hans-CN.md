---
title: 性能调优
description: 合理规划 Worker 槽位、模型并发、数据库连接池、后台任务上限与空闲资源回收。
section: Guides
order: 319
---

主对话与 Workflow 的模型调用均在控制面直接完成，纯问答交互不会拉起 Worker。Worker 容量仅统计当前打开的环境工作区与正在运行的 Codex 回合数，因此切勿将 Worker 槽位数等同于整站所有对话的并发上限。

## 容量的 owner

在等待模型响应或工具返回结果期间，Driver 会主动归还数据库连接；模型并发度、提供商配额、Worker 槽位与数据库查询并发分属四套彼此独立的配额上限。规划数据库容量时，所有控制面副本上的 `Ankole.Repo` 与 `Ankole.Pod.BaseRepo` 连接池总和必须低于目标 PostgreSQL 实例的连接数预算，并为日常运维与后台维护预留余量。在未配置 `BASE_DB_URLS` 的单库部署模式下，每个控制面副本除了为 `Ankole.Repo` 建立 10 个连接的连接池外，还会为 `Ankole.Pod.BaseRepo` 向同一个 `DATABASE_URL` 额外建立一个含 10 个连接的独立连接池（即单副本共占用 `20` 个连接池连接）。若通过 `BASE_DB_URLS` 指向独立的分片数据库，则应按 `副本数 × ankole_pool_size` 估算每个分片实例所需的 `max_connections`。调大连接池之前，请先观察是否确实出现了连接池借出（checkout）排队等待。

| 配置项 | 默认值 | 限制对象 |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_SLOTS` | 部署种子中为 12（未设置时为 9） | 单个 Agent 同时打开的环境工作区与运行中的 Codex 回合总数 |
| `POOL_SIZE`（Compose/Helm 中为 `ANKOLE_DATABASE_POOL_SIZE`） | 10 | 每个控制面副本的 `Ankole.Repo` 数据库连接池大小 |
| `BASE_DB_URLS`（`ankole_pool_size`） | 每分片 10（dev/test 环境为 `2`） | 每个控制面副本上各 `Ankole.Pod.BaseRepo` Base 分片的连接池大小 |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | 300 | 内置 PostgreSQL 实例的 `max_connections` 上限 |
| `background_agent_jobs.max_running_per_agent` | 3 | 单个 Agent 允许并发运行的 Background Agent Job 上限（租户级） |
| `idleReleaseAfter` | 全部六种提供商默认均为 `15m`（设为 `never` 可禁用空闲停止） | Worker 空闲多久后自动停止并释放 CPU 与内存 |

## 调整真正等待的边界

扩容前应先查明请求究竟阻塞在哪道边界上，对症调整：

- **模型请求在等待提供商容量**：检查对应模型提供商的速率配额与凭据池余量。
- **电脑工具报错等待 `no_worker_capacity`**：说明当前缺少空闲的 Worker 槽位；盲目上调槽位上限前，建议先排查已保留的工作区中是否挂着尚未退出的长耗时命令。
- **后台任务（Job）处于排队状态**：可能受限于单 Agent 并发任务上限，也可能受限于 Worker 槽位容量；单纯调高 Worker 槽位数并不会放宽单 Agent 的并发任务上限。
- **数据库连接池借出（checkout）延迟升高**：需综合核查所有控制面副本及各 Base 分片上的 `Ankole.Repo`、`Ankole.Pod.BaseRepo` 连接池配置与 PostgreSQL 服务端负载。

修改 Worker 提供商的 YAML 配置后，新设置会在控制面替换空闲 Worker 时生效，而现存的 Worker 实例（Generation）会继续沿用创建时保存的参数。`idleReleaseAfter` 仅负责回收空闲计算资源，Agent 的持久化主目录（Home）仍由底层存储完整保留。

更多背景请参阅 [工作节点](../worker-management/)、[后台任务](../background-agent-jobs/) 与 [成本管理](../cost-management/)。
