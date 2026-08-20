---
title: Background Agent Jobs
description: Durable, resumable work that survives worker loss — the job state machine, wait-for-input, owner wakeup, and the boundary with the Actor Runtime.
section: Developer guide
order: 105
---

A Background Agent Job is a unit of work that is meant to outlive any single worker. An agent spawns one to do something that takes too long, too many steps, or too much isolation to run inline in its own turn — and then the job runs, pauses for input, fails, or finishes on its own schedule, while the agent that started it stays free to talk to its owner. This page maps that lifecycle against the real code in `Ankole.BackgroundAgentJobs`.

The decisive property, stated up front: a job is durable work, not a child process. Its state lives in PostgreSQL, every transition is fenced and audited, and when its status changes in a way the owner should know about, the job appends a wakeup event back to the owner's session — through the same actor-event queue that ordinary signals use.

## The boundary with the Actor Runtime

A session turn and a background job are different shapes of work, and the runtime keeps them separate. The Actor Runtime owns the live, fenced turn — wake a session, run one model loop, commit. A Background Agent Job owns durable, resumable work that a turn delegates to. The handoff is explicit: a job carries `owner_session_id`, `source_actor_event_id`, and `source_tool_call_id`, so the link from the spawning turn to the job, and back, is always reconstructable.

What this means in practice: a job is not a second session and not a competing claim on the agent. It is work the owner session asked for, with its own state machine, its own retry budget, and its own way of reporting back.

## The job state machine

A job moves through six statuses, and the transitions are constrained by a fixed table:

```text
queued → running → waiting_on_user → running → … → succeeded | failed | stopped
```

- **`queued`** — accepted, not yet claiming an agent running slot.
- **`running`** — occupying one of the agent's running slots (at most three per agent).
- **`waiting_on_user`** — paused for human input. Releases its running slot; a later turn resumes it.
- **`succeeded`**, **`failed`**, **`stopped`** — terminal. A terminal job has no live execution.

Every transition goes through `transition_allowed?/2`, so a `queued` job cannot jump to `succeeded` without passing through `running`, and a terminal job cannot move at all. The table is the contract; nothing in application code may bypass it.

## Wakeup: reporting back to the owner

When a job lands in a status the owner should hear about, the lifecycle commits the transition and appends a wakeup event to the owner's session in the same transaction. Three statuses produce a wakeup:

| Job status | Wakeup event type |
|---|---|
| `succeeded` | `background_agent_job.completed` |
| `failed` | `background_agent_job.failed` |
| `waiting_on_user` | `background_agent_job.waiting` |

The wakeup is a normal actor event — same queue, same fencing, same session controller as any other signal — addressed to `owner_session_id` and routed through the job's `reply_route` (its binding, channel, thread). The owner session does not poll; it gets woken exactly when there is something to report. A transition into `queued` or `running` produces no wakeup, because those are not things the owner needs to act on.

The wakeup event's source id encodes the job, the status, and the attempt number, so a resumed job's later wakeup cannot be confused with an earlier one.

A completion wakeup carries a bounded result summary. When the persisted final response is larger than the summary limit, the owner Agent calls `show_background_job_details` with `result_offset: 0`, then passes each returned `result.next_offset` to the next call until it is `null`. The UTF-8-safe segments reconstruct the exact response. This keeps the wakeup and each result read bounded without adding another Job operation or losing access to the durable result.

## Resume and wait-for-input

`waiting_on_user` is the pause that keeps the job alive without holding a slot. When the job needs a human decision, it transitions to `waiting_on_user`; the latest-status projection records `interrupted` with error code `request_user_input` and a pending tool call, so the owner's next turn has a precise place to resume from. When the human answers, the job transitions back to `running` and continues.

A job can also continue from a previous job rather than from its own pause: `continued_from_job_id` and `workspace_owner_job_id` record the chain. This is how long work gets handed forward without losing the thread or the workspace.

## Recovery across worker failure

Because the job state is durable, worker loss is a recoverable event, not a data loss event. The runtime gives a job a bounded retry budget — at most five execution attempts, and at most five consecutive turn failures — and when an attempt does not start cleanly, `requeue_unstarted_attempt` decrements the attempt counter and puts the job back to `queued`, clearing `started_at` on the first attempt so it looks like a fresh start.

Two claim paths cover the two recovery shapes:

- **`claim_attempt_in_tx`** — claim a job for a new execution attempt.
- **`claim_continuation_in_tx`** — claim a job to continue after a pause.

Both take the agent's slot lock and then the job row under `FOR UPDATE`, in that fixed order. Concurrent dispatchers for the same agent therefore resolve the same way every time. A retried attempt that exceeds the budget lands in `failed`; a job that has been cancelled lands in `stopped`. The retry delay between attempts is bounded at 30 seconds, so a transiently failed job does not hammer the provider.

AIGateway quota exhaustion with a known future recovery time returns the Job to `queued`, releases its Worker assignment, and schedules dispatch for that time. The acquired attempt stays consumed, so repeated quota failures remain inside the five-attempt budget. A stale or missing recovery time uses the ordinary bounded Job retry path instead of immediate dispatch.

## Dispatch and the agent's plugins

A job retains one optional workspace template, but each execution uses the agent's *current* enabled Agent Plugins and compatible Skills — not a snapshot frozen at spawn time. The dispatch path (`BackgroundAgentJobDispatch.process`) resolves the job from the actor event, hands it to the turn runtime, and treats steer events separately so a live delivery to the session is not mistaken for a job steer. Every model turn goes through AIGateway with the provider binding that the Job saved at creation. If that provider has several credentials, AIGateway owns their selection, affinity, refresh, and retry; the Job has no account field or account concurrency slot.

When a job first initializes its workspace, the runner composes the project `AGENTS.md`: the optional workspace template comes first, followed by the rendered job context — the agent's SOUL and MISSION, and execution facts. The shared `app/library/templates/AGENT_JOB.md` remains an extension point, but the shipped file is empty, so the runner omits the Job Guidance section. The Codex project config sets the native subagent wait minimum to one minute and the default to two minutes. It does not set the maximum, so Codex keeps its default. This reduces repeated model turns after empty waits, as tracked in [openai/codex#35259](https://github.com/openai/codex/issues/35259). A resumed thread keeps its existing `AGENTS.md`.

## The operator surface

Three console-scoped routes cover what an operator needs:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/background-agent-jobs` | List jobs |
| `GET` | `/background-agent-jobs/:job_id` | Read one job |
| `POST` | `/background-agent-jobs/:job_id/cancel` | Cancel a job |

Cancellation drives the job to `stopped`; it does not yank a live worker out from under a running turn. The turn finishes or fails on its own, fenced by the same activation and revision checks every worker write goes through.

## What Background Agent Jobs are not

A job is not a free-form background process. It is a state machine with a fixed transition table, a bounded retry budget, and a single owner session it reports back to. It is not a way to run work outside the permission boundary — the job runs as its agent, under the same plugins and skills. And it is not a replacement for the Actor Runtime; the two share the actor-event queue and the fencing machinery, but a job owns resumable work while the runtime owns the live turn. The boundary is deliberate, and crossing it goes through a documented transition, not through reaching into the other layer's internals.

## Next steps

- For the live turn a job is spawned from and reports back to, read the [Actor Runtime](../actor-runtime/) page.
- For the model turns a job's execution runs, read the [AIGateway API](../ai-gateway/).
- For how a job's wakeup reaches the owner as a normal signal, read the [SignalsGateway](../signals-gateway/) page.
