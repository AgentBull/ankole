---
title: Cron schedules
description: The operator's task-oriented view of schedules — create, list, pause, resume, run manually, and inspect runs, with worked examples.
section: User guide
order: 48
---

Schedules give an agent a rhythm. A cron schedule fires a session on a recurring expression; a checkback is a one-shot self-wakeup the agent sets during a turn. This page is the operator's task-oriented view of the schedule surface — the routes, the moves, and the worked examples. It complements the [Schedules](../schedules/) concept page with concrete operations.

The decisive property, stated up front: schedules fire through a signal binding, and the binding decides where the result posts. A schedule without a healthy binding fires into nowhere. Configure the binding first, then the schedule.

## List and read

```bash
curl https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

List schedules on a session with `GET .../cron-schedules`. Read one with `GET .../cron-schedules/:cron_schedule_id`. A schedule carries its `name`, `schedule` (the cron expression map), `timezone`, `status` (`active`/`paused`/`deleted`/`failed`), `next_fire_at`, and `last_fire_at`.

## Create

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "binding_name": "main",
    "name": "morning-briefing",
    "schedule": { "cron": "0 9 * * *", "kind": "cron" },
    "timezone": "Asia/Shanghai",
    "payload": { "task": "Produce today'\''s briefing." }
  }'
```

Three fields are easy to get wrong:

- **`timezone`** — the cron expression is evaluated here. Set it explicitly; a schedule without a timezone is ambiguous.
- **`binding_name`** — the schedule fires through this binding. If it is disabled or unavailable, the fire produces no deliverable result.
- **`payload.task`** — what the agent should do. Keep it short; the persona carries the style.

## Pause and resume

```bash
# Pause
curl -X POST .../cron-schedules/<id>/pause -H "Authorization: Bearer $CONSOLE_TOKEN"

# Resume
curl -X POST .../cron-schedules/<id>/resume -H "Authorization: Bearer $CONSOLE_TOKEN"
```

Pause stops the schedule from firing without deleting it. Status moves to `paused`; `next_fire_at` clears. Resume re-arms the planner and recomputes the next fire time. Use pause for holidays, incidents, or temporary silence.

## Run manually

```bash
curl -X POST .../cron-schedules/<id>/runs -H "Authorization: Bearer $CONSOLE_TOKEN"
```

A manual run fires the schedule immediately, outside its cron rhythm. It does not advance the cron calendar — the next natural fire is unaffected. Use it to test a new schedule, or to run one on demand.

## Inspect runs

```bash
curl .../cron-schedules/<id>/runs -H "Authorization: Bearer $CONSOLE_TOKEN"
```

The runs list shows each concrete fire — when it happened and its outcome. A schedule in `failed` hit its failure policy after repeated fire failures; read the runs for the cause before resuming or recreating.

## Update and delete

```bash
# Update (change the expression, timezone, or task)
curl -X PATCH .../cron-schedules/<id> -H "..." -d '{ "schedule": { "cron": "0 8 * * *", "kind": "cron" } }'

# Remove
curl -X DELETE .../cron-schedules/<id> -H "Authorization: Bearer $CONSOLE_TOKEN"
```

Updating a schedule cancels its pending recurring events and re-arms the planner, so a changed expression takes effect cleanly. Removing a schedule deletes it — recreate if needed.

## Checkbacks (read-only)

Checkbacks are one-shot self-wakeups the agent sets during a turn. The operator surface is read-only:

```bash
# List pending checkbacks
curl .../sessions/<session_id>/checkbacks -H "Authorization: Bearer $CONSOLE_TOKEN"

# Cancel a checkback
curl -X DELETE .../sessions/<session_id>/checkbacks/<scheduled_event_id> -H "Authorization: Bearer $CONSOLE_TOKEN"
```

## A worked example

Create a daily 09:00 briefing in Shanghai time, test it manually, then let it run:

1. Confirm the binding `main` is enabled on the agent's session.
2. `POST .../cron-schedules` with `cron: "0 9 * * *"`, `timezone: "Asia/Shanghai"`, `binding_name: "main"`.
3. `POST .../cron-schedules/<id>/runs` — watch the bound channel for the first output.
4. If the output is right, leave it. If not, `PATCH` the `payload.task` or the persona, and run again.

## What this guide is not

It is not the concept page — for the schedule model, fields, and failure policy, read [Schedules](../schedules/). It is not a troubleshooting guide — for when a schedule does not fire, read [Schedule troubleshooting](../cron-troubleshooting/). And it is not a cron-expression reference — the expression syntax is standard cron, and the `timezone` field is the one that matters.

## Next steps

- For the concept page, read [Schedules](../schedules/).
- For troubleshooting, read [Schedule troubleshooting](../cron-troubleshooting/).
- For automation shapes that use schedules, read [Automation blueprints](../automation-blueprints/).
