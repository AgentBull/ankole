---
title: Performance tuning
description: Worker slots, model concurrency, database pools, Job limits, and idle release.
section: Guides
order: 319
---

Main and Workflow model calls run in the control plane. Pure questions do not start a Worker. Worker capacity counts open environment workspaces and running Codex turns, so Worker slots do not cap all conversations.

## Capacity owners

A Driver releases its database connection while it waits for a model or tool. Model concurrency, provider quota, Worker slots, and database query concurrency are separate limits. Size the total `Ankole.Repo` and `Ankole.Pod.BaseRepo` connection pools across control-plane replicas below each PostgreSQL server's connection budget, with room for administration and maintenance connections. In single-database deployments where `BASE_DB_URLS` is unset, `Ankole.Pod.BaseRepo` opens a separate 10-connection pool to `DATABASE_URL` alongside `Ankole.Repo`'s 10-connection pool (`20` pool connections per replica). When `BASE_DB_URLS` points to dedicated shard databases, size each shard server's `max_connections` for `replicas × ankole_pool_size`. Measure pool checkout waits before changing pool sizes.

| Knob | Default | What it caps |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_SLOTS` | 12 in the deployment seeds (9 when unset) | open environment workspaces and running Codex turns of one Agent |
| `POOL_SIZE` (`ANKOLE_DATABASE_POOL_SIZE` in Compose/Helm) | 10 | the `Ankole.Repo` control-plane database connection pool per replica |
| `BASE_DB_URLS` (`ankole_pool_size`) | 10 per shard (`2` in dev/test) | each `Ankole.Pod.BaseRepo` Base shard connection pool per replica |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | 300 | Postgres `max_connections` (bundled server) |
| `agent_computer.background_agent_job.max_running_per_agent` | 3 | running Background Agent Jobs per Agent (tenant-scoped) |
| `idleReleaseAfter` | `15m` across all six providers (`never` disables idle stop) | how long a Worker stays idle before it stops and frees its CPU and memory |

## Tune the boundary that is waiting

- A model request that waits for provider capacity needs a provider quota or credential check.
- A computer tool that waits for `no_worker_capacity` needs free Worker slots. Check commands still running in retained workspaces before raising the limit.
- A queued Background Job can wait for its per-Agent Job cap or Worker capacity. Raising Worker slots does not change the Job cap.
- Database checkout delays require checking both `Ankole.Repo` and `Ankole.Pod.BaseRepo` pools and PostgreSQL capacity across all replicas and Base shards.

Provider YAML changes take effect when the control plane replaces an idle Worker. Existing generations keep their saved settings. `idleReleaseAfter` controls idle resource release; persistent Home remains on provider storage.

See [Workers](../worker-management/), [Background Jobs](../background-agent-jobs/) and [cost management](../cost-management/).
