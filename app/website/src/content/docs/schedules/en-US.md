---
title: Schedules
description: How to give an agent a recurring rhythm — cron schedules on a session, pause and resume, manual runs, and the checkback self-wakeup pattern.
section: User guide
order: 21
---

A schedule is what lets an agent wake on time instead of only on a message. Ankole has two kinds: a **cron schedule** fires a session on a recurring cron expression, and a **checkback** is a delayed self-wakeup an agent sets during a turn. This page is the operator view of both.

The decisive property, stated up front: schedules own only time semantics. The durable correctness — what fires, whether it already fired, whether it was cancelled — lives in the domain tables and the actor-event idempotency, not in the scheduler process. A schedule row that says "fire at 09:00" produces a wake edge; the actor runtime decides what happens after.

## Where schedules live

A cron schedule belongs to one agent session, and it carries a binding name — the signal binding the fire should come through. So a schedule is scoped to `(agent_uid, session_id, binding_name)`. The session is the actor that gets woken; the binding is the route the wake event takes, which decides the channel and reply mode the agent's response uses.

## The cron schedule fields

A cron schedule carries what you would expect, plus a few worth knowing:

| Field | Meaning |
|---|---|
| `name` | a label for the schedule |
| `schedule` | the cron expression map (the structured form the normalizer accepts) |
| `timezone` | the timezone the cron expression is evaluated in |
| `payload` | what to deliver to the agent when the schedule fires |
| `status` | `active`, `paused`, or deleted |
| `next_fire_at` / `last_fire_at` | the planner's view of when it next fires and last fired |
| `failure_policy` | what happens when a fire fails |
| `idempotency_key` | protects against duplicate schedule creation |

The `timezone` field is the one operators trip on: a cron expression without a timezone is ambiguous, and Ankole evaluates the expression in the timezone you set. Set it explicitly, even for a deployment that runs in one timezone — it makes a schedule portable across deployments.

## Create, read, update

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "binding_name": "...", "name": "morning-briefing", "schedule": { ... }, "timezone": "Asia/Shanghai", "payload": { ... } }'
```

List schedules on a session with `GET /agents/:agent_uid/sessions/:session_id/cron-schedules`, read one with `GET .../cron-schedules/:cron_schedule_id`, and update one with `PATCH .../cron-schedules/:cron_schedule_id`. Updating a schedule cancels its pending recurring events and re-arms the planner, so a changed expression takes effect cleanly rather than racing the old one.

## Pause, resume, and manual run

Three operations cover the operational lifecycle:

- **Pause** — `POST .../cron-schedules/:cron_schedule_id/pause`. Stops the schedule from firing without deleting it. Status moves to `paused`; `next_fire_at` clears.
- **Resume** — `POST .../cron-schedules/:cron_schedule_id/resume`. Re-arms a paused schedule and recomputes `next_fire_at`.
- **Manual run** — `POST .../cron-schedules/:cron_schedule_id/runs`. Fires the schedule immediately, outside its cron rhythm. Use this to test a schedule or to run one on demand; it does not advance the cron calendar.

A manual run produces a concrete fire event, recorded just like a scheduled one, so you can inspect it through the runs list (`GET .../cron-schedules/:cron_schedule_id/runs`) alongside the naturally fired ones.

## Checkbacks: the self-wakeup

A checkback is the other shape of schedule: a delayed self-wakeup an agent sets during a turn, for "look again in an hour." It is one-shot, not recurring. The agent creates it through its own tools; the operator surface is read-only:

- `GET /agents/:agent_uid/sessions/:session_id/checkbacks` — list pending checkbacks for a session.
- `DELETE /agents/:agent_uid/sessions/:session_id/checkbacks/:scheduled_event_id` — cancel a checkback.

Replacing a pending checkback preserves the cancelled event as audit history, so you can see what the agent deferred and when it was cancelled.

## When something does not work

- **A schedule did not fire** — check `status` is `active`, `next_fire_at` is in the future, and the session's signal binding is enabled. A schedule whose binding is disabled will not produce a deliverable wake event.
- **It fired at the wrong time** — check `timezone`. A cron expression evaluated in the wrong timezone fires at the right local-looking time in the wrong zone.
- **A manual run had no effect** — check the run in the runs list; a fire that produced no actor event usually means the session could not accept it (the agent Principal is disabled, or the binding is unavailable).
- **Duplicate schedules appeared** — the `idempotency_key` exists to prevent this; reuse it on retries of the same create.

## Next steps

- For the routes, read the [Console API reference](../console-api/).
- For the session a schedule wakes, read the [Actor Runtime](../actor-runtime/) developer page.
- For the binding the fire routes through, read [Signal bindings](../signal-bindings/).
