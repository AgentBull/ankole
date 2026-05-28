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
- `BullX.MailBox.StreamingOutput.Redis`
- `BullX.MailBox.Dispatcher`, unless disabled by `config :bullx, :mail_box`
- `BullX.AIAgent.AmbientBatchWorker`
- `BullX.AIAgent.DailyResetWorker`

There is no current background-job worker tree and no legacy routing-bus
runtime.

## Current Flow

The implemented business flow is:

```text
provider event
  -> plugin ChannelAdapter.normalize_inbound/2
  -> BullX.IMGateway.ChannelAdapter.accept_inbound/4
  -> BullX.IMGateway.accept_cloud_event/2
  -> im_rooms + im_messages
  -> BullX.MailBox.route/2
  -> mailbox_delivery_rules
  -> mailboxes + mailbox_sessions + mailbox_entries
  -> BullX.MailBox.Dispatcher
  -> BullX.AIAgent.handle_mailbox_entry/2
  -> conversations + conversation_messages
  -> BullX.LLM
  -> BullX.IMGateway.send_message/2 for visible IM output
```

The only currently implemented receiver dispatches are:

- `receiver_type = "ai_agent"`: invokes `BullX.AIAgent`.
- `receiver_type = "blackhole"`: marks the entry processed.

Any other receiver type fails the entry with a safe error.

## Boundaries

**Plugin adapters** are trusted compile-time code. They own provider-specific
transport details and normalize inbound provider payloads to CloudEvents maps.
Adapters do not write MailBox entries directly.

**IMGateway** owns IM facts. It upserts `im_rooms`, inserts or updates
`im_messages`, resolves human channel actors through `BullX.Principals`, and
turns IM provider events into internal IM mail.

**MailBox** owns internal delivery windows. It matches CloudEvents mail against
delivery rules, creates one `mailbox_entries` row per matched receiver, claims
ready entries, and calls the receiver dispatcher. It does not own IM messages,
AIAgent conversations, workflow runs, or outbound provider facts.

**AIAgent** owns AI conversation state and model/tool execution. It reads the IM
fact referenced by MailBox, persists conversation messages, runs ACL checks,
calls tools and LLM providers, and sends visible IM output through IMGateway.

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
event's `data.channel.adapter` matches the adapter extension id before handing
the event to IMGateway.

IMGateway stores addressed messages, ambient messages, command events, action
events, and message lifecycle events. It maps provider lifecycle events to
internal mail types:

- `bullx.message.edited` -> `bullx.im.message.edited`
- `bullx.message.recalled` -> `bullx.im.message.recalled`
- `bullx.message.deleted` -> `bullx.im.message.deleted`
- other IM message events -> `bullx.im.message.received`

Addressed, command, and action mail from a human channel actor is routed only
when the actor's channel identity is verified. Ambient and lifecycle mail is
still routable after the IM fact is stored.

## Mail Delivery

`BullX.MailBox.route/2` builds a routing context from CloudEvents fields and
evaluates active `mailbox_delivery_rules` in ascending `priority` and `id`
order. Every matching rule delivers an entry. Priority orders evaluation; it is
not a uniqueness boundary and does not stop fan-out.

`BullX.MailBox.deliver/2` accepts a direct delivery request, creates or reuses a
mailbox, creates or reuses a session, inserts an entry, and wakes the
dispatcher. Duplicate entries are detected per mailbox by a SHA-256 dedupe hash.

`BullX.MailBox.claim_ready/2` leases ready entries with `FOR UPDATE SKIP
LOCKED`. A leased entry becomes claimable again after its lease expires.

`BullX.MailBox.Dispatcher` is an OTP GenServer. It periodically claims ready
entries and processes them. It also wakes early when new entries are delivered.

## Outbound IM

Receivers do not call plugin adapters directly for visible IM output. They call
`BullX.IMGateway.send_message/2`.

IMGateway writes an outbound `im_messages` row with `status = pending`, sends
through the matching channel adapter, and then marks the row `sent`, `recalled`,
or `failed`. Provider message ids and safe errors are stored on the outbound IM
fact.

Streaming visible output uses `BullX.MailBox.StreamingOutput` backed by Redis.
The stream buffer is weak runtime state with retention TTLs. The persisted IM
outbound fact remains in `im_messages`.

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
- `mailboxes`
- `mailbox_delivery_rules`
- `mailbox_sessions`
- `mailbox_entries`
- `conversations`
- `conversation_messages`

UUID primary keys are generated in code with `BullX.Ecto.UUIDv7` or
`BullX.Ext.gen_uuid_v7/0`; the migrations do not rely on PostgreSQL-side UUID
defaults.

`mailbox_sessions` and `mailbox_entries` are created as unlogged tables. They
are delivery-window state, not business truth.

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
