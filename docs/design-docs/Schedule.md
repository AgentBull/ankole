# Schedule

Schedule is the control-plane subsystem that turns time into actor work. An
Ankole agent does not wake up because time passed. A schedule records a future
obligation in PostgreSQL, the control plane materializes an `ActorInput` when the
obligation is due, and ActorRuntime starts the normal worker turn from that
input.

This document covers two user-visible schedule primitives:

- `check_back_later`: a one-shot self-wakeup the agent creates from an active
  turn when the current decision is better made later.
- `cron`: one recurring schedule that keeps producing future fires until it is
  paused, removed, or disabled.

They share the same durable fire path. They do not share the same product
meaning.

## Reference Semantics

BullX Agent's `check_back_later` is the closest reference for one-shot delayed
self-wakeup: the model supplies `reason`, `check`, and optional compact context;
the future wake runs as a distinct checkback turn; and the agent may stay silent
when nothing needs user attention.

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
Oban is the wake edge, and `ActorInput` remains the actor handoff.

## Core Invariants

`actor_scheduled_events` is the schedule truth. `oban_jobs` is only a wake-up
edge. An Oban job may be duplicated, retried, delayed, or rebuilt. It must never
be consulted as the source of product semantics.

All semantic idempotency is database-backed:

- domain idempotency is enforced by unique indexes on schedule rows;
- wake-up idempotency may use Oban uniqueness only as a noise reducer;
- fire idempotency is enforced by scheduled-event status plus the stable
  `ActorInput` ingress key.

The control plane owns time. Workers may request a schedule through RuntimeFabric
RPC, but workers do not own durable timers, recurrence, next-fire computation,
or schedule status.

Firing a schedule means appending an `ActorInput`. It does not mean choosing a
worker. Once the input is appended, ActivationManager and the existing worker
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
idempotency key, Oban wake edge, ActorInput, and terminal status.

```text
check_back_later tool
  -> actor_scheduled_events(kind = check_back_later)
  -> Oban wake edge
  -> ActorInput(type = check_back_later.wakeup)
  -> LlmTurn(kind = checkback_generation)

cron schedule definition
  -> actor_cron_schedules
  -> actor_scheduled_events(kind = cron_fire, cron_schedule_id = ...)
  -> Oban wake edge
  -> ActorInput(type = cron.fire)
  -> LlmTurn(kind = scheduled_task)
```

## Storage Shape

Use boring text statuses plus database check constraints, matching the current
ActorInput style. Do not introduce PostgreSQL enums for this v1.

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
- `source_llm_turn_id`, `source_actor_input_id`.
- `signal_channel_id`, `provider_thread_id`, `provider_entry_id`: reply route
  fields copied into the fired ActorInput when that is semantically correct.
- `source_provenance`: JSON object for audit-only facts such as transport route,
  authenticated worker id, key revision, source activation uid, actor epoch,
  source revision, and source RPC request id.
- `wake_payload`: JSON object used to build the future ActorInput payload.
- `oban_job_id`, `actor_input_id`.
- `fire_attempts`, `fire_claimed_at`, `fired_at`, `cancelled_at`.
- `last_fire_error`: JSON object.
- timestamps.

Indexes and constraints:

- unique `(kind, agent_uid, session_id, idempotency_key)`;
- unique `(cron_schedule_id, cron_fire_slot_at)` where `cron_schedule_id IS NOT
  NULL`;
- index `(status, due_at)`;
- index `(agent_uid, session_id, status, due_at)`;
- index `actor_input_id`;
- index `oban_job_id`;
- JSON object checks for `source_provenance`, `wake_payload`, and
  `last_fire_error`;
- non-empty checks for `timezone` and `idempotency_key`;
- status and kind check constraints.

The unique idempotency key should be permanent. If a tool call created a
schedule and that schedule was later cancelled, retrying the same tool call
returns the existing cancelled event rather than expressing a different
commitment with the same key.

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
- `delivery`: JSON object or null.
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

`check_back_later` uses `schedule.check_back_later.create`.

The request payload must include:

```json
{
  "request_id": "rpc request id",
  "turn_ref": { "...": "ActorTurnRef" },
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
  "reply_route": {
    "binding_name": "feishu-main",
    "signal_channel_id": "channel id",
    "provider_thread_id": "thread id",
    "provider_entry_id": "source entry id"
  }
}
```

The handler must:

1. validate the `turn_ref` shape;
2. authorize the authenticated RuntimeFabric route against that turn with
   `WorkerRouteAuth.authorize_turn_route(turn_ref, route, :write)`;
3. verify the requested reply route belongs to the current turn context or to an
   ActorInput referenced by the turn;
4. validate `tool_call_id` and `idempotency_key`;
5. parse time in the control plane using `system.timezone` as the default;
6. insert the `actor_scheduled_events` row;
7. insert the Oban wake job in the same transaction.

The response is stable across retries:

```json
{
  "status": "scheduled",
  "scheduled_event_id": "uuid",
  "due_at": "2026-06-27T10:30:00Z",
  "timezone": "Asia/Shanghai"
}
```

When the row already exists, return `status = "already_scheduled"` with the same
ids and timestamps.

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
append ActorInput with a stable ingress_event_id
mark scheduled event fired with actor_input_id
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

The Oban worker is `Ankole.ActorRuntime.Jobs.FireScheduledEvent`.

Its job args contain only:

```json
{ "scheduled_event_id": "uuid" }
```

The worker:

1. calls `ScheduledEvents.fire_due_event(event_id)`;
2. treats `:noop` as success;
3. returns errors only for transient or real failures;
4. wakes ActivationManager after a committed ActorInput append.

A scheduled event enters `failed` only through domain code, not by reading Oban
as schedule truth. Permanent validation failures should mark the event failed in
a transaction and then have the worker return `:ok` or `{:cancel, reason}` so
Oban does not retry. Transient failures return `{:error, reason}`. If Oban
eventually discards a wake job, a reconciler may mark the scheduled event failed
or re-arm it according to the schedule's failure policy.

Oban uniqueness may be set on `(worker, scheduled_event_id)` for states such as
scheduled, available, executing, and retryable. This is not a correctness
guarantee. Correctness is the scheduled-event claim plus ActorInput ingress
idempotency.

The fired ActorInput ingress key is stable:

```text
check_back_later:<scheduled_event_id>:wakeup
cron:<cron_schedule_id>:<cron_fire_slot_at_iso8601>
```

The scheduled-event claim is the primary idempotency guard. The appended
ActorInput also uses `(agent_uid, binding_name, ingress_event_id)` as its live
handoff key, so retries inside the firing window converge to one open
ActorInput.

## Actor Inputs And Turns

`check_back_later` fires:

```text
ActorInput.type = check_back_later.wakeup
LlmTurn.kind = checkback_generation
request_context.turn_mode = check_back_later
```

`cron` fires:

```text
ActorInput.type = cron.fire
LlmTurn.kind = scheduled_task
request_context.turn_mode = cron
```

ActorRuntime must explicitly branch on these input types. They must not fall
through as ordinary `generation` turns.

Schedule prompt facts travel on `turn_start.request_context`. The worker reads
`schedule_origin`, `turn_mode`, and `silent_success_allowed` from that current
turn payload while building the system prompt. They are not conversation
history and are not returned by `agent_conversation.context.resolve`.

`ActorInputTypes.consumption_path/1` should include explicit entries:

```text
check_back_later.wakeup -> direct
cron.fire -> direct
```

`ActorInputTypes.stale_after_session_reset?/1` should keep the existing behavior
for `cron.*`: already-materialized cron notices are stale after a reset barrier.
`check_back_later.wakeup` is not stale by default.

## Prompt Contract

The worker prompt should expose schedule-origin context as a runtime fact, not
as human-authored text.

For `check_back_later`:

- say this is a one-shot delayed self-wakeup scheduled earlier by the agent;
- say it is not a user message, heartbeat, cron, or recurring monitor;
- include `due_at`, `fired_at`, `reason`, `check`, and `context_summary`;
- use the context as background, not as permission to replay old tasks;
- if nothing needs user attention, the agent may finish silently;
- if the check is still legitimately blocked, the agent may schedule a new
  one-shot checkback.

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
- optional `provider_entry_id`.

`schedule_provenance` is audit and authorization context:

- source turn id;
- source actor input ids;
- source tool call id;
- RPC request id;
- authenticated worker id;
- authenticated key revision;
- transport route;
- source actor epoch and revision.

Fire must never use `schedule_provenance.transport_route` to choose a worker.
That route may be stale. Fire appends an ActorInput and lets ActorRuntime
schedule live work.

For `check_back_later`, copy the original `provider_entry_id` into the fired
ActorInput by default. If the original entry was deleted or recalled before the
checkback is consumed, the existing tombstone guard cancels the input. This is
the conservative behavior: do not produce a visible reply anchored to withdrawn
content.

For cron, do not copy the creation message's `provider_entry_id` into recurring
fire ActorInputs. A recurring schedule should not stop forever because the chat
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

Deleted schedules do not arm new events. Already-fired ActorInputs and committed
turns are history. Still-scheduled future events are cancelled transactionally
when the schedule is deleted.

## Reset Semantics

`check_back_later` is an agent commitment to revisit one concrete question. It
survives daily reset. If its `due_at` was before reset but Oban fires it after
reset, the fired input enters the successor active conversation and carries both
the original due time and actual fired time.

Cron definitions survive reset. Individual already-materialized `cron.fire`
ActorInputs are session-local system notices and remain stale after reset, as
the current `cron.*` reset rule already says. A cron definition whose fire was
discarded by reset computes a later fire through the normal recurrence path.

This distinction keeps one-time agent promises durable while still preventing
old routine system notices from crossing a session reset barrier.

## Delivery And Silent Success

Checkback delivery is conservative. It should only produce a visible provider
reply when the user needs attention: meaningful result, blocker, requested
decision, or time-sensitive risk. Silent success is normal.

Cron delivery is schedule-defined. A recurring report usually delivers the final
assistant output every run. A monitoring schedule may opt into quiet success, in
which case a clean run can commit without provider-visible output.

The commit coordinator must allow silent success for schedule-origin turns when
their request context permits it. Silent success still consumes the ActorInput
and marks the turn succeeded. It just creates no outbox row.

Silent success is still a normal worker commit. The worker must send a
`turn_final_proposal` with an explicit `silent_success` marker in response,
request context, or metadata. CommitCoordinator must then:

- mark the `LlmTurn` succeeded;
- consume the `ActorInput`;
- create no provider outbox row;
- either create no assistant `Message` or create an internal/introspection
  `Message`, according to the schedule-origin policy;
- record enough response metadata for audit and debugging.

The worker must not express silent success by failing to send a final proposal.
The turn still needs a fenced, committable, auditable terminal result.

Provider-visible output uses normal `signal_gateway_outbox` rows. The scheduler
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

- `check_back_later`: create a one-shot delayed self-wakeup;
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
- duplicate Oban jobs do not duplicate ActorInputs.

Fire transaction:

- scheduled and due event appends one ActorInput and marks fired;
- already fired, cancelled, failed, or not-due event is no-op;
- retry after partial failure is safe through the ActorInput ingress key;
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

- `check_back_later.wakeup` starts `checkback_generation`;
- `cron.fire` starts `scheduled_task`;
- prompt context marks both as schedule-origin events, not user messages;
- checkback silent success consumes the input and creates no outbox;
- cron default delivery creates provider-visible outbox;
- cron quiet-success policy creates no outbox;
- visible checkback reply uses the original reply route;
- checkback source entry tombstone cancels consumption;
- cron fire ignores the schedule-creation entry tombstone.

Reset:

- pending checkbacks survive reset;
- due-before-reset, fired-after-reset checkback enters the successor
  conversation with due/fired timestamps;
- materialized cron fires after the reset barrier are stale;
- cron definitions survive reset and continue with later fires.
