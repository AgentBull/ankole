---
title: Observability
description: What to watch when running Ankole — the Console read surfaces mapped to the operator questions they answer, plus how to read the structured logs.
section: Guides
order: 311
---

Observability in Ankole is not one dashboard; it is a set of read surfaces on the Console API, each answering a different question. This page maps the question an operator actually asks to the route that answers it, and shows how to read the structured logs that sit underneath all of them.

The decisive property, stated up front: the durable read surfaces (sessions, conversations, jobs, audit) are PostgreSQL state, not ephemeral metrics. When something went wrong, the record of it is still there after the process that produced it is gone. Logs tell you what the process was doing; the Console surfaces tell you what the system *decided*.

## The operator questions and where they answer

| Operator question | Console route | What you read |
|---|---|---|
| "What is this agent doing right now?" | `GET /agents/:agent_uid/sessions` | the agent's live sessions |
| "What did a turn actually call?" | `GET /ai-gateway/conversations` and `.../conversations/:id/messages` | the model calls and messages of recent turns |
| "Is a background job stuck?" | `GET /background-agent-jobs` and `.../:job_id` | job status (`queued`/`running`/`waiting_on_user`/`succeeded`/`failed`/`stopped`), attempts, result/error |
| "Are workers healthy?" | `GET /agent-computer-workers` | worker state and assignments |
| "Did a schedule fire?" | `GET .../cron-schedules/:id/runs` | concrete fires and their outcomes |
| "What did the agent remember, and who changed it?" | `GET /brain/audit-log` and `.../entries/:id/audit-log` | append-only Brain knowledge history |
| "Is dreaming fit to run?" | `GET /brain/dreaming-fitness` | dreaming preconditions and recent state |
| "What pending wakeups does a session have?" | `GET .../sessions/:id/checkbacks` | pending checkbacks the agent set |
| "Is Brain healthy overall?" | `GET /brain/status` | Brain configuration and health |

Every row is a stateless bearer-authenticated Console read — the same surface the [Console operations](../console-operations/) page indexes by task.

## How to read the logs underneath

The control plane emits structured logs with a stable shape: an event name, a human message, and structured fields, at a severity from `debug` through `notice`/`warning`/`error`. Two `ANKOLE_LOG_*` knobs control what you see:

- **`ANKOLE_LOG_LEVEL`** — `debug | info | warning | error`. Default `info`. Drop to `debug` for a specific reproduction; put it back. A deployment left at `debug` is noisy and slow, and an invalid value is rejected at boot.
- **`ANKOLE_LOG_FORMAT`** — `json` (default, for ingestion) or `pretty` (for local reading via `kit logs pretty`).

In production, leave format at `json` and let your log ingester handle it. The event name is the join key — search by event name first, then narrow by fields. See [Environment variables](../environment-variables/) for the full knob set.

## Three patterns that come up often

### "The bot did not reply"

Work outward from the model, not inward from the schedule. The [FAQ](../faq/) order applies:

1. `/ai-gateway/conversations` for the turn — was there a model call at all?
2. `/agents/:agent_uid/sessions` — did a session wake?
3. `agent-computer-workers` — was a worker ready?
4. The signal binding — is it enabled and healthy?

The conversations route is usually the fastest tell: a turn with a model call that returned an error points at the provider; a turn with no model call points at the binding or the worker.

### "A background job is behaving oddly"

`GET /background-agent-jobs/:job_id` carries `status`, `attempts`, `result`, and `error`. The status vocabulary tells you the shape: `waiting_on_user` is paused for a human, not stuck; `failed` after five attempts is a real failure, not a transient one. Read the `error` before deciding whether to retry — a configuration error retries to the same failure. See [Background jobs (operator view)](../background-jobs-ops/) for the full vocabulary.

### "Did something change in the agent's memory?"

Brain's audit log is append-only, and restorations are themselves audited. `GET /brain/audit-log` shows the history of what the agent believed and who changed it; `GET /brain/entries/:id/audit-log` narrows to one entry. This is the surface for "why does the agent think that?" — the answer is in the audit trail, not in the model's current output.

## What observability is not

It is not a metrics pipeline. Ankole does not emit Prometheus counters or a built-in Grafana dashboard; the read surfaces are PostgreSQL state you query through the Console, and the logs are structured events you ingest with whatever you already run. If you want dashboards, build them on top of the logs and the Console reads — the data is there, the presentation is your choice.

It is also not real-time tracing of every tool call a turn makes. For that level of detail, the conversation's messages and the worker logs are the source; the Console surfaces are for the decisions and the durable state, not the step-by-step.

## Next steps

- For the full read surface, read [Console operations](../console-operations/) and the [Console API reference](../console-api/).
- For the log knobs, read [Environment variables](../environment-variables/).
- For job-state vocabulary, read [Background jobs (operator view)](../background-jobs-ops/).
