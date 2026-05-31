# BullX Architecture

BullX is a single-installation AgentOS runtime. The current branch is an
infrastructure shell: PostgreSQL owns durable facts, OTP processes own only
reconstructible runtime work, and the implemented product path is IM input to
MailBox delivery to AIAgent execution.

The implementation source of truth is the code under `lib/`. This document
describes the current code path only.

## Runtime Shape

`BullX.Application` starts these children under one supervisor:

- `BullXWeb.Telemetry`
- `BullX.Repo`
- `BullX.Config.Supervisor`
- `BullX.I18n.Catalog`
- `Phoenix.PubSub` named `BullX.PubSub`
- `BullX.Plugins.Supervisor`
- `BullX.Runtime.Supervisor`
- `BullXWeb.Endpoint`

`BullX.Runtime.Supervisor` starts runtime workers:

- `BullX.LLM.PluginProviders`
- `BullX.LLM.Catalog.Cache`
- `BullX.Redis`
- `BullX.MailBox.RuntimeTaskSupervisor`
- `BullX.MailBox.Runtime`, unless disabled by `config :bullx, :mail_box`
- `BullX.AIAgent.AmbientBatchWorker`, unless disabled by `config :bullx, :ai_agent_runtime`
- `BullX.AIAgent.DailyResetWorker`, unless disabled by `config :bullx, :ai_agent_runtime`

There is no current background-job worker tree and no legacy routing-bus
runtime.

## Current Flow

The implemented business flow is:

```text
provider event
  -> plugin ChannelAdapter.normalize_inbound/2
  -> BullX.IMGateway.ChannelAdapter.accept_inbound/4
  -> BullX.IMGateway.accept_message_event/2
     -> BullX.MailBox.route/2
        -> mailbox_delivery_rules
        -> agents + mailbox_acceptance_keys + mailbox_entries
        -> BullX.MailBox.Runtime
        -> BullX.AIAgent.handle_mailbox_entry/2
        -> conversations + conversation_messages
        -> BullX.LLM
        -> BullX.IMGateway.send_message/2 for visible assistant output
     -> best-effort im_rooms + im_messages mirror for message facts
```

The only currently implemented agent dispatches are:

- `agents.type = "ai_agent"`: invokes `BullX.AIAgent`.

Any other agent type fails the entry with a safe error.

## Boundaries

**Plugin adapters** are trusted compile-time code. They own provider-specific
transport details and normalize inbound provider payloads to IMGateway message
events.
Adapters do not write MailBox entries directly.

**IMGateway** owns the IM boundary. It validates normalized IM events, resolves
human channel actors through `BullX.Principals`, emits source-neutral internal
IM mail, and best-effort mirrors message facts into `im_rooms` and
`im_messages` for future memory use. Mail routing and delivery do not depend on
those mirror rows.

**MailBox** owns internal delivery windows. It matches CloudEvents mail against
delivery rules, creates one pending `mailbox_entries` row per matched Agent,
and dispatches entries through an in-memory runtime that owns queue order,
timers, coalesce pressure, and in-flight markers. It does not own IM messages,
AIAgent conversations, workflow runs, or outbound provider facts.

**AIAgent** owns AI conversation state and model/tool execution. It reads the IM
mail delivered by MailBox, persists conversation messages, runs ACL checks,
calls tools and LLM providers, and sends visible assistant output through
IMGateway.

**Principals and AuthZ** own accountable subjects and permission decisions.
Humans and agents are Principals; AuthZ grants are evaluated with CEL
conditions over active Principals, groups, resource patterns, action, and
request context.

**Configuration** owns runtime settings through `BullX.Config`. Database-backed
config is cached in ETS after Repo starts; system bootstrap config remains in
Phoenix/Mix config and environment variables.

## IM Input

The active IM adapters are Feishu, Discord, and Telegram. Each adapter exposes
the `:"bullx.im_gateway.channel_adapter"` plugin extension and implements:

- `normalize_inbound/2`
- `deliver/4`
- `fetch_source/1`
- optionally `consume_stream/4`
- optionally `capabilities/0`

`BullX.IMGateway.ChannelAdapter.accept_inbound/4` validates that the normalized
message event's `data.channel.adapter` matches the adapter extension id before
handing the event to IMGateway.

IMGateway routes addressed messages, ambient messages, command events, and
message lifecycle facts as source-neutral AIAgent input mail:

- `bullx.message.received`
- `bullx.message.edited`
- `bullx.message.recalled`
- `bullx.message.deleted`
- `bullx.command.invoked`

Whether the source fact came from IMGateway is carried in `data.source_fact`,
not in the CloudEvents type. IMGateway also provides `data.queue_key` and
`data.conversation_context` so MailBox can group room processing and AIAgent can
build conversation identity from a source-neutral shape. MailBox delivery rules
select receivers; IMGateway includes attention evidence on the mail, and
MailBox derives the delivered entry attention from the CloudEvents data.
Provider edit/recall/delete facts route as
source-neutral lifecycle mail and are mirrored to `im_messages` on a
best-effort basis. AIAgent handles lifecycle mail as conversation revision
control, not as fresh prompt-visible user content. Lifecycle routing is keyed
by provider source refs, not by the edited message's current addressedness, so
an edit that removes an `@agent` mention can still cancel or recall the turn it
already triggered.

Group sources use one `group_message_mode`:

- `addressed_only`: adapters admit only DMs, mentions, replies, commands, or
  other explicitly addressed input.
- `observe_all`: unaddressed group messages are delivered as ambient context
  mail, but AIAgent treats them as context-only and does not proactively reply.
- `engage_all`: unaddressed group messages are delivered as ambient mail that
  AIAgent may batch and selectively handle.

IM adapter direct commands such as `/root_init`, `/webauth`, `/command`, and
`/status` are handled before IMGateway handoff. Other slash commands, including
unknown command names, are delivered through MailBox as `bullx.command.invoked`
with `data.command`. Command events and visible command replies are control
plane messages and are not mirrored to `im_messages`.

Addressed received and command mail from a human channel actor is routed only
when the actor's channel identity is verified. Ambient and lifecycle mail is
still routable without depending on mirror writes. Provider actions that
continue a conversation are normalized as received message mail with action
content.

## Mail Delivery

`BullX.MailBox.route/2` builds a routing context from CloudEvents fields and
evaluates active `mailbox_delivery_rules` in ascending `priority` and `id`
order. Every matching rule delivers an entry. Priority orders evaluation; it is
not a uniqueness boundary and does not stop fan-out.

`BullX.MailBox.deliver/2` accepts a direct delivery request for an `agent_uid`,
records an accepted-key row for idempotency, inserts one pending entry, and
hands that entry to `BullX.MailBox.Runtime`. Duplicate entries are detected per
Agent by an `idempotency_key`; processed mailbox rows are deleted, while the
accepted-key ledger prevents immediate duplicate reacceptance.

The default queue key prefers `cloud_event.data.queue_key`, then the
CloudEvents subject, then `<source>#<id>`. IMGateway sets the queue key to the
provider/source/room/thread identity. Runtime scheduling is scoped by
`agent_uid + queue_key`, so one external mail can fan out to multiple Agents
without their queues or coalescing windows merging.

PostgreSQL stores accepted pending mail only. `mailbox_entries` has the
receiver, queue key, attention, CloudEvents payload, idempotency key, and insert
order. It does not store timers, status, leases, pending ids, or coalesce
pressure. `BullX.MailBox.Runtime` owns those short-lived scheduling facts and
can rebuild them from pending rows after an Elixir process crash.

Normal received-message mail may carry a coalescing config. Runtime computes
the deadline from `inserted_at + data.coalesce.window_ms` and keeps an
in-memory pressure hint keyed by `{agent_uid, queue_key, actor}`. If the hint
reaches `max_chars`, the affected runtime entries wake early; no PostgreSQL row
is rewritten for that scheduling event. When processing starts, MailBox merges
later pending entries from the same actor in the same receiver queue only when
they arrived inside the window and the combined text stays under the character
limit. If any active item in the batch is addressed, the whole delivered batch
is addressed.

Command, abort, edit, recall, and delete mail are control entries. A ready
control entry is claimed before normal entries in the same receiver queue.
Lifecycle events that arrive before materialization are folded into or delete
the pending received entry; after materialization, they dispatch to AIAgent so
it can cancel an active generation or revise completed context.

`BullX.MailBox.process_ready/2` claims ready runtime entries and runs them
synchronously or through `BullX.MailBox.RuntimeTaskSupervisor`. Completed rows
are deleted from `mailbox_entries`; AIAgent conversations, IM mirror rows, and
outbound provider facts remain the durable business records.

## Outbound IM

Agents do not call plugin adapters directly for regular visible assistant
output. They call `BullX.IMGateway.send_message/2`. Command feedback is
control-plane output and is not mirrored to `im_messages`.

IMGateway sends through the matching channel adapter first, then best-effort
mirrors provider-confirmed visible outbound message facts into `im_messages`.
Successful sends require a provider message id. Recall outcomes update
`lifecycle_state` when the target provider message id is known. Failed delivery
attempts and safe errors are runtime facts, not IM message rows.

Streaming visible output uses `BullX.MailBox.StreamingOutput` backed by
`BullX.Redis`. The stream buffer is weak runtime state with retention TTLs. A
provider-confirmed visible message can still be mirrored in `im_messages` when
the adapter returns a provider message id. Stream chunks are UX preview state;
the complete assistant message remains the durable Agent fact. If stream
finalization fails, AIAgent falls back to normal outbound delivery of the final
assistant message when one exists.

## Persistence

Current durable or semi-durable tables include:

- `app_configs`
- `principals`
- `human_users`
- `agents`
- `principal_external_identities`
- `principal_login_auth_codes`
- `principal_groups`
- `principal_group_memberships`
- `permission_grants`
- `llm_providers`
- `im_rooms`
- `im_messages`
- `mailbox_delivery_rules`
- `mailbox_acceptance_keys`
- `mailbox_entries`
- `conversations`
- `conversation_messages`

UUID primary keys are generated in code with `BullX.Ecto.UUIDv7` or
`BullX.Ext.gen_uuid_v7/0`; the migrations do not rely on PostgreSQL-side UUID
defaults.

`mailbox_acceptance_keys` and `mailbox_entries` are created as unlogged tables.
They are delivery-window state, not business truth. Losing PostgreSQL or Redis
runtime state may lose accepted-but-unprocessed mail; the required recovery
boundary is Elixir process crash, where Runtime rebuilds from pending
`mailbox_entries`.

`im_rooms` and `im_messages` mirror the external IM conversation for memory and
inspection. `im_rooms` are keyed by provider external room identity, not by
BullX source id. `im_messages` are keyed by canonical room plus provider message
id and store message content/actor/lifecycle facts. They are not on the routing
critical path; deleting or losing those rows removes the mirror, but IMGateway
can still route new inbound mail and send visible outbound messages.

## Web Surface

The Phoenix router exposes:

- setup pages under `/setup`
- login pages under `/sessions`
- console session API at `/console/api/session`
- internal channel APIs under `/.internal-apis/v1`
- console SPA routes under `/console`
- health endpoints `/livez` and `/readyz`
- OpenAPI description at `/.well-known/service-desc`

The setup wizard composes existing subsystem facades. It does not own separate
durable product facts.

## Not Implemented In This Branch

The following product concepts are vocabulary only in the current branch and do
not have current runtime tables or dispatch implementations:

- Workflow runtime and Workflow nodes
- Work records
- Brain memory
- SubAgent runtime
- non-IM Gateways
- Capability governance beyond current AuthZ and AIAgent tool ACL checks
- SaaS tenants

Do not write code or docs as if these surfaces already exist.

## Design Documents

- [Configuration](./design-docs/Configuration.md)
- [Cache](./design-docs/Cache.md)
- [Ext](./design-docs/Ext.md)
- [I18n](./design-docs/I18n.md)
- [Principal](./design-docs/Principal.md)
- [AuthZ](./design-docs/AuthZ.md)
- [Plugins](./design-docs/Plugins.md)
- [LLMProvider](./design-docs/LLMProvider.md)
- [IMGateway](./design-docs/IMGateway.md)
- [MailBox](./design-docs/MailBox.md)
- [Setup](./design-docs/Setup.md)
- [AIAgent Core](./design-docs/ai-agent/Core.md)
