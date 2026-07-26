---
title: Incident response
description: The end-to-end shape of handling an Ankole incident — contain, diagnose, stop the harm, recover, and learn, using the real Console and deployment surfaces.
section: Guides
order: 312
---

An incident on an Ankole installation — a misbehaving agent, a leaked secret, a bad deploy, a runaway job — has a shape. This page walks it: contain first, then diagnose, then stop the harm, then recover, then learn. Every move uses a surface the other guides document; this page is the order to use them in when something is on fire.

The decisive property, stated up front: Ankole gives you containment moves that take effect in seconds (disable a binding, cancel a job) and recovery moves that take longer (restore PostgreSQL, roll an image). Use the fast ones first. The goal of the first five minutes is to stop the harm, not to understand it.

## Phase 1: contain (seconds to minutes)

Reach for the fastest move that stops the harm. You can undo any of these once you understand the incident.

| Harm | Fastest containment | Command |
|---|---|---|
| An agent is misbehaving in a channel | disable the signal binding | `PATCH /agents/:agent_uid/signal-bindings/:binding_name` with `enabled: false` |
| A background job is runaway or wrong | cancel it | `POST /background-agent-jobs/:job_id/cancel` |
| An agent itself must stop | disable the agent Principal | through `/principals` — removes authority across the installation |
| A schedule is firing into the harm | pause it | `POST .../cron-schedules/:id/pause` |
| A worker is wedged | restart the worker | Compose: `docker compose restart agent-computer-worker`; Helm: delete the worker pod |

Disabling a binding is the single most useful move — it silences the agent in one channel without losing configuration, and it is reversible. cancelling a job lets an in-flight turn finish, so it is not instant, but it stops new work. None of these destroy data.

Do **not** reach for `docker compose down -v` or a database drop in the first five minutes. Those are recovery moves, and they destroy data you will want for diagnosis.

## Phase 2: diagnose (minutes to an hour)

With the harm contained, work out what happened. Use the [Observability](../observability/) surfaces, in this order:

1. **What did the agent actually do?** — `GET /ai-gateway/conversations` and `.../messages` for the turn in question. This is the fastest tell: a model call with a bad output points one way; no model call points another.
2. **What did the system decide?** — `GET /background-agent-jobs/:job_id` for a job, `GET .../cron-schedules/:id/runs` for a schedule, `GET /brain/audit-log` for a memory change. These are durable records; they survive the process.
3. **What did the logs see?** — the structured control-plane logs, searched by event name, narrowed by fields. Drop `ANKOLE_LOG_LEVEL` to `debug` only if the incident is still reproducing; for a past incident, read what was captured at `info`.
4. **Is the worker the culprit?** — `GET /agent-computer-workers` for state, and worker logs for the window.

Separate "the agent did the wrong thing" (a persona or model-profile problem) from "the system did the wrong thing" (a binding, worker, or schedule problem). The fix is different, and confusion between them wastes time.

## Phase 3: stop the harm permanently

Containment was reversible; now make the fix that lets you re-enable things safely.

- **Leaked secret** — rotate it. Put the new value in WorkerEnv (`PUT /worker-envs/:name`), and invalidate the old one at the provider. The old value stays unreadable; do not decrypt it to "check" — set the new one. See [WorkerEnv secrets](../worker-env/).
- **Bad agent behavior** — fix the persona (`MISSION.md`/`SOUL.md`/`DESIGN.md`), tighten the model profile, or narrow the AuthZ grants. Re-enable the binding and watch a few turns before declaring it fixed.
- **Bad deploy** — roll the image. Compose: pin the old digest in `.env`, `docker compose up -d --force-recreate`. Helm: set the old digest in `values-production.yaml`, `helm upgrade`. This does **not** reverse a database migration; if the migration is the problem, restore PostgreSQL from the pre-deploy backup. See [Updating](../updating/).
- **Compromised credentials** — rotate every secret that could have been seen: the worker auth key, the secret base, provider API keys. The blast radius of a compromised `ANKOLE_SECRET_BASE` is the whole installation; treat it as full.

## Phase 4: recover

Bring the system back to a known-good state.

- **Re-enable what you contained** — bindings, schedules, the agent Principal. Do this one at a time, watching the [Observability](../observability/) surfaces after each.
- **Restore from backup if needed** — PostgreSQL from the `pg_dump` archive, Agent Home from the volume snapshot. Test the restore on a separate host first; an untested restore is not a recovery plan.
- **Clear stuck state** — a job in `failed` that you want to re-run: create a new one, or respawn from it (`respawn_background_job`, available to the agent). A schedule in `failed`: fix the underlying cause, then recreate.

## Phase 5: learn

After the incident, the durable record is what lets you respond faster next time.

- **Keep the audit trail** — Brain audit log, job runs, conversation history, and the logs you captured. Do not delete them to "clean up"; they are the evidence.
- **Write down what happened** — the timeline, the containment move that worked, the root cause, the fix. Keep it where the next on-call can find it.
- **Adjust the persona or the grants** — if the incident was an agent doing the wrong thing, the fix is usually in the persona or the AuthZ scope, not in code. See [team-assistant](../team-assistant/) for the persona-as-judgment pattern.
- **Check the backup actually worked** — if you restored, confirm the restored data is what you expect. If you did not need to restore, confirm the backup you would have used is valid.

## What incident response in Ankole is not

It is not a runbook of exact commands for every incident — incidents vary, and the surfaces above are the building blocks, not the script. It is not "restart everything and hope" — that destroys evidence and often makes recovery harder. And it is not a substitute for tested backups; every recovery path here assumes a `pg_dump` and an Agent Home snapshot that you have actually restored once. An untested backup is the most expensive thing you can own in an incident.

## Next steps

- For the read surfaces you diagnose with, read [Observability](../observability/).
- For the upgrade and rollback mechanics, read [Updating](../updating/).
- For secret rotation, read [WorkerEnv secrets](../worker-env/).
- For the permission moves, read [Principal and AuthZ](../principal-authz/).
