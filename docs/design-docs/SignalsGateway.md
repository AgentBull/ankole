# SignalsGateway

SignalsGateway is the boundary between provider ingress, actor mailbox handoff,
and provider-visible outbound effects. It accepts normalized facts from
adapters, applies binding policy, updates the provider mirror, appends durable
actor input when needed, acks the provider after the durable transaction, and
executes actor-committed visible side effects through the gateway outbox.

Only four concepts need to stay separate:

- `IngressFact`: what an adapter or internal source reports to the gateway. It
  carries a stable ingress event id, raw references, and provider metadata when
  the input came from a provider. It is an input shape, not necessarily a table.
- Provider mirror: `signal_channels` and `signal_entries`, the current
  provider-visible or provider-delivered state Ankole has chosen to observe.
- `ActorInput`: the semantic input appended to `actor_mailbox` for a session
  actor, such as `im.message.addressed`, `im.message.may_intervene`,
  `command.steer`, `timer.fired`, or `signal.entry.deleted`.
- Outbox: the one durable table of actor-committed provider-visible side
  effects. Gateway execution reads this same table, uses adapter capabilities,
  and mirrors only after provider success.

Tombstones, idempotency keys, and micro-batch readiness are implementation state
around those four concepts. They should not become new product-level objects.

Provider raw payloads and event names can be retained through `raw_ref` or
provider metadata, but they are not SignalsGateway's actor-facing event model.
Actor-facing semantics live only on `ActorInput.type`.

An IM message is one kind of signal entry. A webhook event is another. The
difference is not whether it can wake an agent; the difference is whether the
source supports provider-visible reply after the signal has been accepted. HTTP
webhook acknowledgement is transport `ack`, not an agent reply.

SignalsGateway is not an audit subsystem. Auditability is a low-priority
byproduct here, not the design driver. Runtime behavior should remain
explainable from these surfaces:

- `signal_channels` and `signal_entries`: latest observed provider-visible or
  provider-delivered mirror.
- `signal_gateway_input_tombstones`: short-lived delete/recall guards before a
  matching receive is accepted.
- `actor_mailbox`: durable-until-consumed accepted input for
  `{agent_uid, session_id}` actors.
- `signal_gateway_outbox`: durable provider-visible side-effect execution
  state.
- Redis visible-output streams: weak in-progress output visibility.

## Vocabulary

`signal` is the umbrella word for external or internal inputs Ankole chooses to
observe. The precise contracts are `IngressFact`, provider mirror rows, and
`ActorInput`.

A `signal channel` is the provider-addressable scope where signal entries occur.
Examples:

- an IM direct chat;
- an IM group chat;
- a Feishu/Lark thread scope when the product wants the thread to be the work
  boundary;
- a GitHub issue or pull request;
- a webhook endpoint;
- an alert stream.

A `signal entry` is one observed item inside a signal channel. Examples:

- an IM message;
- an issue comment;
- a webhook occurrence;
- an alert occurrence;
- a provider card action normalized as an action entry.

A provider thread becomes a signal channel only when that thread is the
conversation or work boundary. Otherwise it stays as `provider_thread_id` inside
a broader channel, such as an IM group chat.

`ack` means protocol-level acknowledgement, such as returning HTTP 200 to a
webhook provider. `reply` means a provider-visible agent output that a human or
external system can see in, or anchored to, the signal channel.

`response` is avoided as a storage and adapter term because it is ambiguous
between HTTP response, model response, and user-visible reply. `duplex` is
avoided because it describes transport shape rather than the user-visible
capability Ankole cares about.

## Important Keys

Most SignalsGateway invariants are key choices. These keys are implementation
identities and indexes, not extra product concepts.

| Key | Shape | Purpose |
| --- | --- | --- |
| `binding_key` | `(agent_uid, binding_name)` | One configured provider ingress for one agent |
| `session_key` | `(agent_uid, session_id)` | Actor session identity |
| `signal_channel_key` | `(signal_channel_id)` | One `signal_channels` row |
| `signal_entry_key` | `(signal_channel_id, provider_entry_id)` | One `signal_entries` row |
| `outbox_key` | `(agent_uid, binding_name, outbound_key)` | One provider-visible side-effect intent |
| `mailbox_idempotency_key` | `(agent_uid, binding_name, ingress_event_id)` | Durable actor handoff idempotency |

Consequences:

- Provider mirror identity is separate from binding identity, so mirroring and
  actor delivery remain separate writes.
- If two ingress routes report the same adapter-normalized physical provider
  channel and entry ids, they update the same mirror row. Actor delivery remains
  keyed by the accepting route. If the provider gives different entry ids for
  the same physical item across bot/app views, the adapter should not invent a
  cross-app dedupe key.
- Mailbox idempotency includes `agent_uid` and `binding_name`, so provider
  redelivery is de-duped for the binding route that accepted the ingress event.
- Tombstones include `signal_channel_id`, so same-looking provider entry ids in
  different channels do not suppress each other.
- Actor sessions are keyed by `session_key`. Signal-backed inputs derive a
  default `session_id` from `signal_channel_id`; non-channel inputs such as
  timers must provide an explicit `session_id`.
- Outbox idempotency is owned by the actor/binding side. The gateway does not
  assume provider ids are globally unique.

## Reply Capability

`signal_channels.reply_mode` records what kind of provider-visible reply the
channel supports:

- `none`: the channel does not support provider-visible agent output. A webhook
  endpoint that only needs HTTP ack is the normal case.
- `channel`: the adapter can post a new provider-visible entry into the same
  channel, but cannot anchor it to a specific source entry.
- `entry`: the adapter can reply anchored to a specific source entry. This also
  permits channel-level output when the adapter declares the matching capability.

This is intentionally richer than `supports_reply`. A GitHub issue can accept a
new comment but not necessarily a nested reply to one comment. An IM thread can
usually support an entry-anchored reply. A pure webhook source usually supports
only ack.

`reply_mode` describes the observed channel surface. Outbox execution checks it
together with adapter capabilities:

```text
post:
  requires adapter.post_entry
  requires reply_mode in channel | entry

reply:
  requires adapter.reply_entry
  requires reply_mode = entry
  requires source entry anchor

edit / delete:
  requires adapter edit/delete capability
  requires provider entry id

reaction:
  requires adapter reaction capability
  requires target entry id
```

The provider mirror should not fake reply support just because an agent would like to
answer. A webhook channel with `reply_mode = none` can still wake an agent; it
only makes provider-visible reply intents unsupported.

HTTP response bodies for webhook providers are not `reply`. If a provider needs
a synchronous body during callback handling, model it as adapter-specific
`ack_mode`, not as provider-visible agent output. v1 does not support
agent-generated synchronous callback bodies; callback ack content must be
adapter-owned and deterministic.

Keep these axes separate:

- `transport_ack`: whether the provider callback needs protocol acknowledgement.
- `actor_delivery`: whether binding policy writes `actor_mailbox`.
- `visible_output`: whether the channel and adapter can perform provider-visible
  side effects.

For example, a webhook event usually needs `transport_ack`, may or may not have
`actor_delivery`, and often has no `visible_output`.

## Runtime Boundary

One agent can have multiple signal bindings. A binding belongs to exactly one
agent. Each ingress unit is explicit `agent + binding`.

SignalsGateway v1 exposes explicit per-agent signal bindings as the operator
model. A binding is the thing an operator creates when connecting one provider
ingress to one agent. It owns adapter selection, provider configuration
reference, ingress policy, and optional admission filters for that route.

Each binding has:

- `name`: the public route key used by the provider callback surface, such as
  `/api/agents/:agent_uid/signals/:binding_name`;
- `adapter`: the registered adapter factory id;
- `config_ref`: host-owned provider configuration or credential reference, not
  the secret payload itself;
- optional filters: provider-specific admission filters such as chat ids,
  repository names, event types, or trusted realms;
- optional `unaddressed_group_message_policy`: `ignore`, `record_only`, or
  `may_intervene` for IM-like group channels.

`filters` is deliberately small in v1. The only supported shape is:

```text
{"eq": {"field_name": scalar_value}}
```

All `eq` conditions are ANDed. Fields must come from a code allowlist such as
channel id, provider thread id, sender key, source event kind, or repository.
Values must be JSON scalars. Regex, OR groups, scripts, priority, ordering, and
arbitrary nested rules are not v1 user configuration. Future routing can grow
below the same boundary, but current bindings only express deterministic exact
admission.

A binding is not the provider channel and not the session actor. One binding may
receive facts from many provider channels, and each `agent + signal_channel`
normally derives a default session actor later. Non-channel inputs such as
timers provide their session id explicitly instead of creating synthetic signal
channels.

Rule-based delivery routing is intentionally not the v1 configuration surface.
Future versions may add MailBox-style delivery rules below this layer, but v1
keeps the operator story as explicit `agent + binding` ingress followed by
durable actor-mailbox handoff.

Adapter startup failure is scoped to the binding whenever possible. A missing
or unavailable adapter for one binding should mark that binding unavailable and
log the reason; it must not prevent unrelated agents or bindings from accepting
signals. Configuration or code errors after an adapter has been selected may
still fail that binding strictly.

Webhook bindings normally update the provider mirror and append the
source/event-defined ActorInput: the endpoint URL already names the agent and
binding. Accepted webhook entries are agent-relevant unless the binding or
source event definition classifies them as mirror-only. The adapter reports the
IngressFact; it does not own actor-delivery policy. IM group bindings use
`unaddressed_group_message_policy` because humans can speak near an agent
without speaking to it.

The runtime does not make external client queues, locks, caches, or in-memory
state part of the delivery contract. Adapters call a normalized gateway context
directly. Startup builds and
initializes adapters before the HTTP server accepts provider callbacks. A
provider callback ack is sent only after the gateway transaction commits. If a
future provider requires an earlier transport ack, the adapter must first stage
the IngressFact durably or use an adapter-owned deterministic ack path; that
early ack would not mean actor delivery has completed.

Signal adapters and shared provider consumers live at the provider ingress /
control-plane boundary. They are not started inside the agent computer. The
agent computer is the execution runtime for one `{agent_uid, session_id}` actor
after the input has already become durable in PostgreSQL.

Adapter implementations should normalize from the provider surface they actually
receive at runtime. Do not add compatibility branches for both raw provider
events and provider-library-normalized events unless the real plugin execution
path can deliver both shapes.

Missing adapter factories are warned and skipped for that binding. Malformed
enabled binding metadata and non-factory startup failures remain startup errors.

## Responsibility

SignalsGateway owns:

- normalized provider ingress from signal adapters;
- binding and command admission policy, including group-message admission;
- latest-state provider mirror updates for signal channels and entries;
- signal-to-session mapping and actor-mailbox event construction;
- short-lived tombstones for delete/recall;
- provider-visible outbox execution;
- weak visible-output stream state for in-progress assistant output;
- provider limitation boundaries that affect what can be mirrored or replied to.

SignalsGateway does not own:

- session actor execution, turns, summaries, generation leases, checkpoint
  semantics, or command execution semantics;
- the rule for whether a user recall/delete should also recall or delete prior
  assistant output;
- Principal/AuthZ truth, except for exposing a host-owned bridge that adapters
  can call with observed platform-subject facts;
- plugin discovery, plugin activation, or provider setup persistence;
- a universal audit log of every upstream provider payload;
- a universal rule-routing engine or arbitrary MailBox-style delivery rules;
- transport ack policy beyond whether ingress was accepted by the gateway;
- ZeroMQ activation, actor leases, agent computer lifecycle, or final-proposal
  commit.

## Adapter Contract

The public adapter-facing ingress API has concrete methods:

- `emitEntry(input, options?)`
- `emitEntryDeleted(input, options?)`
- `emitEntryRecalled(input, options?)`
- `emitReaction(input, options?)`
- `emitAction(input, options?)`

These methods are concrete on purpose: adapter code should not need to
construct a large generic union by hand. The gateway may merge them internally
into a shared IngressFact planner, but that helper is an implementation detail.
Adapter methods never directly create ActorInputs.

It also exposes adapter logging and the adapter's display user name:

- `getLogger(prefix?)`
- `getUserName()`

Normalized IngressFacts include stable `ingress_event_id`, provider entry id
when there is a provider entry, thread id when the provider has one, optional
channel data, text, formatted content, attachments, links, mentions, author, raw
payload reference, provider metadata, and provider observation time. For
external providers, `ingress_event_id` is normally derived from the normalized
provider event id. For internal facts, such as timers, it is derived from the
source's fire id. Delete/recall facts include `provider_entry_id`, `thread_id`,
`kind = deleted | recalled`, optional delete time, optional channel, optional
entry snapshot, and raw payload reference. Reaction and action facts are typed
separately.

When an inbound entry has attachments, materialization happens before mirroring
and mailbox enqueue. Durable payloads must carry provider references,
blob/storage references, or file paths visible to the agent computer, not live
adapter closures or host-only temp paths. The provider mirror row and mailbox
snapshot should see the same normalized attachment view.

Core IngressFact kinds are intentionally small:

- `entry.received`
- `entry.deleted`
- `entry.recalled`
- `reaction.changed`
- `action.invoked`
- registered internal facts such as `timer.fired`

Visible text commands are command semantics carried by text-bearing
`entry.received` IngressFacts. The visible entry is still mirrored and still
participates in provider delete/recall behavior, but command classification
chooses `ActorInput(type = command.<name>)` during ingress planning. Commands
are first-class ActorInput events. The actor-facing event identity stays
`command.<name>`; sharing the addressed IM resolver does not change a command
event into `im.message.addressed`.

Adapters declare capabilities instead of making the host guess behavior:

- inbound: `entry_receive`, `entry_delete`, `entry_recall`, `reaction_add`,
  `reaction_remove`, `action_event`, `modal_event`;
- outbound: `post_entry`, `reply_entry`, `edit_entry`, `delete_entry`,
  `add_reaction`, `remove_reaction`, `divider`, `card`, `modal`, `streaming`,
  `ephemeral`, `outbound_idempotency`, `outbound_reconciliation`.

The adapter object must provide the host-facing methods the runtime actually
uses, including initialization, callback handling, thread/channel identity
helpers, entry parsing, optional outbound operations, optional channel lookup,
optional reasoning-trace authorization, and optional streaming-card support.

Adapter implementations may split callback validation, identity normalization,
attachment materialization, outbound operations, lookup, auth bridging, and
streaming support into smaller modules. SignalsGateway only relies on the
normalized IngressFact input and explicit outbound capabilities.

For text-command providers, the adapter also owns provider-specific visible-text
normalization: preserving structured mentions, reporting whether an entry is
really directed at the agent, and supplying exact mention prefixes when the
shared command parser needs them. The command names and ActorInput semantics
remain code-defined by SignalsGateway and the actor runtime.

## Core User Stories

For a human IM message explicitly directed to an agent, SignalsGateway mirrors
the visible entry, appends `im.message.addressed`, writes it to the channel's
session actor mailbox, wakes that actor, and later sends only explicit
`signal_gateway_outbox` rows committed by the actor runtime.

For IM group traffic that is not explicitly directed to the agent,
`unaddressed_group_message_policy` decides whether the entry is ignored,
mirrored only as `record_only`, or converted into `im.message.may_intervene`.
Mention detection remains adapter-owned because only the adapter can know
whether a provider event contained a real structured mention.

For a webhook event, the endpoint names the agent and binding, and the normalized
channel id chooses the session actor. HTTP ack means the signal was durably
accepted or explicitly rejected; it does not wait for the agent turn to finish
and it is not a provider-visible reply.

For delete or recall, the provider mirror is updated immediately. Pending mailbox input
can be removed before the actor sees it; otherwise a lifecycle event is written
to the same actor mailbox. SignalsGateway never infers deletion of prior
assistant output.

For `/steer`, the adapter/shared parser recognizes a visible command entry. The
gateway mirrors the visible entry and appends
`ActorInput(type = command.steer)` as the actor-facing event according to command
admission. The session actor may consume that event through the same resolver
path used for `im.message.addressed`; that resolver mapping is static runtime
code keyed by `ActorInput.type`, not database state or user configuration.
Checkpoint consumption, revision fencing, and final commit belong to the session
actor runtime and Elixir control plane.

## End-To-End Flow

Ingress path:

```text
adapter callback
  -> load binding by binding_key
  -> construct typed IngressFact
  -> validate durable JSON payloads
  -> evaluate deterministic eq filters
  -> classify route, binding policy, and command admission
  -> transaction:
       - tombstone check/update
       - mirror effect by signal_entry_key
       - mailbox effect by session_key / mailbox_idempotency_key
  -> return accepted, recorded, ignored, filtered, or error
  -> external layer may provider-ack after commit
  -> external layer may best-effort actor wake; actor_mailbox is durable truth
```

Malformed payloads must fail before provider ack unless a future adapter first
stages the raw input durably. In particular, mailbox payloads, outbox payloads,
and provider mirror JSON fields must be JSON-serializable before insert. Runtime
values such as processes, functions, references, tuples, arbitrary structs, and
non-boolean atoms are not stringified into durable state.

Actor outbound path:

```text
actor final proposal committed
  -> write signal_gateway_outbox row by outbox_key
  -> dispatcher normalizes adapter contract and capability allowlist
  -> dispatcher checks reply_mode and adapter capability
  -> adapter send / reconcile
  -> on confirmed success:
       - update outbox status
       - mirror provider-visible outbound by signal_entry_key
  -> on unsupported, failed, or unknown_after_send:
       - update outbox only
       - never fake provider mirror state
```

Gateway acceptance means the IngressFact has been durably processed by
SignalsGateway. If the route writes actor mailbox, it also means the input has
been durably accepted for the session actor. It does not mean the agent finished
a turn. Provider send failure after final-proposal commit stays on
`signal_gateway_outbox` and does not revoke the accepted mailbox input.

SignalsGateway does not own execution scheduling. One-active-turn fencing, actor
epochs, revision checks, agent computer crash recovery, and checkpoint
consumption belong to the actor store and Elixir control plane. ZeroMQ carries
live activation and progress only; it is not the durable queue.

## Provider Mirror Contract

`signal_channels` and `signal_entries` are provider mirror tables. They are the
current provider-visible or provider-delivered mirror of accepted observable
facts and confirmed provider-visible outbound effects. They are not routing
state, an audit log, actor transcript, provider truth, or a durable queue.

The mirror does not record which binding saw which channel. Binding-specific
handling is answered by the route that accepted the ingress event, the mailbox
row written by that route, and the actor store's consumed-input record. A
mirror-only entry is simply a mirrored entry with no ActorInput for that ingress
route.

The provider mirror is updated by:

- accepted provider-backed IngressFacts;
- confirmed successful provider-visible outbox sends.

The provider mirror is not updated by:

- actor runtime messages;
- failed or unsupported outbox attempts;
- Redis streaming deltas;
- ignored group traffic;
- raw provider audit trails.

`signal_channels.id` is the adapter-normalized provider channel id. It is not
scoped by agent uid, binding name, plugin id, or provider app id by the gateway.
The adapter must normalize to the physical provider channel when the provider
exposes one stable identity, even if several bindings observe it. It should add
realm/domain/tenant identity when raw provider channel ids can collide across
realms, and add app identity only when the provider's channel ids are actually
app-scoped. Cross-binding mirror dedupe is best-effort and identity-based: if the
provider exposes the same stable channel and entry ids, rows can be shared; if it
does not, the gateway stores separate mirror rows rather than guessing. The
gateway does not add a separate realm dimension because the real collision
probability is owned by the adapter's channel-id normalization.

The provider mirror is not routing state. The same normalized channel boundary is
also used to derive the default session id, but the mirror row does not route
actor input. Choose channel granularity from the user story:

- an IM DM or group chat is normally one signal channel;
- a GitHub issue or pull request is normally one signal channel;
- a webhook endpoint is one signal channel only when all occurrences share one
  work context;
- a webhook carrying an object id should usually map each object to its own
  signal channel.

`signal_channels` stores:

- `id`;
- `kind`, such as `im_dm`, `im_group`, `webhook_endpoint`, `issue`,
  `alert_stream`, or `unknown`;
- `reply_mode`: `none`, `channel`, or `entry`;
- optional name/title;
- visibility when the provider exposes it;
- metadata and raw provider payload;
- timestamps.

`signal_entries` stores one row per `(signal_channel_id, provider_entry_id)` and
uses that pair as its primary key. `provider_entry_id` means the
adapter-normalized entry id stored in the mirror; it is not necessarily the raw
provider id. `thread_id` is not provider mirror identity; thread scope stays in
the actor mailbox and outbox as `provider_thread_id`, where batching and provider
delivery need it.

`signal_entries` also reserves recall/search fields. These fields are part of
the mirror row because later full-text and vector recall need a stable searchable
document identity even when provider ids or normalized payload shapes evolve:

- `document_id`: stable opaque id for recall/search indexes. It is not provider
  identity and does not replace `(signal_channel_id, provider_entry_id)`.
- `search_text`: flattened human-visible content for full-text search.
- `metadata_text`: flattened searchable side fields, such as author, title,
  link labels, or provider metadata selected for recall.
- `content_hash`: hash of recall-relevant content used to detect whether
  search/vector indexes need refresh.

Vector storage, embedding profiles, ranking, and re-embedding workers belong to
the recall/search subsystem. SignalsGateway only reserves the stable entry-side
fields that subsystem will need.

For providers that do not expose a message-like entry id, the adapter must
derive a `provider_entry_id` stable enough for provider redelivery. A webhook
provider's event id is usually the right value. If a provider has no stable
event id, the adapter should make that limitation explicit and avoid claiming
stronger latest-state guarantees than it can keep.

Provider mirror behavior:

- Receive upserts entry text, formatted content, attachments, links, author,
  mentions, metadata, raw payload, and provider time.
- Deletes and recalls hard-delete the mirrored entry because the table
  represents current visible or delivered state.
- Reactions update the entry reaction map and preserve raw provider reaction
  keys when available.
- Reaction changes for unknown or unmirrored entries are ignored in v1.
- Re-mirroring an entry preserves existing reaction state.
- A mirror update with an older provider time must not overwrite a newer stored
  mirror row.
- Unsupported or unserializable raw values are sanitized instead of crashing the
  mirror path.
- Inbound edit events are not part of the current SignalsGateway contract.

Provider mirror time semantics are deliberately small:

- `provider_time` is used only to prevent stale provider-backed IngressFacts
  from overwriting newer mirrored state.
- `gateway_time` is used for tombstone TTLs, micro-batch readiness timers, retry
  backoff, and first/last-seen bookkeeping.
- `actor_time` belongs to actor runtime state and does not order provider
  mirroring.

`ignore` intentionally does not mirror unaddressed IM group entries. The mirror
matches what Ankole chose to observe for that binding; it is not a universal
provider audit log.

## Ingress Policy And Effects

For each `IngressFact`, SignalsGateway applies binding policy and writes the
needed effects in one transaction. One input can update the provider mirror,
append or remove actor mailbox input, refresh a tombstone, and then accept or
reject the provider callback.

Common cases:

| Input case | Effects |
| --- | --- |
| Unaddressed IM group + `ignore` | Ack only |
| Unaddressed IM group + `record_only` | Mirror entry, no ActorInput |
| Unaddressed IM group + `may_intervene` | Mirror entry, append `im.message.may_intervene` |
| DM or structured mention | Mirror entry, append `im.message.addressed` with its event-defined micro-batch readiness |
| Webhook accepted for agent work | Mirror entry, append the source/event-defined ActorInput |
| Webhook mirror-only | Mirror entry, no ActorInput |
| Recognized visible command such as `/steer` | Mirror visible command entry, append `command.steer` under command admission |
| Timer fired | Append `timer.fired` with explicit `session_id` |
| Delete/recall before receive | Write tombstone so a late receive is dropped |
| Delete/recall while mailbox pending | Refresh tombstone, delete mirrored entry, cancel/remove pending mailbox input |
| Delete/recall after actor commit | Refresh tombstone, delete mirrored entry, append `signal.entry.deleted` or `signal.entry.recalled` |

This is the only place where binding policy turns ingress facts into actor
input. `record_only` means mirror effect only; it is not an event type and it
does not create an actor-side receipt.

Gateway behavior uses existing facts instead of writing a separate per-entry
lifecycle table:

- `ignore` writes no mirror row and no ActorInput.
- `record_only` and other mirror-only receives write the mirror row and stop.
- any provider-backed receive that appends ActorInput writes the mailbox row
  before ack.
- actor commit records consumed input in actor store while writing actor
  messages and any `signal_gateway_outbox` rows.
- delete/recall refreshes the tombstone first, then checks mailbox and actor
  store state to decide whether to remove pending input, append a lifecycle
  ActorInput, or only update the mirror.

`unaddressed_group_message_policy` is an IM-like group-channel binding policy,
not a Feishu/Lark-specific rule. It only applies after the binding route has
classified the message as not explicitly directed to the agent.

`record_only` updates the mirror, then stops. It creates no ActorInput, no actor
mailbox row, no resolver selection, no scheduling metadata, and no actor
transcript change.

`record_only` still needs IngressFact idempotency. The mirror uses
`(signal_channel_id, provider_entry_id)` plus provider time for latest-state
idempotency. If a provider route needs callback redelivery de-dupe beyond that,
it may store a processed ingress-event key, but that key is not entry lifecycle.
Do not create an ActorInput just to get idempotency.

DM entries are always explicit for the target binding. IM group entries become
explicit when the adapter exposes a structured mention, reply-to-bot,
application command, or provider-native bot invocation. Plain text containing
`@` is not enough unless the adapter normalized it into a structured fact that
the binding route treats as explicit.

`may_intervene` is direct in the default v1 event definitions. It appends
`ActorInput(type = im.message.may_intervene)` without batching.

The same phrase appears at three levels with different meanings:
`unaddressed_group_message_policy = may_intervene` is the binding policy;
`ActorInput.type = im.message.may_intervene` is the semantic input delivered to
the actor; the actor runtime has code that maps that type to its intervention
judgment path.

Webhook entries normally update the mirror and append the source/event-defined
ActorInput. A binding or source event definition may still classify webhook
entries as mirror-only when the source is meant for history or recall rather
than immediate agent work.

Internal facts such as `timer.fired` bypass the provider mirror unless they
explicitly carry a signal channel. They enter through a configured internal
binding, use `ingress_event_id` for idempotency, and must provide an explicit
`session_id`. v1 keeps the same key shape for provider-backed and internal
inputs: an internal binding has a real `binding_name`, typically
`internal:<source_name>`, and mailbox idempotency stays `(agent_uid,
binding_name, ingress_event_id)`.

If the agent runtime has a pending clarify question for a provider channel, the
gateway routes an otherwise unaddressed IM group reply with text as explicit
mailbox input only when the actor-runtime clarify registry matches
`{agent_uid, session_id or signal_channel_id}` and any expected sender
constraint. The clarify registry remains owned by the agent runtime;
SignalsGateway only reads this boolean routing answer. If it does not match, the
entry follows normal unaddressed group policy.

## Actor Inputs

SignalsGateway writes a small CloudEvents-style envelope into `actor_mailbox`.
The envelope is a shape convention, not an external runtime dependency.
`type` is the ActorInput semantic type chosen by binding policy and command
classification; it is not the IngressFact kind.

Envelope fields:

- `specversion = "1.0"`
- `id`: `ingress_event_id` and enqueue idempotency key
- `source`: `signal://<adapter>/<encoded_channel_id>` for channel-scoped input,
  or `internal://<binding_name>/<session_id>` for internal input
- `subject`: `signal_entries:<provider_entry_id>` or
  `signal_actions:<action_id>` for provider-backed input; internal input may use
  a source-specific subject such as `timers:<timer_id>` or omit it
- `time`
- `type`
- `data.session`
- optional `data.channel`
- optional `data.entry`
- optional `data.mentions`
- optional `data.raw`
- optional `data.command`
- optional `data.action`
- optional `data.internal`

SignalsGateway writes only actor-facing inputs to `actor_mailbox`:

- `im.message.addressed`: explicit IM input, micro-batched by the default v1
  readiness policy.
- `im.message.may_intervene`: unaddressed IM group input that the binding lets
  the agent inspect, direct by default.
- webhook and action inputs: type is chosen by source/event definition code;
  binding policy decides whether that input is admitted, ignored, or mirror-only.
- `command.*`: visible text command events. Individual command types choose their
  consumption path through code keyed by `ActorInput.type`; `command.steer` may
  use the same path as `im.message.addressed`.
- `signal.entry.deleted` / `signal.entry.recalled`: written only when the
  original input already reached actor state.

Lifecycle ActorInputs use a deterministic code path. They update actor
transcript or actor state to reflect the provider deletion/recall and must not
invoke an LLM prompt or function-calling tool just to synchronize that state.

Provider reactions, `record_only` entries, ignored entries, streaming deltas,
and agent outbound effects are not ActorInputs. GitHub issues, pull requests,
comments, and review comments should map into the same generic receive/delete
shapes unless a provider-specific shape is truly required.

## Code Contracts Vs Stored State

Some gateway behavior must be durable state because it crosses process crashes
or provider retries. Some behavior should stay in code because making it
database-driven would create a second control plane without a user story.

Stored state:

- provider mirror rows: `signal_channels` and `signal_entries`;
- short-lived tombstones for delete/recall races;
- `actor_mailbox` rows until the actor consumes them;
- `signal_gateway_outbox` rows until provider-visible side effects resolve;
- route-level binding config such as adapter id, credential reference, filters,
  and `unaddressed_group_message_policy`;
- processed ingress-event keys when a route needs redelivery de-dupe beyond
  mirror upsert idempotency.

Code contracts:

- `ActorInput.type -> actor consumption path`, including `command.steer` using
  the addressed IM path;
- per-ActorInput readiness function that decides whether this input participates
  in micro-batching;
- command parser and command admission for `/new`, `/compress`, `/retry`,
  `/steer`, and `/stop`;
- public adapter context methods such as `emitEntry` and `emitAction`;
- internal constructors for accepted `IngressFact` and outbox adapter contracts;
- the CloudEvents-style envelope shape written to `actor_mailbox`;
- strict JSON normalization for durable mailbox, outbox, and mirror payloads;
- source/event definitions that map webhook/action facts to ActorInput types.

Do not store `resolver_key`, per-entry `observed_only` rows, binding-channel
observation rows, or entry-lifecycle rows just to make implementation routing
look configurable. Do not let arbitrary binding rows define new ActorInput type
semantics either; bindings may choose routes and admission policy, while event
semantics live in code. If a future product story needs such configurability, it
should introduce that story explicitly instead of smuggling it into gateway
state.

## Background Jobs And TTL Cleanup

TTL cleanup is one SignalsGateway use case of the broader control-plane
background-job runtime. The background-job runtime is an Ankole-wide
infrastructure choice, not a SignalsGateway submodule. SignalsGateway should say
what periodic or deferred work it needs and what guarantees that work needs; it
must not make the gateway tables or actor-mailbox semantics depend on the job
runtime.

TTL-like storage needs a resident cleanup path:

- `signal_gateway_input_tombstones`: delete rows after `tombstoned_until`.
- processed ingress-event keys, if implemented as a separate table: delete after
  their redelivery window.
- consumed or archived `actor_mailbox` rows: cleaned by actor store policy, not
  by SignalsGateway.
- Redis visible-output streams: use Redis expiry or stream trimming; final
  recovery must not depend on them.

Oban is the default choice for that Ankole-wide background-job runtime because
future work will need persisted enqueue, retries, uniqueness/idempotency,
scheduled jobs, cron-like recurring jobs, operational visibility, and
Postgres-backed coordination. This choice does not make Oban part of
SignalsGateway's data model. Oban jobs may operate on SignalsGateway tables,
but they do not replace `actor_mailbox`, `signal_gateway_outbox`, or provider
mirror rows.

Use one Oban queue for v1 background work, including SignalsGateway jobs. Do not
create queues named after subsystems such as `signals_gateway`, `recall`,
`sync`, or `outbox` by default. A single queue keeps scheduling behavior easy to
reason about: all jobs share one concurrency limit, one backlog, and one
operational surface. Job type, worker module, args, tags, and uniqueness rules
can describe the work without turning queues into architecture. Split queues
only after a concrete operational need appears, such as resource isolation,
starvation prevention, strict external rate-limit isolation, or different
concurrency/SLA requirements.

Other runtimes remain valid for different work classes, but they are not the v1
background-job default. A simple supervised process is acceptable for very local
idempotent maintenance, but it should not become a second job system once Oban is
present. A cron scheduler such as Quantum schedules time but is not a durable job
ledger. Broadway is a candidate for long-running ingestion or processing
pipelines with external producers, back-pressure, batching, acknowledgements,
and high concurrency; it is not the default application background-job runtime.

TTL cleanup should run as an Oban recurring job once the background-job runtime
is installed. The worker should use bounded, idempotent deletes, emit
telemetry/logging, and never rely on exactly-once timer execution.

## Actor Session Mapping

SignalsGateway computes the default signal-backed session actor identity from
the agent uid and signal channel id:

```text
session_id = signal-channel:<signal_channel_id>
actor_id = {agent_uid, session_id}
```

The same channel routes to the same session actor for one agent. Different
channels route to different session actors. `provider_thread_id` participates in
batching, entry context, and provider delivery, but it does not define the
session boundary and is not duplicated into `signal_entries`.

Inputs without a signal channel, such as internal timer facts, must carry an
explicit `session_id`. They can enqueue actor mailbox events without creating a
`signal_channels` row or `signal_entries` mirror row. Unless they deliberately
carry a channel, they do not enter the provider mirror.

The agent runtime owns product conversation state, messages, summaries, and turn
recovery. Its runtime state may include binding name and provider realm id, but
SignalsGateway should not create a separate session for provider thread or
ActorInput type.

Daily Reset and `/new` are actor-runtime conversation-window semantics.
SignalsGateway may deliver the triggering internal input or command event, but it
does not change `actor_id` or provider mirror identity.

## Commands

The adapter or shared parser recognizes visible text command events on
text-bearing `entry.received` IngressFacts:

- `/new`
- `/compress`
- `/retry`
- `/steer`
- `/stop`

Command classification produces `ActorInput(type = command.*)` as the
actor-facing event for recognized command entries. The typed command payload
looks like:

```json
{
  "name": "steer",
  "raw": "/steer be concise",
  "argsText": "be concise",
  "status": "stub"
}
```

SignalsGateway does not implement undo, steering, retry, stop, or
assistant-output recall semantics. ActorInput classifies the semantic ingress;
the session actor runtime decides what the command means.

`/steer` is a typed command event like `/new`, `/compress`, `/retry`, and
`/stop`. The command remains `ActorInput(type = command.steer)` even when its
resolver path is equivalent to `im.message.addressed`. If the session actor is
running, the Elixir control plane may send a ZeroMQ `mailbox_updated` or
`checkpoint_nudge`, and the agent computer may consume the event at a checkpoint.
SignalsGateway must not model steering as a second control queue.

`/undo` is not a command. If a user wants to retract input, the provider
recall/delete lifecycle event is the supported path.

Command parsing trims leading bot mentions for mentioned commands, allows
multi-line arguments, and normalizes full-width spaces and digits before
matching. A full-width slash remains user text.

## Actor Mailbox Handoff

There is no durable gateway-to-agent queue separate from `actor_mailbox`.
Accepted agent-relevant signals are written into `actor_mailbox` in the same
transaction that updates the provider mirror and tombstone state. The row is
durable-until-consumed: it covers the crash recovery gap after provider ack and
before actor turn commit, but it is not permanent history.

SignalsGateway does not lock a whole session while an actor turn is running. New
mailbox rows for the same `session_id`, including follow-up messages and
`command.steer`, can still be appended durably. The actor runtime owns when to
consume them, whether to checkpoint early, and how to fence overlapping turn
commits.

The actor store owns the physical mailbox schema; SignalsGateway owns the signal
payload and idempotency contract it writes. Mailbox payloads should be minimal
dispatch snapshots, not raw provider payload copies. Heavy raw data,
attachments, and long-lived searchable content should stay in `signal_entries`,
attachment/blob storage, or actor messages after commit.

Consuming a mailbox input is the actor-side ack boundary. The actor store locks
the mailbox row, rejects it if a delete/recall tombstone canceled the input,
writes the consumed-input marker, inserts any actor-committed outbox intents,
and removes the mailbox row in one transaction. There is no separate in-flight
table and no second ack queue.

Required logical mailbox metadata:

- `agent_uid`, `binding_name`
- `session_id`
- `ingress_event_id`
- optional `signal_channel_id`, `provider_thread_id`, `provider_entry_id`
- `type`
- `available_at`
- `payload` as a minimal dispatch snapshot

Micro-batched inputs also carry readiness grouping metadata:

- `batch_scope`
- `sender_key`

The signal input idempotency key is `(agent_uid, binding_name,
ingress_event_id)`. For provider-backed input, `ingress_event_id` normally
comes from the normalized provider event id. For internal input, it comes from
the configured source, such as a timer fire id.

`sender_key` is the adapter-normalized stable sender identity used for
same-sender micro-batching. It must prefer the normalized principal or platform
subject when available, then fall back to the provider author id. Display names
must not be used as sender identity. Direct inputs set `available_at = now` and
do not need `batch_scope` or `sender_key`.

After the session actor successfully commits the turn, messages, and any
`signal_gateway_outbox` rows that consume a mailbox entry, that mailbox row can
be deleted, archived, or compacted by TTL. It must not become a third long-lived
copy beside `signal_entries` and actor messages.

Before a consumed mailbox row is deleted, archived, or compacted, the actor
store must durably expose whether that mailbox input reached actor state.
Delete/recall handling depends on this distinction: pending input can be
removed, consumed input produces a lifecycle ActorInput, and mirror-only input
only updates the provider mirror. The gateway asks actor store for this answer;
it does not maintain a separate entry-lifecycle store.

The actor commit that consumes a signal-backed mailbox row must run in the same
actor-store transaction as writing actor messages and any
`signal_gateway_outbox` rows produced by that turn. That commit must verify the
source mailbox input has not been canceled by delete/recall after the actor read
it. If the input was canceled, the commit is rejected as stale and must not write
actor messages or outbox rows for that input.

Mailbox readiness is generic but code-defined. Each ActorInput type has a
runtime event definition with a small readiness function. If the function says
"batchable" for a specific input, the gateway appends a normal mailbox row,
delays readiness through `available_at`, stores `batch_scope` and `sender_key`,
and lets ready reads take a contiguous same-sender prefix. The default v1 event
definitions make only `im.message.addressed` batchable. Webhook events,
`im.message.may_intervene`, lifecycle events, command events, and action events
are ready immediately by default.

Micro-batching is represented by mailbox readiness metadata, not by another
durable queue. A micro-batched ActorInput row needs only three readiness fields:

- `available_at`;
- `batch_scope = {binding_name, signal_channel_id, provider_thread_id}`;
- `sender_key`.

When a new micro-batched input is accepted, pending mailbox entries with the same
readiness scope get the same later `available_at`. When the actor runtime reads
ready rows, it reads only the contiguous same-sender prefix:

- `Alice, Alice, Alice` can become one actor turn input group.
- `Alice, Bob, Alice` becomes three actor turn input groups.

The database may index ready rows by agent uid, binding name, signal channel id,
and provider thread id. That index is only for mailbox reads; it is not a
domain concept. The session boundary remains channel-level; thread scope only
affects batching and provider delivery.

In other words, micro-batching is a processing-time window:

```text
readiness rule = event-definition function plus short readiness window
ready read rule = contiguous same-sender prefix
```

Delete/recall follows the facts already stored in `signal_entries`,
`signal_gateway_input_tombstones`, `actor_mailbox`, and actor store. It must not
create a separate entry-lifecycle table.

Delete and recall share the same lifecycle logic. The only difference is the
lifecycle ActorInput type generated after actor state has already consumed the
original input.

Every delete/recall writes or refreshes the short-lived tombstone before
state-specific handling. This prevents provider retry or late receive from
recreating a mirrored entry after the user deleted or recalled it.

| Transition | Effect |
| --- | --- |
| `unseen + delete/recall` | Write `tombstoned_until`; late receive is dropped |
| `tombstoned_until + receive` | Drop receive, do not re-mirror, do not wake |
| `accepted receive + mailbox row still pending` | Pending ActorInput exists in `actor_mailbox` |
| `accepted receive + actor store consumed input` | Original input reached actor state |
| `mirror-only receive + delete/recall` | Refresh tombstone, delete mirrored entry only |
| `pending mailbox + delete/recall` | Refresh tombstone, delete mirrored entry, cancel/remove pending mailbox row |
| `consumed actor input + delete/recall` | Refresh tombstone, delete mirrored entry, append lifecycle ActorInput |

`signal_gateway_input_tombstones` is the short-lived storage for the
`tombstoned_until` state. Its primary key is `(agent_uid, binding_name,
signal_channel_id, provider_entry_id)`, so a recall in one channel cannot
suppress a same-id entry in another channel. The receive and tombstone paths use
a transaction-scoped advisory lock over `(agent_uid, binding_name,
signal_channel_id, provider_entry_id)`; whichever side wins commits before the
other observes state.

## Outbound And Recovery Boundary

SignalsGateway executes only explicit `signal_gateway_outbox` rows committed by
the Elixir control plane after a final proposal from the agent computer. It does
not infer that a recalled user entry should recall or delete prior agent output.
The committed intent is the `signal_gateway_outbox` row itself; there is no
second actor-outbox table that the gateway later copies from.

`signal_gateway_outbox` uses `(agent_uid, binding_name, outbound_key)` as its
primary key. `outbound_key` is the agent-supplied idempotency key for one
provider-visible side effect.

An outbox row is keyed by `(agent_uid, binding_name, outbound_key)` and follows
a small state machine:

```text
created -> unsupported
created -> sending -> succeeded
                 \-> failed
                 \-> unknown_after_send
```

Outbox is an external sink boundary:

| Layer | Guarantee |
| --- | --- |
| Postgres outbox row | Exactly-once intent persistence by `outbox_key` |
| Adapter send attempt | At-least-once attempt unless idempotency/reconciliation exists |
| Provider mirror update | Only after confirmed provider success |

The dispatcher first normalizes the adapter into a small contract: declared
capabilities, a send callback, and an optional reconciliation callback.
Capabilities are parsed from a fixed allowlist. Unknown capability names are
adapter errors and must not move the row to `sending`.

Supported outbox behavior:

- `post`: requires `post_entry` and `reply_mode` of `channel` or `entry`;
  mirror agent entry only after provider success.
- `reply`: requires `reply_entry` and `reply_mode = entry`; mirror agent entry
  only after provider success.
- `edit`: requires `edit_entry`; re-mirror agent entry only after provider
  success.
- `delete`: requires `delete_entry`; delete the mirrored target only after
  provider success.
- `reaction_add`: requires `add_reaction`; update the provider mirror only after
  provider success.
- `reaction_remove`: requires `remove_reaction`; update the provider mirror only after
  provider success.
- `divider`: requires `divider`, a post-capable channel surface, and posts
  through the adapter entry surface; the provider mirror stores fallback visible
  text.
- `card`: requires `card`, a post-capable channel surface, and posts through
  the adapter entry surface; the provider mirror stores fallback visible text
  until provider-native card mirroring is richer.
- Unsupported operations are marked `unsupported` and do not change the provider
  mirror.
- Provider failures do not fake visible state and do not revoke the already
  accepted mailbox input.

Rich card-like output should remain protocol-first. A portable interactive
output payload and a provider-native escape hatch, such as a Lark-native card,
are both valid `card` payloads when the adapter declares support. Every such
payload must include fallback visible text so the provider mirror, notification
surfaces, and unsupported clients retain a meaningful current-state mirror.

Outbox rows store retry counters, last attempt/error fields, provider send
started time, recovery state, idempotency key, and provider entry id. If a
process restarts after `platform_send_started_at`, the dispatcher first attempts
adapter reconciliation when a provider entry id exists. If the adapter cannot
prove idempotency or reconciliation, the row becomes `unknown_after_send`
instead of blindly replaying a possibly delivered entry.
Adapters that support idempotent sends must reuse the same idempotency key
across retries.

The gateway does not promise provider side-effect exactly-once unless the
provider/adapter can support idempotency or reconciliation. It does promise not
to fake provider mirror state before confirmed provider success.

Final assistant-message truth belongs to the actor store. The session actor
runtime owns turns, assistant messages, delivery metadata, summaries, and the
rule for whether a user recall/delete should also delete bot output.

Redis visible-output streams are retained as weak progress only. They use agent,
session, and stream identity, and are safe to lose. They may mirror ZeroMQ
stream chunks for UI resume or provider streaming cards, but final output
recovery goes through the actor-store/outbox boundary, not Redis.

## Feishu/Lark Adapter Boundary

The Lark plugin uses one shared long-connection consumer per `domain + app_id`.
Feishu/Lark long-connection delivery is cluster-mode, not broadcast-mode:
opening multiple clients for the same app id can split events randomly. Chat
ingress and identity realtime sync therefore share the same connection owner for
that app key.

Different app ids are different bot accounts. If multiple Feishu/Lark bot
accounts sit in the same group and are connected to different agents, Ankole
must run one long-connection client per app id. Each app view can produce its
own accepted ActorInput. The provider mirror only shares storage when the
adapter-normalized channel id and provider entry id are identical; if the
provider gives different message ids per app, the gateway does not dedupe across
them.

The local OTP shape is a unique `Registry` plus a `DynamicSupervisor` owned by
the Lark plugin. The registry key is `{domain, app_id}`. Starting or looking up a
connection is idempotent: lookup may find the existing owner, and concurrent
starts collapse through the registry-backed process name. The dynamic
supervisor can run many owners at the same time, one per distinct key, while
preventing two local owners for the same key.

The registered owner is the per-app runtime boundary. It builds the
`FeishuOpenAPI.Event.Dispatcher` for the active chat and identity consumers of
that key and runs one `FeishuOpenAPI.WS.Client`. A setup change that alters the
consumer set for the same key restarts that owner with a new dispatcher; it does
not add another WebSocket client for the same app id.

The shared Lark consumer belongs to provider ingress, not to a per-session agent
computer. It normalizes provider events into IngressFacts; SignalsGateway then
applies binding policy, writes accepted ActorInputs into `actor_mailbox`, and
lets the Elixir control plane wake the relevant session actor.

The chat-channel config includes the same `domain` field as identity-provider
config. A Feishu app and a Lark app with the same `app_id` are different
connection realms. Chat and identity realtime sync can share a connection only
when both use the same `domain + app_id`.

For a shared app, chat consumers should be included before identity realtime
sync opens or reuses the connection, and identity consumers should be included
before its startup full sync. Otherwise Feishu/Lark's non-broadcast delivery can
route events away from the runtime path that needs them.

The Elixir adapter should use `libs/feishu_openapi`, especially
`FeishuOpenAPI.WS.Client` and `FeishuOpenAPI.Event.Dispatcher`, for the
long-connection path. The plugin itself owns official event payload parsing,
sender and mention extraction, resource descriptors, card-action mapping, and
provider error classification.

Long-connection `event` and `card` frames are trusted decoded frames from the
provider transport. HTTP webhook or HTTP card-callback surfaces, if enabled,
must verify signatures before mutating the raw body and then normalize into the
same IngressFact/action facts as the long-connection path.

Provider-visible behavior:

- Message receive uses `im.message.receive_v1`. The adapter/binding route maps
  normalized receive IngressFacts to `im.message.addressed`,
  `im.message.may_intervene`, or `record_only` mirroring as configured.
- Message recall uses `im.message.recalled_v1`. SignalsGateway hard-deletes the
  provider mirror row and writes lifecycle only if the receive reached the actor.
- Message edit has no official event as of June 6, 2026. Do not implement
  realtime handling; the generic contract has no inbound edit event.
- Reactions use `im.message.reaction.created_v1` and
  `im.message.reaction.deleted_v1`. SignalsGateway updates the reaction map for
  an already mirrored entry.

Event names such as `im.message.updated_v1` are not official Feishu/Lark events
in this model and must not be implemented unless Feishu/Lark exposes the event
in official documentation and in the app event-subscription console.

Because Feishu/Lark cannot notify message edits, a group entry mirrored through
`record_only` or `may_intervene` can remain stale after a user edits it in
Feishu/Lark. This is a provider limitation, not a gateway queue failure.

Provider-specific limitations belong in adapter design and tests, not in
generic mirror semantics. `signal_entries` remains a latest-state mirror of
observed facts; it is not expected to converge to provider state for lifecycle
changes that the provider never emits and the adapter never fetches through an
official API.

## Edge Cases

The gateway user-story surface includes these contract cases:

- `ignore` ignores non-mentioned IM group entries and does not update the
  provider mirror.
- `record_only` mirrors unaddressed IM group entries and does not wake the
  agent.
- `may_intervene` mirrors unaddressed IM group entries and emits
  `im.message.may_intervene`.
- Literal `@Agent` text is not a structured mention.
- DM entries route as explicit input.
- Structured group mentions route as explicit input even when
  `unaddressed_group_message_policy = ignore`.
- Webhook entries update the mirror and append ActorInput by the source/event
  definition unless the binding or source event definition classifies them as
  mirror-only.
- A channel with `reply_mode = none` can still wake the agent; it just cannot
  receive provider-visible outbox reply.
- Pending clarify can route a group reply to the agent without a mention only
  through the actor-runtime clarify lookup contract.
- Consecutive same-sender explicit IM entries batch.
- A different sender breaks the batch.
- Same channel with different provider threads keeps the same session actor.
- Different channels produce different session actors.
- Recall/delete while an explicit receive is pending removes the pending
  mailbox input.
- Every recall/delete creates or refreshes a tombstone so stale receives are
  ignored.
- Recall/delete tombstones are scoped by signal channel.
- Recall/delete of a `record_only` entry updates the provider mirror but does not wake
  the agent.
- Recall/delete of an entry already committed into actor state writes lifecycle
  input to the actor but does not delete agent output unless the actor commits a
  delete intent.
- Raw reaction keys survive mirroring and re-mirroring.
- Provider entry ids are scoped by signal channel id, so same-looking ids in
  different channels do not collide.
- Same physical provider channel and entry facts may share one mirror row when
  the adapter has stable matching provider ids; mailbox idempotency remains
  route-scoped, so mirror dedupe does not suppress an accepted ActorInput.
- A consumed mailbox row must leave a durable actor-store marker before
  compaction so later recall/delete can distinguish consumed input from pending
  input.
- Actor commit must reject a mailbox input canceled by recall/delete after the
  actor read it.
- GitHub-like webhook facts map to generic receive/delete shapes.
- Final outbound posts are mirrored only after provider success.
- Provider outbound failure marks the outbox row failed while the accepted
  mailbox input remains durable.
- Agent returned reaction, divider, and card intents execute only through
  declared adapter capabilities.
- `/undo` is treated as normal text, not a typed command.
- `/new`, `/compress`, `/retry`, `/steer`, and `/stop` are typed command
  ActorInputs under command admission.
- Outbox edit, reply, idempotency, and reconciliation options are passed through
  the adapter contract.

## Invariants

- Signal binding identity is agent uid plus binding name.
- A binding does not define provider channel identity or actor session identity.
- Rule-based delivery routing is not the v1 user configuration surface.
- Routeable agent input does not depend on `signal_channels` or
  `signal_entries` primary keys.
- Provider mirror identity is signal channel id plus provider-visible entry id,
  not agent uid or binding name.
- Binding-channel observation is not a gateway identity.
- Entry lifecycle is not a gateway identity; delete/recall behavior is derived
  from tombstones, provider mirror, actor mailbox, and actor store consumed-input
  state.
- Mailbox signal idempotency identity is agent uid, binding name, and
  ingress event id.
- Tombstone identity includes signal channel id because provider entry ids are
  not globally unique.
- Provider mirror dedupe and mailbox idempotency are separate; re-mirroring an
  entry must not suppress the accepted mailbox write for the current binding.
- `ignore` does not mirror ignored IM group traffic.
- Inbound edit events are not supported by the current gateway contract.
- A provider delete/recall refreshes a tombstone and hard-deletes the provider
  mirror row but does not recall agent output by itself.
- Only explicit actor-committed `signal_gateway_outbox` rows create
  provider-visible side effects.
- Provider send failure after final-proposal commit belongs to the outbox row,
  not to the accepted mailbox event.
- HTTP webhook ack is not a provider-visible reply.
- ZeroMQ is a live activation and progress channel, not durable signal storage.
- Redis visible-output streams are progress hints, not final output truth.
- Provider-specific gaps are adapter limitations, not reasons to widen generic
  gateway semantics.
