---
title: Performance tuning
description: Worker slots, model concurrency, database pools, Job limits, and idle release.
section: Guides
order: 319
---

Because main-conversation and Workflow model calls run directly in the control plane, conversational questions that invoke no environment tools never start a Worker. Worker capacity counts only open environment workspaces and active Codex turns, so Worker slot limits do not cap overall conversation concurrency.

## Capacity owners

Each Session Driver releases its PostgreSQL connection while waiting on a model call or Worker tool, keeping model concurrency, upstream provider quotas, Worker slots, and database query concurrency independent of one another. Size the combined `Ankole.Repo` and `Ankole.Pod.BaseRepo` connection pools across all control-plane replicas so they stay comfortably below each PostgreSQL server's `max_connections` budget, leaving headroom for administrative and maintenance sessions.

In single-database deployments where `BASE_DB_URLS` is unset, `Ankole.Pod.BaseRepo` opens its own 10-connection pool to `DATABASE_URL` alongside `Ankole.Repo`'s 10-connection pool—totaling `20` pool connections per control-plane replica. When `BASE_DB_URLS` points to dedicated shard databases, size each shard server's `max_connections` for `replicas × ankole_pool_size`. Always measure actual pool checkout wait times before raising pool sizes.

| Knob | Default | What it caps |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_SLOTS` | `12` in deployment seeds (`9` when unset) | Open environment workspaces and active Codex turns on a single Agent's Worker |
| `POOL_SIZE` (`ANKOLE_DATABASE_POOL_SIZE` in Compose/Helm) | `10` | Connections per replica in the `Ankole.Repo` pool for the control-plane database |
| `BASE_DB_URLS` (`ankole_pool_size`) | `10` per shard (`2` in dev/test) | Connections per replica in each `Ankole.Pod.BaseRepo` pool for a Base shard |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | `300` | `max_connections` on the bundled PostgreSQL server |
| `agent_computer.background_agent_job.max_running_per_agent` | `3` | Concurrently running Background Agent Jobs per Agent (tenant-scoped) |
| `idleReleaseAfter` | `15m` across all six providers (`never` disables idle stop) | How long a Worker stays idle before the control plane stops it to free CPU and memory |

## Tune the boundary that is waiting

- **Model calls waiting on provider capacity:** Inspect your upstream provider rate limits, quotas, and credential pool.
- **Computer tools waiting with `no_worker_capacity`:** Free up or expand Worker slots. Check for long-running shell commands in retained workspaces before raising `ANKOLE_MAX_CONCURRENT_SLOTS`.
- **Background Agent Jobs staying queued:** Check both the per-Agent running Job cap (`agent_computer.background_agent_job.max_running_per_agent`) and available Worker slots—increasing Worker slots alone does not raise the Job cap.
- **Database pool checkout delays:** Inspect utilization across both `Ankole.Repo` and `Ankole.Pod.BaseRepo` pools, as well as PostgreSQL connection counts on the control-plane server and every Base shard.

Edits to Worker provider YAML apply when the control plane replaces an idle Worker; running Worker generations keep the settings with which they launched. While `idleReleaseAfter` releases idle compute resources, each Agent's persistent Home remains intact on provider storage.

See [Workers](../worker-management/), [Background Jobs](../background-agent-jobs/), and [cost management](../cost-management/).
