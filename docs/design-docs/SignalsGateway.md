# Signals Gateway

## Summary

The Signals Gateway is BullX's transport boundary for external events and
external channel delivery. It normalizes inbound transport payloads into
`BullX.Gateway.Signal`, hands accepted Signals to the configured Router, and
durably stores the Router's opaque internal delivery requests through an
Oban-backed Mailbox. It also accepts already-authorized external `Delivery`
commands and dispatches them through configured adapters with best-effort
recovery, terminal receipts, and dead-letter replay.

The Gateway does not persist inbound events as Signal rows. It does not maintain
a durable Signal log, subscription checkpoints, or historical Signal replay.
PostgreSQL stores resolved delivery intent jobs, outbound dispatch buffers,
stream buffers, terminal receipts, and dead-letter recovery records. PostgreSQL
does not store an inbound Signal table in this design.

## Scope

This design covers the transport and delivery infrastructure owned by
`BullX.Gateway`:

- the normalized `BullX.Gateway.Signal` envelope, JSON serialization, JSON
  deserialization, and strict CloudEvents 1.0 JSON Event Format rules;
- Gateway adapter extension points, source configuration, inbound
  normalization, source connectivity checks, and external outbound delivery;
- the inbound `content + event` contract, external actors, reply channels, and
  redacted source provenance;
- transport security, source gating, moderation hooks, acknowledgement
  boundaries, and provider failure boundaries;
- the minimal post-router delivery protocol: `DeliveryIntent`, `delivery_key`,
  the Oban-backed Mailbox, worker handoff, per-delivery dedupe, retry, and
  crash recovery;
- external outbound `Delivery`, content validation, outcomes, retry,
  best-effort PostgreSQL-backed dispatch buffering, stream buffering, terminal
  failure dead letters, and replay;
- Gateway supervision, startup ordering, telemetry, security, privacy, and
  implementation acceptance criteria.

## Goals

- Keep the Gateway as a transport boundary, not a business routing or Agent
  runtime boundary.
- Preserve a single normalized Signal envelope for heterogeneous external
  sources.
- Make inbound acceptance depend on Router resolution and durable Mailbox
  enqueue, not on process-local memory.
- Provide durable at-least-once delivery for resolved internal intents through
  Oban.
- Keep per-delivery idempotency explicit through `delivery_key`.
- Keep Mailbox and `ConsumerDelivery` as transport handoff mechanics, not
  Agent attention, Admission, Work, or Governance mechanics.
- Let trusted plugins contribute adapters without changing Gateway core for each
  provider.
- Provide best-effort recovery for accepted outbound deliveries without claiming
  external exactly-once side effects.
- Keep raw provider payloads, provider secrets, private adapter config, and
  private content out of telemetry and error details.

## Non-Goals

- The Gateway does not define Router rule syntax, rule priority, fanout policy,
  permission checks, LLM routing policy, or Agent selection.
- The Gateway does not define how Signals enter Agent attention, Mission, Work,
  Brain, or other business consumers.
- The Gateway does not decide how an Agent generates a response Signal or
  external Delivery.
- The Gateway does not create Admission relationships, resolve Principals,
  authorize business actions, approve Effects, or evaluate Outcomes.
- The Gateway does not define Phoenix webhook route topology, OAuth callback
  topology, or provider-specific HTTP paths.
- The Gateway does not introduce a generic participant, room, session, thread,
  or multi-tenant model.
- The Gateway does not execute Function Calling or Capability calls.
- The Gateway does not provide permanent occurrence-level dedupe or permanent
  per-delivery dedupe.

## Cleanup Plan

- Delete inbound Signal persistence from the intended implementation. Do not add
  a `signals` table, a durable `BullX.Signals` append context, a
  `gateway_dedupe_seen` table, a Gateway event bus built on Phoenix.PubSub, a
  subscriber registry, a persistent Signal journal, checkpoints, snapshots, or
  historical replay.
- Merge inbound carrier normalization, configured source lookup, outbound
  delivery, terminal receipts, and dead-letter recovery under the
  `BullX.Gateway` boundary.
- Reuse `BullX.Plugins` for adapter extension discovery, `BullX.Config` for
  runtime source configuration, `BullX.Repo`, `BullX.Ecto.UUIDv7`,
  `BullX.Ext.gen_uuid_v7/0`, `BullX.Retry`, Ecto changesets and constraints,
  Oban, and the existing application startup conventions.
- Add only the public contracts needed by this design:
  `BullX.Gateway.Signal`, `BullX.Gateway.DeliveryIntent`,
  `BullX.Gateway.Mailbox`, `BullX.Gateway.SignalDeliveryWorker`,
  `BullX.Gateway.ConsumerDelivery`, adapter behaviours, source registry,
  source supervisor, outbound delivery structs, best-effort dispatch buffers,
  stream buffers, receipts, dead letters, and related migrations. Keep the
  Router's rule model, RouteDecision records, and Agent ingress behavior in
  Runtime and future Admission designs.
- Preserve these invariants: the Gateway does not parse business identity, does
  not create Admission, does not turn external actors into Principals, does not
  persist inbound events as Signal rows, and does not store provider secrets,
  raw webhook bodies, or private payloads in Oban args, dispatch buffers, stream
  buffers, dead letters, or error details.
- Verify implementation with focused Gateway, Mailbox, adapter, outbound, and
  recovery tests, then run `bun precommit`.

## Terms

**Signal** is BullX's normalized statement that something happened. A Signal is
a JSON-neutral envelope. It is not a task, a queue item, an Admission decision,
or a database fact. A Signal can come from chat, webhook, email, CRM updates,
GitHub issues, market data, timers, Work status changes, Agent output, or
internal producers.

**Gateway** is the transport boundary. On inbound paths, the Gateway receives a
normalized adapter input, constructs `BullX.Gateway.Signal`, calls the Router,
and persists resolved delivery intents through the Mailbox. On outbound paths,
the Gateway receives an already-authorized external `Delivery` and invokes the
configured adapter.

**Adapter** is a trusted plugin-provided transport implementation. An adapter
verifies provider authenticity, parses provider payloads, normalizes inbound
transport data, renders outbound deliveries, and calls provider APIs.

**Configured source** is one adapter instance configured for an Installation.
The pair `{adapter, channel_id}` is unique after case folding. `channel_id` is a
configured source id. It is not a tenant id, external room id, or user id.

**Scope** is the adapter-defined external conversation or event domain, such as
a chat, channel, repository, timer namespace, or market feed. `scope_id` has
meaning only within `{adapter, channel_id}`. `thread_id` is an optional
adapter-local subdomain.

**Router** resolves a Signal into zero or more `DeliveryIntent` values at
publish time. Gateway depends on the callback shape, not the rule model,
destination ontology, or Agent selection semantics.

**DeliveryIntent** is the Router's opaque internal delivery request. Gateway
uses it for durable handoff and idempotency. It is not an Admission decision, an
external channel message, or a business Effect.

**Mailbox** is the Oban-backed durable delivery mailbox. It enqueues resolved
`DeliveryIntent` values, retries jobs, recovers pending jobs after BEAM crashes,
dedupes enqueue by delivery, and hands work to
`BullX.Gateway.SignalDeliveryWorker`.

**ConsumerDelivery** is the worker-facing handoff to the configured Runtime
boundary. Gateway passes the restored `DeliveryIntent` to this boundary and
maps the result to Oban lifecycle state. Consumer selection and consumer
meaning are outside this design.

**External Delivery** is a Gateway outbound command to `send`, `edit`, or
`stream` content to an external channel. A Delivery may correspond to an Effect
that Governance already allowed, but the Gateway does not make that decision.

## Design constraints

1. The Gateway has no dependency on an external event bus runtime. The contract
   is expressed through BullX modules, plugin extension declarations, Oban,
   PostgreSQL, and CloudEvents JSON.
2. `BullX.Gateway.Signal` uses strict CloudEvents 1.0 JSON Event Format.
   Extension attributes are top-level JSON properties, not a nested
   `extensions` map. Extension attribute names use only lowercase letters and
   digits.
3. A Signal is not a database fact. `BullX.Gateway.Signal` is a normalized
   envelope and mailbox payload, not a PostgreSQL row.
4. The Mailbox stores resolved `DeliveryIntent` values. It does not store
   un-routed Signals.
5. Routing happens only at publish time. Already enqueued jobs do not re-route
   when route configuration changes.
6. The Mailbox provides durable at-least-once delivery and per-delivery enqueue
   dedupe. It does not provide consumer side-effect exactly-once semantics.
7. Adapters own provider semantics. Gateway core validates the carrier shape,
   not provider-specific business fields.
8. Transport reliability is explicit and limited. Inbound reliability combines
   adapter prechecks, Gateway policy hooks, Router resolution, and Oban
   Mailbox enqueue. Outbound reliability uses a best-effort dispatch buffer,
   transport retry, terminal failure dead letters, and replay.
9. Gateway core can start before Runtime. Gateway source listeners and outbound
   dispatchers may run before Router is available, but inbound publish and
   terminal finalization must check Router availability before resolving
   Signals. Mailbox job execution is gated on Runtime and consumer readiness,
   not Router readiness, because those jobs already contain resolved
   `DeliveryIntent` values.
10. Gateway supervision adds a transport failure boundary. It does not move
    unrelated Runtime responsibilities or change the Runtime supervision tree
    without a separate design reason.

## System shape

Inbound delivery has one durable acceptance boundary: all resolved intents must
be accepted by the Mailbox.

```text
External payload
-> Listener or route mount identifies configured source and loads source config
-> Adapter verifies provider transport with that source config and parses payload
-> Adapter returns one normalized inbound input
-> Gateway validates carrier shape and JSON neutrality
-> Gateway validates normalized source identity, provenance, and occurrence key
-> Gateway runs transport security, gating, and moderation hooks
-> Gateway builds BullX.Gateway.Signal
-> Router.resolve(signal) returns DeliveryIntent values
-> Mailbox.enqueue_all(intents) writes Oban jobs
-> Gateway returns accepted or error to the adapter
```

The core routing and mailbox path is:

```text
BullX.Gateway.Signal
-> Router / Rule Engine
-> [BullX.Gateway.DeliveryIntent]
-> Oban-backed Mailbox
-> BullX.Gateway.SignalDeliveryWorker
-> ConsumerDelivery
```

Outbound delivery has a different boundary. The Gateway accepts an already
authorized `Delivery`, writes the best-effort dispatch state before returning
accepted, invokes the adapter asynchronously, records terminal outcome, and
publishes an outcome Signal through the same Router and Mailbox boundary.

## Signal envelope

`BullX.Gateway.Signal` uses CloudEvents 1.0 JSON Event Format. The implementation
may use a struct or embedded schema, but its persisted form is the serialized
map inside Oban job args or outcome payloads. The design does not add a
`signals` table.

The base CloudEvents fields are:

| Field | Requirement |
| --- | --- |
| `id` | BullX UUIDv7. Used for tracing and payload correlation, not as a database primary key. |
| `specversion` | Always `"1.0"`. |
| `source` | Non-empty URI reference, for example `bullx://gateway/feishu/main`. |
| `type` | Dotted event type. Gateway core defines inbound and delivery outcome carrier types. |
| `subject` | Optional human-readable subject. Code must not parse it for routing. |
| `time` | RFC3339 timestamp from provider time or Gateway receive time. |
| `datacontenttype` | Always `"application/json"`. |
| `dataschema` | Optional schema URI. |
| `data` | JSON-neutral object. Inbound Gateway Signals use the `content + event` contract. |

BullX extension attributes are top-level CloudEvents properties with the
`bullx` prefix. Attribute names contain only lowercase letters and digits.
Gateway-defined attribute names stay at or below 20 characters.

| Attribute | Requirement |
| --- | --- |
| `bullxoccurkey` | Required. Stable Signal occurrence identity used to build mailbox `delivery_key` values. |
| `bullxadapter` | Required for Gateway carriers. Configured adapter id, for example `feishu`. |
| `bullxchannel` | Required for Gateway carriers. Configured `channel_id`, for example `main`. |
| `bullxflags` | Optional short string that stores redacted transport hook flag codes. |
| `bullxmoderated` | Optional boolean indicating that moderation changed `data.content`. |

`BullX.Gateway.Signal.dump/1` must emit a flat CloudEvents JSON map.
`BullX.Gateway.Signal.load/1` must reject a nested `extensions` map because that
shape is not the CloudEvents JSON Event Format used by BullX.

`source` is CloudEvents context. It is not the Gateway routing key. Router and
consumers that need configured source information must read `bullxadapter` and
`bullxchannel`, not parse `source`.

Gateway carrier types are:

```text
com.agentbull.x.inbound.received
com.agentbull.x.delivery.succeeded
com.agentbull.x.delivery.failed
```

New external providers do not add new carrier types. Provider-specific
differences live under `data.event.type`, `data.event.name`, and
`data.event.data`.

`bullxoccurkey` is supplied by the adapter or internal producer. Examples:

```text
github:webhook_delivery_id
feishu:event_id
cron:schedule_id:scheduled_at
manual:user_id:client_request_id
```

If a provider has no native event id, the adapter must derive a stable id for
that occurrence. Gateway core must not use `Signal.id` as the occurrence dedupe
key because repeated publication of the same external occurrence may create a
new Signal id.

## Inbound data contract

An inbound Gateway Signal `data` object contains these fields:

| Field | Requirement |
| --- | --- |
| `content` | Non-empty content block list for Agents, LLMs, and humans. |
| `event` | Machine-readable event fact with `type`, `name`, `version`, and `data`. |
| `duplex` | Boolean derived from `event.type`. |
| `actor` | Channel-local external actor with at least `id`, `display`, and `bot`. |
| `scope_id` | Required non-empty adapter-local external conversation, repository, feed, or timer scope. |
| `thread_id` | Required key. Value may be `null` or a non-empty string. |
| `refs` | Stable external anchors. Defaults to `[]`. |
| `reply_channel` | Required when `duplex = true`; contains `adapter`, `channel_id`, `scope_id`, `thread_id`, and `reply_to_external_id`. |
| `provenance` | Adapter-normalized external source proof without secrets or raw body. |

`reply_channel.scope_id` and `reply_channel.thread_id` must match the current
Signal data. `reply_channel.reply_to_external_id` is nullable. If the provider
has a stable message, action, or event anchor, the adapter must fill the field
so Runtime can copy it into outbound `Delivery.reply_to_external_id`. If the
provider can only reply to the same scope or thread, the field is `null`.

The minimal content block shape is:

```elixir
%{
  "kind" => "text" | "image" | "audio" | "video" | "file" | "card",
  "body" => %{}
}
```

`text` content uses a non-empty `"text"` value in `body`. Non-text content must
include non-empty `"fallback_text"` so consumers and adapters that cannot handle
rich media can degrade safely. Media body values should use URIs. If an adapter
receives a byte buffer, it must upload or encode that buffer into a URI before
constructing content.

Adapters normally provide `content`. Only `message_recalled`, `reaction`,
`action`, and `slash_command` may use deterministic synthetic text fallback.
For `trigger`, an adapter-owned deterministic text projection is valid content.
`message` and `message_edited` must provide an adapter-owned content projection.
Empty content is not a valid inbound Signal.

The `event` field has this shape:

```elixir
%{
  "type" => "message" | "message_edited" | "message_recalled" |
            "reaction" | "action" | "slash_command" | "trigger",
  "name" => "feishu.message.posted",
  "version" => 1,
  "data" => %{}
}
```

`event.type` is the Gateway-owned semantic axis. `event.name` and `event.data`
belong to the adapter. Gateway core must not maintain an allowlist of
`event.name` values or parse provider business fields in `event.data`.

| `event.type` | `duplex` | Common source |
| --- | --- | --- |
| `message` | true | Chat message creation. |
| `message_edited` | true | Chat message edit. |
| `message_recalled` | true | Chat message recall or deletion. |
| `reaction` | true | Emoji reaction add or remove. |
| `action` | true | Button action, card action, form submit, or modal submit. |
| `slash_command` | true | Slash command or similar chat command input. |
| `trigger` | false | Webhook, polling event, market tick, timer, or internal trigger. |

Modal submit folds into `action`. Modal close, typing, presence, assistant
thread creation, and other provider-specific events do not get Gateway semantic
types. If an adapter must preserve them, it uses `event.name` and `event.data`.

Gateway core validates only the minimal transport fields for each event type:

| `event.type` | Required `event.data` fields |
| --- | --- |
| `message` | No additional fields. |
| `message_edited` | `target_external_id`. |
| `message_recalled` | `target_external_id`. |
| `reaction` | `target_external_id`, `emoji`, `action`. |
| `action` | `target_external_id`, `action_id`, `values`. |
| `slash_command` | `command_name`, `args`. |
| `trigger` | No additional fields. |

Each `refs` item has this minimal shape:

```elixir
%{"kind" => string, "id" => string, "url" => optional_string}
```

Gateway core does not interpret `ref.kind` and does not use refs as route keys.

## Actor and provenance

Gateway `actor` is a channel-local external identity, not a BullX Principal:

```elixir
%{
  "id" => "ou_xxx",
  "display" => "Alice",
  "bot" => false,
  "profile" => %{"email" => "person@example.com"},
  "metadata" => %{"workspace_key" => "workspace_xxx"}
}
```

`actor.id` may later be input to Principal resolution as an external id, but the
Gateway does not call Principal resolution and does not write Principal ids into
Signals. Principal matching, automatic creation, activation codes, login codes,
and authorization belong to Principal, Admission, and Governance designs.

`provenance` stores adapter-normalized external facts, such as provider event
id, delivery header id, external message id, external timestamp, provider app
id, or a raw body hash. `provenance` must not store plaintext tokens, signature
secrets, OAuth codes, full webhook bodies, or private payloads.

## Inbound publish path

Source lookup happens before adapter verification. Active source listeners are
started from configured sources and therefore carry the normalized runtime
source config when they call the adapter. Passive webhook or callback routes
must identify `{adapter, channel_id}` from a trusted route mount, host, header,
or other transport-specific discriminator, load the enabled source config, and
then call the adapter verification and normalization code with that config.
Unknown or disabled sources are rejected before adapter verification.

Adapters own provider-specific verification and parsing once they receive the
configured source config. Gateway core owns the normalized carrier contract,
policy hooks, Router call, Mailbox enqueue, and transport telemetry.

An adapter is responsible for:

- validating provider signatures, HMAC, JWT, challenge flows, timestamp
  windows, replay headers, tokens, or provider-specific authenticity proofs
  against the supplied source config;
- parsing provider payloads and provider error responses;
- mapping provider events into one of the Gateway `event.type` values;
- constructing `content`, `event.name`, `event.version`, `event.data`, `actor`,
  `refs`, `scope_id`, `thread_id`, `provenance`, and a stable occurrence key;
- ensuring each `normalize_inbound/3` and Gateway publish call handles exactly
  one normalized inbound input;
- applying occurrence-level duplicate suppression before Gateway publish when a
  provider source requires that behavior.

Provider batched payloads must be split by the adapter listener before calling
`normalize_inbound/3` and Gateway publish. The Gateway publish acceptance
contract is defined for one normalized input. Provider acknowledgement and retry
aggregation for batched webhook payloads belongs to the adapter listener.

Gateway publish is responsible for:

- receiving the already looked-up configured source context from the listener
  or route boundary;
- rejecting normalized input whose adapter or channel does not match that
  configured source context;
- validating JSON-neutral values and the Gateway carrier contract;
- validating non-empty `content`, required `event`, `actor`, `scope_id`,
  `thread_id`, `refs`, `reply_channel`, `provenance`, and occurrence key;
- validating minimal fields for the seven Gateway event types without parsing
  adapter-owned business data;
- running transport security, gating, and moderation hooks;
- generating `BullX.Gateway.Signal.id`;
- calling Router / Rule Engine;
- enqueuing returned `DeliveryIntent` values through the Mailbox;
- emitting telemetry.

Gateway publish does not write inbound Signal rows, write a gateway dedupe
table, or save raw provider payloads. If Router returns an empty list, Gateway
can still return accepted. That means the Signal passed Gateway policy and
routing, but no durable internal delivery was created.

The Gateway acceptance boundary is the Mailbox commit. Router results must be
given to `Mailbox.enqueue_all/1` as one batch. Duplicate enqueue counts as
success. If any non-duplicate intent fails to enqueue, the publish fails as a
whole. The implementation must use `Repo.transaction/1`, `Ecto.Multi`, or an
equivalent mechanism so the adapter never receives accepted while only part of
the resolved intent set was persisted.

Gateway publish returns one of these shapes:

```elixir
{:ok, :accepted, signal, mailbox_result}
{:error, %BullX.Gateway.InboundError{} = error}
```

Accepted means the Signal passed Gateway policy, Router returned successfully,
and the Mailbox accepted all resolved delivery intents. The adapter may
acknowledge the provider event according to provider semantics.

An inbound error means the publish did not complete. The adapter combines
`error.retryable?` with provider semantics to decide whether to acknowledge,
retry, reject, or surface provider-specific failure.

`BullX.Gateway.InboundError` contains:

| Field | Requirement |
| --- | --- |
| `class` | One of `:malformed`, `:policy_denied`, `:security_denied`, `:router_unavailable`, `:router_contract`, `:store_unavailable`, `:adapter_contract`, or `:unknown_source`. |
| `retryable?` | Boolean. Defaults to true only for `:router_unavailable` and `:store_unavailable`. |
| `safe_message` | Short message without secrets or raw payload. |
| `details` | JSON-neutral redacted map. |

Error classes mean:

- `:malformed` means the normalized input or Signal carrier shape is invalid.
- `:unknown_source` means `{adapter, channel_id}` is not configured, disabled,
  or not expected for that listener.
- `:security_denied` and `:policy_denied` mean the transport boundary
  explicitly rejected the input.
- `:router_unavailable` means Router, rule storage, or a Router dependency is
  temporarily unavailable.
- `:router_contract` means Router returned invalid `DeliveryIntent` values,
  duplicated required keys, omitted required fields, or raised a non-transient
  contract error.
- `:store_unavailable` means Oban, Repo, Mailbox transaction, or outcome
  publishing storage is unavailable.
- `:adapter_contract` means the adapter returned normalized input that does not
  satisfy the Gateway inbound contract.

Malformed payloads, transport verification failures, and policy denials produce
telemetry and security logs. This design does not persist policy denial as an
audit-grade fact. Audit-grade Governance rejection belongs to Governance and
Effect designs.

## Transport policy hooks

Gateway hooks are limited to transport concerns. Hooks are not Governance and
cannot create Principals, Admission, Work, or Effects.

Inbound hooks run in this order:

```text
Configured source lookup
-> Adapter verification and normalization with source config
-> Gateway carrier validation
-> Security checks normalized source and input
-> Gating decides whether the input may enter the Gateway
-> Moderation flags or redacts transport content
-> Gateway constructs BullX.Gateway.Signal
-> Router.resolve
-> Mailbox.enqueue_all
```

Hook rules:

- `Security` is mandatory. The default implementation checks that the source is
  enabled and that normalized input matches the already selected source.
  Provider signatures stay adapter-owned and use source config supplied before
  normalization.
- `Gating` and `Moderation` are optional configured modules and default to
  no-op. They must have short timeouts and return `:allow`,
  `:allow_with_flags`, `:deny`, or redacted content.
- `:deny` does not construct a Signal, call Router, or write Mailbox jobs. The
  adapter decides provider acknowledgement according to provider semantics.
- Moderation may rewrite `content` and add `bullxflags` or `bullxmoderated`. It
  must not rewrite `id`, `source`, `type`, `time`, `provenance`, `scope_id`,
  `thread_id`, or occurrence key.
- Hook timeout, exception, or invalid return defaults to deny. A
  flag-and-continue fallback is allowed only when source config explicitly
  enables it, and the fallback must write top-level `bullxflags`.

Outbound has only a transport security hook. `Security.sanitize_outbound/2`, or
an equivalent function, runs before adapter calls to remove secrets, validate
deliverable content, and normalize redacted errors. LLM-aware moderation,
persona shaping, approval, and human pause/resume belong to upstream Runtime
and Governance.

## Post-router delivery boundary

Gateway owns the durable transport handoff after Router resolution. That
handoff exists so an adapter can acknowledge an external occurrence only after
BullX has either rejected it or durably accepted every resolved internal
delivery. It is not an Admission layer: Gateway does not decide which Agent may
pay attention, which Work should exist, or which external Effect may happen.

Gateway core depends on one Router callback:

```elixir
resolve(BullX.Gateway.Signal.t()) ::
  {:ok, [BullX.Gateway.DeliveryIntent.t()]} | {:error, term()}
```

The Router owns rule matching, fanout, destination selection, and consumer
descriptor construction outside this design. Gateway validates only the
returned delivery shape, the Gateway-owned queue allowlist, and JSON-safe
payload constraints before persisting jobs.

`BullX.Gateway.DeliveryIntent` is the opaque post-router delivery request
accepted by the Mailbox. It contains a schema version, `delivery_key`,
`signal_occurrence_key`, `route_id`, `consumer_key`, `delivery_kind`, queue
options, an opaque `consumer` descriptor, the serialized Signal, and non-secret
metadata. Gateway treats `consumer` as data for the configured
`ConsumerDelivery` implementation. Gateway must not parse it for Agent,
Admission, Work, Governance, or LLM behavior.

`delivery_key` is the per-delivery idempotency boundary. The canonical input
is:

```text
signal_occurrence_key + route_id + consumer_key + delivery_kind
```

The implementation may encode that tuple as deterministic JSON and hash it
with `BullX.Ext.generic_hash/1`. It must not use Elixir term inspection output
as the canonical encoding.

Route-at-publish semantics are intentionally simple:

- `{:ok, []}` means the publish is accepted and creates no internal delivery.
- Routing applies only at publish time. Already enqueued jobs do not re-route
  when route configuration changes.
- If the same external occurrence arrives again, Gateway calls Router again and
  Mailbox suppresses only duplicate concrete deliveries inside the dedupe
  window.
- Cancelling pending delivery when a route is disabled is an operator,
  Runtime, or Governance concern, not a Gateway Mailbox concern.

`BullX.Gateway.Mailbox` persists resolved delivery intents as Oban jobs. It
does not route Signals, match patterns, maintain subscriptions, replay
historical Signals, create route decisions, or create Admission records.

Mailbox exposes three operations:

```elixir
enqueue(BullX.Gateway.DeliveryIntent.t()) ::
  {:ok, :enqueued | :duplicate, Oban.Job.t()} | {:error, term()}

enqueue_all([BullX.Gateway.DeliveryIntent.t()]) ::
  {:ok, [enqueue_result]} | {:error, term()}

to_multi(Ecto.Multi.t(), name :: atom(), [BullX.Gateway.DeliveryIntent.t()]) ::
  Ecto.Multi.t()
```

`enqueue_all/1` is all-or-nothing for Gateway publish. Duplicate enqueue counts
as success; any non-duplicate insert error rolls back the batch and maps to
`InboundError.class = :store_unavailable`. `to_multi/3` is the composable API
for terminal outcome recording and other callers that already own a
transaction.

All Mailbox jobs use `BullX.Gateway.SignalDeliveryWorker`. Router may choose
the opaque consumer descriptor, allowlisted queue, priority, and max attempts,
but not the worker module. QueueGate controls Gateway-owned queues based on
Runtime and consumer readiness. QueueGate does not wait for Router readiness
because already persisted jobs contain resolved delivery intents.

Mailbox dedupe is finite and per delivery. Oban uniqueness is based on
`delivery_key`, not the whole args map, `Signal.id`, trace id, schema version,
queue, priority, or metadata. Stronger occurrence suppression belongs to the
adapter before publish or to a separate product design.

Mailbox guarantees at-least-once delivery of resolved intents, BEAM crash
recovery for pending jobs, Oban retry, finite duplicate suppression by
`delivery_key`, and eventual completed, cancelled, or discarded job state.
Mailbox does not guarantee consumer side-effect exactly-once, route replay,
historical Signal replay, subscription checkpoints, occurrence-level permanent
dedupe, or per-delivery permanent dedupe.

`BullX.Gateway.SignalDeliveryWorker` restores the `DeliveryIntent`, calls the
configured `BullX.Gateway.ConsumerDelivery`, and maps `:ok`,
`{:retry, reason}`, and `{:discard, reason}` to Oban lifecycle results. The
worker does not route, parse route policy, call inbound adapter parsers, execute
LLM policy, or inspect Agent attention state.

## Adapter source configuration

Gateway adapters are plugin extensions. A plugin contributes an adapter through
the existing `BullX.Plugins` extension contract:

```elixir
%{
  point: :"bullx.gateway.adapter",
  id: "feishu",
  module: MyFeishuPlugin.GatewayAdapter,
  opts: []
}
```

`BullX.Gateway` reads enabled adapter extensions through
`BullX.Plugins.Registry.enabled_extensions_for/1`. The plugin host owns plugin
discovery and enabled-plugin supervision. Gateway owns adapter extension
semantics and configured source runtime behavior.

Configured sources come from a writable runtime configuration projection, not a
new source table. Runtime config must be backed by `BullX.Config` persisted
configuration or an equivalent operator-writable projection. Static environment
or file config may seed startup, but enabling a source, changing a source, or
saving connectivity freshness must write back to the same source config
projection.

The config key is `bullx.gateway.sources`. The stored value is a JSON array:

```json
[
  {
    "adapter": "feishu",
    "channel_id": "main",
    "enabled": true,
    "config": {
      "app_id": "cli_xxx",
      "secret_ref": "bullx.plugins.feishu.app_secret"
    },
    "outbound_retry": {
      "max_attempts": 3,
      "base_ms": 250,
      "max_ms": 10000
    },
    "connectivity": {
      "fingerprint": "sha256:redacted-config-fingerprint",
      "checked_at": "2026-05-13T00:00:00Z",
      "status": "ok",
      "max_age_seconds": 86400,
      "details": {"provider": "feishu"}
    }
  }
]
```

Configured source rules:

- `{adapter, channel_id}` is unique after lowercasing.
- `adapter` must match an enabled `:"bullx.gateway.adapter"` extension id.
- `channel_id` is a configured source id, not an external room, tenant, or user.
- Plaintext secrets stay in `BullX.Config` secret declarations. Source config
  may reference secret keys but must not inline secret values into Signals,
  Oban args, telemetry, or dead-letter rows.
- Invalid config follows existing `BullX.Config` fallback rules. An enabled
  source using an unknown adapter is a Gateway startup or config error.
- Disabled source drafts may be stored in config or control-plane projection,
  but Gateway runtime does not start source children for them and does not allow
  outbound lookup through them.
- Enabling or materially changing a source requires a fresh successful
  `connectivity_check` for the exact redacted config fingerprint unless the
  caller explicitly saves the source as a disabled draft.
- `connectivity.fingerprint` is based on normalized non-secret config and
  secret reference names. It must not use secret values.
- `connectivity.details` is redacted and operator-facing.
- Connectivity freshness applies only to the exact current fingerprint. If
  `connectivity.max_age_seconds` is configured, freshness also requires
  `checked_at` inside that window. Without `max_age_seconds`, freshness requires
  only the same fingerprint and `status = "ok"`.
- `connectivity` lives in the same projection entry as the source config.
  Gateway startup trusts only the current entry's `fingerprint`, `checked_at`,
  and `status`; it does not infer freshness from process memory, telemetry, or
  an operator session.

Adapter-specific source config belongs to the adapter extension. Gateway core
orchestrates source storage, fingerprinting, common validation, and lifecycle.
Each adapter extension supplies its own config codec and public redaction.

Adapter behaviour:

| Callback | Responsibility |
| --- | --- |
| `config_schema/0` | Declare adapter-owned source config shape, defaults, secret refs, and generated fields. |
| `normalize_config/1` | Cast persisted JSON config into adapter runtime config. |
| `public_config/1` | Return operator-facing redacted config projection. |
| `capabilities/0` | Declare inbound modes, outbound operations, content kinds, and stream strategy. |
| `connectivity_check/1` | Validate submitted source config without starting a listener or publishing a Signal. |
| `source_child_spec/1` | Return listener, poller, or consumer child spec for an enabled source; the child receives normalized runtime source config; passive adapters may return `:ignore`. |
| `normalize_inbound/3` | Convert one provider payload plus source config and request metadata into one normalized inbound input. Batched payloads must be split before this callback. |
| `deliver/2` | Execute external `:send` or `:edit` Delivery. |
| `stream/3` | Execute external `:stream` Delivery. |

`capabilities/0` must be specific enough for Gateway core to reject unsupported
transport before calling the adapter.

| Axis | Values |
| --- | --- |
| `inbound_modes` | Adapter-owned modes such as webhook, websocket, poller, passive, or timer. |
| `outbound_ops` | Supported external `Delivery.op` values: `:send`, `:edit`, `:stream`. |
| `content_kinds` | Supported outbound content block kinds: `:text`, `:image`, `:audio`, `:video`, `:file`, `:card`. |
| `stream_strategy` | `:native`, `:post_edit`, `:buffered`, or `:unsupported`. |

Gateway validates `outbound_ops` and `content_kinds` for each external
Delivery. `stream_strategy = :unsupported` makes `:stream` fail with
`:unsupported_op` before any adapter call. Capability declarations are
transport facts. They do not define routing, Admission, Agent behavior, or
business policy.

Webhook route mounting is outside this design. A Phoenix route, Plug, Bandit
handler, or provider callback topology may call `normalize_inbound/3`, but it
must identify the configured source and load source config before adapter
verification. The route shape belongs to the Web boundary.

## External outbound delivery

External outbound delivery answers one question: how an already constructed and
allowed `Delivery` reaches an external channel. It does not answer why an Agent
responds, which Gateway should be used, or whether an external action passed
Governance.

`BullX.Gateway.deliver/1` accepts an external `Delivery`:

| Field | Requirement |
| --- | --- |
| `id` | Caller-provided UUIDv7. The same intended external effect must reuse the same id. |
| `generation` | Non-negative integer. Normal delivery uses `0`; dead-letter replay uses `> 0`. |
| `op` | `:send`, `:edit`, or `:stream`. |
| `channel` | `{adapter, channel_id}` configured source key. |
| `scope_id` | Adapter-local external conversation, repository, feed, or timer scope. |
| `thread_id` | Optional adapter-local thread key. |
| `reply_to_external_id` | Optional external message id used for replies. |
| `target_external_id` | Required for `:edit`. |
| `content` | Non-empty content block list for `:send` and `:edit`; live Enumerable deltas for `:stream`. |
| `caused_by_signal_id` | Optional Signal id for correlation. It need not exist in a table. |
| `extensions` | Adapter-specific, JSON-neutral, non-secret hints. |

Outbound content blocks reuse the inbound content block kinds and fallback
rules. Before invoking an adapter, Gateway validates the Delivery carrier
shape, adapter operation support, content kind support, stream strategy, and
outbound transport sanitization. Gateway does not run LLM-aware moderation,
persona shaping, approval, or human pause/resume.

`BullX.Gateway.deliver/1` returns after Gateway acceptance. It does not wait for
provider terminal success or failure:

```elixir
{:ok, :accepted, delivery_id}
{:error, %BullX.Gateway.OutboundError{}}
```

An accepted Delivery can fail later. Terminal results are expressed as
`com.agentbull.x.delivery.succeeded` or `com.agentbull.x.delivery.failed`
Signals. Gateway constructs the outcome Signal, calls Router.resolve, and
enqueues resolved `DeliveryIntent` values through the Mailbox. It does not write
outcome Signals into a `signals` table.

The outbound dispatch buffer is best-effort. It reduces accepted Delivery loss
after an Elixir container crash, but it is not a highly available durable queue
and does not guarantee external exactly-once effects. UNLOGGED buffer rows can
be lost after PostgreSQL crash, unclean shutdown, disk loss, or failover. If a
provider accepted an external effect but Gateway crashed before recording a
terminal outcome, Gateway cannot know whether the effect happened unless the
provider supports an idempotency key based on `delivery_id` or an adapter-owned
idempotency key. Upstream Runtime or Effect code must still track unresolved
business effects and resubmit when terminal outcome is missing.

`BullX.Gateway.OutboundError` contains:

| Field | Requirement |
| --- | --- |
| `class` | One of `:malformed`, `:unknown_source`, `:security_denied`, `:unsupported_op`, `:already_dead_lettered`, `:not_replayable`, or `:store_unavailable`. |
| `retryable?` | Boolean. Defaults to true only for `:store_unavailable`. |
| `safe_message` | Short message without secrets or raw payload. |
| `details` | JSON-neutral redacted map. |

An outbound `Outcome` is a transport result:

| Field | Requirement |
| --- | --- |
| `delivery_id` | Original `Delivery.id`. |
| `generation` | Delivery generation. Normal delivery is `0`; replay is `> 0`. |
| `status` | `:sent`, `:degraded`, or `:failed`. |
| `external_message_ids` | Provider message or effect ids. |
| `primary_external_id` | Optional primary id for later edit or reply. |
| `warnings` | Required and non-empty when `status = :degraded`. |
| `error` | Required, JSON-neutral, and redacted when `status = :failed`. |

Adapter success callbacks can return only `:sent` or `:degraded` outcomes.
Unsupported operations, capability mismatch, security denial, and carrier shape
errors before Gateway acceptance return synchronous `OutboundError` and do not
produce terminal outcomes. After Gateway acceptance, adapter errors, adapter
exceptions, unsupported returns, contract violations, and attempts-exhausted
states normalize to `:failed`.

Outcome Signals use strict CloudEvents JSON Event Format. The outcome
`bullxoccurkey` is stable:

```text
gateway:delivery:<delivery_id>:<generation>:outcome
```

An outcome Signal uses a new UUIDv7 `id`, the configured source in `source`,
and terminal recording time in `time`. Its `data` has this shape:

```elixir
%{
  "delivery" => %{
    "id" => delivery_id,
    "generation" => generation,
    "adapter" => adapter,
    "channel_id" => channel_id,
    "scope_id" => scope_id,
    "thread_id" => thread_id
  },
  "outcome" => %{
    "status" => "sent" | "degraded" | "failed",
    "external_message_ids" => external_message_ids,
    "primary_external_id" => primary_external_id,
    "warnings" => warnings,
    "error" => redacted_error
  }
}
```

`delivery.succeeded` uses `outcome.status = "sent"` or `"degraded"`.
`delivery.failed` uses `outcome.status = "failed"` and must include redacted
`error`. Outcome Signals do not use the inbound `content + event` data
contract.

## Outbound retry contract

Gateway outbound retry covers transport delivery only. It does not retry
business Effect decisions. `Delivery.id` remains the same across all retry
attempts for one generation.

`ScopeWorker` retries `:send` and `:edit` adapter calls:

- `max_attempts` comes from source runtime config `outbound_retry`; the default
  is `3`.
- Backoff uses `BullX.Retry` or an equivalent exponential backoff. Adapter
  `retry_after_ms` details take precedence when present, but must be capped by
  Gateway config.
- Retryable adapter error kinds are `"rate_limit"`, `"network"`, `"timeout"`,
  and `"provider_unavailable"`.
- Terminal adapter error kinds are `"auth"`, `"permission"`, `"not_found"`,
  `"payload"`, `"unsupported"`, `"contract"`, and `"security_denied"`.
- Unknown error kinds are terminal unless the adapter explicitly sets
  `details["is_transient"] = true`.
- Adapter exception, exit, throw, and success-path contract violation normalize
  to terminal `:failed` outcome with `error.kind = "exception"` or
  `"contract"`.
- Attempts exhaustion normalizes to terminal `:failed` outcome. The final error
  keeps the last error kind and records `attempts_exhausted = true` in details.

`:stream` is not automatically retried after Gateway begins consuming the live
Enumerable. Adapter error, task exit, adapter restart, or operator cancellation
produces terminal `delivery.failed`; the dead-letter row has
`replayable = false`. Stream terminal success and terminal failure both enter
terminal finalization: Gateway captures `terminal_outcome`, publishes an
outcome Signal through Router, writes a receipt, and enqueues outcome Mailbox
jobs in the same transaction. Terminal stream failure also writes a
non-replayable dead-letter summary. If `:stream` is rejected before adapter
invocation because of capability, security, or shape validation, Gateway
returns synchronous `OutboundError` and does not produce a terminal outcome.

If terminal finalization hits `:store_unavailable` after the terminal outcome
has been captured in the dispatch row, `ScopeWorker` must not call the external
provider again. It retries only receipt, dead-letter, and outcome mailbox job
persistence. If BEAM crashes after provider acceptance but before
`terminal_outcome` is written to the dispatch row, recovery can only see a stale
`running` row and may invoke the provider again after lock timeout. Avoiding
duplicate external effects depends on provider support for `delivery_id` or an
adapter-owned idempotency key.

## Best-effort outbound dispatch buffer

Gateway uses PostgreSQL UNLOGGED tables for best-effort outbound dispatch
buffering. The goal is to recover accepted outbound Delivery rows after an
Elixir container crash. The buffer is not fully durable: PostgreSQL crash,
unclean shutdown, UNLOGGED table truncation, disk loss, or replica failover can
lose accepted Delivery rows.

`LISTEN/NOTIFY` is only a wakeup mechanism. Business data must be written to the
UNLOGGED table first, and `pg_notify/2` must run in the same transaction. Worker
startup and reconnect must scan pending, running, and active rows before
relying on notifications. Notifications are not a reliable queue.

Discrete `:send` and `:edit` deliveries use `gateway_outbound_dispatches`:

| Column | Type | Meaning |
| --- | --- | --- |
| `delivery_id` | `uuid` | Original Delivery id. |
| `generation` | `integer` | Normal delivery is `0`; replay is `> 0`. |
| `op` | native enum | `send` or `edit`. |
| `status` | native enum | `pending`, `running`, or `terminalizing`. |
| `adapter` | `text` | Configured adapter id. |
| `channel_id` | `text` | Configured source id. |
| `scope_id` | `text` | Adapter-local scope. |
| `delivery` | `jsonb` | Replayable, JSON-neutral Delivery snapshot. Secrets are redacted; message content is not redacted. |
| `terminal_outcome` | `jsonb` | Nullable redacted terminal outcome snapshot. |
| `attempts` | `integer` | Adapter attempts already executed. |
| `next_attempt_at` | `utc_datetime_usec` | Next eligible attempt time. |
| `locked_by` | `text` | Nullable worker identity. |
| `locked_at` | `utc_datetime_usec` | Nullable lock time. |
| `inserted_at` | `utc_datetime_usec` | Insert time. |
| `updated_at` | `utc_datetime_usec` | Update time. |

The primary key is `{delivery_id, generation}`. For `:send` and `:edit`,
`deliver/1` writes this row before acceptance and calls
`pg_notify('gateway_outbound_dispatches', delivery_id:generation)` in the same
transaction. Only after commit does `deliver/1` return
`{:ok, :accepted, delivery_id}`. If the same `{delivery_id, generation}` is
already pending, running, or terminalizing, `deliver/1` returns accepted without
writing a duplicate row.

The outbound dispatcher claims due rows from `gateway_outbound_dispatches` and
hands each row to a `ScopeWorker`. `ScopeWorker` serializes adapter calls by
`{adapter, channel_id, scope_id}`. Retryable failure updates `attempts` and
`next_attempt_at` and releases the lock.

After the adapter returns a terminal outcome, the worker first writes the
redacted outcome snapshot into `terminal_outcome` and changes the row to
`terminalizing`. That row is the recovery source until terminal finalization
finishes. Receipt visibility depends on outcome routing availability: Gateway
does not write a receipt before Router resolves the outcome Signal and the
receipt, optional dead letter, and outcome Mailbox jobs commit together.
If finalization fails, the row remains `terminalizing`; recovery retries
finalization from `terminal_outcome` and must not invoke the provider again.

If BEAM crashes during adapter invocation or after adapter return but before
`terminal_outcome` is written, the row may remain `running`. Recovery may retry
after stale lock timeout, which can duplicate provider side effects. Gateway can
only pass `delivery_id` or an adapter-owned idempotency key to the provider; it
does not provide provider side exactly-once behavior.

## Stream buffer

Stream delivery uses resumable-stream-style best-effort buffering. `:stream`
acceptance means a `gateway_stream_sessions` row has been written and stream
execution has been handed to a supervised Gateway execution boundary.
`deliver/1` does not wait for chunks or provider terminal outcome. If `:stream`
is rejected before session creation, Gateway returns synchronous
`OutboundError` and does not produce a terminal outcome.

`gateway_stream_sessions`:

| Column | Type | Meaning |
| --- | --- | --- |
| `stream_id` | `uuid` | Stream session id; defaults to `Delivery.id` or a generation-derived id. |
| `delivery_id` | `uuid` | Original Delivery id. |
| `generation` | `integer` | Delivery generation. |
| `adapter` | `text` | Configured adapter id. |
| `channel_id` | `text` | Configured source id. |
| `scope_id` | `text` | Adapter-local scope. |
| `strategy` | native enum | `native`, `post_edit`, or `buffered`. |
| `status` | native enum | `active`, `terminalizing`, `succeeded`, `failed`, or `cancelled`. |
| `last_seq` | `bigint` | Highest written application-level batch sequence. |
| `terminal_outcome` | `jsonb` | Nullable redacted terminal outcome. |
| `expires_at` | `utc_datetime_usec` | Buffer expiration time. |
| `inserted_at` | `utc_datetime_usec` | Insert time. |
| `updated_at` | `utc_datetime_usec` | Update time. |

`gateway_stream_chunks`:

| Column | Type | Meaning |
| --- | --- | --- |
| `stream_id` | `uuid` | Stream session id. |
| `seq` | `bigint` | Application-level batch sequence starting at 1. It is not a provider chunk or token sequence. |
| `chunk` | `jsonb` | JSON-neutral application-level batch snapshot. It is not a raw provider or HTTP chunk and contains no secrets. |
| `inserted_at` | `utc_datetime_usec` | Insert time. |
| `expires_at` | `utc_datetime_usec` | Buffer expiration time. |

The primary key is `{stream_id, seq}`. The Gateway stream wrapper must not write
every upstream HTTP chunk, provider event, or LLM token delta to PostgreSQL. It
first aggregates deltas into Gateway application-level batches.

Text streams flush a batch at least when one of these conditions is true:

- accumulated text reaches a newline;
- accumulated visible text exceeds 10 characters;
- stream completes;
- stream fails;
- stream is cancelled.

Non-text content flushes as a complete block or provider-neutral event batch.
Empty deltas, heartbeats, and provider-only metadata do not create PostgreSQL
chunks unless they represent application-level recoverable state.

Each batch append writes `gateway_stream_chunks`, updates `last_seq`, and calls
`pg_notify('gateway_stream_chunks', stream_id:seq)` in the same transaction.
Resume reads `stream_id + seq` from PostgreSQL. Notifications wake waiters but
do not carry business data. Resume guarantees reconstruction only for
application-level batches already written to PostgreSQL. It does not promise
token-level recovery. The final batch must flush before terminal outcome.

The stream buffer provides best-effort resumability. Gateway can reconstruct
previously appended batches, but it cannot continue a crashed producer, recover
unwritten final fragments, guarantee provider side-effect exactly-once, or
recover stream state after UNLOGGED table truncation. For `:native` and
`:post_edit`, adapters may use provider resume/session ids when available. For
`:buffered`, Gateway can send the final non-streaming message only if the stream
fully wrote and terminal state is known; partial streams can only fail or
degrade.

Stream terminal success and failure use the same terminal finalization path as
discrete deliveries. The stream session row captures the redacted
`terminal_outcome` and remains the recovery source while finalization is
pending. A successful stream writes a succeeded receipt. A failed stream writes
a dead-lettered receipt and a non-replayable dead-letter summary. Receipt
visibility still depends on Router resolving the outcome Signal and the
receipt, optional dead letter, and outcome Mailbox jobs committing atomically.

Every best-effort buffer row has TTL through `expires_at`. A Gateway retention
worker deletes expired rows. Retention controls storage usage and is not
business audit.

## Terminal receipts and dead letters

Gateway stores a lightweight terminal receipt ledger for external
`Delivery.id` idempotency. The receipt table is not a dispatch queue and cannot
reconstruct queued or in-flight delivery.

`gateway_delivery_receipts`:

| Column | Type | Meaning |
| --- | --- | --- |
| `delivery_id` | `uuid` | Original Delivery id. |
| `generation` | `integer` | Normal delivery is `0`; replay attempts are `> 0`. |
| `adapter` | `text` | Configured adapter id. |
| `channel_id` | `text` | Configured source id. |
| `scope_id` | `text` | Adapter-local scope. |
| `terminal_status` | native enum | `succeeded` or `dead_lettered`. |
| `outcome_signal_id` | `uuid` | Terminal outcome Signal id. The Signal does not need a table row. |
| `dead_letter_id` | `uuid` | Nullable; set for terminal failure. |
| `updated_at` | `utc_datetime_usec` | Last terminal receipt update time. |

The primary key is `{delivery_id, generation}`. Normal `deliver/1` uses
`generation = 0`. Dead-letter replay increments the dead-letter `replay_count`
and uses that value as the new generation.

If `{delivery_id, generation}` already has a `succeeded` receipt, Gateway
returns `{:ok, :accepted, delivery_id}` and does not call the adapter again. If
it already has a `dead_lettered` receipt, normal `deliver/1` returns
`:already_dead_lettered`; recovery must use dead-letter replay or a new
Delivery id chosen by upstream code.

Gateway must capture terminal outcome before terminal finalization. For
discrete deliveries, the worker writes redacted `terminal_outcome` to the
dispatch row and changes the row to `terminalizing`. For streams, the Gateway
execution boundary writes redacted `terminal_outcome` to the stream session row
and changes the stream session status to `terminalizing`. From that point, the
terminalizing row plus
`terminal_outcome` is the recovery source, and recovery can retry only terminal
finalization, not provider invocation or stream execution.

Terminal finalization constructs an outcome Signal and calls Router.resolve to
obtain zero or more outcome `DeliveryIntent` values. Router unavailable, Router
timeout, or invalid outcome intents fail finalization. Receipt and dead-letter
rows remain unwritten, and the terminalizing dispatch or stream session row
stays available for retry. Until finalization commits, operator receipt lookup
does not show the terminal result; recovery reads `terminal_outcome` from the
terminalizing row.

After Router succeeds, Gateway uses one `Repo.transaction/1`, `Ecto.Multi`, or
equivalent atomic transaction:

- For `delivery.succeeded`, write or update `gateway_delivery_receipts` and
  enqueue all outcome Signal DeliveryIntent jobs through Mailbox `to_multi/3`.
- For `delivery.failed` with `replayable = true`, write or update
  `gateway_dead_letters`, write or update `gateway_delivery_receipts`, and
  enqueue all failed outcome Signal DeliveryIntent jobs through
  Mailbox `to_multi/3`.
- For `delivery.failed` with `replayable = false`, write a redacted
  non-replayable dead-letter summary, write or update
  `gateway_delivery_receipts`, and enqueue all failed outcome Signal
  DeliveryIntent jobs through Mailbox `to_multi/3`.

If receipt or dead-letter write succeeds but an outcome DeliveryIntent enqueue
fails, the transaction must roll back. Finalization failure returns
`OutboundError.class = :store_unavailable` with `retryable? = true`.
Successful finalization deletes the discrete dispatch row or updates the stream
session status to the final stream state. Finalization failure leaves the
dispatch or stream session row in `terminalizing`.

`gateway_dead_letters` stores terminal delivery failures for operator or
upstream runtime replay.

| Column | Type | Meaning |
| --- | --- | --- |
| `id` | `uuid` | BullX UUIDv7 primary key. |
| `delivery_id` | `uuid` | Original Delivery id; indexed. |
| `adapter` | `text` | Configured adapter id. |
| `channel_id` | `text` | Configured source id. |
| `scope_id` | `text` | Adapter-local scope. |
| `thread_id` | `text` | Nullable. |
| `delivery` | `jsonb` | Replayable JSON-neutral Delivery snapshot for `:send` and `:edit`; nullable when `replayable = false`. |
| `summary` | `jsonb` | Redacted terminal summary. Stream failures store non-replayable summary here. |
| `last_error` | `jsonb` | Redacted error map. |
| `attempts_total` | `integer` | Attempts before terminal failure. |
| `replayable` | `boolean` | False for stream failures. |
| `replay_count` | `integer` | Starts at 0. |
| `inserted_at` | `utc_datetime_usec` | Insert time. |
| `updated_at` | `utc_datetime_usec` | Last replay or update time. |

`gateway_dead_letters` is a normal logged PostgreSQL table. Operator recovery
needs stronger persistence than the best-effort dispatch buffer.

Dead letters redact secrets, credentials, tokens, signatures, OAuth codes,
private adapter config, and private file handles. Replayable snapshots may
include message content and external target identifiers required for replay, so
dead-letter access is sensitive operator access and not a general audit browsing
surface.

`:stream` is a live transport operation. Its content is an Enumerable, and the
provider may have already received partial output. Gateway does not store stream
chunks as replayable dead-letter content and does not replay stream dead
letters. Stream failure rows use `replayable = false`, `delivery = null`, and a
redacted summary.

Adapter stream strategies:

| Strategy | Meaning |
| --- | --- |
| `:native` | Provider supports incremental streaming; adapter sends chunks. |
| `:post_edit` | Adapter sends a placeholder or first message, then edits as chunks arrive. |
| `:buffered` | Adapter consumes the stream and sends one final non-streaming message. |
| `:unsupported` | Gateway rejects `:stream` with `:unsupported_op` before adapter invocation. |

For `:native` and `:post_edit`, external users may see partial output before
terminal success. For `:buffered`, Gateway can send the final non-streaming
message only when full stream state has been recorded. Adapter error, task exit,
adapter restart, or operator cancellation produces `delivery.failed` and a
non-replayable dead-letter summary.

`BullX.Gateway.replay_dead_letter/1` loads a replayable Delivery snapshot,
increments `replay_count`, sets replay generation, and submits the Delivery to
the best-effort dispatch buffer. Replay success publishes `delivery.succeeded`;
replay failure updates `last_error` and publishes `delivery.failed`.
Non-replayable rows return `OutboundError.class = :not_replayable`.

## Supervision and startup

Gateway adds a core supervisor and source supervisor. Gateway does not carry
Runtime. Runtime consumes and produces Signals under a separate design.

Startup order preserves the ingress gate: Gateway core can start before Runtime
because it provides registries, Mailbox API, buffer API, ScopeWorker supervision,
and dead-letter replay infrastructure. Oban can also start before Runtime, but
Gateway queues must stay paused or inactive until Runtime and consumer delivery
boundaries are ready. QueueGate does not wait for Router readiness because
Mailbox jobs already contain resolved delivery intents. Inbound publish and
terminal finalization check Router availability at the point where they resolve
Signals; Router unavailability returns a retryable publish or finalization
error instead of blocking already resolved Mailbox job execution.

Target startup order:

```text
BullX.Repo
-> BullX.Config.Supervisor
-> BullX.Principals.Bootstrap
-> BullX.I18n.Catalog
-> BullX.Plugins.Supervisor
-> Oban
-> BullX.Gateway.Supervisor
-> BullX.Runtime.Supervisor
-> BullX.Gateway.SourceSupervisor
-> BullXWeb.Endpoint
```

`BullX.Gateway.Supervisor` owns:

- adapter registry or equivalent reconstructible state from enabled plugin
  extensions and `bullx.gateway.sources`;
- scope registry and scope supervisor for outbound `ScopeWorker` processes;
- QueueGate or equivalent gate that resumes or starts Gateway Oban queues after
  Runtime and consumer delivery readiness;
- outbound dispatcher that scans `gateway_outbound_dispatches`, handles
  `LISTEN/NOTIFY` wakeups, claims due rows, and hands discrete deliveries to
  `ScopeWorker`;
- stream buffer and retention workers for stream session and chunk append,
  resume reads, and TTL cleanup;
- dead-letter replay supervisor when replay workers need bounded concurrency.

`BullX.Gateway.SourceSupervisor` owns enabled source listeners, pollers, and
consumers. It reads Gateway core adapter registry and source config projection,
but starts after `BullX.Runtime.Supervisor`.

If Router becomes temporarily unavailable after startup, inbound publish returns
`InboundError.class = :router_unavailable`, and the adapter decides provider
retry or reject semantics. Terminal finalization keeps the terminalizing row and
retries from `terminal_outcome`. If a Mailbox worker calls a temporarily
unavailable Runtime consumer, `ConsumerDelivery` returns `{:retry, reason}`.

Oban owns Mailbox job persistence, retry, crash recovery, and job lifecycle.
Gateway Supervisor restart reconstructs adapter and source state from config
and plugin registry. Pending Mailbox jobs remain in Oban and do not depend on
Gateway process memory. Gateway event delivery does not depend on
Phoenix.PubSub.

## Telemetry and observability

Gateway telemetry serves transport operations and operator diagnosis. It is not
input to business routing decisions.

Events:

- `[:bullx, :gateway, :inbound, :start | :stop | :exception]`
- `[:bullx, :gateway, :signal, :publish, :start | :stop | :exception]`
- `[:bullx, :gateway, :mailbox, :enqueue, :start | :stop | :exception]`
- `[:bullx, :gateway, :mailbox, :delivery, :start | :stop | :exception]`
- `[:bullx, :gateway, :delivery, :start | :stop | :exception]`
- `[:bullx, :gateway, :delivery, :finished]`
- `[:bullx, :gateway, :dispatch_buffer, :claim | :recover | :notify | :exception]`
- `[:bullx, :gateway, :stream_buffer, :append | :resume | :expire | :exception]`
- `[:bullx, :gateway, :dead_letter, :replay, :start | :stop | :exception]`

Metadata may include `adapter`, `channel_id`, `scope_id`, `event_type`,
`event_name`, `signal_id`, `signal_occurrence_key`, `route_id`, `consumer_key`,
`delivery_key`, `delivery_id`, `generation`, `outcome`, `attempts`, and
`duplicate?`.

Metadata must not include raw webhook bodies, content text, tokens, signatures,
OAuth codes, private files, private adapter config, or provider secrets.

## Security, Privacy, Governance

BullX plugins are trusted compile-time extensions. Gateway still keeps the
transport security boundary explicit:

- Source listeners or callback routes identify the configured source and load
  source config before adapter verification.
- Adapters verify provider authenticity before normalization using that source
  config.
- Gateway rejects unknown or disabled configured sources.
- Gateway stores normalized Mailbox payloads and does not store raw provider
  bodies.
- Oban args may contain Signal content, so Mailbox access is
  operator-sensitive.
- Outbound dispatch buffers and stream buffers may contain message content,
  external target identifiers, and partial chunks, so buffer access is
  operator-sensitive.
- Adapter and Gateway error maps preserve useful root-cause class while
  redacting secrets.
- Source config stores secret references, not secret values.
- Dead-letter access is sensitive because replayable snapshots may contain
  message content and external target identifiers.
- Gateway `actor` remains an external channel-local identity until a Principal
  design resolves it.
- Gateway does not approve risky outbound actions. Governance and Effect
  designs decide when external Delivery may be submitted.

## Alternatives Considered

### Persist inbound Signal rows

Persisting every inbound Signal would provide a historical event log, but it
would also make Gateway responsible for audit, replay, retention, and privacy
semantics that belong to product-level Signal, Admission, Work, Governance, or
Brain designs. This design keeps inbound Signals as normalized envelopes and
Mailbox payloads. Only resolved delivery intents and outbound recovery records
are durable Gateway facts.

### Use a process-local event bus for Gateway delivery

A process-local bus would reduce storage writes, but it would lose pending
delivery on process restart and make crash recovery depend on process memory.
Gateway delivery needs durable at-least-once semantics for resolved intents, so
the Mailbox uses Oban.

### Let Mailbox route Signals

Routing inside Mailbox would mix pattern matching, permissions, fanout, and
consumer selection into the delivery persistence layer. This design keeps Router
as the only route resolver and makes Mailbox responsible only for delivery of
already resolved intents.

### Make outbound dispatch fully durable

A logged durable outbound queue would reduce accepted Delivery loss during
PostgreSQL failure, but it would imply a stronger guarantee that Gateway cannot
carry through provider side effects. The selected UNLOGGED buffer states the
real guarantee: best-effort recovery from Elixir container crashes, not
provider exactly-once or cross-database crash durability. Business code must
track unresolved Effects above Gateway.

### Store configured sources as first-class tables

First-class source tables would support richer control-plane workflows, but the
current plugin and configuration designs already provide writable runtime
configuration and secret references. This design keeps configured sources in
`BullX.Config` until a separate control-plane design requires stronger source
state.

## Implementation Handoff

### Goal

Implement `BullX.Gateway` as a transport boundary that normalizes inbound
Signals, resolves them through Router, persists resolved `DeliveryIntent` values
through an Oban-backed Mailbox, and supports external channel Delivery through
best-effort dispatch buffers, terminal receipts, and dead-letter replay. Do not
persist inbound events as Signal rows.

### Context Pointers

- `docs/design-docs/Plugins.md`
- `docs/design-docs/Configuration.md`
- `docs/design-docs/Principal.md`
- `lib/bullx/plugins/*`
- `lib/bullx/principals/*`
- `lib/bullx/retry.ex`
- Oban documentation for unique jobs, worker return values, and engine
  differences.

### Constraints

- Use the existing plugin extension registry for adapter contributions.
- Use runtime configuration for configured sources.
- Use BullX-side UUIDv7 generation for UUID primary keys.
- Keep inbound Signal persistence out of scope.
- Keep Router rule language, Agent selection, Admission, Principal resolution,
  Governance, and Effect approval out of Gateway.
- Keep process-local state reconstructible from PostgreSQL, runtime config, and
  plugin registry.
- Keep Gateway-owned Mailbox execution queues behind Runtime and consumer
  readiness gating. Do not gate already resolved Mailbox job execution on Router
  readiness.
- Gate Router use only where Router is actually called: inbound publish and
  terminal finalization.

### Tasks

1. Add Oban infrastructure and Gateway queue configuration.
   Acceptance: migrations, supervision, queues, and test mode can enqueue
   Gateway Mailbox jobs. Gateway queues are paused or inactive before Runtime
   and consumer delivery readiness, then resume or start after those boundaries
   are ready. QueueGate does not wait for Router readiness. Gateway does not use
   Phoenix.PubSub as its event bus.

2. Add `BullX.Gateway.Signal` validation, `dump/1`, and `load/1`.
   Acceptance: serialization uses strict CloudEvents 1.0 JSON Event Format;
   extension attributes are top-level lowercase alphanumeric properties;
   `source` is a non-empty URI reference; `time` is an RFC3339 timestamp;
   nested `extensions` maps are rejected; `data` is a JSON object;
   `bullxoccurkey` is required; Gateway carriers require `bullxadapter` and
   `bullxchannel`; no inbound Signal table or durable append context is added.

3. Add adapter config and adapter behaviour.
   Acceptance: `{adapter, channel_id}` is unique after lowercasing; disabled
   drafts do not enter runtime; public config redacts secrets; connectivity
   fingerprint, checked-at metadata, and optional max age live in the same
   writable source config projection; freshness applies only to the exact
   fingerprint; `outbound_retry` is readable; capabilities expose inbound modes,
   outbound ops, content kinds, and stream strategy.

4. Add the inbound normalization facade.
   Acceptance: source lookup happens before adapter verification, either
   because the active listener already carries source config or because a
   passive callback route identifies `{adapter, channel_id}` and loads source
   config before adapter verification; `normalize_inbound/3` and Gateway
   publish handle one normalized input per call; batched provider payloads are
   split by adapter listeners; a mock adapter can produce
   `com.agentbull.x.inbound.received`; required
   `content`, `event`, `actor`, `refs`, `provenance`, `scope_id`, `thread_id`,
   `reply_channel`, and occurrence key rules are enforced; the seven event
   types validate only minimal transport fields.

5. Add transport security, gating, and moderation hooks.
   Acceptance: denial does not construct a Signal, call Router, or write
   Mailbox jobs; timeout and error default to denial; flags and redactions use
   top-level CloudEvents extension attributes or redacted metadata; hooks do not
   change provenance, scope, thread, or occurrence key.

6. Add Router boundary and test stub.
   Acceptance: Gateway depends only on
   `resolve(signal) :: {:ok, [DeliveryIntent]} | {:error, reason}`; Router
   unavailable maps to `:router_unavailable`; invalid intents map to
   `:router_contract`; implementation does not include rule syntax, priorities,
   Agent selection, or LLM routing policy.

7. Add `BullX.Gateway.DeliveryIntent`.
   Acceptance: `delivery_key` is based on canonical
   `signal_occurrence_key + route_id + consumer_key + delivery_kind`; fanout to
   multiple consumers creates distinct keys; queue must be from a Gateway-owned
   allowlist; dumped data is JSON-serializable.

8. Add `BullX.Gateway.Mailbox`.
   Acceptance: `enqueue/1` and `enqueue_all/1` use per-job Oban uniqueness;
   default implementation inserts jobs one at a time; uniqueness is based on
   `delivery_key`; `states: :all` and a finite dedupe period are used; duplicate
   enqueue counts as success; any non-duplicate failure rolls back
   `enqueue_all/1`; `to_multi/3` or equivalent composable API exists for
   terminal finalization; args do not contain raw bodies, secrets, file handles,
   or unstable structs.

9. Add `BullX.Gateway.SignalDeliveryWorker` and
   `BullX.Gateway.ConsumerDelivery`.
   Acceptance: worker module is fixed; consumer returns `:ok`,
   `{:retry, reason}`, or `{:discard, reason}`; discard maps to Oban
   `cancelled`; retry, exception, exit, and throw follow Oban retry and enter
   `discarded` only after attempts are exhausted.

10. Add external outbound Delivery, Outcome, retry, dispatch buffers, stream
    buffers, receipts, dead letters, and replay.
    Acceptance: `deliver/1` returns after Gateway acceptance; unsupported
    operation, content kind, or stream strategy is rejected before adapter call;
    `:send` and `:edit` acceptance occurs only after dispatch row commit and
    notification transaction; identical `{delivery_id, generation}` in pending,
    running, or terminalizing state returns accepted; dispatcher scans buffers
    before relying on notifications; `:stream` acceptance occurs after session
    row write and supervised execution handoff; stream wrapper writes
    application-level batches, not raw provider chunks; terminal outcome
    snapshot is captured before Router.resolve; receipt visibility depends on
    outcome routing availability; terminalizing dispatch or stream session row
    plus `terminal_outcome` is the recovery source; receipt or dead-letter
    writes and outcome Mailbox jobs commit atomically; terminal finalization
    retry does not call the provider again; stream success writes a receipt;
    stream failure writes a receipt plus non-replayable DLQ row; replay uses
    generation `> 0`.

11. Add `BullX.Gateway.Supervisor` and `BullX.Gateway.SourceSupervisor`.
    Acceptance: Gateway core starts after Oban and before Runtime;
    SourceSupervisor starts after Runtime; Gateway Mailbox queues wait for
    Runtime and consumer readiness, not Router readiness; inbound publish and
    terminal finalization check Router availability where they call Router;
    Gateway restart reconstructs adapter and source state from config and
    plugin registry; pending Mailbox jobs remain in Oban.

12. Add telemetry, redaction, dedupe, buffer, and recovery tests.
    Acceptance: telemetry includes transport metadata but excludes payload
    bodies, content text, and secrets; worker crash retries jobs; duplicate
    `delivery_key` does not enqueue twice; pending and running dispatch rows can
    be scanned after BEAM crash; UNLOGGED table truncation is tested or
    simulated as the accepted-loss boundary.

### Done When

- Gateway adapter contributions use `:"bullx.gateway.adapter"`.
- Inbound Signals exist only as normalized envelopes and payloads inside
  Mailbox jobs or outcome publication data.
- Signal JSON uses strict CloudEvents 1.0 JSON Event Format with top-level BullX
  extension attributes.
- Mailbox uses Oban for durable at-least-once delivery and per-delivery enqueue
  dedupe.
- `delivery_key` is the idempotency boundary and does not equal `Signal.id`.
- `DeliveryIntent.queue` comes from a Gateway-owned allowlist, and every
  Gateway-owned Mailbox execution queue is gated on Runtime and consumer
  readiness, not Router readiness.
- Oban uniqueness does not compare full args, queue, priority, or metadata.
- Mailbox exposes a composable `Ecto.Multi` API used by terminal finalization.
- Consumer requested discard maps to Oban `cancelled`; attempts exhaustion maps
  to Oban `discarded`.
- Route-at-publish semantics are explicit and tested.
- Gateway publish is all-or-nothing across resolved Mailbox jobs.
- Provider batched payloads are split before Gateway publish.
- Gateway code does not include Agent selection, Admission, Work creation,
  Principal resolution, or Governance decisions.
- External outbound `deliver/1` returns after Gateway acceptance, not provider
  terminal outcome.
- Best-effort dispatch and stream buffers use UNLOGGED tables and
  `LISTEN/NOTIFY` only as wakeup.
- Terminal outcome finalization writes receipts or dead letters and outcome
  Mailbox jobs atomically.
- Receipt visibility depends on outcome routing availability; terminalizing
  rows plus `terminal_outcome` snapshots are the recovery source until
  finalization commits.
- `:send` and `:edit` terminal failures can replay from dead letters; `:stream`
  terminal success writes receipts, and `:stream` terminal failures write
  receipts plus non-replayable dead-letter summaries.
- Focused Gateway tests and `bun precommit` pass.

### Stop And Ask

Stop implementation and ask a targeted question if any of these requirements
appear necessary:

- defining Router rule language, priority, fanout, or Agent selection in this
  implementation;
- persisting raw provider payloads or full inbound event audit;
- permanently suppressing external occurrences instead of relying on adapter
  pre-publish dedupe or Mailbox per-delivery dedupe;
- letting Gateway approve, deny, or hold outbound Effects rather than delivering
  already submitted Delivery commands;
- moving configured sources from runtime configuration into first-class tables;
- upgrading the best-effort UNLOGGED outbound buffer into a logged durable
  queue.
