---
title: Background jobs (operator view)
description: How to watch and cancel an agent's background jobs — the status states, what waiting-on-user looks like, the retry budget, and how cancellation behaves.
section: User guide
order: 20
---

A background job is work an agent delegates out of its own turn — something long, isolated, or multi-step. As an operator you do not create jobs directly; the agent does, during a turn. Your job is to watch them, understand what their states mean, and cancel one when you need to. This page is the operator view; the lifecycle internals are in the [Background Agent Jobs](../background-agent-jobs/) developer page.

The decisive property, stated up front: a job is durable work, not a child process. Its state survives worker loss, and cancelling it does not yank a live worker out from under a running turn.

## List and read jobs

```bash
curl https://ankole.example.com/api/v1/background-agent-jobs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

List jobs with `GET /background-agent-jobs`, and read one with `GET /background-agent-jobs/:job_id`. A job carries its `title`, `task`, `status`, `attempts`, `result` or `error`, and the `owner_session_id` it reports back to. Filter the list to the jobs you care about — by agent, by status, or by recency — using the query parameters the [Console API reference](../console-api/) documents.

## What each status means

A job moves through six statuses. The ones you act on as an operator:

| Status | What it means | What you do |
|---|---|---|
| `queued` | accepted, waiting for a running slot | usually nothing — it will start when a slot frees |
| `running` | occupying one of the agent's running slots (at most three per agent) | watch; nothing to do unless it runs too long |
| `waiting_on_user` | paused for human input; has released its slot | answer the agent's question through the owning session; the job resumes |
| `succeeded` | terminal; the job finished and reported back | read the `result` |
| `failed` | terminal; the job exhausted its retry budget or hit an unrecoverable error | read the `error`; decide whether to re-run |
| `stopped` | terminal; cancelled by an operator | nothing; the job will not run again |

`waiting_on_user` is the one worth pausing on. It is not stuck — it is waiting for a human decision, and it has given its running slot back so the agent can do other work. The agent's question reaches the owning session as a `background_agent_job.waiting` event; answering it through that session resumes the job.

## The retry budget

A job has a bounded retry budget: at most **five execution attempts**, and at most **five consecutive turn failures**. When an attempt does not start cleanly, the runtime puts the job back to `queued` and tries again, with a bounded delay (around 30 seconds between attempts). A job that exceeds the budget lands in `failed` with the cause in its `error`. So a job in `failed` is not a job that gave up after one try — it is a job that tried its budget and could not succeed.

## Cancel a job

```bash
curl -X POST https://ankole.example.com/api/v1/background-agent-jobs/<job_id>/cancel \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

Cancellation drives the job to `stopped`. It does not yank a live worker out from under a running turn — the turn finishes or fails on its own, fenced by the same checks every worker write goes through. This is why a cancelled job may briefly show `running` before it settles to `stopped`: the in-flight turn is allowed to complete, and then the cancellation takes hold.

## When something does not work

- **A job sits in `queued` for a long time** — the agent may already have three jobs running (the per-agent slot limit). Cancel a running one, or wait for one to finish.
- **A job is `running` for too long** — check the agent's model profiles and the upstream provider; a long-running job is usually waiting on the model, not on Ankole.
- **A job went to `failed`** — read the `error`. If the cause is transient (a provider timeout), the agent can create a new job; if it is a configuration error, fix the configuration first.
- **`waiting_on_user` but no question arrived** — the wakeup event goes to the owning session; check that the session's signal binding is enabled and the channel is in scope.

## Next steps

- For the lifecycle internals — the state machine, the wakeup events, and the recovery model — read [Background Agent Jobs](../background-agent-jobs/).
- For the routes, read the [Console API reference](../console-api/).
- For the turn a job runs inside, read the [Actor Runtime](../actor-runtime/) developer page.
