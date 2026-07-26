---
title: Performance tuning
description: The capacity knobs — concurrent turns, database pool, Postgres max connections, worker turn caps, per-agent job slots — and the relationships between them that decide how much an installation can do at once.
section: Guides
order: 319
---

Performance in Ankole is mostly capacity: how many turns run at once, how many database connections they can draw from, and how many jobs an agent can run in parallel. This page names the knobs, gives their defaults, and — the part that matters — explains how they relate, because turning one without the others is how you get either a slow installation or a failed one.

The decisive property, stated up front: the knobs form a chain. Concurrent turns need database connections; database connections are capped by Postgres; job slots multiply the turns an agent can run. Raise one without the others and the chain breaks at the weakest link — turns queue, connections exhaust, or Postgres refuses connections. Tune them as a set, against the shape of your load, not one at a time.

## The capacity chain

A turn touches the control plane (which uses the database pool), the worker (which runs the model loop), and Postgres (which serves the pool). The relationship, in one line:

```text
(concurrent turns) × (connections per turn)  ≤  database pool size  ≤  Postgres max_connections
```

Every turn holds database work; every database connection comes from Postgres. If your concurrent-turns setting implies more connections than the pool allows, turns queue on the pool. If the pool size implies more connections than Postgres allows, connections are refused. The defaults are set so a single small host works; scaling out means raising them together.

## The knobs

| Knob | Default | What it caps |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_TURNS` | 9 | concurrent actor turns the worker(s) will accept |
| `ANKOLE_DATABASE_POOL_SIZE` | 10 | the control-plane database connection pool |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | 300 | Postgres `max_connections` (bundled server) |
| `agent_computer.background_agent_job.max_turns_per_worker` | configurable | per-worker turn cap for background jobs |
| `max_running_per_agent` | 3 | at most three running background jobs per agent |

The defaults (9 turns, 10 pool, 300 Postgres) are conservative and fit a single small host. The tuning question is which to raise, and by how much, when the installation is busier than that.

## Tune for the symptom

Different symptoms point at different knobs. Read the symptom before you turn anything.

### "Turns are slow to start" (queuing)

Turns queue when the worker pool is full — `ANKOLE_MAX_CONCURRENT_TURNS` is the ceiling on concurrent turns the worker accepts. If the [Observability](../observability/) surfaces show turns waiting for a slot, raise the cap. But raise it only as far as the rest of the chain allows: more concurrent turns mean more database work, and if the pool is already near its limit, raising the turn cap just moves the queue from the worker to the pool.

### "Turns are slow once running" (database saturation)

A turn that holds a database connection waits when the pool is exhausted. Raise `ANKOLE_DATABASE_POOL_SIZE` — but only up to what Postgres allows. The bundled Postgres defaults to 300 connections; an external server has its own `max_connections`. If the pool size approaches Postgres's limit, raise Postgres's limit first (or let the bundled server's `ANKOLE_POSTGRES_MAX_CONNECTIONS` grow), then raise the pool.

### "Background jobs queue" (agent slot saturation)

Each agent runs at most `max_running_per_agent` (3) jobs concurrently. If an agent has three jobs in `running` and more in `queued`, the cap is the limit — not the worker, not the pool. Either accept the queue, or spread the work across more agents (each gets its own three slots). Raising `max_running_per_agent` is rarely the right move; the per-worker turn cap (`max_turns_per_worker`) and the global turn cap fence it anyway.

### "Provider calls are the bottleneck" (not an Ankole knob)

If `/ai-gateway/conversations` shows model calls taking most of a turn's time, the bottleneck is the provider, not Ankole. No capacity knob fixes that — see [Cost management](../cost-management/) for the model-side levers (cheaper `primary`, lower `reasoning_effort`), which also make turns faster.

## A worked sizing

A busier installation, say 5 active agents each running 1–2 jobs and answering in channels:

- **Concurrent turns** — raise `ANKOLE_MAX_CONCURRENT_TURNS` to match the realistic peak (15–20), not the theoretical max.
- **Database pool** — raise `ANKOLE_DATABASE_POOL_SIZE` so the pool is not the queue point (20–30 for this load).
- **Postgres** — confirm `ANKOLE_POSTGRES_MAX_CONNECTIONS` (300) comfortably exceeds the pool plus the worker's own connections plus headroom; it usually does, but an external server may need its own `max_connections` raised.
- **Per-agent job slots** — leave at 3; spread more work across agents rather than raising it.

The numbers are not magic — they are "the smallest set that handles your peak without queuing at any link," and you find them by watching the [Observability](../observability/) surfaces after each change.

## Worker count, not just worker capacity

On Kubernetes, the worker is a Deployment you can scale horizontally — more worker pods, each with its own `ANKOLE_MAX_CONCURRENT_TURNS`. The capacity math is then `worker pods × turns per worker`, still bounded by the database pool and Postgres. On Compose (single host), you have one worker; scaling means raising its turn cap, up to what the host and the database allow.

Horizontal worker scaling is the cleaner path when a single worker's host is the limit; vertical (raising one worker's caps) is the cleaner path when the database is the limit and the host has headroom.

## What performance tuning is not

It is not "turn everything up." Raising a cap past what the layer below it allows moves the bottleneck, it does not remove it, and a setup with every knob maxed is usually slower than one with the right knobs at the right size. It is not a substitute for reading the symptom — the [Observability](../observability/) surfaces tell you which link is the queue point, and tuning without that reading is guessing. And it is not free; more concurrency means more provider tokens as well as more connections, so pair it with the [Cost management](../cost-management/) levers.

## Next steps

- For the knobs as environment variables, read [Environment variables](../environment-variables/).
- For the surfaces that show the symptom, read [Observability](../observability/).
- For the model-side levers that also affect speed, read [Cost management](../cost-management/).
- For the worker that runs the turns, read [Agent Computer](../agent-computer/).
