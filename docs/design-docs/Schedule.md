# Schedule

The Schedule subsystem wakes a single consumer—an Agent Session by default, or
an Automation Job when bound—at a requested time. PostgreSQL is the durable
authority for what must run and when, while Oban acts strictly as the timer
that wakes the control plane when a deadline arrives.

Users and Agents can create two kinds of schedules:

- **`check_back_later`**: Wakes the originating Agent Session once.
- **`cron`**: Runs a recurring task inside a dedicated execution Session derived
  from the rule.

Checkbacks and manual cron triggers persist a `scheduled_events` row *before*
wake-up, whereas automatic cron triggers insert a `scheduled_events` history row
at fire time. Both `CronSchedule` and `ScheduledEvent` model their lifecycles
with `AshStateMachine`: pausing, deleting, or completing a cron rule clears
`next_fire_at` in the same statement, a PostgreSQL `CHECK` constraint forbids a
non-null `next_fire_at` on any Cron status other than `active`, and updates,
fires, and Human access revocations all acquire locks in the same canonical
order.

`Ankole.Schedule` is the root Ash domain:

- Every public write entry point opens `Repo.transact_top_level/2`—covering
  checkback `create`, `update`, and `cancel`; cron `create`, `update`, `pause`,
  `resume`, `remove`, and `run`; plus `fire_due_event` and `fire_cron`—while
  Console `/api/v2` routes expose generic actions on `ScheduledEvent` and
  `CronSchedule`. If a fire fails, Ankole rolls back the attempt transaction and
  records the failure diagnostic in a second top-level transaction.
- Callers already inside an open transaction—such as the Sessions schedule tools
  committing inside their tool-receipt transaction—compose `*_in_tx` helpers on
  `Schedule.Checkbacks` and `Schedule.Cron`. Reads and row locks use Ash
  queries.
- `ScheduledEvent` actions type-check durable attributes directly: structured
  provenance, wake payloads, and error diagnostics use the shared strict JSON
  object type, and the TimeZone owner validates modified timezone strings.
  Failure and cancellation actions validate only their own diagnostic fields so
  they can still record compensation even when a row's execution target is
  broken.

## The Control Plane Owns Time

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
- Cron creation reads the trusted `created_by` option from the authenticated
  turn or Console Principal—ignoring any actor fields in the request body—and
  subsequent fires inherit the rule's stored version.

At fire admission, Schedule locks and verifies every associated Human *before*
locking the event, cron rule, or bound Automation Job (locking both Humans in
ascending UID order when the schedule and the bound Automation Job depend on
different Humans). Automatic fires validate against the rule's authorization and
copy it onto the history row and Signal at fire time. Revoking a Human's access
pauses their active cron rules and cancels pending fires and checkbacks: an
already admitted fire may finish its current turn, but completing that turn
cannot schedule another valid fire, and resuming or manually running a rule
never renews a revoked authorization.

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
`cron:<schedule_id>` Session for `cron_fire`), Binding, due timestamp, time
zone, deduplication key, optional source Signal, AI message, and provider reply
route. `wake_payload` holds the prompt/input for the future execution,
`source_provenance` captures the authenticated request and turn-fence metadata
that created the row, Oban job args point back to the owning event or rule, and
waking the consumer records the resulting `signal_id` or
`automation_job_run_id`.

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

Both Schedule and raw Webhook delivery dispatch work through
`Signals.Trigger.deliver_in_tx/4`: when `automation_job_id` is set (enforced by
a foreign key), it inserts a durable `AutomationJob` run; when unbound, it
appends a Signal in the owning domain, storing typed `signal_id` and
`automation_job_run_id` references on each source table.

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

### One Recurring Rule

`cron_schedules` stores recurring rules. Its UUID primary key stays internal:
model tools address a rule by its non-blank `name` (unique across the Agent's
active rules), and a turn running inside that rule's execution Session can
inspect its own rule without passing either identifier.

PostgreSQL restricts `cron_schedules.status` to four values (individual fire
failures live on `ScheduledEvent` history rows rather than adding a fifth Cron
status):

- `active`
- `paused`
- `deleted`
- `completed`

Each row stores the Agent, `owner_session_id` (management scope), Binding,
recurrence rule, time zone, task input, delivery targets, and the prior and next
planned wake-up timestamps, deduplicated on creation by:

```text
(agent_uid, owner_session_id, idempotency_key)
```

### The Cron Execution Session

Because a Session serializes Turns that share one linear model transcript, a
cron fire must not run inside `owner_session_id`. Instead, every rule derives a
dedicated execution Session `cron:<schedule_id>` while `owner_session_id`
tracks management ownership (and cannot itself be a `cron:*` Session).

Separating the two Sessions provides three guarantees:

- Fires of a single rule execute sequentially with the rule's own AIGateway
  conversation, transcript, and Workspace.
- Long-running cron turns never block interactive user turns in
  `owner_session_id`, and separate cron rules never block one another.
- Output targets use public Conversation UUIDs: Pod output commits as native
  Agent Messages, and external channel output writes Delivery intents for the
  configured routes.

Because a cron fire never sees the `owner_session_id` transcript, a direct-Agent
rule must store a self-contained standing instruction in `payload.task`. When a
human replies to a delivered cron message in chat, that reply routes to
`owner_session_id`, which sees the committed cron Message as shared Conversation
context rather than the cron Session's internal tool history.

Editing `payload` or `delivery` closes the rule's active AIGateway conversation
so the next fire starts a fresh conversation from the updated definition,
whereas time-only edits keep the conversation open. Deleting or completing a
rule likewise closes its AIGateway conversation so daily session resets stop
selecting it; if a fire is already mid-turn when the conversation closes, that
turn finishes writing into the closed conversation by ID.

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
- `quiet_success` (boolean, default `false`)

Scheduled turns—and never ordinary turns—expose the
`finish_scheduled(outcome, reply)` termination tool:

- For a user-visible update, the model calls `outcome: "reply"` with a non-empty
  `reply` string. Whenever a check fails, observes changed state, or needs human
  action, the model must send a visible reply.
- Only when `quiet_success` is `true` and nothing noteworthy changed may the
  model call `outcome: "silent_success"` with `reply: null`.
- Invalid arguments or disallowed `silent_success` calls return a standard tool
  error so the model can self-correct within its tool loop; scheduled turns do
  not use constrained JSON response formats or extra rounds to repair output
  formatting.

Accepting `finish_scheduled` ends the turn and records its outcome and reply
text alongside the tool journal in Sessions' typed round state so recovery reads
that committed outcome without re-running `finish_scheduled`. If a scheduled
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

All rule mutations and fires lock the `cron_schedules` row first, and automatic
fires read live `payload` and `delivery` at fire time:

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
      "conversation_id": "019a2b00-0000-7000-8000-000000000041"
    },
    {
      "binding_name": "lark-record",
      "conversation_id": "019a2b00-0000-7000-8000-000000000042",
      "provider_thread_id": "thread-b"
    }
  ],
  "quiet_success": false
}
```

Every target requires `conversation_id`: native Pod targets omit `binding_name`,
external targets add `binding_name` plus optional `provider_thread_id`, and
duplicate `(conversation_id, binding_name, provider_thread_id)` tuples are
rejected. The first entry is the primary target—its `binding_name` (when
present) must match the rule's Binding, and Schedule copies that primary route
onto `ScheduledEvent` and `Signal` while freezing the full `targets` list inside
`wake_payload`. Disabling a provider Binding does not block the cron turn from
executing; each outbound Delivery enforces its own route and error policy after
completion. Cron turns may use `silent_success` only when `delivery.quiet_success`
is `true`.

Operators can configure multiple targets via the Console or REST API (omitting
`quiet_success` on a route edit keeps the stored boolean), whereas Agent tool
calls can create or replace only the current turn's route—though an Agent may
toggle `quiet_success` on an operator-configured multi-target rule without
overwriting its `targets`. Direct-Agent rules require a non-empty `payload.task`
at creation and across updates unless bound to an `automation_job_id`.

## What Happens When the Time Arrives

When `next_fire_at` arrives, automatic cron execution follows a single pipeline:

```text
cron rule.next_fire_at
  -> FireCron job
  -> lock and authorize rule
  -> insert fired history for the slot
  -> Signals.accept_in_tx or automation job run insert
  -> record consumer id and advance next_fire_at
  -> Sessions driver or automation job execution
```

Checkbacks and manual runs execute via `FireScheduledEvent`, which locks a due
row with `status = scheduled`, dispatches its consumer, and transitions the row
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
  at fire time, Schedule writes a `cancelled` history row without advancing.

Wake-ups emit CloudEvents 1.0 envelopes—`check_back_later.wakeup` for checkbacks
and `cron.fire` for cron fires—carrying the event/history ID, due time, fire
time, time zone, primary reply route, and frozen delivery targets, persisted on
either the `Signal` (`signal_id`) or `AutomationJob` run
(`automation_job_run_id`) alongside `fired_at` (while stripping the internal
event ID and delivery routes from the model-visible prompt). Model tool queries
map known cancellations and domain errors to stable reason codes and collapse
all other diagnostics to `schedule_fire_failed` without leaking request, Signal,
Oban, or provider IDs; operators see full diagnostics in the Console.

Across admission, updates, manual runs, final failed-history inserts, and Human
revocation, Schedule enforces one strict lock order:

1. Associated `Human` rows in ascending UID order
2. Consumer `AutomationJob` (locked before `CronSchedule`—including on manual
   runs, failed-history inserts whose foreign key locks the job, Binding edits
   locking the new job, and cron updates that lock the requested job first and
   then re-normalize against the locked rule so concurrent recurrence progress
   is preserved; live-Binding lookups reject concurrent Binding changes before
   inserting history against an unlocked consumer, while retained events lock
   their stored consumer)
3. `CronSchedule`
4. `ScheduledEvent`
5. `Session`, `Workspace`, and `Signal`

Because `FireCron` re-checks the locked rule's status and `next_fire_at`, stale
Oban jobs harmlessly skip paused, deleted, completed, or rescheduled rules;
after an outage, `FireCron` fires all missed intervals as a single catch-up fire
for the retained slot and computes the next `next_fire_at` forward from `now`.

## Tell the Agent Why It Woke Up

Sessions maps scheduled Signals to dedicated turn kinds:

| Signal type | Turn kind | Agent schedule mode |
| --- | --- | --- |
| `check_back_later.wakeup` | `checkback_generation` | `check_back_later` |
| `cron.fire` | `scheduled_task` | `cron` |

The control plane derives the schedule mode from the Signal type and passes the
schedule origin and `quiet_success` permission in request context without
duplicating the mode. For `cron.fire`, the prompt also tells the Agent that
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
  rule's `owner_session_id`; reply routes come from the active input, cron
  provenance records `driver_epoch` and the frozen route, and an optional
  `automation_job_id` must belong to an active job on the same Agent (clearable
  or replaceable on update).
- Inside a derived `cron:<schedule_id>` execution Session, the turn may call
  only `list`, `get`, `runs`, and `pause`—and strictly on its own rule. Calling
  `pause` lets a self-stopping task halt future recurrences once a condition is
  met while keeping its AIGateway conversation open so the current turn can
  still deliver its reply; by contrast, a cron turn cannot create rules, edit
  its own task, resume or trigger itself, or `remove` its rule (since `remove`
  closes the active AIGateway conversation).

## Rules

- Persist every user-affecting schedule in PostgreSQL; use Oban strictly to trigger due checks, keeping at most one pending `FireCron` job at `next_fire_at` per active rule.
- Store only historical fires in automatic cron run lists, never re-fire a `fired` or `failed` slot, and emit at most one `Signal` or `AutomationJob` run per scheduled event.
- Execute every cron fire in its derived `cron:<schedule_id>` Session (never in `owner_session_id`), keeping the complete standing prompt in `payload.task` for direct-Agent rules and running one Agent turn regardless of target count.
- Restrict Agent schedule tools to the current turn's route, and restrict cron-originated turns to inspecting or pausing their own rule.
- Cancel pending checkbacks whenever their source provider entry is canceled or removed.
- Allow silent completion without a reply only when the schedule explicitly enables `quiet_success`.
