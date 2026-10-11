---
title: Performance tuning
description: Worker slots, model concurrency, database pools, Job limits, and idle release.
section: Guides
order: 319
---

Main and Workflow model calls run in the control plane. Pure questions do not start a Worker. Worker capacity counts open environment workspaces and running Codex turns, so Worker slots do not cap all conversations.

## Capacity owners

A Driver releases its database connection while it waits for a model or tool. Model concurrency, provider quota, Worker slots, and database query concurrency are separate limits. Size the total database pools across control-plane replicas below the Postgres connection budget, with room for administration and other services. Measure pool checkout waits before changing it.

| Knob | Default | What it caps |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_SLOTS` | 12 in the deployment seeds (9 when unset) | open environment workspaces and running Codex turns of one Agent |
| `ANKOLE_DATABASE_POOL_SIZE` | 10 | the control-plane database connection pool |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | 300 | Postgres `max_connections` (bundled server) |
| `max_running_per_agent` | 3 | at most three running background jobs per agent |
| `idleReleaseAfter` | Docker / Kubernetes: `never`; Cloudflare / Vercel / Lambda / Function Compute: `15m` | how long a Worker stays idle before it stops and frees its CPU and memory |

## Tune the boundary that is waiting

- A model request that waits for provider capacity needs a provider quota or credential check.
- A computer tool that waits for `no_worker_capacity` needs free Worker slots. Check commands still running in retained workspaces before raising the limit.
- A queued Background Job can wait for its per-Agent Job cap or Worker capacity. Raising Worker slots does not change the Job cap.
- Database checkout delays require a pool and Postgres capacity check across all replicas.

Provider YAML changes take effect when the control plane replaces an idle Worker. Existing generations keep their saved settings. `idleReleaseAfter` controls idle resource release; persistent Home remains on provider storage.

See [Workers](../worker-management/), [Background Jobs](../background-agent-jobs/) and [cost management](../cost-management/).
