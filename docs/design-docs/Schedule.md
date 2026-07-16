# Schedule

Schedule is the control-plane subsystem that turns time into actor work. An
Ankole agent does not wake up because time passed. A schedule records a future
obligation in PostgreSQL, the control plane materializes an `ActorEvent` when
the obligation is due, and ActorRuntime starts the normal worker turn from that
event.

This document covers two user-visible schedule primitives:

- `check_back_later`: a one-shot self-wakeup the agent creates from an active
  turn when the current decision is better made later.
- `cron`: one recurring schedule that keeps producing future fires until it is
  paused, removed, or disabled.

They share the same durable fire path. They do not share the same product
meaning. For where Schedule sits in the whole system, see `docs/README.md`;
the actor event journal it feeds is described in
`docs/design-docs/SignalsGateway.md`.

## Reference Semantics

BullX Agent's `check_back_later` is the closest reference for one-shot delayed
self-wakeup: the model supplies `reason`, `check`, and optional compact context;
the future wake runs as a distinct checkback turn; and routine outcomes may stay
silent. Ankole keeps the same one-shot mechanism but broadens the user story to
reminders and promised follow-ups, so checkbacks are visible by default. Quiet
success is an explicit opt-in for requests such as "only tell me if it changes."

Hermes and OpenClaw are the useful references for recurring cron work:

- a gateway or control-plane daemon owns scheduled execution;
- cron jobs run in fresh or explicitly selected agent sessions;
- the cron prompt should be self-contained because the run is not a live user
  message;
- delivery is scheduler-owned, so the agent should not duplicate the same final
  answer through a messaging tool;
- recurring jobs need lifecycle controls such as list, pause, resume, update,
  remove, manual run, and run history;
- cron-triggered runs must not receive broad permission to recursively create
  more cron jobs.

The external references are the Hermes
[Scheduled Tasks (Cron)](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/cron.md)
guide, OpenClaw's
[Scheduled tasks](https://docs.openclaw.ai/automation/cron-jobs#how-cron-works)
guide, and OpenClaw's
[cron tool implementation](https://github.com/openclaw/openclaw/blob/main/src/agents/tools/cron-tool.ts).
BullX Agent's local `check_back_later` implementation is the one-shot reference.

Ankole adopts those semantics, but not their storage shape. Hermes's JSON file
and file lock, OpenClaw's broad Gateway tool schema, and script-only command cron
are not Ankole's v1 architecture. In Ankole, PostgreSQL is the semantic ledger,
Oban is the wake edge, and `ActorEvent` remains the actor handoff.

## Core Invariants

`actor_scheduled_events` is the schedule truth. `oban_jobs` is only a wake-up
edge. An Oban job may be duplicated, retried, delayed, or rebuilt. It must never
be consulted as the source of product semantics.

All semantic idempotency is database-backed:

- domain idempotency is enforced by unique indexes on schedule rows;
- wake-up idempotency may use Oban uniqueness only as a noise reducer;
- fire idempotency is enforced by scheduled-event status plus the stable
  `ActorEvent` source key.

The control plane owns time. Workers may request a schedule through RuntimeFabric
RPC, but workers do not own durable timers, recurrence, next-fire computation,
or schedule status.

Firing a schedule means appending an `ActorEvent`. It does not mean choosing a
worker. Once the event is appended, ActivationManager and the existing worker
assignment path decide how to run it.

Dynamic actor cron is not `Oban.Plugins.Cron`. The existing static Cron plugin
configuration remains appropriate for application jobs such as daily resets and
cleanup. Operator- or agent-created recurring schedules live in Ankole domain
tables and use Oban scheduled jobs only as wake edges.

## Domain Model

There are two durable concepts:

- `ScheduledEvent`: one pending or terminal fire attempt. This is the shared
  path for `check_back_later` and individual cron fires.
- `CronSchedule`: one recurring definition. It produces `ScheduledEvent`
  records over time.

`check_back_later` does not need a separate definition table. It creates exactly
one `ScheduledEvent(kind = "check_back_later")`.

`cron` needs a recurrence definition table because the same schedule keeps
producing fires. A cron definition creates `ScheduledEvent(kind = "cron_fire")`
rows. Each event is still one concrete future fire with its own `due_at`,
idempotency key, Oban wake edge, ActorEvent, and terminal status.

```text
check_back_later tool
  -> actor_scheduled_events(kind = check_back_later)
  -> Oban wake edge
  -> ActorEvent(type = check_back_later.wakeup)
  -> worker turn (request_context.turn_mode = check_back_later)

cron schedule definition
  -> actor_cron_schedules
  -> actor_scheduled_events(kind = cron_fire, cron_schedule_id = ...)
  -> Oban wake edge
  -> ActorEvent(type = cron.fire)
  -> worker turn (request_context.turn_mode = cron)
```

## Storage Shape

Use boring text statuses plus database check constraints, matching the current
ActorEvent style. Do not introduce PostgreSQL enums for this v1.

### actor_scheduled_events

This table stores one concrete fire.

Required columns:

- `id`: UUIDv7 primary key.
- `kind`: text, one of `check_back_later`, `cron_fire`.
- `status`: text, one of `scheduled`, `firing`, `fired`, `cancelled`, `failed`.
- `agent_uid`, `session_id`, `binding_name`.
- `due_at`: UTC instant when the event may fire.
- `timezone`: IANA timezone used when interpreting the schedule.
- `requested_at`.
- `idempotency_key`: stable caller key.
- `cron_schedule_id`: nullable FK to `actor_cron_schedules`.
- `cron_fire_slot_at`: nullable intended slot time for cron fires.
- `tool_call_id`: nullable model tool call id.
- `source_actor_event_id`: the actor event whose turn created this schedule.
- `origin_ai_message_id`: nullable reference to the `ai_gateway_messages` row
  whose model output requested the schedule.
- `signal_channel_id`, `provider_thread_id`, `source_entry_id`: reply route
  fields copied into the fired ActorEvent when that is semantically correct.
- `source_provenance`: JSON object for audit-only facts such as transport route,
  authenticated worker id, key revision, source activation uid, actor epoch,
  source revision, and source RPC request id.
- `wake_payload`: JSON object used to build the future ActorEvent payload. For
  checkbacks it includes the effective `quiet_success` boolean, defaulting to
  `false`.
- `oban_job_id`, `actor_event_id`.
- `fire_attempts`, `fire_claimed_at`, `fired_at`, `cancelled_at`.
- `last_fire_error`: JSON object.
- timestamps.

Indexes and constraints:

- unique `(kind, agent_uid, session_id, idempotency_key)`;
- unique `(cron_schedule_id, cron_fire_slot_at)` where `cron_schedule_id IS NOT
  NULL`;
- index `(status, due_at)`;
- index `(agent_uid, session_id, status, due_at)`;
- index `actor_event_id`;
- index `oban_job_id`;
- JSON object checks for `source_provenance`, `wake_payload`, and
  `last_fire_error`;
- non-empty checks for `timezone` and `idempotency_key`;
- status and kind check constraints.

The unique idempotency key should be permanent. If a tool call created a
schedule and that schedule was later cancelled, retrying the same tool call
returns the existing cancelled event rather than expressing a different
commitment with the same key.

The worker-generated checkback key treats omitted and `quiet_success = false`
as the same existing contract. It adds a policy discriminator only when
`quiet_success = true`, so enabling quiet delivery creates a distinct semantic
commitment without changing retry behavior for existing callers. If a caller
reuses an explicit key with different input, the persisted event wins and the
RPC response reports that persisted effective policy.

### actor_cron_schedules

This table stores one recurring definition.

Required columns:

- `id`: UUIDv7 primary key.
- `status`: text, one of `active`, `paused`, `deleted`, `failed`.
- `agent_uid`, `session_id`, `binding_name`.
- `name`: operator-facing optional label.
- `schedule`: JSON object.
- `timezone`: IANA timezone for cron wall-clock fields.
- `payload`: JSON object used to build each cron fire.
- `delivery`: JSON object containing a provider route. Cron delivery currently
  requires `signal_channel_id`.
- `next_fire_at`, `last_fire_at`.
- `idempotency_key`: stable creation key.
- `created_by`: JSON object describing whether creation came from a turn,
  operator API, or trusted plugin.
- `failure_policy`: JSON object for future alerting/backoff behavior.
- timestamps.

Indexes and constraints:

- unique `(agent_uid, session_id, idempotency_key)`;
- optional unique `(agent_uid, name)` where `status != 'deleted' AND name IS NOT
  NULL`;
- index `(status, next_fire_at)`;
- index `(agent_uid, session_id, status)`;
- JSON object checks for `schedule`, `payload`, `created_by`, and
  `failure_policy`.

The v1 schedule JSON supports only recurring forms:

```json
{ "kind": "every", "every_ms": 3600000, "anchor_at": "2026-06-27T00:00:00Z" }
{ "kind": "cron", "expression": "0 9 * * *", "timezone": "Asia/Shanghai", "stagger_ms": 0 }
```

There is intentionally no cron `at` schedule kind. One-shot work belongs to
`check_back_later`.

## Schedule RPC

Worker-originated scheduling goes through RuntimeFabric RPC. The RPC handler
receives the authenticated transport route from RPCLane; the worker must not
provide that route in the JSON payload.

`check_back_later` uses the `schedule.check_back_later.*` RPC family:
`create`, `list`, `get`, `update`, and `cancel`.

The request payload must include:

```json
{
  "request_id": "rpc request id",
  "turn": { "...": "ActorTurnRef" },
  "tool_call_id": "provider tool call id",
  "idempotency_key": "stable key",
  "schedule": {
    "after": { "value": 30, "unit": "minutes" },
    "at": null,
    "timezone": "Asia/Shanghai"
  },
  "reason": "why waiting is useful",
  "check": "what to inspect later",
  "context_summary": "compact optional context",
  "quiet_success": false,
  "reply_route": {
    "binding_name": "feishu-main",
    "signal_channel_id": "channel id",
    "provider_thread_id": "thread id",
    "source_entry_id": "source entry id"
  }
}
```

The handler must:

1. validate `turn` as an `ActorTurnRef`;
2. authorize the authenticated RuntimeFabric route against that turn with
   `WorkerRouteAuth.authorize_turn_route(turn_ref, route, :write)`;
3. verify the requested reply route belongs to the current turn context or to
   the actor event referenced by the turn;
4. validate `tool_call_id`, `idempotency_key`, and the optional boolean
   `quiet_success`, defaulting it to `false`;
5. parse time in the control plane using `system.timezone` as the default;
6. persist the effective quiet policy in `wake_payload` and insert the
   `actor_scheduled_events` row;
7. insert the Oban wake job in the same transaction.

The response is stable across retries:

```json
{
  "status": "scheduled",
  "scheduled_event_id": "uuid",
  "due_at": "2026-06-27T10:30:00Z",
  "timezone": "Asia/Shanghai",
  "quiet_success": false
}
```

When the row already exists, return `status = "already_scheduled"` with the same
ids, timestamps, and persisted effective `quiet_success` value. The response
must describe the stored commitment, not merely echo the latest request.

After a successful create, the initiating turn's visible reply confirms what
will be checked, when it will run, and whether a normal or unchanged outcome
will be reported.

`list` returns only pending checkbacks for the current agent and session, while
`get` can inspect a known event from that same scope. `update` accepts a partial
replacement of `reason`, `check`, `context_summary`, `quiet_success`, or
`schedule`; `cancel` targets a known event id. Reads use turn-read route
authorization, and mutations use turn-write route authorization. Update also
validates the current reply route because the replacement event becomes the
new delivery commitment.

An update does not rewrite an audit row or try to reschedule its existing Oban
job. In one transaction it inserts a replacement scheduled event and wake job,
then marks the prior event cancelled with the replacement id. Any old wake edge
can still execute, but the guarded fire claim sees the cancelled status and
no-ops. Repeated updates and cancellation follow that replacement chain to the
current pending event, so a model holding an earlier event id cannot leave a
newer replacement running by mistake.

The worker emits create, update, and cancel effect receipts only after the RPC
returns successfully. Conversation text alone is not evidence that durable
schedule state changed, so the model must not claim a correction or revocation
was applied without a confirmed tool result.

Cron management can be exposed through a Phoenix control-plane API and, later,
through a model-visible `cron` tool. Both surfaces call the same domain context.
The model-visible tool should be narrower than OpenClaw's broad Gateway tool:

- `list`, `get`, `add`, `update`, `pause`, `resume`, `remove`, `run`, `runs`;
- recurring schedules only: `every` and `cron`;
- no one-shot `at`;
- no command/script-only payload in v1;
- no broad cron mutation grant inside a cron-triggered run.

Cron-created-from-turn RPCs also carry `turn_ref` and are authorized against the
current worker route. Operator API calls use Principal/AuthZ instead of
RuntimeFabric route auth.

## Transaction Boundaries

Schedule creation is one transaction. Do not insert a domain row and then insert
the Oban job in a later non-transactional call.

The creation transaction should be expressed as `Repo.transact` with
`Ecto.Multi` and Oban's multi insert support:

```text
insert scheduled_event or cron_schedule
insert Oban wake job using the inserted row id and due_at
commit both together
```

If Oban insertion fails, the schedule row must roll back. A schedule row without
a wake edge is recoverable by a sweeper, but creating that state during the
normal write path is still a bug.

Fire is also one transaction:

```text
guarded claim scheduled event
append the ActorEvent with a stable source_event_id
mark scheduled event fired with actor_event_id
for cron:
  lock actor_cron_schedules row FOR UPDATE
  verify status still active
  update last_fire_at
  compute next_fire_at
  insert the next actor_scheduled_events row using the cron slot unique key
  insert the next Oban wake job
commit
wake ActivationManager after commit
```

The claim should be a guarded update:

```sql
UPDATE actor_scheduled_events
SET status = 'firing',
    fire_attempts = fire_attempts + 1,
    fire_claimed_at = $now,
    updated_at = $now
WHERE id = $event_id
  AND status = 'scheduled'
  AND due_at <= $now
RETURNING *
```

If no row is returned, the Oban worker returns `:ok` as a business no-op. It
must not retry terminal, not-due, cancelled, or already-fired events.

Failures that should be retried return an Oban error. If the transaction rolls
back, fields updated inside that transaction roll back as well; persistent error
diagnostics may be written in a separate best-effort update after rollback.

## Fire Worker

The Oban worker is `Ankole.SignalsGateway.ActorRuntime.Jobs.FireScheduledEvent`.

Its job args contain only:

```json
{ "scheduled_event_id": "uuid" }
```

The worker:

1. calls `ScheduledEvents.fire_due_event(event_id)`;
2. treats `:noop` as success;
3. returns errors only for transient or real failures;
4. wakes ActivationManager after a committed ActorEvent append.

A scheduled event enters `failed` only through domain code, not by reading Oban
as schedule truth. Permanent validation failures should mark the event failed in
a transaction and then have the worker return `:ok` or `{:cancel, reason}` so
Oban does not retry. Transient failures return `{:error, reason}`. If Oban
eventually discards a wake job, a reconciler may mark the scheduled event failed
or re-arm it according to the schedule's failure policy.

Oban uniqueness may be set on `(worker, scheduled_event_id)` for states such as
scheduled, available, executing, and retryable. This is not a correctness
guarantee. Correctness is the scheduled-event claim plus actor event source
idempotency.

The fired actor event's `source_event_id` is stable:

```text
check_back_later:<scheduled_event_id>:wakeup
cron:<cron_schedule_id>:<cron_fire_slot_at_iso8601>
```

The scheduled-event claim is the primary idempotency guard. The appended
ActorEvent also uses `(agent_uid, binding_name, source_event_id)` as its
handoff key, so retries inside the firing window converge to one open actor
event.

## Actor Events And Turns

`check_back_later` fires:

```text
ActorEvent.type = check_back_later.wakeup
request_context.turn_mode = check_back_later
```

`cron` fires:

```text
ActorEvent.type = cron.fire
request_context.turn_mode = cron
```

ActorRuntime must explicitly branch on these event types. They must not fall
through as ordinary `generation` turns.

Schedule prompt facts travel on `turn_start.request_context`. The worker reads
`schedule_origin`, `turn_mode`, and `silent_success_allowed` from that current
turn payload while building the system prompt. They are not conversation
history and are not returned by `agent_conversation.context.resolve`.

Both event types are direct events: they are ready immediately and never enter
IM batching.

Daily reset does not make either schedule event stale. A materialized
`cron.fire` or `check_back_later.wakeup` behind the reset barrier remains in the
actor queue and enters the successor conversation when it reaches the head.

## Prompt Contract

The worker prompt should expose schedule-origin context as a runtime fact, not
as human-authored text.

For `check_back_later`:

- say this is a one-shot delayed self-wakeup scheduled earlier by the agent;
- say it is not a user message, heartbeat, cron, or recurring monitor;
- include `due_at`, `fired_at`, `reason`, `check`, and `context_summary`;
- use the context as background, not as permission to replay old tasks;
- produce a concise provider-visible result by default, including when nothing
  changed or the work is still waiting;
- finish silently only when this checkback has `quiet_success = true`, and only
  when there is no meaningful result, failure, blocker, human decision, state
  change, or time-sensitive risk to report;
- if the check is still legitimately blocked, the agent may schedule a new
  one-shot checkback. Quiet authorization is not inherited: it must set
  `quiet_success = true` again when the same user-authorized quiet obligation is
  deliberately continued.

For `cron.fire`:

- say this is a recurring scheduled task fire, not a live user message;
- include the cron schedule id, optional name, intended slot time, due time,
  fired time, timezone, and payload text;
- say the scheduler owns delivery of the final assistant output;
- tell the agent not to call messaging tools for the same configured delivery
  target;
- say routine cron runs should use the self-contained payload, not ambient chat
  memory, unless the schedule explicitly targets a persistent session;
- if the schedule allows quiet success, the agent may finish silently when there
  is nothing meaningful to report;
- cron-triggered turns do not receive broad cron management access. At most they
  may inspect or remove/disable their own current schedule when the schedule
  grants that narrow self-cleanup capability.

The model-visible split should remain simple:

- use `check_back_later` for "check this once later";
- use `cron` for "keep doing this on a cadence";
- do not emulate either with shell sleeps, polling loops, or process managers.

## Routing And Tombstones

Store reply routing separately from schedule provenance.

`reply_route` is the provider-visible target for future output:

- `binding_name`;
- `signal_channel_id`;
- `provider_thread_id`;
- optional `source_entry_id`.

`schedule_provenance` is audit and authorization context:

- source actor event id;
- source tool call id;
- RPC request id;
- authenticated worker id;
- authenticated key revision;
- transport route;
- source actor epoch and revision.

Fire must never use `schedule_provenance.transport_route` to choose a worker.
That route may be stale. Fire appends an ActorEvent and lets ActorRuntime
schedule live work.

For `check_back_later`, copy the original `source_entry_id` into the fired
ActorEvent by default. If the original entry was deleted or recalled before the
checkback runs, the removal handling cancels the checkback. This is the
conservative behavior: do not produce a visible reply anchored to withdrawn
content.

For cron, do not copy the creation message's `source_entry_id` into recurring
fire events. A recurring schedule should not stop forever because the chat
message that created it was deleted. Store the creation entry only in
`schedule_provenance`. Cron delivery should target a channel or thread, not an
old source entry, unless a future product explicitly defines entry-anchored
recurring replies.

## Time Semantics

All schedule parsing is control-plane owned.

`check_back_later` accepts exactly one of:

- `after`: relative delay;
- `at`: absolute time.

Bare local `at` strings are interpreted in `system.timezone`. Explicit `Z` or
offset timestamps are treated as absolute instants. The result must be bounded:

- reject due times earlier than `now + min_delay`;
- reject due times beyond `max_horizon`;
- reject invalid timezones;
- bound `reason`, `check`, and `context_summary` lengths;
- require JSON object payloads for provenance and wake payload.

Cron supports:

- `every`: fixed interval on an anchored grid;
- `cron`: 5- or 6-field cron expression in an IANA timezone.

Cron expressions are wall-clock expressions in their timezone. Do not convert
the requested local time to UTC before storing the expression. For example,
"6pm Shanghai daily" is:

```json
{ "kind": "cron", "expression": "0 18 * * *", "timezone": "Asia/Shanghai" }
```

DST behavior must match the system timezone helper used by daily reset:
ambiguous local times choose the first occurrence, and gaps move to the
post-gap instant. If the chosen cron parser has Vixie-style day-of-month /
day-of-week OR behavior, document that behavior in the operator-facing API.

Oban scheduled precision is not semantic precision. `actor_scheduled_events.due_at`
keeps the intended instant. The fire worker must still check `due_at <= now`
before firing.

## Cron Recurrence Policy

Cron schedules are continuous until paused, removed, or disabled. They do not
create one-shot `at` jobs.

On a normal fire:

1. materialize the due cron event;
2. append `cron.fire`;
3. lock the `actor_cron_schedules` row `FOR UPDATE`;
4. verify the schedule is still active;
5. advance `last_fire_at`;
6. compute the next future fire;
7. arm the next `actor_scheduled_events` row and Oban job in the same
   transaction.

The row lock is load-bearing. Oban scheduled jobs and uniqueness options reduce
duplicate wake pressure, but recurrence correctness comes from the locked domain
row plus the `(cron_schedule_id, cron_fire_slot_at)` unique key.

After downtime or Oban backlog, v1 coalesces missed slots by default. It fires
at most one overdue run per schedule and advances `next_fire_at` to the next
future slot after `now`. This avoids a restart stampede for high-frequency
schedules. Backfill can be added later as an explicit schedule policy.

Manual run is not a new schedule. It creates an immediate `cron_fire` event with
a `trigger = "manual"` payload and leaves recurrence state unchanged unless the
run itself updates or removes the schedule.

Paused schedules keep definition and history but do not arm new events. Resume
recomputes `next_fire_at` from the resume time.

Deleted schedules do not arm new events. Already-fired actor events and their
completed work are history. Still-scheduled future events are cancelled
transactionally when the schedule is deleted.

## Reset Semantics

`check_back_later` and each concrete cron fire are durable commitments. They
survive daily reset. If a scheduled event's `due_at` was before reset but Oban
fires it after reset, the fired event enters the successor active conversation
and carries both the original due time and actual fired time.

Already-materialized `cron.fire` actor events behind the reset barrier remain
open and are consumed from the successor conversation. Due cron rows that have
not materialized are not cancelled or re-armed by reset; the existing fire
worker materializes the same `cron_fire_slot_at` afterward. Reset does not
advance `last_fire_at` or `next_fire_at`. Recurrence advances only after that
concrete fire is claimed and materialized through the normal locked cron path.

This keeps daily reset as a conversation-history boundary rather than a second
missed-fire policy. The scheduled-event claim and cron slot idempotency still
guarantee that the preserved occurrence fires at most once.

## Delivery And Silent Success

Checkback delivery is visible by default because "check later," reminders, and
promised follow-ups create an expectation that the agent will return. A
checkback may opt into quiet success only when the original user explicitly
asked not to hear about normal or unchanged outcomes. Even then, meaningful
results, failures, blockers, requested decisions, state changes, and
time-sensitive risks remain visible.

Cron delivery is schedule-defined. A recurring report usually delivers the final
assistant output every run. A monitoring schedule may opt into quiet success, in
which case a clean run can commit without provider-visible output.

Silent success is still a normal, fenced completion. When a schedule-origin
turn has nothing meaningful to report and its request context allows quiet
success, the worker must produce exactly `<silent_success/>`; the worker then
sends `turn_noop_completed`. The control plane sets `actor_events.completed_at`
and creates no outbox row.
Any model calls the turn already made remain committed in
`ai_gateway_messages`; those rows are the audit record, and no separate
assistant or introspection message is created.

The worker must not express silent success with empty output. Empty output and
`<silent_success/>` on a turn without quiet authorization cannot complete the
user-visible path. Every turn still needs a fenced, committable, auditable
terminal result — either `turn_completed` naming a Response with a user-visible
projection or the explicitly authorized noop completion.

Provider-visible output uses normal `signal_gateway_outbox_entries` rows. The scheduler
does not send messages directly from the fire worker, and the worker should not
call messaging tools for the same configured target.

## Public Surfaces

Control-plane API:

- list schedules by agent/session;
- get one cron schedule and recent fires;
- create/update/pause/resume/remove cron schedules;
- manually run a cron schedule;
- list checkbacks created by an agent;
- cancel a pending checkback.

Model-visible tools:

- `check_back_later`: create, list, inspect, update, and cancel one-shot delayed
  self-wakeups in the current conversation;
- `cron`: manage recurring schedules when policy allows it.

Operator UI can be added on top of the same context. It should show schedule
truth from Ankole tables, not from Oban jobs.

## Test Plan

Schedule RPC authorization:

- missing or malformed `turn_ref` is rejected;
- stale revision or wrong transport route is rejected;
- reply route not associated with the current turn is rejected;
- empty `tool_call_id` or `idempotency_key` is rejected.

DB idempotency:

- concurrent schedule requests with the same idempotency key create one row;
- retrying an existing request returns `already_scheduled`;
- if Oban insert fails, the domain row rolls back;
- duplicate Oban jobs do not duplicate actor events.

Fire transaction:

- scheduled and due event appends one ActorEvent and marks fired;
- already fired, cancelled, failed, or not-due event is no-op;
- retry after partial failure is safe through the actor event source key;
- failed fire records retryable error without marking business no-op as error.

Time parsing:

- `check_back_later` rejects both/neither `after` and `at`;
- local `at` uses `system.timezone`;
- explicit offset timestamps stay absolute;
- past, too-near, too-far, and invalid timezone values are rejected;
- DST ambiguous and gap cases follow the daily-reset helper.

Cron recurrence:

- `every` stays on the anchored grid without drift;
- cron expressions are interpreted in their timezone;
- pause stops arming new events;
- resume recomputes next future fire;
- manual run does not move the recurrence schedule;
- backlog coalesces missed slots by default.

ActorRuntime and worker:

- `check_back_later.wakeup` starts a turn with `turn_mode = check_back_later`;
- `cron.fire` starts a turn with `turn_mode = cron`;
- prompt context marks both as schedule-origin events, not user messages;
- checkback default delivery creates provider-visible outbox even for unchanged
  or still-waiting results;
- an explicitly quiet checkback can complete via the noop marker and creates no
  outbox row;
- cron default delivery creates provider-visible outbox;
- cron quiet-success policy creates no outbox;
- visible checkback reply uses the original reply route;
- removal of the checkback's source entry cancels the checkback;
- cron fire ignores the schedule-creation entry tombstone.

Reset:

- pending checkbacks survive reset;
- due-before-reset, fired-after-reset checkback enters the successor
  conversation with due/fired timestamps;
- due-before-reset, fired-after-reset cron enters the successor conversation
  with its original slot and due/fired timestamps;
- materialized cron fires after the reset barrier remain queued and execute
  once in the successor conversation;
- reset does not cancel, re-arm, or advance cron recurrence.
