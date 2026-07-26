---
title: Worker management
description: How to observe and manage Agent Computer workers — list, inspect, and understand the worker pool, concurrent-turn capacity, and what to do when a worker is unhealthy.
section: User guide
order: 52
---

Workers are the Agent Computer processes that run agent turns. The control plane manages their lifecycle — starting them, assigning turns, fencing their replies — and the operator observes their state and capacity. This page is the operator's view of the worker surface: how to list and inspect workers, what the capacity numbers mean, and what to do when a worker is unhealthy.

The decisive property, stated up front: workers are **replaceable execution substrate**. The control plane owns the turn and the commit; the worker owns the execution. A worker that crashes is restarted by its supervisor; the turn it was running is retried by the control plane. You do not "fix" a worker — you let the supervisor restart it, and you fix the configuration that caused the failure.

## List workers

```bash
curl https://ankole.example.com/api/v1/agent-computer-workers \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /agent-computer-workers` lists every worker the control plane knows about — its id, status, and assignment state. A healthy worker is ready and has turn slots available; a busy worker has active turns consuming its capacity.

## What the capacity numbers mean

Each worker has a `maxConcurrentTurns` setting (controlled by `ANKOLE_MAX_CONCURRENT_TURNS`, default 9). The worker reports its available turn slots — how many more turns it can accept — through the admission hint. The control plane uses this hint to avoid sending work to a full worker.

On Compose (single host), there is one worker; scaling means raising its turn cap. On Helm (Kubernetes), the worker is a Deployment you can scale horizontally — more pods, each with its own cap. See [Performance tuning](../performance-tuning/) for the capacity chain (turns × pool × Postgres).

## When a worker is unhealthy

- **Worker will not start** — check the image (`ANKOLE_AGENT_COMPUTER_IMAGE`), the `SYS_ADMIN`/seccomp/`/proc` requirements (see [Platform support](../platform-support/)), and the worker auth key (`ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`).
- **Worker starts but turns fail** — check the control-plane logs for the turn error; the worker reports it, and `handle_turn_error` classifies it. See [The agent loop](../agent-loop/) for the retry boundary.
- **Worker is slow** — check `/ai-gateway/conversations` for the turn's model calls; a slow worker is usually waiting on the provider, not on the worker itself.
- **Worker pod is OOM-killed (Helm)** — raise the pod's memory limit, or reduce `ANKOLE_MAX_CONCURRENT_TURNS` so fewer concurrent turns fit in the same memory.

Do not try to "repair" a worker process. The supervisor restarts it; the control plane retries the turn. Your job is to fix the configuration or the capacity that caused the failure, not to intervene in the process.

## Restart a worker

On Compose:

```bash
docker compose restart agent-computer-worker
```

On Helm, delete the pod and let the Deployment recreate it:

```bash
kubectl -n ankole delete pod -l app.kubernetes.io/component=worker
```

A restart is the right move when a worker is wedged — stuck in a state where it accepts no turns but the supervisor has not restarted it. The control plane's turn-level fence ensures in-flight turns are retried on the new worker; no data is lost.

## What this guide is not

It is not the Agent Computer concept page — for the loop, the tools, and the ownership boundary, read [Agent Computer](../agent-computer/). It is not a Kubernetes operations guide — pod lifecycle, resource limits, and node affinity are your cluster's concern. And it is not a performance-tuning guide — for the capacity chain, read [Performance tuning](../performance-tuning/).

## Next steps

- For the worker concept page, read [Agent Computer](../agent-computer/).
- For the capacity chain, read [Performance tuning](../performance-tuning/).
- For the turn lifecycle and retry, read [The agent loop](../agent-loop/) and [Actor Runtime](../actor-runtime/).
- For the platform requirements, read [Platform support](../platform-support/).
