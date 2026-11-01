# Workflow

A Workflow runs one fixed JavaScript program that orchestrates bounded subagent
tasks. The main Agent starts the run once; the control plane persists the
program, every task call, and every result in PostgreSQL; and when the run
completes or fails, the main Agent receives a single lifecycle event.

Workflows and `BackgroundAgentJob`s solve complementary problems: a Workflow
handles bounded fanout and multi-stage control flow, whereas a
`BackgroundAgentJob` runs one long-lived Codex session that can accept follow-up
messages. Because a Workflow task cannot spawn a nested Workflow, orchestration
has a fixed depth of one. However, a Workflow task can delegate
`BackgroundAgentJob`s and hibernate until they finish, allowing a single
`agent()` call to supervise hours of background work behind one schema-validated
result.

Every Workflow participant follows the shared asynchronous Session contract in
[Sessions](Sessions.md#execute-tools-and-asynchronous-work): its Session ID is
its address, `owner_session_id` names its parent, incoming mail wakes a
hibernating unit, and lifecycle Signals travel one level up to that parent.

## What the Main Agent Can Do

Each model-facing tool performs a single Workflow operation rather than
multiplexing subcommands through an `action` parameter.

`workflow` starts a new run from these arguments:

- `title`: required display text (at most 200 characters)
- `script`: required JavaScript source for the program body
- `args`: optional JSON object exposed to the script as `args`
- `concurrency`: optional per-run concurrent task limit (`1` through `32`)
- `max_agent_calls`: optional total task limit for the run (`1` through `1,024`)
- `model_profile`: optional custom model profile inherited from the current turn

Deployment-wide Workflow settings cap `concurrency` and `max_agent_calls` if the
caller requests higher numbers. `workflow` returns the decimal `run_id` and the
initial `running` status; the main Agent must not poll the run, because the
control plane delivers a completion or failure Signal to the owner Session
automatically.

`show_workflow` inspects one run owned by the current Agent:

- When `result_offset` is omitted, it returns the current run status, task
  counts, up to 32 live tasks (ordered with `attention` rows first, each showing
  `call_seq`, `label`, `status`, sleep `note`, `attention`, `wake_at`, and
  `wake_count`), and up to 10 task failure summaries. A `sleeping` task is still
  in progress—not finished—hibernating until an event wakes it.
- For a completed run, passing a UTF-8 byte offset in `result_offset` reads one
  bounded result slice (up to 8,000 bytes) alongside the total byte length while
  omitting task summaries; pass the returned next offset to read subsequent
  slices directly from PostgreSQL.

`send_message_to_workflow_task` asynchronously and idempotently appends one
owner message to a live task identified by `run_id` and `call_seq`, without
blocking for a task reply: a sleeping task wakes to process the message, a
running task receives it when its active Turn finishes, a queued task reads it
upon dispatch, and a terminal task rejects it.

`list_workflows` returns up to 32 runs owned by the current Agent, optionally
filtered by status (`live` for `running`; `done` for `completed`, `failed`, and
`cancelled`) and paginated with the turn-local `page` cursor from the previous
call.

`cancel_workflow` idempotently cancels a run by `run_id`: it blocks new task
dispatch, signals active task turns to stop, prevents recovery from resuming the
run, and suppresses the normal completion event.

Inside each subagent task, the tool catalog includes a private `submit_result`
tool—never exposed to the main Agent—declared with provider strict mode. When
the subagent calls `submit_result`, the control plane validates the payload
against the task's JSON Schema before committing; if validation fails, the task
turn remains open so the subagent can fix the payload and submit again.

## Task Sleep and Wake

Every task turn ends in one of three outcomes: `submit_result`, `sleep`, or
failure. Calling the private `sleep` tool parks the call in the durable
`sleeping` state and ends the current turn. While sleeping, a task holds no
Worker slot and consumes neither per-run nor per-Agent concurrency; its required
`note` (at most 200 characters) explains through `show_workflow` what the task
is waiting on.

Each `sleep` schedules a durable deadline Signal (`workflow.task.wakeup`) at
`now + wake_after_ms`, clamped between 1 minute and 48 hours. Any earlier ready
Signal on the task Session wakes the task ahead of that deadline—such as an
owner `workflow.task.message` or a lifecycle event from a `BackgroundAgentJob`
that the task created. Claiming a wake passes through the standard dispatch
gates, so if the Agent is at capacity, Ankole defers the wake again. Once
admitted, the wake turn resumes the existing AIGateway conversation with the
triggering event rendered as the user message and rebuilds `submit_result` from
the persisted task contract (`prompt`, `schema`, and `label`).

Each sleep resets the call's per-wake attempt counter to zero while consuming
one unit from the hard cap of 16 sleeps per call. If a wake turn crashes before
submitting or sleeping, Ankole returns the call to `queued`, where the still-open
wake Signal drives redelivery within the three-attempt budget. An hourly
watchdog also scans for sleeping calls whose `wake_at` deadline passed more than
an hour ago: if the Session still has an open mailbox Signal, the watchdog
re-notifies the Session; if no open Signal exists, it fails the call with
`workflow_task_wake_lost` rather than letting it sleep indefinitely.

### Delegating BackgroundAgentJobs

Each Workflow task receives `create_background_job`,
`show_background_job_details`, `send_message_to_background_job`, and
`stop_background_job`. When a task creates a Job, Ankole sets the Job's
`owner_session_id` to the task Session so Job lifecycle wakeups—including
`waiting_on_user` clarifications—route to the task's mailbox rather than waking
the main Agent. Upon waking, the task evaluates the Job output (answering a
clarification from its own context or escalating to the owner) and eventually
calls `submit_result`.

Task dispatches, owner messages, and deadline wakeups propagate the parent run's
native Conversation ID or external Binding as the delivery context for delegated
Jobs, while the task itself runs in its own `wf_task:<call_id>` Session and
AIGateway conversation. Because that task Session is not the parent
Conversation's Session, a native task cannot post direct chat replies to the
parent Conversation; instead, Job events wake the task, the task submits its
typed result to the Workflow, and the finished Workflow wakes the main Agent.

Creating a delegated Job locks both the parent run and the calling task inside
the insert transaction, preventing a task from spawning a Job after either parent
row has stopped running. When a Workflow run reaches any terminal status,
post-commit cleanup idempotently stops every live Job whose `owner_session_id`
belongs to one of that run's task Sessions.

### Attention

Calling `sleep` with `attention: true` flags the task as waiting for owner
guidance and, in the same transaction, enqueues a `workflow.run.attention`
Signal on the owner Session using an idempotent source ID bucketed by hour—so
multiple task escalations within the same hour coalesce into a single owner
wakeup. Because the attention event acts as a lightweight pointer, the main
Agent inspects waiting notes via `show_workflow` and replies to individual tasks
with `send_message_to_workflow_task`. Admitting the resulting wake clears the
task's `attention` flag, and if an attention wakeup is ever missed, the task's
sleep deadline eventually fires so a subsequent `attention: true` sleep lands in
a fresh hour bucket.

## Script Contract

The control plane wraps the stored JavaScript source in this fixed harness:

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

Scripts invoke subagents through `agent(prompt, opts)`, where `prompt` is a
non-empty string and `opts` may specify `label`, `model_profile`, and `schema`.
Task schemas use the supported OpenAPI 3 JSON Schema subset with a single
non-null top-level type (`object`, `array`, `string`, `number`, `integer`, or
`boolean`):

- Every `object` schema—at the root or nested—must explicitly declare
  `properties`, `required` (listing every declared property key once and no
  extra keys), and `additionalProperties: false`, without `minProperties` or
  `maxProperties`.
- `array`, `string`, `number`, and `integer` schemas retain their supported
  item, length, regex pattern, numeric range, and `multipleOf` constraints.

When a task succeeds, `agent(...)` resolves to its validated result; when a task
exhausts its retries and fails, `agent(...)` resolves to `null` (since a valid
schema result is never `null`, scripts can branch cleanly on `null` for task
failures while full failure summaries appear in the owner completion event and
`show_workflow`).

Scripts use `Promise.all` for concurrent fanout and ordinary JavaScript
conditionals and loops—each written with an explicit, statically visible upper
bound—to drive multi-stage pipelines without round-tripping through the main
Agent. The function isolate exposes no filesystem, network, module-import, or
real-clock timer APIs, replaces `Math.random()` and `Date.now()` with
deterministic shims, and spins up a fresh short-lived isolate per replay step
rather than holding an isolate open while tasks execute.

Returning a string from the script stores it directly as the result text,
returning any other JSON value serializes it with `JSON.stringify`, and
returning `undefined` produces an empty result.

## Which Process Does What

The Elixir control plane:

- authorizes run creation, inspection, listing, cancellation, and task-result
  submissions
- persists runs and task calls in PostgreSQL
- enforces per-run and per-Agent task concurrency caps
- executes each task through a control-plane Session Driver equipped with Web
  tools, read-only Brain tools, BackgroundAgentJob delegation tools, `sleep`,
  and `submit_result`
- preserves the task's AIGateway conversation and committed tool receipts across
  retries (up to three call attempts per wake segment)
- drives deterministic script replay, commits memo updates, and delivers the
  terminal run Signal to the owner Session

The function runtime:

- executes the wrapped JavaScript in a sandboxed, one-shot User Worker
- collects unresolved `agent()` invocations as the next pending batch
- verifies memo call order and arguments on every replay
- enforces CPU/wall-clock, output, pending-call, and memo-size caps
- aborts an in-flight isolate when the control plane cancels the run

Agent Computer executes only `BackgroundAgentJob`s delegated by tasks—a Workflow
task itself never occupies an Agent Computer Worker slot. Within a task turn,
the Session Driver enforces model, iteration, output, and inactivity limits and
allows up to three in-turn repair prompts if the model stops without calling
`submit_result` or `sleep`, while the Workflow call row tracks the outer
three-attempt cap (if a Driver crashes mid-turn, recovery adopts the running
call without burning an extra call attempt).

PostgreSQL owns durable Workflow state, a transient `RunServer` coordinates
replays for an active run, `PokeRun` provides its durable Oban wakeup, and the
conversation Reconciler repairs any run missing its `RunServer` or awaiting
terminal cleanup—even if a node crashed before dispatching the first task event.
After committing a replay step, the caller wakes the newly created task Drivers;
after terminal cleanup commits, it wakes the owner Session; and `attention`
sleeps emit their owner Signal in the tool's post-commit hook, with
`EnsureDriver` and the Reconciler healing any missed PubSub wakeups.

## Human Work Authorization

Under [Human Offboarding](HumanOffboarding.md), every Workflow run freezes
`authorization_kind`, `human_uid`, and `human_access_version` from the
triggering Signal and propagates that snapshot to task dispatches and delegated
Jobs. Run creation itself does not run a replay; instead, `RunServer` re-checks
current Human access inside its replay-input transaction before invoking the
function runtime—without waiting for asynchronous offboarding sweeps—and every
new task dispatch, wake, or retry re-checks Human access at admission.

Workflow tasks and delegated Jobs authorize Drive and Pod resources as the
executing Agent's Principal. The retained Human authorization controls whether
work may be admitted; it does not intersect the Agent's resource grants. Private
file paths resolve in that Agent's private root. References to received files
use the source Message's frozen attachment object, and moving or replacing the
source node does not alter those bytes.

If Human access is revoked, Ankole marks the run `cancelled`, cancels unstarted
calls, and blocks further dispatch, while allowing already admitted task turns
and Worker turns to finish and record their results without sending an
offboarding abort.

## What PostgreSQL Stores

`workflow_runs` stores the immutable script and `args`, owner identity and reply
route, requested concurrency/call caps, exact cumulative `memo_bytes`, model
profile, run status, final result text, terminal error, and
`cleanup_completed_at`. Run IDs are PostgreSQL `bigint` identity values starting
at `1,000` up to `Number.MAX_SAFE_INTEGER` (carried over `RuntimeFabric` as
decimal strings). Run creation is idempotent per `(agent, owner_session, source_tool_call)`,
returning the existing row—even if already terminal—on duplicate requests.

`workflow_agent_calls` stores one row per `agent()` call keyed uniquely by
`(run_id, call_seq)` so replay never duplicates a task. Each row records the
zero-based `call_seq`, original call arguments, `label`, `model_profile`,
`status`, `attempt_count`, sleep `note`, sleep deadline, `wake_count`,
`attention` flag, terminal result envelope, and error; delegated
`BackgroundAgentJob`s link back via `owner_session_id = "wf_task:<call_id>"`
without needing a separate foreign-key column.

Task dispatch is likewise idempotent: each call uses Session `wf_task:<call_id>`
and Signal source ID `workflow:call:<call_id>:dispatch`, and a replay commit
enqueues all new dispatch Signals in a single batch call (see
[Signals](Signals.md)). Whenever Ankole inserts new call arguments or writes a
terminal call envelope, the same transaction measures exact Torque-encoded byte
growth, updates `memo_bytes`, and rejects any write that would push the run past
its 6 MiB durable memo cap.

## Replay and Memo Semantics

Before calling the function runtime, the control plane sorts the run's calls by
`call_seq` and assembles the longest contiguous prefix of terminal calls—mapping
succeeded calls to `{ok: true, value}` and failed calls to
`{ok: false, code, summary}`—stopping at the first `queued`, `running`, or
`sleeping` row.

The function runtime re-executes the immutable script from the top against that
memo prefix:

- For each replayed `agent()` call within the prefix, the runtime verifies that
  the call name and arguments match the recorded entry at that exact index,
  returning the stored envelope on match or failing with
  `program_replay_diverged` on mismatch.
- Once execution advances past the memo prefix, the runtime captures the next
  batch of unresolved `agent()` promises and returns them as pending calls.

Back on the control plane, `Replay` compares the returned pending batch against
any non-terminal rows already persisted: exact matches are reused, new trailing
calls are appended, and any mutated argument, missing stored call, or reordered
sequence fails the run with `workflow_replay_diverged`. Because the prefix stops
at the first non-terminal call, later pipeline stages wait until all earlier
calls settle, while calls issued together in one `Promise.all` batch run
concurrently.

## States and Recovery

Workflow runs follow a one-way lifecycle:

```text
running -> completed | failed | cancelled
```

Individual `agent()` calls transition along these paths (never leaving a
terminal state once settled):

```text
queued -> running -> succeeded | failed
running <-> sleeping
sleeping -> failed
queued | running | sleeping -> cancelled
running -> queued
queued -> failed
```

Here, `running -> queued` and `queued -> failed` handle task retries (including
failed wake turns, where the open wake Signal retains redelivery ownership after
the initial dispatch Signal has completed) and dispatch-time configuration
errors.

PostgreSQL constraints enforce valid `(status, wake_kind, wake_at)` triples:
`sleeping` calls require `wake_kind = sleep` and a `wake_at` timestamp; `queued`
calls either carry `wake_kind = agent_capacity` with a retry timestamp or leave
both null; and `running` or terminal calls clear both columns. Claiming a call
clears the wait columns and sets `progress_at`, and each newly committed
tool-result round advances `progress_at` in the same transaction under the
`(slot, run, call)` lock order—replaying an existing journal, rolling back a
round, finishing a stale attempt, or touching unrelated metadata never refreshes
`progress_at`.

At most one temporary `RunServer` runs per active Workflow to serialize replays
against PostgreSQL truth:

- Across all tenants, the conversation Reconciler scans without an outer
  transaction for active runs lacking a `RunServer` and terminal runs lacking
  `cleanup_completed_at`, inserting standalone idempotent `PokeRun` jobs (with
  the next pass retrying any failed insert).
- Each in-flight function-runtime request monitors both its `RunServer` and its
  caller task, cancelling the HTTP call if either exits (if HTTP cancellation
  raises unexpectedly, Ankole logs a scrubbed warning with only the exception
  class and stacktrace—omitting messages and arguments—and returns a best-effort
  result).
- A site-wide replay supervisor caps concurrent function-runtime replay HTTP
  requests at four—distinct from Workflow task concurrency—so if all four replay
  slots are busy, additional `RunServer`s stay durable and retry after 30
  seconds.

Task recovery preserves committed progress:

- If a `sleep` or `submit_result` receipt has already committed for the active
  input, recovery reads the receipt or recorded tape and finalizes the input
  without re-claiming the task or calling a model—even if the tenant is
  suspended.
- Otherwise, if a task turn exits without submitting or sleeping—or if the
  hourly watchdog finds a `running` call with no `progress_at` advance for an
  hour—Ankole returns the call to `queued`, failing the call on the third failed
  attempt within the current wake segment. Like `BackgroundAgentJob`s,
  recoverable Worker errors keep the triggering task Signal open because the
  `workflow_agent_calls` row owns retry accounting.
- If a terminal `workflow.run.completed` or `workflow.run.failed` Signal
  exhausts owner-Session retries and enters `dead_letter`, Ankole posts a
  fallback notice rendered directly from the durable Signal payload (task counts
  and result preview), matching the `BackgroundAgentJob` wakeup guarantee so the
  user sees the outcome even when the main Agent fails to relay it.

Whenever a running call transitions to `sleeping`, `succeeded`, `failed`, or
back to `queued` for retry, post-commit cleanup releases its concurrency slot by
running `Mail.release_capacity/1` in a top-level transaction:

- `Recovery.reconcile_stale_tasks/3` wires that capacity release into
  `after_commit` on `Repo.transact_top_level/2` before running terminal cleanup
  (logging any capacity-wake error without blocking cleanup, since deferred
  waiters retain their retry timestamp), and Sessions transactions that fold in
  a task transition call `Ankole.Workflow.cleanup_terminal_transition/1` after
  commit.
- Capacity release wakes the oldest `agent_capacity`-waiting call across the
  Agent's running Workflows that has not hit its per-run `concurrency` cap,
  locking `(slot_scope, run, call, session, signal)` in order. Tasks that failed
  before admission hold no slot to release, and calls deferred for Worker
  shortage, delivery errors, or retry backoff keep their scheduled retry time.

When a run enters `completed`, `failed`, or `cancelled`, the terminal
transaction immediately marks all remaining `queued`, `running`, and `sleeping`
calls `cancelled`, freeing capacity slots up front. Post-commit cleanup then
batch-appends idempotent `command.stop` Signals to cancelled task Sessions,
stops any live delegated `BackgroundAgentJob`s, and stamps
`cleanup_completed_at` once every stop succeeds (returning cleanup errors to
`RunServer` for retry, with startup recovery re-running cleanup for any terminal
run still missing `cleanup_completed_at`). On explicit `cancel_workflow`,
post-commit cleanup asks any running `RunServer` to stop—aborting any active
replay request—without spawning a replacement `RunServer`, and PostgreSQL state
guards ensure late replay responses or task results can never revive a cancelled
run, even across a multi-node [RuntimeFabric](RuntimeFabric.md) cluster.

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
| Program memo input | n/a | 8 MiB |
| Program pending calls | 64 | 1,024 |
| Program pending-call bytes | 1 MiB | 8 MiB |
| Final result text | n/a | 1 MiB |

Operators tune deployment defaults via the AppConfigure keys
`workflow.max_concurrency_per_run`, `workflow.max_running_per_agent`, and
`workflow.max_agent_calls_per_run`; individual `workflow` tool calls can lower
these bounds for a run, never raise them.

Keeping the durable memo cap at 6 MiB leaves headroom beneath the function
runtime's 8 MiB request limit. If a run exceeds 6 MiB, it fails with an
actionable error instructing the main Agent to reduce fanout, return compact
summaries from tasks, or split the pipeline across multiple runs. Workflows do
not impose a shared cross-task token budget; instead, each task turn enforces
the standard per-turn token limits from its Session request context.

## Console activity inspection

In the Console, the Home background-activity panel queries Workflow state for a
single Agent in the active tenant, gated independently by
`site_console:agent:<agent_uid>:workflow`:

- Live calls are queried independently of parent run status so a `running` call
  admitted before Human access revocation remains visible even after its parent
  run turns `cancelled`.
- Run rows include `running` runs that currently have zero live calls as well as
  terminal runs whose `cleanup_completed_at` is still null.
- Calls and runs paginate with separate cursors and project `wake_kind`,
  `wake_at`, persisted status counts, sleep notes, `attention` flags, and
  bounded error summaries directly—rendering a sleep countdown only when
  `wake_kind` is `"sleep"`, keeping capacity waiters labeled `queued`, and never
  guessing from timestamp age whether a task is stuck.

This read-only projection omits script source, full result bodies, and raw memo
payloads, triggers no cancellations, wakeups, or cleanups, and keeps delegated
`BackgroundAgentJob` counts (linked via `owner_session_id`) separate rather than
summing them into a combined busy counter; see
[Background Agent Job](BackgroundAgentJob.md) and
[Automation Jobs](AutomationJobs.md) for the sibling activity sections.

## Module Owners

`Ankole.Workflow` is the root Ash domain declaring resources and cross-domain
entry points—including read actions, `cleanup_terminal_transition/1`,
`create_with_dispatch`, `send_task_message`, and `defer_task_event`—while
`Sessions` and `BackgroundAgentJobs` transactions compose `*_in_tx` helpers from
`TaskLifecycle`, `Lifecycle`, and `Slot` directly and run post-commit cleanup
after their outer transaction commits.

Inside the domain, responsibilities split cleanly across submodules:

- `RunServer` coordinates replays and waiting-period watchdogs, calling
  `Replay.commit_replay_pending/3`, `Replay.complete_replay/3`,
  `Replay.fail_replay/4`, and `Recovery.reconcile_stale_tasks/3`—private
  top-level operations that open `Repo.transact_top_level/2`, reject open caller
  transactions, and own their post-commit cleanup (with watchdog sweeps also
  releasing capacity slots before cleanup).
- `Queries` serves read projections—including the registered read model
  `Queries.capacity_candidate/2`, which selects only the IDs of the next
  capacity waiter across calls, runs, and Signals.
- `Lifecycle` creates and terminates runs; `TaskLifecycle` drives task state
  transitions (including a single compensation helper that cancels an active
  call and notifies its Session in one transaction when its parent run stops,
  and releasing capacity slots when a running call retries back to `queued`);
  `Replay` persists memo prefixes; `Mail` enqueues Signals and wakes capacity
  waiters; `Slot` enforces the `(slot, run, call)` lock order; and `Recovery`
  repairs lost wakeups.
- Resource actions enforce valid transitions through `AshStateMachine` inside
  the caller's tenant and transaction.
