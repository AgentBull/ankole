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

Every Workflow participant follows the shared async-work actor contract in
[SignalsGateway](SignalsGateway.md#async-work-units): the session id is the
address, the owner session is the parent, mail wakes a hibernating actor, and
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
`sleeping_until`, and `wake_count`, with attention rows first. A sleeping task
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
Agent Computer sends this tool with provider strict mode. The control plane
validates the value again. A rejected value does not end the task turn, so the
subagent can correct it and submit it again.

## Task Sleep and Wake

A task turn can end in exactly three ways: `submit_result`, `sleep`, or
failure. The private `sleep` tool parks the call as durable `sleeping` state
and ends the turn. A sleeping task holds no Worker slot and does not count
against run or Agent concurrency. Its required `note` (at most 200 characters)
tells the owner what it waits for through `show_workflow`.

Every sleep schedules one durable deadline event (`workflow.task.wakeup`) at
`now + wake_after_ms`, bounded between one minute and 48 hours. Any ready
ActorEvent on the task session wakes the task earlier: an owner
`workflow.task.message`, or a lifecycle event from a BackgroundAgentJob the
task created. The wake claim reuses the ordinary dispatch gates, so a full
Agent re-defers the wake. The wake turn continues the same AIGateway
conversation; the triggering event renders as its user message, and the turn
request context carries the durable task contract (`prompt`, `schema`, `label`)
so every wake can rebuild `submit_result`.

Each sleep resets the call attempt budget to zero and consumes one unit of the
hard wake budget of 16 sleeps per call. A crashed wake turn returns the call to
`sleeping` — its open wake event owns redelivery — and the three-attempt budget
still bounds repeated wake failures. The hourly watchdog treats a sleeping call
whose deadline passed more than an hour ago as overdue: with an open mailbox
event it re-notifies the session, and with none it fails the call as
`workflow_task_wake_lost` instead of sleeping forever.

### Delegating BackgroundAgentJobs

The task tool catalog includes `create_background_job`,
`show_background_job_details`, `send_message_to_background_job`, and
`stop_background_job`. A Job created by a task records the task session as its
`owner_session_id`, so the existing Job lifecycle wakeup reaches the task
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
- dispatches each task as an Actor turn with its own conversation
- starts deterministic replay and commits each replay result
- runs each task at most three times
- sends the terminal event to the owner Session

The Rust kernel:

- runs the fixed JavaScript wrapper in a bare `deno_core` isolate
- records unresolved `agent` calls as a pending batch
- checks the memo sequence during replay
- enforces execution, output, pending-call, and memo limits
- cancels an in-flight isolate when the control plane cancels the run

Agent Computer:

- runs each `wf_task:<call_id>` turn in an independent conversation and
  continues that conversation on every wake turn
- gives the task Web tools, optional read-only Brain tools, the four
  BackgroundAgentJob delegation tools, `sleep`, and `submit_result`
- applies the turn model, iteration, output-token, and inactivity limits
- makes one repair attempt when the model neither submits a result nor sleeps

PostgreSQL is the durable owner. RuntimeFabric only transports live turn and
RPC traffic.

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

The task Actor session is `wf_task:<call_id>`. The dispatch ActorEvent source ID
is `workflow:call:<call_id>:dispatch`. These identities make task dispatch
idempotent.

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
dispatch-time configuration failure. A call that has ever slept retries back to
`sleeping` instead of `queued`, because its open wake event owns redelivery
while the completed dispatch event cannot re-dispatch a queued row. A terminal
state cannot return to a live state.

One temporary `RunServer` serializes replay for one run. PostgreSQL remains the
source of truth. RuntimeEvents rebuilds drivers for all `running` rows after a
control-plane restart. A new replay reads the script and memo from PostgreSQL,
so completed tasks do not run again.

The replay supervisor runs at most four kernel replay isolates at one time. If
all four slots are in use, another running run stays durable and its `RunServer`
retries after 30 seconds. This limit controls replay isolates, not Workflow task
concurrency.

If a task turn exits before it submits a result or sleeps, the control plane
returns the same call to `queued`, or to `sleeping` after its first sleep. The
third failed attempt inside one wake segment makes the call `failed`. The same
triggering event stays open through these attempts, and a Workflow task event
follows the Job rule for dead-letter accounting: recoverable Worker errors keep
the event open because the call row owns the retry budget. A one-hour watchdog
applies the same compensation to a stale running call and recovers overdue
sleeping calls as described under Task Sleep and Wake.

A dead-lettered `workflow.run.completed` or `workflow.run.failed` wakeup keeps
the Job-wakeup guarantee: the notice renders the run counts and result preview
from the durable payload, so the outcome reaches the user without the Agent
runtime that failed to relay it.

When a running call succeeds or reaches a terminal failure, the same
transaction advances the earliest call in that run that was deferred for Agent
capacity. It wakes one task because one task released one slot. Deferrals for a
Worker shortage, delivery failure, or an active retry keep their own retry
time.

A completed or failed run changes every remaining queued or running call to
`cancelled` in the same transaction as the run terminal state. This releases
every task-capacity slot before external cleanup. After the transaction commits,
the control plane appends idempotent `command.stop` events for cancelled task
sessions and stops live Jobs owned by any task session in the run. The run
records one cleanup completion time only after all stop operations succeed.
Startup recovery includes terminal runs without that time and repeats the
idempotent cleanup before it marks them complete.

Cancellation uses the same durable call cleanup. The control plane also cancels
the kernel run after the transaction commits. A late task result observes the
cancelled call and cannot revive the run.

The current control-plane deployment model uses one control-plane node. A
duplicate driver is still safe: PostgreSQL state guards, unique call and event
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

Workflow v1 has no batch-wide token budget. Each task still uses the ordinary
turn limits from its request context.
