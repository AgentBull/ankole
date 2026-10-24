# Workflow

A Workflow runs one fixed JavaScript program that can call bounded subagent
tasks. The main Agent starts the run once. The control plane stores the program,
each task, and each result in PostgreSQL. The main Agent receives one new event
when the run completes or fails.

A Workflow is for bounded fanout and multi-stage control flow. A
BackgroundAgentJob is for one long-running Codex task that can receive later
messages. A Workflow task cannot create another Workflow, so orchestration has
depth one. A task can create BackgroundAgentJobs and hibernate until they
finish, which lets one `agent()` call own hours of delegated work behind a
bounded schema result.

Every Workflow participant follows the shared async-work Session contract in
[Sessions](Sessions.md#execute-tools-and-asynchronous-work): the session id is the
address, the owner session is the parent, mail wakes a hibernating unit, and
lifecycle signals travel one level up.

## What the Main Agent Can Do

Each model tool performs one Workflow operation. The tools do not use an
`action` field to select operations.

`workflow` starts one run. Its input contains:

- `title`: required display text of at most 200 characters
- `script`: required JavaScript source for the program body
- `args`: an optional JSON object that the script reads as `args`
- `concurrency`: an optional per-run task limit from 1 through 32
- `max_agent_calls`: an optional total task limit from 1 through 1,024
- `model_profile`: an optional custom model profile from the current turn

The configured Workflow limits can reduce `concurrency` and `max_agent_calls`.
The tool returns the decimal `run_id` and the initial `running` status. The
main Agent must not poll the run. The control plane sends one completion or
failure event to the owner Session.

`show_workflow` reads one run that belongs to the current Agent. Without
`result_offset`, it returns the concrete status, task counts, at most 32 live
tasks, and at most ten task failure summaries. A live task row carries
`call_seq`, `label`, `status`, the task's sleep `note`, its `attention` flag,
`wake_at`, and `wake_count`, with attention rows first. A sleeping task
is executing, not finished: it hibernates until an event wakes it. For a
completed run, set `result_offset` to a stable UTF-8 byte offset to read one
bounded result segment. A segment contains at most 8,000 bytes. Use its next
offset to read the next segment.

`send_message_to_workflow_task` appends one owner message to a live task,
addressed by `run_id` and `call_seq`. The append is asynchronous and idempotent
per tool call: a sleeping task wakes with the message, a running task receives
it when its current Turn ends, a queued task reads it after its dispatch, and a
terminal task rejects it. The tool cannot block on a task reply.

`list_workflows` lists at most 32 runs that belong to the current Agent. The
optional status is `live` or `done`. `live` selects `running`. `done` selects
`completed`, `failed`, and `cancelled`. The optional `page` is the turn-local
page reference from the preceding result.

`cancel_workflow` accepts one `run_id`. Cancellation is idempotent. It stops new
tasks, asks running task turns to stop, and prevents restart recovery from
starting the run again. Cancellation does not send a completion event.

Each Workflow task receives one private `submit_result` tool. This tool is not
available to the main Agent. A successful submission must match the task schema.
The control plane declares this tool with provider strict mode and validates
the value when it commits the result. A rejected value does not end the task turn, so the
subagent can correct it and submit it again.

## Task Sleep and Wake

A task turn can end in exactly three ways: `submit_result`, `sleep`, or
failure. The private `sleep` tool parks the call as durable `sleeping` state
and ends the turn. A sleeping task holds no Worker slot and does not count
against run or Agent concurrency. Its required `note` (at most 200 characters)
tells the owner what it waits for through `show_workflow`.

Every sleep schedules one durable deadline event (`workflow.task.wakeup`) at
`now + wake_after_ms`, bounded between one minute and 48 hours. Any ready
Signal on the task session wakes the task earlier: an owner
`workflow.task.message`, or a lifecycle event from a BackgroundAgentJob the
task created. The wake claim reuses the ordinary dispatch gates, so a full
Agent re-defers the wake. The wake turn continues the same AIGateway
conversation; the triggering event renders as its user message, and the turn
request context carries the durable task contract (`prompt`, `schema`, `label`)
so every wake can rebuild `submit_result`.

Each sleep resets the call attempt budget to zero and consumes one unit of the
hard wake budget of 16 sleeps per call. A crashed wake turn returns the call to
`queued`. Its open wake event owns redelivery, and the three-attempt budget
bounds repeated wake failures. The hourly watchdog treats a sleeping call
whose deadline passed more than an hour ago as overdue: with an open mailbox
event it re-notifies the session, and with none it fails the call as
`workflow_task_wake_lost` instead of sleeping forever.

### Delegating BackgroundAgentJobs

The task tool catalog includes `create_background_job`,
`show_background_job_details`, `send_message_to_background_job`, and
`stop_background_job`. A Job created by a task records the task session as its
`owner_session_id`, so the Job lifecycle wakeup reaches the task
mailbox and never notifies the main Agent's session. The task judges the Job
outcome and submits the schema-shaped result; a delegated Job that enters
`waiting_on_user` also wakes the task, which answers with its own context or
escalates.

When a run reaches a terminal status, cleanup stops every live Job whose owner
session is one of the run's task sessions, using the idempotent Job stop. Job
creation locks the owning run and task in the insert transaction, so a task
cannot add a Job after either row stops running.

### Attention

`sleep` with `attention: true` marks the call as waiting for owner input. The
same transaction appends one `workflow.run.attention` event to the owner
session with an hour-bucket idempotent source id, so any number of escalations
inside one hour collapse into one owner wakeup. The payload is a pointer: the
owner reads current waiting notes through `show_workflow` and answers each task
with `send_message_to_workflow_task`. The wake claim clears the attention flag.
A lost attention event self-heals: the task's deadline fires, and a renewed
attention sleep lands in a new bucket.

## Script Contract

The control plane puts the stored script in this fixed wrapper:

```js
"use strict";
const args = /* JSON.stringify(run.args), fixed at creation */;
const agent = (prompt, opts = {}) => {
  if (typeof prompt !== "string" || prompt.trim() === "") {
    throw new Error("agent(prompt, opts) needs a non-empty prompt string");
  }
  return tools.agent({ prompt, ...opts }).then((r) => (r && r.ok ? r.value : null));
};
const __wf_value = await (async () => {
/* <stored model script, immutable after creation> */
})();
if (__wf_value !== undefined) {
  text(typeof __wf_value === "string" ? __wf_value : JSON.stringify(__wf_value));
}
```

The script can call `agent(prompt, opts)`. `prompt` must be a non-empty string.
`opts` can contain `label`, `model_profile`, and `schema`. A schema must use the
supported OpenAPI 3 JSON Schema subset and must have one non-null top-level type:
`object`, `array`, `string`, `number`, `integer`, or `boolean`.

Each object schema, including a nested object, must explicitly contain
`properties`, `required`, and `additionalProperties: false`. `required` must
list every property exactly once and must not contain another name. Object
schemas do not support `minProperties` or `maxProperties`. Array, string,
number, and integer schemas keep their supported item, length, pattern, range,
and `multipleOf` bounds.

A successful call resolves to its submitted value. A failed call resolves to
`null` after its retry budget is exhausted. A valid success value can never be
`null`, so the script can use `null` as the task-failure signal. The owner event
and `show_workflow` contain the failure summaries.

Use `Promise.all` for parallel calls. Normal JavaScript conditions and loops
can create later stages without another main-Agent turn. Every loop must have a
fixed bound that is visible in the script.

The runner supplies no file, network, import, or timer API. `Math.random()` and
`Date.now()` use deterministic shims. The runner starts a new isolate for each
replay and does not keep an isolate alive while tasks run.

The script must return its final value. A string becomes result text directly.
Another JSON value becomes JSON text. A script that returns `undefined` has an
empty result.

## Which Process Does What

The Elixir control plane:

- authorizes create, read, list, cancel, and task-result requests
- stores each run and call in PostgreSQL
- limits task admission for one run and one Agent
- runs each task through a Session Driver on the control plane
- gives tasks Web and read-only Brain tools, Job delegation, sleep, and submit_result
- keeps the same AIGateway conversation and committed tool history on retries
- starts deterministic replay and commits each replay result
- runs each task at most three times
- sends the terminal event to the owner Session

The Rust kernel:

- runs the fixed JavaScript wrapper in a bare `deno_core` isolate
- records unresolved `agent` calls as a pending batch
- checks the memo sequence during replay
- enforces execution, output, pending-call, and memo limits
- cancels an in-flight isolate when the control plane cancels the run

Agent Computer runs Codex Jobs delegated by a task. A Workflow task itself
holds no Worker slot. The Driver applies the task's model, iteration, output,
and inactivity limits and up to three repair attempts when it neither submits
nor sleeps. The Workflow owner keeps the three-call-attempt limit. Recovery of
a crashed Driver adopts its running call without another call attempt.

PostgreSQL is the durable owner. RunServer performs replay; `PokeRun` is its
Oban wakeup. The conversation Reconciler also repairs a missing
RunServer or pending terminal cleanup when no task event exists yet.

After a replay commit, the caller delivers new task events to their Drivers.
Terminal cleanup delivers the owner event after the state commit. An attention
sleep returns its owner event to the tool's post-commit actions.
Future task wakeups use EnsureDriver. Reconciler repairs a missed delivery.

## Human Work Authorization

Each run stores `authorization_kind`, `human_uid`, and `human_access_version`
from the source Signal under [Human Offboarding](HumanOffboarding.md).
Task dispatch and delegated Jobs retain that fact. A replay, new task, wake,
or retry must pass the current Human check before admission.
Run creation does not admit a replay. RunServer checks the stored authorization
in its replay-input transaction before it calls the kernel. This check does not
wait for asynchronous Human work cleanup.

Revocation marks the run cancelled, cancels pending calls, and prevents new
dispatch. Already admitted calls can finish and retain their results. Cleanup
does not send an offboarding abort to an admitted Worker turn.

## What PostgreSQL Stores

`workflow_runs` stores the immutable script and arguments, the owner identity
and reply route, requested limits, exact cumulative memo byte count, model
profile, status, final result, and terminal error. A run ID is a PostgreSQL
identity bigint from 1,000 through the JavaScript maximum safe integer. A
terminal run also stores the time when its task and delegated-Job cleanup
finished. RuntimeFabric carries the run ID as a decimal string.

Creation is idempotent for the same Agent, owner Session, and source tool call.
A repeated request returns the stored run, including a terminal run, instead of
creating a second run.

`workflow_agent_calls` stores one row for each `agent()` call. The row contains
the run ID, zero-based call sequence, original arguments, label, model profile,
status, attempt count, sleep note, sleep deadline, wake count, attention flag,
result envelope, and error. The unique `(run_id, call_seq)` key prevents replay
from creating the same task twice. A Job delegated by a task needs no link
column: the Job's `owner_session_id` is the task session.

The task Session is `wf_task:<call_id>`. The dispatch Signal source ID
is `workflow:call:<call_id>:dispatch`. These identities make task dispatch
idempotent. One replay commit accepts the dispatch Signals of all its new calls
as one list (see [Signals](Signals.md)).

The control plane updates `memo_bytes` in the same transaction that stores new
call arguments or a terminal result envelope. It measures the exact Torque
encoding and rejects a write that would move the run above 6 MiB.

## Replay and Memo Semantics

The control plane orders calls by `call_seq` and builds the longest terminal
prefix. A succeeded call contributes `{ok: true, value}`. A failed call
contributes `{ok: false, code, summary}`. Queued and running calls stop the
prefix.

The kernel re-runs the program from the start with this memo. Each replayed
`agent()` call must match the stored name and arguments at the same position.
The kernel returns the stored envelope for a matched call. If a call does not
match the supplied memo, the kernel fails the replay with
`program_replay_diverged`. It returns the next unresolved batch as pending
calls when the memo matches.

The control plane compares the pending batch with existing non-terminal rows.
It reuses exact matches and inserts only the new suffix. A changed argument, a
missing stored call, or an altered order fails the run with
`workflow_replay_diverged`. A Workflow script cannot change after creation.

This prefix rule means that a later stage starts only after every call before
that stage is terminal. Calls in one pending batch can run in parallel.

## States and Recovery

A run has this state path:

```text
running -> completed | failed | cancelled
```

A call has these state paths:

```text
queued -> running -> succeeded | failed
running <-> sleeping
sleeping -> failed
queued | running | sleeping -> cancelled
running -> queued
queued -> failed
```

`running -> queued` and `queued -> failed` cover task retry and a
dispatch-time configuration failure. A failed wake attempt returns to `queued`.
The same open wake Signal owns redelivery, even when the original dispatch
Signal has completed. A terminal state cannot return to a live state.

`wake_kind` and `wake_at` store the wait contract. A sleeping call requires
`wake_kind = sleep` and a deadline. A queued call can have an `agent_capacity`
wait and its retry time, or no wait. Running and terminal calls have neither
field. PostgreSQL checks these combinations. Claim clears both fields and
sets `progress_at`; a new committed tool-result round advances `progress_at`.
The watchdog uses this timestamp, not unrelated metadata updates.

One temporary `RunServer` serializes replay for one run. PostgreSQL is the
source of truth. The conversation Reconciler asks the Workflow owner for runs
without a `RunServer` and terminal runs that need cleanup, then inserts the
`PokeRun` job. The pass reads every tenant and needs no transaction:
each idempotent job insert stands alone, and the next pass repeats a failed
one. This also covers a crash before the first task event.
A new replay reads the script and memo from PostgreSQL, so completed tasks do
not run again. Each native replay handle monitors its `RunServer` owner and
execution task. Exit of either process cancels the isolate without another
guardian process.

An unexpected replay-isolate cancellation failure emits a warning with the
failure class and stack locations. It omits exception messages and function
arguments and returns the best-effort cancellation result.

The replay supervisor runs at most four kernel replay isolates at one time. If
all four slots are in use, another running run stays durable and its `RunServer`
retries after 30 seconds. This limit controls replay isolates, not Workflow task
concurrency.

If a successful `sleep` or `submit_result` result has committed for the current
input, recovery reads its receipt or recorded tape and closes that input without
a new task claim or model request. It preserves the committed Workflow state,
even when the tenant is suspended. Without a committed ending result, recovery
uses the retry or adoption path.

If a task turn exits before it submits a result or sleeps, the control plane
returns the same call to `queued`. The
third failed attempt inside one wake segment makes the call `failed`. The same
triggering event stays open through these attempts, and a Workflow task event
follows the Job rule for dead-letter accounting: recoverable Worker errors keep
the event open because the call row owns the retry budget. The hourly watchdog
applies the same compensation when a running call has no newly committed
tool-result round for one hour. Run locks the current Workflow call in the
slot, run, and call order before it records the round. The new round
and the call's progress timestamp commit in the same transaction. An existing
journal, a rolled-back round, an earlier attempt, or a cancelled or terminal
call does not renew that timestamp. A single model or tool round with no
committed progress remains subject to the watchdog. The watchdog also recovers
overdue sleeping calls as described under Task Sleep and Wake.

A dead-lettered `workflow.run.completed` or `workflow.run.failed` wakeup keeps
the Job-wakeup guarantee: the notice renders the run counts and result preview
from the durable payload, so the outcome reaches the user without the Agent
runtime that failed to relay it.

After a running call sleeps, succeeds, or reaches a terminal failure, the
post-commit work runs `Mail.release_capacity/1` in its own top-level
transaction. `Recovery.reconcile_stale_tasks/3` registers this
work with `Repo.transact_top_level/2` through `after_commit`, then runs terminal
cleanup. A failed capacity wake is logged and does not prevent that cleanup;
the deferred task keeps its retry time. A Sessions transaction that composes a
task transition calls `Ankole.Workflow.cleanup_terminal_transition/1` after its
commit. It advances the oldest queued call across the Agent's running workflows
that waits for capacity. A workflow at its own concurrency limit is not
eligible. The wake transaction locks the Agent slot scope, run, call, Session,
and Signal in that order. A task that failed before admission did not release a
slot. Deferrals for a Worker shortage, delivery failure, or an active retry keep
their own retry time.

A completed or failed run changes every remaining queued or running call to
`cancelled` in the same transaction as the run terminal state. This releases
every task-capacity slot before external cleanup. After the transaction commits,
the control plane appends idempotent `command.stop` events for cancelled task
sessions in one transaction and stops live Jobs owned by any task session in
the run. The run
records one cleanup completion time only after all stop operations succeed.
The replay and watchdog owner functions return the run with this time, or with
cleanup errors that require another attempt. `RunServer` uses this result to
stop or retry. Startup recovery includes terminal runs without that time and
repeats the idempotent cleanup before it marks them complete.

Cancellation uses the same durable call cleanup. After the transaction commits,
cleanup tells the active `RunServer` to stop. On normal exit, that owner
cancels any running kernel replay and stops its replay task. Cleanup does not
start a replacement `RunServer`; a later wake reads the terminal state before
native replay. A late replay or task result cannot revive the cancelled run.

The control-plane deployment model uses one control-plane node. A
duplicate driver is safe: PostgreSQL state guards, unique call and event
keys, and the kernel run-ID fence prevent duplicate durable effects.

## Cost Boundaries

| Boundary | Default | Hard limit |
| --- | ---: | ---: |
| Concurrent tasks requested by one run | 8 | 32 |
| Running Workflow tasks for one Agent | 8 | 64 |
| Agent calls in one run | 32 | 1,024 |
| Sleeps for one call | n/a | 16 |
| One sleep duration | n/a | 1 minute through 48 hours |
| One owner task message | n/a | 8 KiB |
| Stored script | n/a | 256 KiB |
| Stored `args` JSON | n/a | 64 KiB |
| One call argument object | n/a | 8 KiB |
| One successful result value | n/a | 24 KiB |
| Durable memo budget | n/a | 6 MiB |
| Kernel memo input | n/a | 8 MiB |
| Kernel pending calls | 64 | 1,024 |
| Kernel pending-call bytes | 1 MiB | 8 MiB |
| Final result text | n/a | 1 MiB |

The AppConfigure keys `workflow.max_concurrency_per_run`,
`workflow.max_running_per_agent`, and `workflow.max_agent_calls_per_run` set the
deployment limits. A run request cannot raise these limits.

The 6 MiB durable memo budget reserves space below the kernel's 8 MiB input
limit. If a run reaches the budget, it fails with a message that tells the main
Agent to reduce fanout, return summaries, or split the work into more runs.

Workflow has no batch-wide token budget. Each task uses the ordinary
turn limits from its request context.

## Console activity inspection

The Home background activity area reads Workflow facts for one Agent in the
current tenant. Its separate read permission is `agent:<agent_uid>:workflow`.
Live calls are queried independently of the parent run state, so a running call
admitted before Human access was revoked remains visible under its cancelled
parent. The projection also includes running runs with no live calls and terminal
runs whose `cleanup_completed_at` is still unset. Calls and runs have independent
cursors; native status counts, sleep notes, deadlines, attention and bounded error
summaries explain persisted facts without inferring that an old update is stuck.
The call projection includes `wake_kind` and `wake_at`. The Console shows a sleep
deadline only for `wake_kind: "sleep"`. Capacity retries retain queued status.

This endpoint reads no scripts, full results or memo bodies and performs no
cancellation, wakeup or cleanup. A delegated Background Job retains its Workflow
task Session as `owner_session_id`; these related rows are not added into a
single busy count. See [Background Agent Job](BackgroundAgentJob.md) and
[Automation Jobs](AutomationJobs.md) for the other independently authorized groups.

## Module Owners

`Ankole.Workflow` declares the resources and cross-domain interfaces, including
reads, `cleanup_terminal_transition/1`, `create_with_dispatch`,
`send_task_message`, and `defer_task_event`. A Sessions or Background Agent Job
transaction composes the `_in_tx` functions of `TaskLifecycle`, `Lifecycle`,
and `Slot` directly, then performs cleanup after its own commit.

`RunServer` calls `Replay.commit_replay_pending/3`, `Replay.complete_replay/3`,
`Replay.fail_replay/4`, and `Recovery.reconcile_stale_tasks/3` directly. These
private domain operations use `Repo.transact_top_level/2` and reject a caller
transaction before they write. Each operation owns the cleanup that follows
its commit. The watchdog also releases committed capacity before cleanup.

`Queries` reads projections; `Lifecycle` creates and ends runs;
`TaskLifecycle` owns task transitions; `Replay` commits the durable memo;
`Mail` appends events and releases capacity; `Slot` owns the slot, run, and
call lock order; `Recovery` restores lost wakeups. `RunServer` coordinates
replay and keeps its waiting-period watchdog.
Reads and row locks use Ash queries. `Queries.capacity_candidate/2` is a
registered read model: it selects the next capacity waiter across calls, runs,
and Signals and gives only identifiers. The resource actions own legal
transitions through `AshStateMachine`; each action uses the caller's tenant
and transaction. `TaskLifecycle` uses one
compensation function when a stopped run has a running call. It cancels
the call and notifies its Session in the same transaction. A retry that queues a
running call releases its slot and wakes capacity waiters after commit, just as
a terminal result does.
