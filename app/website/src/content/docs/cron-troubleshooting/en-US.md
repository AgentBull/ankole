---
title: Schedule troubleshooting
description: When a cron schedule does not fire, fires at the wrong time, or fires but nothing posts — work these checks in order, against the real status, binding, and model-profile boundaries.
section: Guides
order: 310
---

A schedule that misbehaves falls into one of four buckets: it is not firing, it is firing at the wrong time, it is firing but nothing posts, or it landed in `failed`. This page works them in the order that finds the cause fastest. Most schedule problems are configuration, not code.

The decisive property to keep in mind: a schedule owns only *time*. It produces a wake edge at the moment its cron expression says, in the timezone it carries. Everything after that — whether the binding delivers, whether the agent runs, whether the model resolves — is a different subsystem's boundary, and the fix is almost never on the schedule itself.

## Symptom: it did not fire

### Check 1: confirm the schedule exists and is `active`

```bash
curl https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

Find the schedule and confirm its `status`. The status vocabulary is `active`, `paused`, `deleted`, `failed`:

- **`paused`** — someone paused it. Resume with `POST .../cron-schedules/:id/resume`.
- **`deleted`** — it was removed; recreate it.
- **`failed`** — the schedule hit its failure policy. Read the runs list (`GET .../cron-schedules/:id/runs`) for the cause; fix the underlying issue, then recreate or resume as the policy allows.
- **`active`** with a `next_fire_at` in the past — the scheduler has not picked it up, or the control plane was down across the fire window.

Only `active` schedules fire. This is the first check because it is the most common silent failure.

### Check 2: confirm `next_fire_at` is set and in the future

An `active` schedule with `next_fire_at: null` is armed but has no next fire planned — usually because it was just resumed and the planner has not recomputed, or because the schedule's expression could not be normalized. Patch the schedule (`PATCH .../cron-schedules/:id`) to re-trigger normalization; if `next_fire_at` stays null, the schedule expression is invalid and the normalizer rejected it silently.

### Check 3: was the control plane up at the fire time?

The scheduler is a control-plane process. If the control plane was down, restarting, or migrating across the window when the schedule should have fired, that fire is missed — Ankole does not retroactively fire schedules for downtime windows. If the cadence matters across outages, plan around it; a daily 09:00 schedule missed during a 09:00–09:05 restart fires tomorrow, not at 09:06.

## Symptom: it fired at the wrong time

### Check 4: the timezone

A cron expression is evaluated in the schedule's `timezone`. The single most common "wrong time" cause is a timezone mismatch — a 09:00 schedule evaluated in UTC when the team is in `Asia/Shanghai` fires five hours early. Confirm `timezone` matches where the team is. `next_fire_at` is computed in that timezone; compare it against a clock in the same zone.

### Check 5: the cron expression itself

A misformatted expression is either rejected at normalization (and `next_fire_at` stays null — see Check 2) or normalized to something other than what you intended. Fire the schedule manually (`POST .../cron-schedules/:id/runs`) to confirm the *task* works; then fix the expression separately. The manual run does not validate the cron timing — it validates everything downstream.

## Symptom: it fired but nothing posted

The schedule fired; the problem is downstream. This is where schedule troubleshooting stops being about the schedule.

### Check 6: the binding the schedule fires through

A schedule fires through its `binding_name`, which decides the channel and reply mode. If that binding is disabled, unavailable (it records `unavailable_reason`), or points at a channel the agent cannot post in, the fire produced an event that went nowhere. Confirm the binding is enabled and healthy through `GET /agents/:agent_uid/signal-bindings`.

### Check 7: the agent's model profiles

A scheduled turn is a real turn — it needs the same model profiles a hand-driven turn does. If `primary`/`light`/`heavy` are unbound or resolve to a provider whose credentials are stale, the scheduled turn fails the same way a conversational one would, just silently because no human is watching. Confirm through `/agents/:agent_uid/model-profiles` and the provider rows.

### Check 8: the worker

A scheduled turn needs a ready worker. On a busy installation, the worker pool may be at capacity when the schedule fires; the turn queues but does not run until a slot frees. Check `/background-agent-jobs` and worker logs for the fire window. A schedule that "sometimes works, sometimes does not" is often a capacity issue, not a schedule issue.

## Symptom: it landed in `failed`

### Check 9: read the runs, then fix the underlying cause

A schedule in `failed` hit its failure policy after repeated fire failures. The runs list (`GET .../cron-schedules/:id/runs`) records each fire and its outcome — read the most recent failures for the cause. The cause is almost always one of Checks 6–8 (binding, model profiles, worker), not the schedule itself. Fix the downstream issue before resuming or recreating, or the schedule will fail again.

Do not delete a `failed` schedule to "reset" it without reading the runs — you lose the failure history that tells you what to fix.

## The fastest path: a manual run

If you are not sure whether the problem is timing or downstream, run the schedule manually first:

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules/<cron_schedule_id>/runs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

A manual run produces a concrete fire event, recorded in the runs list. If the manual run posts, the problem is timing (Checks 4–5) or the scheduler (Checks 1–3). If the manual run also fails to post, the problem is downstream (Checks 6–8), and the cron timing was never the issue.

## What this page is not

It is not a schedule-design guide — for the shape of a schedule and its fields, read [Schedules](../schedules/). And it is not a way to make schedules fire retroactively; missed fires during downtime stay missed, by design. The schedule subsystem is thin on purpose: it owns time, and hands off to everything else. Troubleshooting it is mostly troubleshooting what it hands off to.

## Next steps

- For the schedule surface, read [Schedules](../schedules/).
- For the automation shapes that use schedules, read [Automation blueprints](../automation-blueprints/).
- For the binding a schedule fires through, read [Signal bindings](../signal-bindings/).
