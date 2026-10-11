---
title: 性能调优
description: Worker 槽位、模型并发、数据库连接池、Job 上限与空闲回收。
section: Guides
order: 319
---

主对话与 Workflow 的模型调用在控制面运行，纯问答不启动 Worker。Worker 容量只计算打开的环境工作区与运行中的 Codex 回合，不能把槽位数当成所有对话的并发上限。

## 容量的 owner

Driver 等待模型或工具时释放数据库连接。模型并发、provider 配额、Worker 槽位和数据库查询并发是分别管理的上限。各控制面副本的连接池总量须低于 Postgres 的连接预算，并为管理操作和其他服务留出空间。先观察连接池 checkout 等待，再调整容量。

| 旋钮 | 默认 | 限制什么 |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_SLOTS` | 部署种子中为 12（未设置时为 9） | 单个 Agent 打开的环境工作区与运行中的 Codex 回合 |
| `ANKOLE_DATABASE_POOL_SIZE` | 10 | 控制面数据库连接池 |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | 300 | Postgres `max_connections`（内置服务器） |
| `max_running_per_agent` | 3 | 每个 agent 最多三个运行中后台任务 |
| `idleReleaseAfter` | Docker / Kubernetes: `never`; Cloudflare / Vercel / Lambda / Function Compute: `15m` | Worker 空闲多久后停止并释放 CPU 和内存 |

## 调整真正等待的边界

- 模型请求等待 provider 容量时，检查 provider 配额与凭据。
- 电脑工具等待 `no_worker_capacity` 时，需要空 Worker 槽位；提高上限前先检查保留工作区中的在途命令。
- 后台 Job 排队可能受每 Agent 的 Job 上限或 Worker 容量限制。提高 Worker 槽位不会改变 Job 上限。
- 数据库 checkout 延迟需要检查全部副本的连接池与 Postgres 容量。

provider YAML 修改在控制面替换空闲 Worker 时生效，既有 generation 保留已保存的设置。`idleReleaseAfter` 控制空闲资源回收，持久 Home 仍由 provider 存储保留。

另见 [工作节点](../worker-management/)、[后台任务](../background-agent-jobs/) 与 [成本管理](../cost-management/)。
