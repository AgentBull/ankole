# MailBox

MailBox is BullX's internal CloudEvents delivery runtime. It answers one
question: which Agents should handle this mail, and when?

The implementation lives in `BullX.MailBox` and `BullX.MailBox.*`.

## Responsibility

MailBox owns:

- Agent-addressed delivery rules
- delivery rules
- short processing sessions
- delivery entries
- weak Redis-backed visible-output streams
- entry leasing and dispatch

MailBox does not own:

- IM message truth
- AIAgent conversation truth
- AuthZ policy truth
- LLM provider state
- outbound provider message state
- workflow or work business facts

## Input

MailBox accepts CloudEvents-shaped maps. The event is stored on each
`mailbox_entries.cloud_event` as JSON.

There are two entry points:

- `BullX.MailBox.route/2` matches active delivery rules and delivers one entry
  per matched rule.
- `BullX.MailBox.deliver/2` directly delivers a caller-specified `agent_uid`
  request.

## Delivery Rules

`mailbox_delivery_rules` contains:

- `name`
- `active`
- `priority`
- `match_expr`
- `agent_uid`
- `attention`
- `session_key_template`
- `available_delay_ms`
- `coalesce_key_template`
- `metadata`

`match_expr` is CEL validated through the Rust NIF-backed matcher. Active rules
are evaluated by ascending `priority` and `id`.

Priority only orders evaluation. Every matching rule delivers; equal-priority
fan-out is expected behavior.

The setup flow creates source-scoped rules named
`setup.default.<adapter>.<source>.channel`.

## Routing Context

`route/2` projects CloudEvents fields into a matcher context with:

- `source`
- `type`
- `time`
- `data`
- `event.id`
- `event.identity.source`
- `event.identity.id`
- `channel`
- `scope`
- `actor`
- `refs`
- `reply_address`
- `routing_facts`

`BullX.MailBox.RoutingContext.project/1` exposes the public sample projection
used by setup modules.

## Tables

`mailbox_sessions` stores a weak processing window for one Agent:

- `agent_uid`
- `session_key`
- `status`: `active`, `closed`, or `failed`
- `last_entry_at`
- lease fields
- `closed_at`
- `metadata`

`mailbox_entries` stores one delivered item for one Agent:

- monotonic `entry_seq`
- `agent_uid`
- `mailbox_session_id`
- `status`: `pending`, `leased`, `processed`, `discarded`, or `failed`
- `attention`: `addressed`, `ambient`, `command`, `action`, `lifecycle`, or
  `system`
- `cloud_event`
- `reply_address`
- `available_at`
- `dedupe_hash`
- `coalesce_key`
- lease fields
- `attempts`
- `safe_error`

`mailbox_sessions` and `mailbox_entries` are unlogged tables. They are delivery
window state, not business truth.

## Deliver

`deliver/2` normalizes the request, then in one database transaction:

1. loads the target Agent row;
2. gets or creates the `mailbox_sessions` row;
3. inserts a `mailbox_entries` row.

The default session key is:

- `cloud_event.subject`, when present;
- otherwise `<source>#<id>`;
- otherwise `default`.

The dedupe hash includes `agent_uid`, CloudEvents source/id, attention, and a
dedupe key. Routed mail uses the delivery rule id as the dedupe key, so one
external event can be delivered to multiple Agents without colliding.

After a successful insert, MailBox wakes the dispatcher with a delay based on
`available_at`.

## Processing

`claim_ready/2` leases entries whose `available_at` is due and whose status is
`pending` or whose previous lease has expired. It uses
`FOR UPDATE SKIP LOCKED`, sets `status = leased`, increments `attempts`, and
sets a 60-second lease.

`process_entry/2` preloads the Agent and session, dispatches the entry, and
marks it `processed` or `failed`.

Current dispatch behavior:

- `agents.type = "ai_agent"` calls `BullX.AIAgent.handle_mailbox_entry/2`.
- `agents.type = "blackhole"` succeeds without side effects.
- any other Agent type fails with `unknown_agent_type`.

`BullX.MailBox.Dispatcher` is a GenServer. It processes ready entries on a
timer, wakes when new work arrives, and schedules the next wake from
`next_ready_at/0` when the queue is idle.

## Streaming Output

`BullX.MailBox.StreamingOutput` is a weak Redis-backed stream buffer for visible
output chunks. It stores stream metadata and chunks with TTLs, publishes chunk
pointers over Redis Pub/Sub, and supports resume/follow operations.

The Redis child is `BullX.Redis`. It is a neutral runtime dependency backed by
the configured cache Redis URL; MailBox and AIAgent depend on it as peers.

Streaming output is not business truth. The Agent still persists its own
conversation facts, and IMGateway still persists outbound IM facts.

## Invariants

- MailBox stores delivery windows, not Agent business state.
- Rule priority does not stop fan-out.
- Duplicate delivery is scoped to one Agent.
- Process-local dispatcher state is reconstructible from database rows.
- Agents are responsible for idempotency inside their own business facts.
