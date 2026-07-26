---
title: 事故响应
description: 处理一次 Ankole 事故的端到端形态——遏制、诊断、止损、恢复、学习，使用真实的 Console 与部署界面。
section: Guides
order: 312
---

一次 Ankole 部署上的事故——行为异常的 agent、泄漏的 secret、糟糕的部署、失控的任务——有它的形态。本页走完它：先遏制，再诊断，再止损，再恢复，再学习。每一步用的都是其它指南文档化的界面；本页是着火时使用它们的顺序。

先把决定性的性质说清楚：Ankole 给你秒级生效的遏制动作（禁用 binding、取消任务）和较慢的恢复动作（还原 PostgreSQL、滚动镜像）。先用快的。头五分钟的目标是止损，不是理解。

## 阶段 1：遏制（秒到分钟）

伸手拿最快的止损动作。这些在你理解事故后都能撤销。

| 危害 | 最快遏制 | 命令 |
|---|---|---|
| agent 在频道里行为异常 | 禁用 signal binding | `PATCH /agents/:agent_uid/signal-bindings/:binding_name`，带 `enabled: false` |
| 后台任务失控或出错 | 取消它 | `POST /background-agent-jobs/:job_id/cancel` |
| agent 本身必须停 | 禁用 agent Principal | 通过 `/principals`——跨部署移除权限 |
| schedule 正在把危害推进 | 暂停它 | `POST .../cron-schedules/:id/pause` |
| worker 楔住 | 重启 worker | Compose：`docker compose restart agent-computer-worker`；Helm：删 worker pod |

禁用 binding 是最有用的单一动作——它让 agent 在一个频道里静音而不丢配置，且可逆。取消任务让进行中的回合跑完，所以不即时，但停止新工作。这些都不毁数据。

头五分钟**不要**伸手拿 `docker compose down -v` 或删数据库。那些是恢复动作，会毁掉你诊断要用的数据。

## 阶段 2：诊断（分钟到一小时）

危害遏制后，搞清发生了什么。按这个顺序用[可观测性](../observability/)界面：

1. **agent 实际做了什么？**——`GET /ai-gateway/conversations` 和 `.../messages` 看目标回合。这是最快的判据：一次输出糟糕的模型调用指向一处；没有模型调用指向另一处。
2. **系统决定了什么？**——`GET /background-agent-jobs/:job_id` 看任务，`GET .../cron-schedules/:id/runs` 看 schedule，`GET /brain/audit-log` 看记忆变更。这些是持久记录；熬得过进程。
3. **日志看到了什么？**——结构化的控制面日志，按事件名搜、按字段收窄。仅在事故仍在复现时把 `ANKOLE_LOG_LEVEL` 降到 `debug`；过去的事故读 `info` 捕获到的。
4. **是 worker 的锅吗？**——`GET /agent-computer-workers` 看状态，worker 日志看窗口。

把"agent 做了错事"（人设或 model profile 问题）与"系统做了错事"（binding、worker 或 schedule 问题）分开。修复不同，混淆它们浪费时间。

## 阶段 3：永久止损

遏制是可逆的；现在做让你能安全重新启用的修复。

- **泄漏的 secret**——轮换它。把新值放进 WorkerEnv（`PUT /worker-envs/:name`），并在 provider 作废旧的。旧值保持不可读；不要为"检查"而解密它——设新值。见 [WorkerEnv secret](../worker-env/)。
- **糟糕的 agent 行为**——修人设（`MISSION.md`/`SOUL.md`/`DESIGN.md`）、收紧 model profile、或收窄 AuthZ 授予。重新启用 binding，观察几个回合再宣布修好。
- **糟糕的部署**——回滚镜像。Compose：`.env` 固定旧 digest，`docker compose up -d --force-recreate`。Helm：`values-production.yaml` 设旧 digest，`helm upgrade`。这**不**反向数据库 migration；migration 是问题就还原部署前的 PostgreSQL 备份。见[升级](../updating/)。
- **凭证被入侵**——轮换每个可能被看到的 secret：worker 认证 key、secret base、provider API key。被入侵的 `ANKOLE_SECRET_BASE` 影响范围是整套部署；按全套处理。

## 阶段 4：恢复

把系统带回已知良好状态。

- **重新启用你遏制的**——binding、schedule、agent Principal。一次一个，每个之后观察[可观测性](../observability/)界面。
- **需要时从备份还原**——从 `pg_dump` 归档还原 PostgreSQL，从卷快照还原 Agent Home。先在单独主机上测还原；未经测试的还原不是恢复计划。
- **清理楔住的状态**——想重跑的 `failed` 任务：创建新的，或从它重生（`respawn_background_job`，agent 可用）。`failed` 的 schedule：修底层原因再重建。

## 阶段 5：学习

事故之后，持久记录让你下次更快响应。

- **保留审计轨迹**——Brain 审计日志、任务运行、会话历史、你捕获的日志。不要为"清理"而删它们；它们是证据。
- **写下发生了什么**——时间线、奏效的遏制动作、根因、修复。放在下一个 on-call 找得到的地方。
- **调整人设或授予**——若事故是 agent 做错事，修复通常在人设或 AuthZ 范围里，不在代码里。人设作为判断的模式见 [team-assistant](../team-assistant/)。
- **检查备份确实管用**——还原了，确认还原的数据是预期的。没需要还原，确认你本会用的备份有效。

## Ankole 的事故响应不是什么

它不是每种事故的精确命令 runbook——事故各异，上面的界面是构件，不是脚本。它不是"重启一切并祈祷"——那毁证据，常让恢复更难。它也不是经过测试的备份的替代——这里的每条恢复路径都假设有一份你实际还原过一次的 `pg_dump` 和 Agent Home 快照。未经测试的备份，是事故里你能拥有的最贵的东西。

## 下一步

- 你用以诊断的读取界面，读[可观测性](../observability/)。
- 升级与回滚机制，读[升级](../updating/)。
- secret 轮换，读 [WorkerEnv secret](../worker-env/)。
- 权限动作，读 [Principal 与 AuthZ](../principal-authz/)。
