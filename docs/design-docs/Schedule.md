# Schedule

Schedule starts one consumer at a requested time. The consumer is an Agent
session by default. It can also be an automation job. PostgreSQL stores what
must happen and when. Oban wakes the control plane when that time arrives.

Users can create two kinds of schedules:

- `check_back_later` wakes the same Agent session once.
- `cron` runs a task on a recurring schedule, in the rule's own execution
  session.

Checkbacks and manual cron runs store their event before wake-up. Automatic
cron fires create an `actor_scheduled_events` history row when they fire.

## The Control Plane Owns Time

The Elixir control plane calculates times, stores schedules, and changes their
state. The control-plane conversation tools call this owner directly.

`actor_scheduled_events` stores one-shot wake-ups and cron history.
`actor_cron_schedules.next_fire_at` is the only domain fact for the next
automatic fire. Each active rule has one pending `FireCron` job. `oban_jobs`
only tells Oban when to call Schedule.

Database keys and ActorEvent source IDs prevent an Oban retry from creating the
same work twice.

## Human Work Authorization

Both scheduled events and cron rules store `authorization_kind`, `human_uid`,
and `human_access_version` under [Human Offboarding](HumanOffboarding.md).
Checkbacks inherit the source ActorEvent. Cron creation uses the trusted
`created_by` option from the authenticated turn or Console Principal; request
body fields cannot replace it. New fires inherit the rule's retained version.

Fire admission checks and locks each associated Human before the event, cron,
and bound Automation Job. Automatic fires use the rule authorization; their
history and ActorEvent inherit it at fire time. When the work and job depend on different Humans,
it locks both in UID order. Revocation pauses old cron rules and cancels pending
fires and checkbacks. An admitted fire may finish, but completion cannot create
another valid fire. Resume or manual run does not renew an old authorization.

## What PostgreSQL Stores

### One Wake-Up

`actor_scheduled_events` stores a planned checkback or manual run, or an
automatic cron fire history row.

Its ID is a PostgreSQL identity bigint that starts at `1000` and cannot exceed
JavaScript's maximum safe integer. Model tools call it `checkback_id` and use a
number.

The `kind` value is one of:

- `check_back_later`
- `cron_fire`

The `status` value is one of:

- `scheduled`
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

After wake-up, the row records the new ActorEvent or automation run ID.
The Oban job arguments identify its owning event or rule.

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

Schedule inserts automatic history before it creates work, in the same
transaction. The slot key rejects a second fire of that slot.

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
Scheduled turns finish through the `finish_scheduled(outcome, reply)` tool.
A visible result uses `outcome: "reply"` and a nonempty reply string. When
`quiet_success` is true, a successful check without a useful update can use
`outcome: "silent_success"` and a null reply. Failures, changed state, or a
need for human action require a visible reply. Ordinary turns do not expose
this termination tool.

The tool validates the arguments and silent-success permission. An invalid
call returns a normal tool error, so the model can correct it in its tool loop.
An accepted result ends the turn. Its outcome and visible text are recorded
with the tool journal in Conversations' typed round state; recovery reads that
result without executing the termination tool again. Scheduled turns do not
use a JSON response format or a separate format-repair round.

A turn that ends with nonempty ordinary text and no accepted termination result
completes as a visible reply. Silent success still requires an accepted
`finish_scheduled` call. A turn with neither result becomes a dead letter.
The same transaction stores its failure reason and Response anchor, ends the
applied input prefix, releases the turn, and queues the standard failure notice
for the current reply owner. Unapplied instructions stay queued. Repeated
completion requests return the same rejection without another notice. Lease
expiry cannot run the failed task again; recorded tool results stay in the tape.

Raw scheduled model text is never streamed to a channel, including after a
preview owner changes. The accepted tool reply or the completed ordinary text
enters the final outbox. Clarify and attachment tools keep their existing delivery contracts.
Text markers have no control meaning.

Updating a pending checkback changes the same row in place, so `checkback_id`
does not change. When the due time changes, Schedule moves the Oban job. A row
that an earlier version replaced returns `checkback_replaced` to get, update,
and cancel.

Canceling a checkback changes its state to `cancelled`.
Removing its source provider entry also cancels matching pending checkbacks.

## Create, Pause, or Change a Recurring Rule

Creating an active rule stores its first `next_fire_at` and schedules its
`FireCron` job. A successful automatic fire stores history and the next time
in the same transaction.

Schedule locks the recurring rule before it changes or fires it. Automatic
fires read the current payload and delivery at fire time. A payload-only
update keeps `next_fire_at`. A time-rule update calculates a new time. Both
move or restore the one pending FireCron job to the retained time. An executing
job keeps its claim; a new pending job receives the next wake-up.

Pausing clears `next_fire_at`. Its old job returns noop. Resuming calculates
the next time from the moment of resumption. Resuming an active rule schedules
its existing `next_fire_at` again.

Removing a rule marks it `deleted`, clears `next_fire_at`, ends the execution
conversation, and cancels pending manual runs.

A manual run creates an immediate wake-up without changing the recurring rule.
It works for an active or paused rule. The caller must provide a request key.
Agent tools use the provider tool call ID, and REST uses `Idempotency-Key`.
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

An operator can add targets through the Console or REST API. An Agent tool
request can create or replace only the current turn route. An Agent can change
`quiet_success` on an operator-managed multi-target rule without replacing its
targets. An operator route update that omits `quiet_success` keeps the existing
value.

The control plane accepts only the target-list delivery form. The v0.68.3 data
migration normalized stored recurring rules and live `scheduled`
event snapshots. Terminal event history and existing outbox rows stayed
unchanged and were never replayed.

A direct-Agent rule requires a non-empty `payload.task` at creation, and an
update must keep it unless an `automation_job_id` consumes the trigger.

Cron turns can use quiet success only when the delivery object enables it.

## What Happens When the Time Arrives

The automatic wake path is:

```text
cron rule.next_fire_at
  -> FireCron job
  -> lock and authorize rule
  -> insert fired history for the slot
  -> ActorEvent append or automation job run insert
  -> record consumer id and advance next_fire_at
  -> Conversations driver or automation job execution
```

Checkbacks and manual runs use `FireScheduledEvent`. Their transaction locks
only a due row with `status = scheduled`, creates its consumer, and changes the
row to `fired`. A repeated call returns noop for a terminal or future event.
Manual runs do not advance the recurring cursor.

Both workers allow ten attempts. Checkback and manual errors retain their
scheduled row and diagnostic until the last attempt marks it `failed`.
Automatic errors are recorded by Oban during retry. The last failure creates a
`failed` history row and advances an active rule whose slot is still current.
Fired and failed automatic slots count toward the occurrence bound; manual
runs do not. An exhausted rule becomes completed and ends its conversation.

A checkback fire produces `check_back_later.wakeup`.
A cron fire produces `cron.fire`.

The event uses a CloudEvents 1.0 envelope. It contains the history or scheduled
event identifier, due time, fire time, time zone, primary reply route, and
frozen delivery targets. A direct consumer stores this envelope in an
ActorEvent. An automation job consumer stores the same envelope in its run.
The model wake-up prompt omits the event identifier and delivery routes.

Schedule records `actor_event_id` for a direct consumer or
`automation_job_run_id` for an automation job consumer, and `fired_at`.
An invalid recurring rule records a cancelled history row without advancing.

Fire admission locks Human sources in UID order before the rule. The remaining
lock order is CronSchedule, ScheduledEvent, then ActorEvent. A FireCron job
checks the current rule state and time, so an old job cannot fire a paused,
deleted, completed, or future rule. After downtime, it fires the retained slot
once and calculates the next time from the current time.

Model projections return a stable domain reason for a known cancellation or
failure. They map all other stored diagnostics to `schedule_fire_failed` and do
not expose request, ActorEvent, Oban, or provider identifiers. The Console keeps
the complete stored diagnostic for operators.

## Tell the Agent Why It Woke Up

Conversations maps scheduled ActorEvents to dedicated turn kinds:

| ActorEvent type | Turn kind | Agent schedule mode |
| --- | --- | --- |
| `check_back_later.wakeup` | `checkback_generation` | `check_back_later` |
| `cron.fire` | `scheduled_task` | `cron` |

The control plane derives the schedule mode from the ActorEvent type. The request
context carries the schedule origin and whether the Agent can report success
without a reply; it does not repeat the mode. A cron turn also says that Ankole
will deliver the configured output. The Agent runs once even when the rule has
multiple targets. After completion, SignalsGateway stores one target-scoped
outbox intent for each target. A BackgroundAgentJob created by that turn keeps
the same frozen targets for its terminal notification. Interactive clarification
stays on the primary target.

The model must not send the same cron result through another messaging tool.

## Schedule Tools

The `check_back_later` and `cron` tools execute in the control-plane Driver.
Checkback operations are `create`, `list`, `get`, `update`, and `cancel`. Cron
operations are `list`, `get`, `runs`, `add`, `update`, `pause`, `resume`, `remove`,
and `run`.

The tool receives the Driver's fenced Run. Reads and writes stay within the
current Agent and Session or the rule's owner conversation. Reply routes come
from the current input. Cron provenance uses `driver_epoch` and the frozen route.
A turn in a rule's execution session resolves only that rule.

An optional `automation_job_id` must name an active job for the same Agent.
Checkback and cron updates can clear or replace this binding.

A turn in a rule's execution session can use only `list`, `get`, `runs`, and
`pause`, and only on that rule. Pause lets a fire stop work whose task says to
stop once a condition is met. Pause does not end the execution conversation, so
the turn still delivers its reply. The turn cannot add rules, change its own
instruction, resume itself, run itself again, or remove its rule; removal ends
the execution conversation that the turn runs in.

## Rules

- PostgreSQL stores every schedule that can affect a user.
- Oban wakes Schedule but does not define the time rule.
- An active recurring rule has one pending FireCron job at `next_fire_at`.
- Automatic cron run lists contain history only.
- A fired or failed automatic slot cannot run again.
- One scheduled event creates at most one ActorEvent or automation job run.
- A cron fire runs in the rule's derived execution session, never in the
  owner conversation.
- A direct-Agent rule stores its complete standing instruction in
  `payload.task`.
- An Agent tool cannot add an unrelated provider route to a schedule.
- One cron event runs at most one Agent turn, independent of its target count.
- A cron-originated turn can only inspect or pause its own rule.
- A canceled source entry cannot retain a pending checkback.
- The schedule row must explicitly allow success without a reply.
