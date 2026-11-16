# Schedule

The Schedule subsystem emits events at requested times. Signals routes each
event to the subscribed Agent Sessions and Automation Jobs. PostgreSQL is the
durable authority for what must run and when, while Oban acts strictly as the
timer that wakes the control plane when a deadline arrives.

Users and Agents can create three scheduled primitives:

- **`check_back_later`**: Wakes the originating Agent Session once.
- **`AgentRoutine` (`agent_routines`)**: Owns a standing Agent duty (`routine:<routine_id>`) that can wake from a recurring Cron schedule, external Connector/event `Binding`s, or both, sharing one transcript, Workspace, standing `task`, and `delivery` contract.
- **`cron`**: Triggers recurring work. A Job-owned or Action-targeted rule routes to its Applet Action without an Agent Session; an Agent-targeted rule belongs to its owning `AgentRoutine` (`owner_routine_id`) and executes in `routine:<routine_id>`.

Checkbacks and manual cron triggers persist a `scheduled_events` row *before*
wake-up, whereas automatic cron triggers insert a `scheduled_events` history row
at fire time. `AgentRoutine`, `CronSchedule`, and `ScheduledEvent` model their lifecycles
with `AshStateMachine`: pausing, deleting, or completing a cron rule clears
`next_fire_at` in the same statement, a PostgreSQL `CHECK` constraint forbids a
non-null `next_fire_at` on any Cron status other than `active`, and updates,
fires, and Human access revocations all acquire locks in the same canonical
order.

`Ankole.Schedule` is the root Ash domain:

- Every public write entry point opens `Repo.transact_top_level/2`—covering
  checkback `create`, `update`, and `cancel`; routine and cron `create`, `update`, `pause`,
  `resume`, `remove`, and `run`; plus `fire_due_event` and `fire_cron`—while
  Console `/api/v2` routes expose generic actions on `ScheduledEvent` and
  `CronSchedule` and Pod `/api/v2/pod/jobs` exposes routine creation, updates, and lifecycle controls. If a fire fails, Ankole rolls back the attempt transaction and
  records the failure diagnostic in a second top-level transaction.
- Callers already inside an open transaction—such as the Sessions schedule tools
  committing inside their tool-receipt transaction—compose `*_in_tx` helpers on
  `Schedule.Checkbacks`, `Schedule.Routines`, and `Schedule.Cron`. Reads and row locks use Ash
  queries.
- `ScheduledEvent` actions type-check durable attributes directly: structured
  provenance, wake payloads, and error diagnostics use the shared strict JSON
  object type, and the TimeZone owner validates modified timezone strings.
  Failure and cancellation actions validate only their own diagnostic fields so
  they can still record compensation even when a row's execution target is
  broken.

## The Control Plane Owns Time

Dispatch preparation and commit use the same fire instant. Under the domain
locks, the control plane compares the current schedule, event, and target Job
with the snapshot used to compute dispatch and concurrency keys. A concurrent
configuration change rolls back preparation and retries from current state
outside the transaction, up to three times. History projections batch receipt
and source-Job reads across the returned schedules and events.

The Elixir control plane computes fire instants, persists schedules, and drives
state transitions, and control-plane Session tools call `Ankole.Schedule`
directly in-process.

`scheduled_events` holds pending one-shot wake-ups and cron execution history,
while `cron_schedules.next_fire_at` is the sole domain authority for the next
automatic fire. Each active cron rule maintains at most one pending `FireCron`
Oban job; `oban_jobs` exists only to notify Schedule when `next_fire_at`
arrives, and PostgreSQL unique constraints plus Signal source IDs prevent Oban
retries from creating duplicate work.

## Human Work Authorization

Under [Human Offboarding](HumanOffboarding.md), both `scheduled_events` and
`cron_schedules` record `authorization_kind`, `human_uid`, and
`human_access_version`:

- Checkbacks inherit authorization from their triggering Signal.
- Cron rules created in an Agent turn inherit the authenticated turn's work
  authorization. Subsequent fires inherit the rule's stored version.
- Personal-assistant work records the owner's Human uid and access version in
  the work tenant, while the assistant remains the execution and audit subject.
- Site Console cron rules accept AI colleagues and run as `service` work under the selected Agent's
  permissions. `created_by` records the authenticated administrator for audit.
  The creation action derives the administrator from the authenticated
  Console Principal and supplies the service authorization. The cron editor
  enables its fields after resolving the selected Agent and initializing the
  draft. If a new schedule link names an unavailable Agent, the operator can
  choose an active Agent. The editor then focuses the schedule name so the operator
  can continue typing. Background refreshes preserve edits for the same Agent and rule.

At fire admission, Schedule locks and verifies every associated Human *before*
locking the event, cron rule, or bound Automation Job (locking both Humans in
ascending UID order when the schedule and the bound Automation Job depend on
different Humans). Automatic fires validate against the rule's authorization and
copy it onto the history row and Signal at fire time. Revoking a Human's access
pauses their active cron rules and cancels pending fires and checkbacks: an
already admitted fire may finish its current turn, but completing that turn
cannot schedule another valid fire, and resuming or manually running a rule
never renews a revoked authorization.

An admitted schedule turn uses the executing Agent's Principal for Drive and
Pod resource checks. Retained Human authorization controls work admission and
offboarding independently of those grants. Its private file paths resolve in
the Agent's private root. Delivery freezes each selected attachment's object in
the Message or unfinished Delivery relation; a file in a conversation root can
only be delivered to that conversation, including when a cron fire has multiple
targets.

## What PostgreSQL Stores

### One Wake-Up

`scheduled_events` stores either a planned checkback, a manual cron run, or a
history row for an automatic cron fire. Its primary key is a PostgreSQL
`GENERATED ... AS IDENTITY` `bigint` starting at `1000` and capped at
JavaScript's `Number.MAX_SAFE_INTEGER` (exposed to model tools as numeric
`checkback_id`).

`kind` is one of:

- `check_back_later`
- `cron_fire`

`status` is managed via `AshStateMachine` and takes one of four values:

- `scheduled`
- `fired`
- `cancelled`
- `failed`

Each row records the Agent, the execution Session (the Session in which the
wake-up runs: the originating Session for `check_back_later`, or the derived
`routine:<routine_id>` Session for Agent `cron_fire` runs), Binding, due timestamp, time
zone, deduplication key, optional source Signal, AI message, and provider reply
route. `wake_payload` holds the prompt/input for the future execution,
`source_provenance` captures the authenticated request and turn-fence metadata
that created the row, Oban job args point back to the owning event or rule, and
firing records its root `signal_id`. The Schedule projection resolves delivered
Signals and Runs through `signal_binding_receipts`, including every fanout target.

State transitions are strictly one-way toward terminal states:

- Planned rows start in `scheduled` (whereas a cron fire rejected at admission
  writes a terminal `cancelled` history row directly via `record_cancelled` so
  it stays out of the active slot index).
- `fire`, `cancel`, and `fail` transition a row to a terminal state that no
  action can revive; `reschedule` and `record_error` keep `scheduled`.
- `Schedule.Store` runs updates inside the caller's transaction after acquiring
  the row lock. Recording a delivery failure skips re-validating the execution
  target so a broken target never blocks failure persistence; by contrast,
  creation and rescheduling validate the full target. `reschedule` permits
  updating only the due time, time zone, `wake_payload`, consumer, reply route,
  and last fire error—never the owner, authorization, source, idempotency key,
  or creation timestamp (reauthorization uses its own dedicated action).

Job-owned cron rules store `owner_job_id` and inherit the Job's work authority.
Their Agent, owner Session and delivery fields are null. Their default Action
Binding targets that Job, and their business payload becomes `ctx.signal.data`
with `cron_fire_slot_at` and `fired_at`. Sources do not create a Session Signal
unless an additional Binding explicitly selects an Agent. Job management APIs,
SDK and CLI are defined in [Automation Jobs](AutomationJobs.md#native-job-sources).
A trashed Page or ancestor suppresses fires and advances the next slot without
spending the occurrence budget; restoring it permits future fires. Job deletion
and Page purge remove owned sources and receipts with the Job.

Schedule and raw Webhook sources route through `Signals.Dispatch`. Their default
Binding selects an Agent Session or Action. Dispatch locks Jobs, Bindings and
receipts before Schedule rows and Session queues; all delivery results commit
with the source transition. `automation_job_id` in source APIs is a projection
of the default Binding. Historical fired events retain their root Signal ID and
receipt references even after the ordinary seven-day receipt retention window.
Deleting a consumer Job removes its Bindings, while an independently owned
source continues to deliver to its remaining subscribers. A source without
subscribers records its due slot without admitting work or waking an Agent.
If a prepared Job or Binding changes before dispatch acquires its locks, the
fire returns a retryable error without consuming the slot. Oban prepares a fresh
snapshot on its next attempt. On the final attempt, failures during admission
or delivery record failed history and advance the rule under the same consumer
and rule locks used for other terminal fire failures.

Deduplication separates request retries from recurring time slots:

- Checkbacks and manual cron runs deduplicate client retries on:
  ```text
  (kind, agent_uid, session_id, idempotency_key)
  ```
- Automatic cron fires mint a fresh internal idempotency key per row (never
  treating an earlier terminal row as proof of a new fire) and guard each
  recurrence slot with a partial unique index:
  ```text
  (cron_schedule_id, cron_fire_slot_at)
  WHERE trigger = scheduled AND status != cancelled
  ```
  Because Schedule inserts the history row before dispatching work in the same
  transaction, this partial index blocks duplicate fires for the same slot: a
  `cancelled` row frees its slot, a `fired` or `failed` row permanently consumes
  its slot, and manual runs bypass the slot index entirely.

### Agent Routines and Recurring Rules

`agent_routines` (`Ankole.Schedule.Schemas.AgentRoutine`) owns standing Agent duties, while `cron_schedules` (`Ankole.Schedule.Schemas.CronSchedule`) stores recurring time rules. Each direct-Agent `CronSchedule` points to its parent `AgentRoutine` via `owner_routine_id` (Job-owned Applet schedules keep `owner_job_id` with `owner_routine_id = NULL`). Model tools address a routine or rule by its non-blank `name` (unique across the Agent's non-deleted routines and active rules), and a turn running inside that routine's execution Session can inspect its own routine without passing an identifier.

PostgreSQL restricts both `agent_routines.status` and `cron_schedules.status` to four values (`active`, `paused`, `deleted`, `completed`; individual fire failures live on `ScheduledEvent` history rows and execution `Signal`s):

- `agent_routines` stores the Agent, `owner_session_id` (management scope), `binding_name`, `name`, standing `task`, `delivery`, `definition_version` (incremented whenever `task` or `delivery` changes), `idempotency_key`, and work authorization.
- `cron_schedules` stores the Agent, `owner_session_id`, optional `owner_routine_id` or `owner_job_id`, Binding, recurrence rule, time zone, task input, delivery targets, and the prior and next planned wake-up timestamps, deduplicated on creation by `(agent_uid, owner_session_id, idempotency_key)`.

### The Routine Execution Session

Because a Session serializes Turns that share one linear model transcript, routine triggers never run inside `owner_session_id`. Instead, every `AgentRoutine` derives a dedicated execution Session `routine:<routine_id>` (and any standalone `CronSchedule` without `owner_routine_id` derives `cron:<schedule_id>`), while `owner_session_id` tracks management ownership (and cannot itself be a `routine:*` or `cron:*` Session).

Separating the two Sessions provides three guarantees:

- Cron fires, coalesced Connector event batches, manual runs, and `check_back_later` follow-ups of the same routine execute sequentially inside `routine:<routine_id>`, sharing one AIGateway conversation (`kind: :routine`), transcript, and Workspace.
- Long-running routine turns never block interactive user turns in `owner_session_id`, and separate routines never block one another.
- Output targets use public Conversation UUIDs: Pod output commits as native Agent Messages, and external channel output writes Delivery intents for the configured routes.

Because a routine turn never sees the `owner_session_id` transcript, `routine.task` (and `payload.task` on standalone Cron rules) stores a self-contained standing instruction. Action destinations carry their own code, and removing a default Action Binding does not create an Agent destination. When a human replies to a delivered routine message in chat, that reply routes to `owner_session_id`, which sees the committed Message as shared Conversation context rather than the routine Session's internal tool history.

Active and paused routines created by a Pod member appear as Living Routine cards on the Pod [Jobs Board](JobsBoard.md) (`/jobs`). Status changes of a `routine:<routine_id>` Session refresh the Pod's room and job summaries, moving the routine card into `running` while a turn or delegated child run executes and returning that card to `scheduled` once execution settles cleanly.

Lifecycle transitions coordinate `AgentRoutine`, child `CronSchedule` rows, and linked external `Binding`s together:

- **Edits**: Changing `task` or `delivery` increments `definition_version`, closes the routine's active AIGateway conversation so the next turn starts from the updated rubric, and seals any open unstarted coalesced `Signal` batch in `routine:<routine_id>`; time-only Cron edits preserve the conversation and `definition_version`.
- **Pause and resume**: Pausing a routine transitions `AgentRoutine` and its child `CronSchedule`s to `paused`, clears `next_fire_at`, cancels pending `cron_fire` and `check_back_later` `ScheduledEvent`s in `routine:<routine_id>`, and revokes unstarted `queued` `Signal`s (`dead_letter` with `reason: "routine_paused"`, while an already running turn finishes normally). Resuming sets `status = active` and computes `next_fire_at` forward from `now` without backfilling missed intervals or replaying events dropped while paused.
- **Finite Cron exhaustion and removal**: Exhausting an occurrence-bounded `CronSchedule` marks that `CronSchedule` `completed`; if the parent `AgentRoutine` still has enabled external `Binding`s, the routine stays `active` so Connector events continue waking `routine:<routine_id>`, whereas if zero triggers remain, the routine transitions to `completed` and closes its AIGateway conversation. Removing a routine disables its external `Binding`s, marks child `CronSchedule`s and the routine `deleted`, cancels pending `ScheduledEvent`s, revokes unstarted `queued` `Signal`s, and closes its AIGateway conversation.

## Set the Time for One Checkback

A checkback specifies either a relative delay or a local wall-clock timestamp.
Relative delays accept units from milliseconds through weeks (default minimum
`1` second, default maximum horizon `366` days):

```json
{
  "after": { "value": 30, "unit": "minutes" },
  "timezone": "Asia/Singapore"
}
```

Wall-clock timestamps convert to an instant through the IANA timezone database
(defaulting to `system.timezone` when `timezone` is omitted):

```json
{
  "at": "2026-07-20T09:00:00",
  "timezone": "Asia/Singapore"
}
```

## Repeat at an Interval or Cron Time

A recurring rule uses either a fixed millisecond interval anchored to an
absolute timestamp:

```json
{
  "kind": "every",
  "every_ms": 3600000,
  "anchor_at": "2026-07-20T00:00:00Z"
}
```

or a 5- or 6-field cron expression evaluated in an IANA time zone (which governs
daylight-saving transitions when finding the first matching instant after the
reference time):

```json
{
  "kind": "cron",
  "expression": "0 9 * * *",
  "timezone": "Asia/Singapore"
}
```

## Create, Change, or Cancel a Checkback

Creating a checkback persists the `scheduled_events` row and its Oban job in one
transaction (returning the existing row on an idempotent retry). Model tools see
five fields:

- `checkback_id` (assigned upon storage)
- `reason` (up to `2,000` characters)
- `check` (up to `4,000` characters)
- `context_summary` (optional, up to `8,000` characters)
- `quiet_success` (boolean, default `true`)

When a turn inside `routine:<routine_id>` schedules a `check_back_later` follow-up (for example, 15 minutes after triaging a Connector event batch), the wakeup inherits `routine:<routine_id>` and reads the live `routine.delivery` target list at fire time so any `outcome: "reply"` fans out across all configured native and external routine destinations.

Scheduled and routine turns end through the `finish_scheduled(outcome, reply, summary?)` termination
tool (`required: ["outcome", "reply"]`, with optional `summary` up to `500` characters). Ankole declares the same tool on Main turns as well, so the Main and
scheduled turns of one conversation share one tool list and one instruction
prefix under its prompt-cache key (see
[Sessions](Sessions.md#prepare-a-model-request)). On a Main turn the tool
rejects the call with a standard tool error, and the turn continues. The
instructions state the completion rule once and key it to the
`schedule_turn_mode` field in the input environment of the newest message:

- For a user-visible update, the model calls `outcome: "reply"` with a non-empty
  `reply` string (and optional `summary`). Whenever a check fails, observes actionable anomalies, or needs human
  intervention, the model sends a visible reply.
- When `quiet_success` is `true` and nothing requires notifying the room, the
  model calls `outcome: "silent_success"` with `reply: null`—either omitting `summary` for a silent check or supplying a concise 1–3 sentence `summary` to record structured audit progress in `signals.turn_summary` without posting a chat message.
- Invalid arguments or disallowed `silent_success` calls return a standard tool
  error so the model can self-correct within its tool loop; scheduled turns do
  not use constrained JSON response formats or extra rounds to repair output
  formatting.

Accepting `finish_scheduled` ends the turn and records its outcome, reply
text, and optional `turn_summary` alongside the tool journal in Sessions' typed round state so recovery reads
that committed outcome and summary without re-running `finish_scheduled`, persisting `turn_summary` onto `signals.turn_summary` inside the terminal commit transaction. If a scheduled
turn finishes with non-empty assistant prose and no accepted `finish_scheduled`
call, Ankole treats that prose as a visible reply; silent completion always
requires an accepted `finish_scheduled` call. If a turn produces neither, Ankole
dead-letters the turn in a single transaction—storing the failure reason and
Response anchor, closing the applied input prefix while leaving unapplied
follow-ups queued, releasing the turn, and queueing a standard failure notice
for the reply owner (idempotent on duplicate completion calls, and never rerun
on lease expiry while keeping committed tool results in the tape).

Scheduled turns never stream raw token deltas to external channels (even if the
preview owner changes): only the accepted `finish_scheduled` reply or completed
final prose enters the delivery intent, clarify and attachment tools follow
their own delivery contracts, and inline text markers carry zero control
meaning.

Updating a pending checkback mutates the row in place—preserving `checkback_id`
and rescheduling the Oban job if the due time changed (rows superseded by an
earlier model version return `checkback_replaced` on `get`, `update`, and
`cancel`). Canceling a checkback sets `status = cancelled`, and removing the
originating provider message entry cancels any matching pending checkbacks.

## Create, Pause, or Change a Recurring Rule

Creating an `active` cron rule computes its initial `next_fire_at` and enqueues
its `FireCron` Oban job; each successful automatic fire inserts history and
advances `next_fire_at` in the same transaction.

Rule mutations and fires acquire their Job and Binding locks before locking
the `cron_schedules` row, following the order below. Automatic fires read live
`payload` and `delivery` at fire time:

- **Updates**: Payload-only edits keep `next_fire_at` unchanged, while
  time-rule edits compute a fresh `next_fire_at`; both reschedule or restore the
  single pending `FireCron` job to match (leaving any currently executing Oban
  job to finish its claim while a fresh pending job covers the next slot).
- **Pause and resume**: Pausing clears `next_fire_at` so any already enqueued
  `FireCron` job exits as a no-op; resuming computes a fresh `next_fire_at` from
  `now` (or re-enqueues the existing `next_fire_at` if already `active`).
- **Removal**: Marks the rule `deleted`, clears `next_fire_at`, closes its
  AIGateway conversation, and cancels pending manual runs.
- **Manual runs**: Immediately enqueue a one-shot wake-up for an `active` or
  `paused` rule without altering `next_fire_at` or the rule itself, deduplicated
  by a required caller key (the provider tool-call ID for Agent tools, or body
  `idempotency_key` on `POST /api/v2/agents/:agent_uid/cron-schedules/:id/runs`).

Cron delivery accepts only the non-empty `targets` list format keyed by public
Conversation UUIDs (never raw provider room IDs):

```json
{
  "targets": [
    {
      "binding_name": "lark-primary",
      "binding_id": "019a2b00-0000-7000-8000-000000000051",
      "conversation_id": "019a2b00-0000-7000-8000-000000000041"
    },
    {
      "binding_name": "lark-record",
      "binding_id": "019a2b00-0000-7000-8000-000000000052",
      "conversation_id": "019a2b00-0000-7000-8000-000000000042",
      "provider_thread_id": "thread-b"
    }
  ],
  "quiet_success": true
}
```

Every target requires `conversation_id`: native Pod targets omit provider route
fields, while external targets identify the binding by `binding_id`, carry its
`binding_name`, and may include `provider_thread_id`. `quiet_success` defaults
to `true` when omitted so recurring routines notify chat rooms only when an
anomaly, blocker, or requested deliverable warrants human attention. Duplicate
`(conversation_id, binding_id, provider_thread_id)` tuples are rejected. The
first entry is the primary target; its binding must match the rule's binding.
Schedule copies that primary route
onto `ScheduledEvent` and `Signal` while freezing the full `targets` list inside
`wake_payload`. Disabling a provider Binding does not block the cron turn from
executing; each outbound Delivery enforces its own route and error policy after
completion. Cron turns may use `silent_success` only when `delivery.quiet_success`
is `true`.

Operators can configure multiple targets via the Console or REST API (omitting
`quiet_success` on a route edit keeps the stored boolean), whereas Agent tool
calls can create or replace only the current turn's route—though an Agent may
toggle `quiet_success` on an operator-configured multi-target rule without
overwriting its `targets`. A rule with a default Agent destination requires a
non-empty `payload.task` at creation, on update, and when it fires.

## What Happens When the Time Arrives

When `next_fire_at` arrives, automatic cron execution follows a single pipeline:

```text
cron rule.next_fire_at
  -> FireCron job
  -> prepare subscriptions, then lock and authorize destinations and rule
  -> insert fired history for the slot
  -> Signals.Dispatch admits Runs and Session Signals
  -> record delivery receipts and advance next_fire_at
  -> Sessions driver and Applet Action execution
```

Checkbacks and manual runs execute via `FireScheduledEvent`, which locks a due
row with `status = scheduled`, dispatches its subscriptions, and transitions the row
to `fired` (returning a no-op if already terminal or still in the future, and
never advancing a cron rule's cursor on manual runs).

Both Oban workers retry up to `10` attempts:

- On checkbacks and manual runs, transient failures keep `status = scheduled`
  with the latest diagnostic until attempt `10` marks the row `failed`.
- On automatic cron fires, Oban tracks intermediate retries and attempt `10`
  inserts a `failed` history row and advances `next_fire_at` if the rule is
  still `active` on that slot. Both `fired` and `failed` automatic slots count
  against any occurrence limit (manual runs do not); hitting the limit marks the
  rule `completed` and closes its AIGateway conversation. If a rule is invalid
  at fire time, Schedule writes a `cancelled` history row and advances the next
  fire without consuming the occurrence budget.

Wake-ups emit CloudEvents 1.0 envelopes—`check_back_later.wakeup` for checkbacks
and `cron.fire` for cron fires—carrying the event/history ID, due time, fire
time, time zone, primary reply route, and frozen delivery targets. Delivery
receipts link the event to each admitted Session Signal or Automation Run,
and its history records the root `signal_id` and `fired_at`. Ankole strips the
internal event ID and delivery routes from the model-visible prompt. Model tool queries
map known cancellations and domain errors to stable reason codes and collapse
all other diagnostics to `schedule_fire_failed` without leaking request, Signal,
Oban, or provider IDs; operators see full diagnostics in the Console.

Across admission, updates, manual runs, final failed-history inserts, and Human
revocation, Schedule enforces one strict lock order:

1. Associated `Human` rows in ascending UID order
2. `AutomationJob` rows in ascending ID order: dispatch locks its destination
   Jobs, while a Job-owned source edit locks only its owner. Agent-owned source
   edits lock current and requested destinations before checking target access
   and changing a Binding. Cron creation locks its requested destination; an
   idempotent creation request preserves the rule and its subscriptions without
   locking their other consumers.
3. `AgentRoutine` rows in ascending ID order
4. Source and external `Binding` rows when dispatching or changing a destination
5. `CronSchedule`
6. `ScheduledEvent` and delivery receipts
7. `Session`, `Workspace`, and `Signal`

Because `FireCron` re-checks the locked rule's status and `next_fire_at`, stale
Oban jobs harmlessly skip paused, deleted, completed, or rescheduled rules;
after an outage, `FireCron` fires all missed intervals as a single catch-up fire
for the retained slot and computes the next `next_fire_at` forward from `now`.

## Tell the Agent Why It Woke Up

Sessions maps scheduled and routine Signals to dedicated turn kinds:

| Signal type | Turn kind | Agent schedule mode |
| --- | --- | --- |
| `check_back_later.wakeup` | `checkback_generation` | `check_back_later` |
| `cron.fire` | `scheduled_task` | `cron` |
| External event / `routine.manual_run` in `routine:<id>` | `scheduled_task` | `routine` |

The control plane derives the schedule mode from the Signal type (or `ankole_routine` extension for routine-targeted external events and manual runs) and passes the
schedule origin and `quiet_success` permission in request context without
duplicating the mode. For `cron.fire` and `routine` turns, the prompt also tells the Agent that
Ankole will fan out its final reply automatically: the Agent executes a single
turn regardless of target count, `Sessions.Presentation` writes a native Agent
Message or external Delivery intent per target upon completion (and propagates
those frozen targets to any `BackgroundAgentJob` spawned by the turn for its
terminal notification, while keeping interactive clarifications on the primary
target), and the model must never re-send the same cron output through another
messaging tool.

## Schedule Tools

Control-plane Drivers execute `check_back_later` (`create`, `list`, `get`,
`update`, `cancel`) and `cron` (`list`, `get`, `runs`, `add`, `update`, `pause`,
`resume`, `remove`, `run`) directly under the Driver's fenced `Run`:

- Queries and mutations are scoped to the current `(agent, session)` or the
  routine/rule's `owner_session_id`; `runs` projections include each run's `turn_outcome` and `turn_summary` alongside trigger and execution timestamps so a daily wrap-up or self-inspecting routine can review prior execution summaries directly; reply routes come from the active input, cron
  provenance records `driver_epoch` and the frozen route, and an optional
  `automation_job_id` must name an active Applet Job whose Page and personal authority the caller may use (clearable
  or replaceable on update).
- In an owner conversation, `cron` `pause` and `remove` operate on the timer schedule of a Hybrid Routine (`AgentRoutine` with both a Cron schedule and enabled external event `Binding`s) while keeping the Routine and its external `Binding`s active; when a Routine has only external `Binding`s (no non-deleted Cron schedule), `pause` and `remove` pause or delete the Routine itself.
- Inside a derived `routine:<routine_id>` execution Session, the turn may call
  only `list`, `get`, `runs`, and `pause`—and strictly on its own routine (where `pause` pauses the entire Routine so self-stopping duties halt both scheduled recurrences and external event wakes). Calling
  `pause` lets a self-stopping task halt future recurrences once a condition is
  met while keeping its AIGateway conversation open so the current turn can
  still deliver its reply; by contrast, a routine turn cannot create rules, edit
  its own task, resume or trigger itself, or `remove` its rule (since `remove`
  closes the active AIGateway conversation).

## Rules

- Persist every user-affecting schedule in PostgreSQL; use Oban strictly to trigger due checks, keeping at most one pending `FireCron` job at `next_fire_at` per active rule.
- Store only historical fires in automatic cron run lists, never re-fire a `fired` or `failed` slot, and emit at most one `Signal` or `AutomationJob` run per scheduled event and Binding.
- Execute every Agent cron fire in its derived `routine:<routine_id>` Session (never in `owner_session_id`), keeping the complete standing prompt in `payload.task` for direct-Agent rules and running one Agent turn regardless of target count.
- Restrict Agent schedule tools to the current turn's route, and restrict cron-originated turns to inspecting or pausing their own rule.
- Cancel pending checkbacks whenever their source provider entry is canceled or removed.
- Allow silent completion without a reply only when the schedule explicitly enables `quiet_success`.
