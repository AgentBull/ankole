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

The `Ankole.BackgroundAgentJobs.Schemas.Job` Ash state machine defines the allowed transitions. Worker completion requires a `running` Job; the operator's `external_complete` action can complete a `queued`, `running`, or `waiting_on_user` Job. Terminal Jobs cannot transition to another status.

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

`waiting_on_user` pauses a job cleanly without holding a running slot. When a job needs a human decision, it transitions to `waiting_on_user` while the latest-status projection records `interrupted` with error code `request_user_input` and the pending tool call, giving the owner Session an exact continuation point. Once the answer arrives, the job transitions back to `running` and resumes. When a `waiting_on_user` job resumes after sitting paused for at least `10` minutes and its latest model call reported at least `128,000` total tokens, `CodexJobSession` starts a fresh thread seeded from the bounded Workspace rebuild (`job.task`, durable Workspace files, bounded attempt history, and any source task/report) rather than replaying a cold large context window, rotating the runtime CLI `contextId` whenever a fresh thread starts or compaction settles.

A new job can also continue from an earlier completed job rather than its own pause: `continued_from_job_id` and `workspace_owner_job_id` link the chain so multi-stage work carries forward both its Codex thread and its workspace.

## Recovery across worker failure

PostgreSQL preserves Job state across Worker failures, while the persistent Home preserves its workspace and Codex thread. Each Job allows at most five execution failures, 25 total slot claims, and five consecutive turn failures. Claiming a fresh slot increments `attempts`; adopting a running attempt does not. Infrastructure interruptions return retryable work to `queued` without charging an execution failure, while retaining the consumed claim count.

Two transactional claim paths handle dispatch and continuation:

- **`claim_attempt_in_tx`** claims a `queued` Job for a new execution attempt.
- **`claim_continuation_in_tx`** claims a Job to continue after input arrives.

Both lock the Agent's capacity before the Job row. Exhausting a retry budget moves the Job to `failed`; operator cancellation moves it to `stopped`.

`Ankole.Sessions.TurnErrorClassifier` selects the retry delay. Infrastructure interruptions use a 15, 30, 60, 120, then 300-second ladder without consuming the execution-failure budget. Retryable execution and provider-capacity failures use 60, 600, 1,800, 3,600, then 7,200 seconds and consume that budget. Terminal rejections fail immediately.

When AIGateway reports credential-pool exhaustion with a future recovery timestamp, Ankole returns the Job to `queued`, releases its Worker assignment, and schedules dispatch for that timestamp without charging an execution failure. The acquired claim still counts toward the 25-claim limit. A missing or past recovery timestamp uses the ordinary execution retry ladder and charges an execution failure.

## Dispatch and the agent's plugins

Each job carries an optional workspace template, and on its first execution admission Ankole atomically snapshots both the resolved provider/model binding and the Agent's enabled Agent Plugins and Skills. Retries and resumes intersect that frozen snapshot with the Agent's current effective set: disabling a capability revokes it immediately and re-enabling restores it, whereas capabilities enabled only after admission cannot be added retroactively. Credentials and mutable Skill files still resolve from their live owners. `Sessions.CodexJob` admits each attempt from its kernel Signal and isolates steer events so ordinary conversation deliveries are never mistaken for job steers. Every model call flows through AIGateway under the captured binding, where AIGateway manages credential-pool selection, affinity, refresh, and retries.

Background Agent Jobs use the same dynamic `skill_view` loader as the main Agent, backed by `Ankole.AIAgent.Library`. Before each run, the Worker computes the loadable Skill set by intersecting the Job's frozen Skill selection with the Agent's currently enabled Skills in `Ankole.AIAgent.Library` and the `ankole-runtime` filter, materializing each permitted package—including companion files, scripts, and MCP declarations—at `/workspace/.ankole/turn-skills/<signal-id>/<skill-name>/`. On each `skill_view` call, the control plane verifies current enablement, reads the Skill manifest or relative package file from `Ankole.AIAgent.Library`, and appends any active per-Agent Skill lesson.

Before every Turn, including resume, the Worker refreshes the complete effective Agent contract (`Ankole.AIAgent.Library.Contracts`) in `$CODEX_HOME/AGENTS.md` and `~/AGENTS.md`, and the visual contract in `~/DESIGN.md`. Workspace templates and repositories own project instructions. Job context and the Skill index arrive as developer instructions. Codex uses a one-minute minimum and ten-minute default for native subagent waits.

## The operator surface

Console API routes under `/api/v2` cover job inspection, turn history, health, and lifecycle control:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/background-agent-jobs` | List jobs |
| `GET` | `/api/v2/background-agent-jobs/:id` | Read one job |
| `GET` | `/api/v2/background-agent-jobs/health` | Read job subsystem health |
| `GET` | `/api/v2/background-agent-jobs/:job_id/turns` | List turns for a job |
| `POST` | `/api/v2/background-agent-jobs/:id/cancel` | Cancel a job |
| `POST` | `/api/v2/background-agent-jobs/:id/complete` | Mark a job completed |

Calling `cancel` transitions the Job to `stopped` and requests cancellation of its live Worker execution; PostgreSQL's Job status, attempt identity, and Turn revision fence any late Worker result from committing.

## What Background Agent Jobs are not

A Background Agent Job is not an untracked background shell process: it is an explicit state machine with a fixed transition table, a bounded retry budget, and a single owner Session that it reports back to. Nor does it step outside AuthZ—each job executes as its owning Agent under the same permissions, Plugins, and Skills. Finally, jobs complement rather than replace `Ankole.Sessions`: both share the Signal queue and fencing primitives, with Sessions owning the live turn and Background Agent Jobs owning long-horizon resumable work.

## Next steps

- For the live turn that spawns a job and receives its wakeups, read the [Sessions](../sessions/) page.
- For the model turns that a job runs, read the [AIGateway API](../ai-gateway/).
- For how a job's wakeup reaches the owner as a normal signal, read the [Signals](../signals/) page.
