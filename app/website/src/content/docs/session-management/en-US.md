---
title: Session management
description: How to observe and manage agent sessions — list sessions, inspect schedules and checkbacks, and understand what a session is in the actor model.
section: User guide
order: 53
---

A session is one long-running actor — the unit `{agent_uid, session_id}` that holds a conversation's context, workspace state, and scheduled work. The operator does not create or delete sessions directly; they are created when a signal arrives or a schedule fires, and they persist as durable state. This page is the operator's view of the session surface: how to list them, what hangs off a session, and what to do when one needs attention.

The decisive property, stated up front: a session is **durable PostgreSQL state, not a live process**. The session controller process is ephemeral — it starts on demand, serializes the session's scheduling, and may crash and restart. The session itself — its actor events, schedules, checkbacks — survives in the database. You observe the durable state, not the process.

## List sessions

```bash
curl https://ankole.example.com/api/v1/agents/<agent_uid>/sessions \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /agents/:agent_uid/sessions` lists the sessions for one agent. Each session is identified by its `session_id` (a base64url-encoded string), paired with the `agent_uid` to form the actor key.

## What hangs off a session

A session carries:

- **Actor events** — the durable inbox. Signals that arrived, turns that ran, commands (steer, stop, retry) that were issued. These are queued, ordered by `queue_sequence`, and processed one at a time.
- **Cron schedules** — recurring schedules that fire this session. See [Cron schedules](../cron-schedules-ops/) for the operator surface.
- **Checkbacks** — one-shot self-wakeups the agent set. See [Schedules](../schedules/) for the concept.
- **The activation** — the live lease that owns the session while a turn runs. See [Actor Runtime](../actor-runtime/) for the fence model.

## Inspect schedules and checkbacks

```bash
# Schedules on a session
curl https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

# Checkbacks on a session
curl https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/checkbacks \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

These are the session-scoped views of the schedule and checkback surfaces. A session with a stuck schedule or a pile of pending checkbacks is one that needs attention — see [Schedule troubleshooting](../cron-troubleshooting/).

## When a session needs attention

- **A schedule is stuck** — read the runs list; the schedule may be `paused`, `failed`, or firing into a disabled binding. See [Cron schedules](../cron-schedules-ops/).
- **Checkbacks are piling up** — the agent set self-wakeups that never resolved. Cancel them with `DELETE .../checkbacks/:id`, or let them fire and observe the outcome.
- **A session seems unresponsive** — check whether the agent Principal is active, the binding is enabled, and the worker is ready. An unresponsive session is usually an unresponsive binding or worker, not a session problem.
- **An actor event is in `dead_letter`** — repeated turn failures pushed the event past the retry budget. Read the event's error, fix the underlying cause, and let the event be retried or resolved.

## What the operator does not do

- **Create sessions** — sessions are created by the system when a signal arrives or a schedule fires. There is no `POST /sessions` route.
- **Delete sessions** — sessions persist as durable state; there is no `DELETE /sessions/:id` route. A session that is no longer needed simply stops receiving events.
- **Restart sessions** — the session controller restarts on its own through the OTP supervisor. The operator restarts the worker, not the session.

## What this guide is not

It is not the Actor Runtime concept page — for the activation fence, the triple fence, and the recovery model, read [Actor Runtime](../actor-runtime/). It is not a conversation-history guide — transcripts are owned by AIGateway, see [AIGateway](../ai-gateway/). And it is not a schedule troubleshooting guide — see [Schedule troubleshooting](../cron-troubleshooting/).

## Next steps

- For the actor model and recovery, read [Actor Runtime](../actor-runtime/).
- For schedules, read [Cron schedules](../cron-schedules-ops/).
- For troubleshooting, read [Schedule troubleshooting](../cron-troubleshooting/).
- For the Console routes, read the [Console API reference](../console-api/).
