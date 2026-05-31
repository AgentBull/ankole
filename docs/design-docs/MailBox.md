# MailBox

MailBox is BullX's internal CloudEvents delivery runtime. It answers one
question: which Agents should handle this mail, and when?

The implementation lives in `BullX.MailBox` and `BullX.MailBox.*`.

## Responsibility

MailBox owns:

- delivery rules
- accepted pending delivery entries
- short-lived runtime queues, timers, coalesce pressure, and in-flight markers
- weak Redis-backed visible-output streams

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

`mailbox_entries` stores accepted pending mail for one Agent:

- monotonic `entry_seq`
- `agent_uid`
- `queue_key`
- `attention`: `addressed`, `ambient`, `command`, `action`, `lifecycle`, or
  `system`
- `cloud_event`
- `idempotency_key`

`mailbox_acceptance_keys` stores the weak idempotency horizon:

- `agent_uid`
- `idempotency_key`
- `entry_id`
- `accepted_at`

Both tables are unlogged. They are delivery-window state, not business truth.
Losing PostgreSQL or Redis state may lose accepted mail. The required recovery
boundary is Elixir process crash: `BullX.MailBox.Runtime` rebuilds from pending
`mailbox_entries`.

## Deliver

`deliver/2` normalizes the request, then in one database transaction:

1. loads the target Agent row;
2. inserts an accepted-key row for idempotency;
3. inserts one `mailbox_entries` row.

The default queue key is:

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
they do not assign attention.

After commit, `deliver/2` hands the entry to `BullX.MailBox.Runtime`. Duplicate
delivery with an existing accepted-key row returns `status: :duplicate`; if the
pending row was already processed and deleted, the duplicate result has no
entry to wake.

## Runtime

`BullX.MailBox.Runtime` is the only MailBox process that owns scheduling state.
It keeps:

- pending entries loaded from PostgreSQL;
- ready ids;
- deferred lifecycle ids and deadlines;
- in-flight ids;
- active receiver queues;
- coalesce pressure keyed by `{agent_uid, queue_key, actor}`;
- the next wake timer.

Runtime queue scope is `{agent_uid, queue_key}`. This preserves fan-out: two
Agents can receive the same CloudEvents mail and process their own queues
without merging entries or blocking each other.

Runtime state is reconstructible. `BullX.MailBox.rebuild_runtime/0` reloads
pending entries from PostgreSQL. No timer, lease, status, pending-id list, or
coalesce-pressure fact is durable.

## Processing

`BullX.MailBox.process_ready/2` claims ready runtime entries and runs them
synchronously or through `BullX.MailBox.RuntimeTaskSupervisor`.

Control mail types are:

- `bullx.command.invoked`
- `bullx.agent.abort`
- `bullx.message.edited`
- `bullx.message.recalled`
- `bullx.message.deleted`

Ready control entries are claimed before normal entries. A control entry also
blocks normal entries in the same `{agent_uid, queue_key}` for that claim pass,
so pending edit/recall/delete can rewrite or drop a received entry before the
normal receive flushes.

Lifecycle entries first check whether their target received-message entry is
still pending in the same receiver queue. Pending targets are rewritten or
deleted before AIAgent sees stale input. In-flight targets are deferred until
the target has materialized into conversation state; once materialized,
lifecycle entries dispatch so AIAgent can cancel an active generation or revise
completed context.

For `bullx.message.received` mail with `data.coalesce`, Runtime computes the
normal due time from `inserted_at + window_ms`. Pressure can wake a batch early
without updating PostgreSQL. `process_entry/2` can merge later pending entries
from the same actor in the same receiver queue when they arrived inside the
window and the combined text stays under the character limit. Covered rows are
deleted after the merged entry succeeds. If any active item in the merged batch
is addressed, the whole delivered batch is addressed.

Current dispatch behavior:

- `agents.type = "ai_agent"` calls `BullX.AIAgent.handle_mailbox_entry/2`.
- any other Agent type is ignored from MailBox's queue after a safe dispatch
  failure.

Completed, discarded, and safely failed MailBox rows are deleted. Business
truth belongs to Receivers such as AIAgent, not to MailBox status rows.

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
- Normal entries in one receiver queue are processed serially.
- Different receiver queues may be processed concurrently.
- Control entries do not wait behind normal entries in the same receiver queue.
- Process-local Runtime state is reconstructible from pending rows.
- Agents are responsible for idempotency inside their own business facts.
