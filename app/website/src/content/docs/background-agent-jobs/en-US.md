---
title: Background Agent Jobs
description: Durable, resumable work that survives worker loss — the job state machine, wait-for-input, owner wakeup, and the boundary with Sessions.
section: Developer guide
order: 105
---

A Background Agent Job is a unit of work designed to outlive any single Worker instance. An Agent spawns one whenever a task takes too long, spans too many steps, or needs dedicated workspace isolation rather than running inline during a foreground turn—allowing the job to run, pause for human input, fail, or complete on its own schedule while the foreground Agent stays free to converse. This page maps that lifecycle directly to `Ankole.BackgroundAgentJobs`.

A Background Agent Job is durable database-backed work, not an ephemeral child process: PostgreSQL owns its state, every transition is fenced and audited, and whenever its status changes in a way that the owner should act on, Ankole appends a wakeup event back to the owner's Session through the standard Signal queue.

## The boundary with Sessions

Foreground turns and background jobs represent distinct work shapes, so the runtime keeps them separate: `Ankole.Sessions` owns a live, fenced turn (wake a Session, run one model loop, commit), whereas a Background Agent Job owns delegated, resumable work. Their linkage is explicit—every job stores `owner_session_id`, `source_signal_id`, and `source_tool_call_id` so the chain from the spawning turn to the job and back is always reconstructable.

At runtime, each job executes inside a dedicated `job:<id>` Session under the same Agent, governed by its own state machine, retry budget, and reporting rules while reporting back to `owner_session_id`.

## The job state machine

Every job progresses through six statuses governed by a fixed transition table:

```text
queued → running → waiting_on_user → running → … → succeeded | failed | stopped
```

- **`queued`** — accepted and waiting, not yet occupying an Agent running slot.
- **`running`** — occupying one of the Agent's running slots (default `3` per Agent).
- **`waiting_on_user`** — paused for human input; releases its running slot until a later turn resumes it.
- **`succeeded`**, **`failed`**, **`stopped`** — terminal states with no live execution.

Every status change passes through `transition_allowed?/2`, preventing a `queued` job from jumping straight to `succeeded` without passing through `running` and preventing any transition out of a terminal status. Nothing in application code may bypass this table.

## Wakeup: reporting back to the owner

Whenever a job enters a status that the owner needs to hear about, `Ankole.BackgroundAgentJobs` commits the transition and appends a wakeup Signal to `owner_session_id` in the same database transaction:

| Job status | Wakeup event type |
|---|---|
| `succeeded` | `background_agent_job.completed` |
| `failed` | `background_agent_job.failed` |
| `waiting_on_user` | `background_agent_job.waiting` |

Each wakeup is an ordinary Signal—using the same queue, epoch fencing, and Session Driver as any other Signal—addressed to `owner_session_id` and routed through the job's `reply_route` (binding, channel, and thread). Rather than polling, the owner Session wakes only when something actionable happens; transitions into `queued` or `running` emit no wakeup.

Because each wakeup event's source ID encodes the job ID, target status, and attempt number, a later wakeup after a resume can never collide with an earlier wakeup from the same job.

Completion wakeups carry a bounded result summary. When the persisted final response exceeds that summary limit, the owner Agent calls `show_background_job_details` starting at `result_offset: 0` and passes each returned `result.next_offset` into the next call until `null`, reconstructing the exact response across UTF-8-safe segments without bloating the wakeup event.

## Resume and wait-for-input

`waiting_on_user` pauses a job cleanly without holding a running slot. When a job needs a human decision, it transitions to `waiting_on_user` while the latest-status projection records `interrupted` with error code `request_user_input` and the pending tool call, giving the owner Session an exact continuation point. Once the answer arrives, the job transitions back to `running` and resumes.

A new job can also continue from an earlier completed job rather than its own pause: `continued_from_job_id` and `workspace_owner_job_id` link the chain so multi-stage work carries forward both its Codex thread and its workspace.

## Recovery across worker failure

Because job state lives in PostgreSQL, losing a Worker is a routine recovery event rather than data loss. Each job receives a bounded retry budget—at most five execution attempts and at most five consecutive turn failures—and if an attempt fails before starting cleanly, `requeue_unstarted_attempt` decrements the attempt counter and returns the job to `queued` (clearing `started_at` on attempt 1 so it looks freshly queued).

Two transactional claim paths handle dispatch and continuation:

- **`claim_attempt_in_tx`** — claims a `queued` job for a new execution attempt.
- **`claim_continuation_in_tx`** — claims a paused job to continue after input arrives.

Both acquire the Agent's slot lock first and then lock the job row `FOR UPDATE` in that fixed order, eliminating deadlocks between concurrent dispatchers for the same Agent. Exhausting the retry budget moves the job to `failed`, while operator cancellation moves it to `stopped`. Retries back off up to 30 seconds so transient upstream glitches do not hammer providers.

When an attempt hits AIGateway quota exhaustion with a known future recovery timestamp, Ankole returns the Job to `queued`, releases its Worker assignment, and schedules dispatch for that timestamp—keeping the acquired attempt counted so repeated quota hits stay bounded within the five-attempt budget. If the recovery timestamp is missing or already past, Ankole uses the standard bounded retry delay instead of immediate dispatch.

## Dispatch and the agent's plugins

Each job carries an optional workspace template, and on its first execution admission Ankole atomically snapshots both the resolved provider/model binding and the Agent's enabled Agent Plugins and Skills. Retries and resumes intersect that frozen snapshot with the Agent's current effective set: disabling a capability revokes it immediately and re-enabling restores it, whereas capabilities enabled only after admission cannot be added retroactively. Credentials and mutable Skill files still resolve from their live owners. `Sessions.CodexJob` admits each attempt from its kernel Signal and isolates steer events so ordinary conversation deliveries are never mistaken for job steers. Every model call flows through AIGateway under the captured binding, where AIGateway manages credential-pool selection, affinity, refresh, and retries.

Background Agent Jobs load Skills through the same Ankole `skill_view` loader as the foreground Agent: ordinary compatible Skills appear in the Job's Skill index, while Skills declaring `brain-recall-only: true` stay out of the index and remain discoverable via Brain (with `get_page` delegating matching discovery records to `skill_view`). Before every read of `SKILL.md` or a bundled file, the loader verifies current effective Plugin and Skill enablement with the control plane so a running Job cannot keep reading a Skill after an operator disables it.

When a job initializes its workspace for the first time, the runner writes the project `AGENTS.md` with any workspace template first, followed by the rendered job context (the Agent's `SOUL.md`, `MISSION.md`, and execution metadata); resumed threads reuse that existing `AGENTS.md`. In the Codex project config, Ankole sets the native subagent wait minimum to one minute and default to two minutes while leaving the maximum at Codex's built-in default, reducing empty-wait model turns as tracked in [openai/codex#35259](https://github.com/openai/codex/issues/35259).

## The operator surface

Three Console API routes cover job inspection and control:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/background-agent-jobs` | List jobs |
| `GET` | `/background-agent-jobs/:job_id` | Read one job |
| `POST` | `/background-agent-jobs/:job_id/cancel` | Cancel a job |

Calling `cancel` transitions the Job to `stopped` and requests cancellation of its live Worker execution; PostgreSQL's Job status, attempt identity, and Turn revision fence any late Worker result from committing.

## What Background Agent Jobs are not

A Background Agent Job is not an untracked background shell process: it is an explicit state machine with a fixed transition table, a bounded retry budget, and a single owner Session that it reports back to. Nor does it step outside AuthZ—each job executes as its owning Agent under the same permissions, Plugins, and Skills. Finally, jobs complement rather than replace `Ankole.Sessions`: both share the Signal queue and fencing primitives, with Sessions owning the live turn and Background Agent Jobs owning long-horizon resumable work.

## Next steps

- For the live turn that spawns a job and receives its wakeups, read the [Sessions](../sessions/) page.
- For the model turns that a job runs, read the [AIGateway API](../ai-gateway/).
- For how a job's wakeup reaches the owner as a normal signal, read the [Signals](../signals/) page.
