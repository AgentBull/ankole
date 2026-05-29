# MailBox

MailBox is BullX's internal CloudEvents delivery runtime. It answers one
question: which Agents should handle this mail, and when?

The implementation lives in `BullX.MailBox` and `BullX.MailBox.*`.

## Responsibility

MailBox owns:

- delivery rules
- short processing sessions
- delivery entries
- weak Redis-backed visible-output streams
- session and control-entry leasing and dispatch

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
- `last_entry_at`
- lease fields

`mailbox_entries` stores one delivered item for one Agent:

- monotonic `entry_seq`
- `agent_uid`
- `mailbox_session_id`
- `status`: `pending`, `leased`, `processed`, `discarded`, or `failed`
- `attention`: `addressed`, `ambient`, `command`, `action`, `lifecycle`, or
  `system`
- `cloud_event`
- `available_at`
- `idempotency_key`
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

- `cloud_event.data.queue_key`, when present;
- otherwise `cloud_event.subject`, when present;
- otherwise `<source>#<id>`;
- otherwise `default`.

The idempotency key is derived from `agent_uid`, CloudEvents source/id,
attention, and a dedupe key. Routed mail uses the delivery rule id as the dedupe
key, so one external event can be delivered to multiple Agents without
colliding.

Entry attention is derived from a direct delivery request when provided, or
from the CloudEvents type and IM routing facts. Delivery rules select receivers;
they do not assign attention or delay.

After a successful insert, MailBox starts a control-entry worker immediately for
control mail, or wakes the dispatcher with a delay based on `available_at` for
normal session mail.

## Processing

`BullX.MailBox.process_ready/2` leases sessions that have due non-control
entries. It uses `FOR UPDATE SKIP LOCKED` so multiple Elixir nodes can claim
different sessions without sharing process-local state. A session worker
heartbeats the session lease while it drains entries for that session serially.

The same processing pass separately leases due command, abort, edit, recall,
and delete entries. These entries are started as standalone workers so they can
affect an active generation without waiting behind normal message work in the
same session. Leased entries or sessions become claimable again after their
lease expires.

`process_entry/2` preloads the Agent and session, dispatches the entry, and
marks it `processed` or `failed`.

Lifecycle entries first check whether their target received-message entry is
still pending in the same session. Pending targets are rewritten or discarded
before AIAgent sees stale input. Leased targets are deferred only until the
target has materialized into conversation state; once materialized, lifecycle
entries dispatch immediately so an edit or recall can cancel an active
generation.

For `bullx.message.received` mail with `data.coalesce`, `process_entry/2` can
merge later pending entries from the same actor in the same session when they
arrived inside the window and the combined text stays under the character
limit. Covered entries are marked processed after the merged entry succeeds. If
any active item in the merged batch is addressed, the whole delivered batch is
addressed.

Current dispatch behavior:

- `agents.type = "ai_agent"` calls `BullX.AIAgent.handle_mailbox_entry/2`.
- any other Agent type fails with `unknown_agent_type`.

`BullX.MailBox.Dispatcher` is a GenServer. It claims realtime control entries
and ready sessions on a timer, starts work through
`BullX.MailBox.SessionWorker`, wakes when new work arrives, and schedules the
next wake from `next_ready_at/0` when the queue is idle.

## Streaming Output

`BullX.MailBox.StreamingOutput` is a weak Redis-backed stream buffer for visible
output chunks. It stores stream metadata and chunks with TTLs, publishes chunk
pointers over Redis Pub/Sub, and supports resume/follow operations.

The Redis child is `BullX.Redis`. It is a neutral runtime dependency backed by
the configured cache Redis URL; MailBox and AIAgent depend on it as peers.

Streaming output is not business truth. The Agent still persists its own
conversation facts, and IMGateway best-effort mirrors outbound IM facts.

## Invariants

- MailBox stores delivery windows, not Agent business state.
- Rule priority does not stop fan-out.
- Duplicate delivery is scoped to one Agent.
- Normal entries in one session are processed serially; different sessions may
  be processed concurrently.
- Control entries do not wait behind normal session entries.
- Process-local dispatcher state is reconstructible from database rows.
- Agents are responsible for idempotency inside their own business facts.
