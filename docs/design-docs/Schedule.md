# Schedule

Schedule starts one consumer at a requested time. The consumer is an Agent
session by default. It can also be an automation job. PostgreSQL stores what
must happen and when. Oban wakes the control plane when that time arrives.

Users can create two kinds of schedules:

- `check_back_later` wakes the same Agent session once.
- `cron` runs a task on a recurring schedule, in the rule's own execution
  session.

Both create one `actor_scheduled_events` row for each actual wake-up.

## The Control Plane Owns Time

The Elixir control plane calculates times, stores schedules, and changes their
state. Workers can request these operations through RPC, but they do not keep
the timers.

`actor_scheduled_events` stores each wake-up. `actor_cron_schedules` stores each
recurring rule. `oban_jobs` only tells Oban when to call Schedule.

Database keys and ActorEvent source IDs prevent an Oban retry from creating the
same work twice.

## What PostgreSQL Stores

### One Wake-Up

`actor_scheduled_events` stores one planned wake-up.

Its ID is a PostgreSQL identity bigint that starts at `1000` and cannot exceed
JavaScript's maximum safe integer. Model tools call it `checkback_id` and use a
number. RuntimeFabric carries it as a canonical decimal string.

The `kind` value is one of:

- `check_back_later`
- `cron_fire`

The `status` value is one of:

- `scheduled`
- `firing`
- `fired`
- `cancelled`
- `failed`

Each row stores the Agent, the execution session, binding, due time, time
zone, and key that prevents duplicates. The execution session is the session
the wake-up runs in: the creating session for a checkback, and the rule's
derived `cron:<schedule_id>` session for a cron fire. The row can also store
the source ActorEvent, AI message, and provider reply route.

`wake_payload` contains the input for the future turn. `source_provenance`
records the authenticated request and the turn-fence values that created it.

The row records its Oban job ID and, after wake-up, the new ActorEvent ID.

Checkbacks and manual cron runs use this request idempotency key:

```text
(kind, agent_uid, session_id, idempotency_key)
```

An automatic cron event gets a new internal key when Schedule creates the row.
Schedule does not use a previous terminal row as proof that a new row exists.

Automatic cron events also use this partial unique key:

```text
(cron_schedule_id, cron_fire_slot_at)
WHERE trigger = scheduled AND status != cancelled
```

Thus, a canceled row releases its slot. A fired or failed row continues to
consume its logical slot. Manual runs do not use this slot key.

Another partial unique index permits at most one automatic cron event with
`status = scheduled` or `status = firing` for each recurring rule.

### One Recurring Rule

`actor_cron_schedules` stores one recurring rule.

Its UUID is internal. Model tools address a recurring rule by its unique stable
`name`. A turn caused by that rule can inspect itself without receiving either
identifier.

The `status` value is one of:

- `active`
- `paused`
- `deleted`
- `completed`

Each row stores the Agent, the owner conversation (`owner_session_id`),
binding, time rule, time zone, input, and delivery targets. It also records
the previous and next planned wake-up.

The creation idempotency key is:

```text
(agent_uid, owner_session_id, idempotency_key)
```

When present, a name must be unique among the Agent's active rules.

### The Cron Execution Session

A Session orders Turns that must share one exact conversation history. A cron
fire does not continue the owner conversation, so it does not run in it.

Each rule derives one stable execution session: `cron:<schedule_id>`.
`owner_session_id` keeps only the management scope. The owner session must not
be a derived cron execution session.

This split gives these guarantees:

- Fires of one rule run one at a time, in order, with the rule's own AIGateway
  conversation, history, and Workspace.
- A long fire does not block user messages in the owner conversation, and
  different rules do not block each other.
- The fire keeps the delivery `signal_channel_id`, so it replies to the
  configured channel.

A direct-Agent rule must store its complete standing instruction in
`payload.task`. A fire never sees the owner conversation transcript. A user
reply to a delivered cron message goes to the owner conversation, which sees
the delivered message as channel context, not the fire's internal history.

An update that changes `payload` or `delivery` ends the rule's active
AIGateway conversation, and the next fire starts a new one from the current
rule. Time-only changes keep the conversation. Removal or completion also
ends the conversation, so the daily session reset stops selecting the dead
session. The reset applies immediately even while a fire runs; that fire
completes into the ended conversation by id.

## Set the Time for One Checkback

A checkback must use either a relative delay or one date and time.

Use a relative delay:

```json
{
  "after": { "value": 30, "unit": "minutes" },
  "timezone": "Asia/Singapore"
}
```

For a date and time, use:

```json
{
  "at": "2026-07-20T09:00:00",
  "timezone": "Asia/Singapore"
}
```

Relative units range from milliseconds through weeks.
The default minimum delay is one second.
The default maximum horizon is 366 days.

If the request omits a time zone, the control plane uses `system.timezone`. It
uses the IANA database to convert local time to an instant.

## Repeat at an Interval or Cron Time

A recurring rule can use a fixed interval or a cron expression.

A fixed interval uses an absolute anchor:

```json
{
  "kind": "every",
  "every_ms": 3600000,
  "anchor_at": "2026-07-20T00:00:00Z"
}
```

A cron expression uses five or six fields:

```json
{
  "kind": "cron",
  "expression": "0 9 * * *",
  "timezone": "Asia/Singapore"
}
```

The planner finds the first matching instant after the reference time. The
configured time zone determines daylight-saving behavior.

## Create, Change, or Cancel a Checkback

One transaction stores the checkback and its Oban job. Repeating the request
with the same key returns the existing checkback.

A checkback contains these model-visible fields:

- `checkback_id` after it is stored
- `reason`
- `check`
- optional `context_summary`
- `quiet_success`

`reason` accepts 2,000 characters.
`check` accepts 4,000 characters.
`context_summary` accepts 8,000 characters.

`quiet_success` defaults to `false`.
When it is `true`, the future turn can return exactly `<silent_success/>`.

Agent Computer then completes the turn without sending a provider message.
Failures, changed state, or a need for human action still require a visible
reply.

Updating a pending checkback creates a new row, cancels the old row, and links
the two.

Canceling a checkback changes its state to `cancelled`.
Removing its source provider entry also cancels matching pending checkbacks.

## Create, Pause, or Change a Recurring Rule

Creating an active rule also plans its first wake-up. Each successful wake-up
plans the next one in the same transaction.

Schedule locks the recurring rule before it changes or fires an automatic
event. An active rule has exactly one automatic event. The event due time and
slot equal `next_fire_at`. A paused or deleted rule has no automatic event and
has no `next_fire_at`.

When an update keeps the next slot, Schedule updates the pending event snapshot
in place. This applies to changes such as the name, input, or delivery route.
The existing Oban job continues to refer to the same event.

When an update changes the next slot, Schedule cancels the old event and
inserts a new event. A canceled history row does not block a new event for the
same slot.

Pausing clears `next_fire_at` and cancels pending wake-ups. Resuming calculates
the next time from the moment of resumption. Resuming an active rule verifies
the current event and does not create another event.

Removing a rule marks it `deleted` and cancels all pending wake-ups.

A manual run creates an immediate wake-up without changing the recurring rule.
It works for an active or paused rule. The caller must provide a request key.
RuntimeFabric uses the provider tool call ID, and REST uses `Idempotency-Key`.
Repeating the same request returns the same event.

Cron delivery uses this form:

```json
{
  "targets": [
    {
      "binding_name": "lark-primary",
      "signal_channel_id": "lark:channel-a"
    },
    {
      "binding_name": "lark-record",
      "signal_channel_id": "lark:channel-b",
      "provider_thread_id": "thread-b"
    }
  ],
  "quiet_success": false
}
```

The list must contain at least one target. Each target requires a binding and a
channel. A provider thread is optional. Duplicate binding, channel, and thread
tuples are invalid.

The first target is the primary target. Its binding must equal the recurring
rule's binding. Schedule copies that route into the scalar fields on the
ScheduledEvent and ActorEvent, so the one Agent turn and its live preview keep
one route. The full target list is frozen in the event `wake_payload`.

An operator can add targets through the Console or REST API. A worker-originated
request can create or replace only the current turn route. A worker can change
`quiet_success` on an operator-managed multi-target rule without replacing its
targets. An operator route update that omits `quiet_success` keeps the existing
value.

The control plane accepts the old scalar delivery form as input and normalizes
it to one target. The data migration normalizes stored recurring rules and live
`scheduled` or `firing` event snapshots. Terminal event history and existing
outbox rows stay unchanged and are never replayed. A downgrade can convert a
one-target rule back to the scalar form, but it stops if any rule has multiple
targets because that conversion would lose configured routes.

A direct-Agent rule requires a non-empty `payload.task` at creation, and an
update must keep it unless an `automation_job_id` consumes the trigger.

Cron turns can use quiet success only when the delivery object enables it.

## What Happens When the Time Arrives

The wake path is:

```text
scheduled event row
  -> Oban wake job
  -> claim due row
  -> ActorEvent append or automation job run insert
  -> mark row fired
  -> ActorRuntime turn or automation job execution
```

Oban can run `FireScheduledEvent` ten times. Each call tells Schedule which
attempt it is.

The transaction claims only a due row with `status = scheduled`. It changes the
state to `firing` and increases `fire_attempts`.

A checkback fire produces `check_back_later.wakeup`.
A cron fire produces `cron.fire`.

The event uses a CloudEvents 1.0 envelope. It contains the scheduled event
identifier, due time, fire time, time zone, primary reply route, and frozen
delivery targets. A direct consumer stores this envelope in an ActorEvent. An
automation job consumer stores the same envelope in its run. The model wake-up
prompt omits the event identifier and delivery routes.

After it writes the consumer record, Schedule changes the row to `fired`. It
records `actor_event_id` for a direct consumer or `automation_job_run_id` for
an automation job consumer. It also records `fired_at`.

A repeated wake does nothing when the row has ended or is not due. If the
recurring rule is no longer valid, Schedule cancels that wake-up.

A retryable error restores `scheduled` for another Oban attempt. After the final
failure, Schedule changes the row to `failed`. If this was an automatic cron
event and the rule is still active, Schedule plans the next slot in the same
transaction. A manual run never moves the recurring cursor.

Every cron write uses this lock order:

```text
CronSchedule
  -> ScheduledEvent
  -> ActorEvent
```

An old Oban job refers to a ScheduledEvent ID. If an update canceled that
event, the job cannot claim it because only a `scheduled` event can fire.

Model projections return a stable domain reason for a known cancellation or
failure. They map all other stored diagnostics to `schedule_fire_failed` and do
not expose request, ActorEvent, Oban, or provider identifiers. The Console keeps
the complete stored diagnostic for operators.

## Tell the Agent Why It Woke Up

ActorRuntime maps scheduled ActorEvents to dedicated turn kinds:

| ActorEvent type | Turn kind | `turn_mode` |
| --- | --- | --- |
| `check_back_later.wakeup` | `checkback_generation` | `check_back_later` |
| `cron.fire` | `scheduled_task` | `cron` |

The request tells the Agent which schedule woke it and whether it can report
success without a reply. A cron turn also says that Ankole will deliver the
configured output. The Agent runs once even when the rule has multiple targets.
After completion, SignalsGateway stores one target-scoped outbox intent for each
target. A BackgroundAgentJob created by that turn keeps the same frozen targets
for its terminal notification. Interactive clarification stays on the primary
target.

The model must not send the same cron result through another messaging tool.

## Schedule through RPC

The RPC API provides these checkback operations:

- `create`
- `list`
- `get`
- `update`
- `cancel`

The RPC API provides these cron operations:

- `list`
- `get`
- `runs`
- `add`
- `update`
- `pause`
- `resume`
- `remove`
- `run`

RPCLane authenticates the worker before it calls `Schedule.RPCBroker`. The
broker limits every checkback read or change to the current Agent and Session,
and every cron read or change to the current Agent and the rule's owner
conversation. A cron-origin turn resolves only its own rule through fire
provenance.

Checkback creation and update require an exact reply-route match. A
worker-originated cron route must contain exactly one target and match the
current binding and channel.
An optional `automation_job_id` must name an active job for the same Agent.
Checkback and cron updates can clear or replace this binding.

A cron-originated turn cannot add, update, pause, resume, remove, or manually
run cron definitions. This prevents one cron turn from creating an uncontrolled
set of more cron rules.

## Rules

- PostgreSQL stores every schedule that can affect a user.
- Oban wakes Schedule but does not define the time rule.
- An active recurring rule has exactly one pending automatic event.
- A canceled automatic event can be replaced in the same slot.
- A fired or failed automatic slot cannot run again.
- One scheduled event creates at most one ActorEvent or automation job run.
- A cron fire runs in the rule's derived execution session, never in the
  owner conversation.
- A direct-Agent rule stores its complete standing instruction in
  `payload.task`.
- A worker cannot add an unrelated provider route to a schedule.
- One cron event runs at most one Agent turn, independent of its target count.
- A cron-originated turn cannot change or manually run cron definitions.
- A canceled source entry cannot retain a pending checkback.
- The schedule row must explicitly allow success without a reply.
