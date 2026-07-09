# SignalsGateway

SignalsGateway is the boundary between provider ingress, actor event handoff,
and provider-visible outbound effects. It accepts normalized facts from
adapters, applies binding policy, updates the provider mirror, appends durable
`actor_events` rows when needed, acks the provider after the durable
transaction, and delivers agent output back to the provider — streamed AI
replies through live preview delivery, and explicit side effects through the
gateway outbox.

If you have built an IM bot against Feishu or Slack webhooks, this boundary
covers the same ground: receive events idempotently, mirror what the provider
shows, decide what wakes the agent, and send replies. If this is your first
Ankole document, read `docs/README.md` first for the system map.

Only four concepts need to stay separate:

- `IngressFact`: what an adapter or internal source reports to the gateway. It
  carries a stable source event id, raw references, and provider metadata when
  the input came from a provider. It is an input shape, not necessarily a table.
- Provider mirror: `signal_gateway_channels` and `signal_gateway_entries`, the current
  provider-visible or provider-delivered state Ankole has chosen to observe.
- `ActorEvent`: the semantic work item appended to `actor_events` for a session
  actor, such as `im.message.addressed`, `im.message.may_intervene`,
  `command.steer`, `cron.fire`, `session.reset_due`, or
  `signal.entry.removed`.
- Outbox: the one durable table of explicit provider-visible side effects.
  Gateway execution reads this same table, uses adapter capabilities, and
  mirrors only after provider success.

Tombstones, idempotency keys, and pending inbound batches are implementation
state around those four concepts. They should not become new product-level
objects.

Provider raw payloads and event names can be retained through `raw_ref` or
provider metadata, but they are not SignalsGateway's actor-facing event model.
Actor-facing semantics live only on `ActorEvent.type`.

An IM message is one kind of signal entry. A webhook event is another. The
difference is not whether it can wake an agent; the difference is whether the
source supports provider-visible reply after the signal has been accepted. HTTP
webhook acknowledgement is transport `ack`, not an agent reply.

SignalsGateway does not own the AI message log. Model history, tool-loop state,
and the final AI output of an actor event live in `ai_gateway_messages`, owned
by AIGateway (see `docs/design-docs/AIGateway.md`). SignalsGateway only
delivers that output to providers and mirrors what was delivered.

SignalsGateway is not an audit subsystem. Auditability is a low-priority
byproduct here, not the design driver. Runtime behavior should remain
explainable from these surfaces:

- `signal_gateway_channels` and `signal_gateway_entries`: latest observed provider-visible or
  provider-delivered mirror. `signal_gateway_entries` is also the long-lived substrate
  for recall/search and future long-term memory.
- `signal_gateway_input_tombstones`: short-lived provider-removal guards before a
  matching receive is accepted.
- pending inbound batches: short-lived provider-message grouping state used to
  decide whether IM traffic becomes addressed input, ambient input, or no actor
  input at all.
- `actor_events`: durable lifecycle work items for `{agent_uid, session_id}`
  actors. A row stays after its work completes; liveness is
  `input_state in (open, dead_letter)` and completion is the `completed_at`
  timestamp. `dead_letter` is reserved for true poison events: ActorRuntime sets
  it only after the same actor event repeatedly reaches worker `turn_error`;
  transport send failures remain retryable delivery failures.
- `actor_event_deliveries`: per-session delivery attempts. A live delivery row
  is what "this session is running something" means.
- `signal_gateway_outbox`: durable provider-visible side-effect execution
  state.
- live AI-reply preview: in-process subscription to AIGateway chunk events for
  streamed replies. Best-effort and transient; never durable truth.

## Vocabulary

`signal` is the umbrella word for external or internal inputs Ankole chooses to
observe. The precise contracts are `IngressFact`, provider mirror rows, and
`ActorEvent`.

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
| `signal_channel_key` | `(signal_channel_id)` | One `signal_gateway_channels` row |
| `signal_entry_key` | `(signal_channel_id, source_entry_id)` | One `signal_gateway_entries` row |
| `outbox_key` | `(agent_uid, binding_name, outbound_key)` | One provider-visible side-effect intent |
| `actor_event_idempotency_key` | `(agent_uid, binding_name, source_event_id)` | Actor event handoff idempotency |

Consequences:

- Provider mirror identity is separate from binding identity, so mirroring and
  actor delivery remain separate writes.
- If two ingress routes report the same adapter-normalized physical provider
  channel and entry ids, they update the same mirror row. Actor delivery remains
  keyed by the accepting route. If the provider gives different entry ids for
  the same physical item across bot/app views, the adapter should not invent a
  cross-app dedupe key.
- Actor event idempotency includes `agent_uid` and `binding_name`, so provider
  redelivery is de-duped for the binding route that accepted the source event.
- Tombstones include `signal_channel_id`, so same-looking provider entry ids in
  different channels do not suppress each other.
- Actor sessions are keyed by `session_key`. Signal-backed events derive a
  default `session_id` from `signal_channel_id`; non-channel events such as
  schedule fires must provide an explicit `session_id`.
- Outbox idempotency is owned by the actor/binding side. The gateway does not
  assume provider ids are globally unique.

### Identity Layers

Four id layers run through the whole system. They are never interchangeable,
and every column or JSON key names its layer:

| Layer | What it identifies | Typical value | Used for |
| --- | --- | --- | --- |
| `source_event_id` | One source event; the idempotency key of ingress | Feishu `Event.id`; namespaced synthetic ids for schedule, retry, reset, and internal commands | De-duplicating provider redelivery; actor event uniqueness |
| `source_entry_id` | One provider entry (message, post, comment) | Feishu `message_id` | Mirror rows, reply anchors, edit/delete/recall targeting |
| `actor_event_id` | One Ankole work item (`actor_events.id`) | uuid | Worker execution, retry, stop, steer, delivery, completion |
| `ai_message_id` | One stored model output (`ai_gateway_messages.id`) | uuid | Any reference to AI output: mirrors, outbox rows, schedules, diagnostics |

An event and an entry are different things: one provider message usually
produces both a `source_event_id` (the delivery event) and a `source_entry_id`
(the message itself), and they can differ across redeliveries. A worker
execution is keyed by `actor_event_id`, never by a source id. A model output is
referenced by `ai_message_id`, never by an actor event id. Writing a value from
one layer into a column named for another layer is a bug, even when the write
appears to work.

## Reply Capability

`signal_gateway_channels.reply_mode` records what kind of provider-visible reply the
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
  requires source entry id

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
- `actor_delivery`: whether binding policy writes `actor_events`.
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
  `/api/v1/agents/:agent_uid/signals/:binding_name`;
- `adapter`: the registered adapter factory id;
- `config_ref`: host-owned provider configuration or credential reference, not
  the secret payload itself;
- optional filters: provider-specific admission filters such as chat ids,
  repository names, event types, or trusted realms;
- optional `unaddressed_group_message_policy`: `ignore`, `record_only`, or
  `may_intervene` for IM-like group channels.

`filters` is the first-party admission predicate for this binding. The supported
shape is:

```json
{"cel": "signal.channel.id == 'lark:chat:allowed' && signal.entry.sender_key.startsWith('lark:user:')"}
```

An empty object means accept every normalized fact for the binding. CEL runs
against exactly two variables:

- `binding`: the binding identity, such as adapter and binding name;
- `signal`: the constructed `IngressFact` projection grouped into `channel`,
  `entry`, `lifecycle`, `reaction`, `action`, `internal`, and `command` fields.

The projection contains normalized, JSON-safe facts that adapters already handed
to the gateway, including metadata, author, mentions, attachments, action/internal
payloads, and provider-visible normalized ids. CEL may inspect provider-specific
JSON when an adapter deliberately places it inside normalized action or internal
payloads; this is still first-party in-memory ingress data, not a new external
capability. CEL does not load database rows, Principal/AuthZ state, actor runtime
state, provider I/O, or custom host-side-effect functions while evaluating.

Parsed slash-command payloads are produced after admission routing, so they are
not part of the CEL admission surface. Filters that need command-like admission
should use the entry text, structured mention prefixes, or adapter metadata that
already exists on the constructed fact.

SignalsGateway uses the native kernel CEL evaluator with the standard CEL
functions and macros available in the current runtime, including string
predicates, regex `matches`, collection membership, and comprehensions such as
`all`, `exists`, `filter`, and `map`. A malformed expression or a runtime error
is a binding configuration error. The gateway must fail before mirror or actor
event writes rather than silently accepting or partially recording the signal.

A binding is not the provider channel and not the session actor. One binding may
receive facts from many provider channels, and each `agent + signal_channel`
normally derives a default session actor later. Non-channel inputs such as
timers provide their session id explicitly instead of creating synthetic signal
channels.

Rule-based delivery routing is intentionally not the v1 configuration surface.
Future versions may add actor-event delivery rules below this layer, but v1
keeps the operator story as explicit `agent + binding` ingress followed by
durable actor event handoff.

Adapter startup failure is scoped to the binding whenever possible. A missing
or unavailable adapter for one binding should mark that binding unavailable and
log the reason; it must not prevent unrelated agents or bindings from accepting
signals. Configuration or code errors after an adapter has been selected may
still fail that binding strictly.

Webhook bindings normally update the provider mirror and append the
source/event-defined ActorEvent: the endpoint URL already names the agent and
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
- signal-to-session mapping and `actor_events` construction;
- short-lived tombstones for provider-removal races;
- provider-visible outbox execution;
- live streamed-reply preview delivery (`AIReplyPreview`) and final-reply
  mirror recovery (`RecoveryScan`);
- provider limitation boundaries that affect what can be mirrored or replied to.

SignalsGateway does not own:

- session actor execution, checkpoint semantics, or command execution
  semantics;
- the AIGateway Responses loop, its message log, continuation anchors, stop
  policy, compaction, or terminal commit;
- the rule for whether a user-side removal should also remove prior assistant
  output;
- Principal/AuthZ truth, except for exposing a host-owned bridge that adapters
  can call with observed platform-subject facts;
- identity-provider catalog/config persistence, full directory sync scheduling,
  or full sync execution. Those belong to `Ankole.IdentityProviders`,
  AppConfigure, and Oban; SignalsGateway only shares provider ingress resources
  with realtime identity consumers when an adapter needs that;
- plugin discovery, plugin activation, or provider setup persistence;
- a universal audit log of every upstream provider payload;
- a universal rule-routing engine or arbitrary runtime delivery rules;
- transport ack policy beyond whether ingress was accepted by the gateway;
- ZeroMQ actor fabric, actor session activations, or agent computer lifecycle.

## Adapter Contract

The public adapter-facing ingress API has concrete methods:

- `emitEntry(input, options?)`
- `emitEntryRemoved(input, options?)`
- `emitReaction(input, options?)`
- `emitAction(input, options?)`

These methods are concrete on purpose: adapter code should not need to
construct a large generic union by hand. The gateway may merge them internally
into a shared IngressFact planner, but that helper is an implementation detail.
Adapter methods never directly create ActorEvents.

It also exposes adapter logging and the adapter's display user name:

- `getLogger(prefix?)`
- `getUserName()`

Normalized IngressFacts include a stable `source_event_id`, a source entry id
when there is a provider entry, thread id when the provider has one, optional
channel data, text, formatted content, attachments, links, mentions, author, raw
payload reference, provider metadata, and provider observation time. Adapters
are responsible for supplying a unique, stable event id for `source_event_id`;
for Feishu/Lark websocket events this is the provider `event_id`. Internal
facts, such as schedule fires, derive it from the source's fire id. Removal
facts include `source_entry_id`, `thread_id`,
`kind = removed`, optional provider lifecycle kind such as `recalled`, optional
removal time, optional channel, optional entry snapshot, and raw payload
reference. Reaction and action facts are typed separately.

When an inbound entry has attachments, materialization happens before mirroring
and actor event append. Durable payloads must carry provider references,
blob/storage references, or file paths visible to the agent computer, not live
adapter closures or host-only temp paths. The provider mirror row and actor
event snapshot should see the same normalized attachment view.

Core IngressFact kinds are intentionally small:

- `entry.received`
- `entry.removed`
- `reaction.changed`
- `action.invoked`
- registered internal facts such as schedule fires and session lifecycle facts
  such as `session.reset_due`

Visible text commands are command semantics carried by text-bearing
`entry.received` IngressFacts. The visible entry is still mirrored and still
participates in provider removal behavior, but command classification
chooses `ActorEvent(type = command.<name>)` during ingress planning. Commands
are first-class actor events. The actor-facing event identity stays
`command.<name>`; sharing the addressed IM resolver does not change a command
event into `im.message.addressed`.

Outbox adapters declare capabilities instead of making the host guess provider
write behavior. The current closed allowlist is:

- `post_entry`;
- `reply_entry`;
- `edit_entry`;
- `delete_entry`;
- `add_reaction`;
- `remove_reaction`;
- `divider`;
- `card`;
- `outbound_reconciliation`.

Inbound adapter behavior is expressed by the normalized `IngressFact` shape and
the explicit host-facing entry/reaction/action APIs, not by a separate
capability vocabulary.

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
shared command parser needs them. The command names and actor event semantics
remain code-defined by SignalsGateway and the actor runtime.

## Core User Stories

For IM traffic, SignalsGateway does not turn every provider message directly
into an actor event. It first places provider messages into a short-lived
inbound batch for the `(agent, binding, channel, provider_thread)` scope. When
that batch closes, the gateway makes exactly one decision: append one
`im.message.addressed` actor event, append one `im.message.may_intervene`
actor event, or append no actor event. ActorRuntime and the worker should
receive one already-formed semantic event, not a list of raw provider messages
that they must re-batch.

For a human IM message explicitly directed to an agent, the resulting addressed
batch represents one person's turn to the agent. Direct messages and structured
group mentions of the bot are addressed triggers. An addressed batch has one
requester sender. The batch may include that sender's neutral same-turn messages
before or after the trigger, plus attachments, but it must not absorb another
sender's speech as part of the user's request.

For IM group traffic that is not explicitly directed to the agent, the same
pending batch can close as ambient observation, mirror-only history, or nothing.
`unaddressed_group_message_policy = may_intervene` allows the closed neutral
batch to become `im.message.may_intervene`. `record_only` mirrors the entries
but creates no actor event. `ignore`/addressed-only group handling may keep a
short wait-for-addressing buffer, but unaddressed messages that never become an
addressed batch are not delivered to the actor. Mention detection remains
adapter-owned because only the adapter can know whether a provider event
contained a real structured mention.

For a webhook event, the endpoint names the agent and binding, and the normalized
channel id chooses the session actor. HTTP ack means the signal was durably
accepted or explicitly rejected; it does not wait for the agent turn to finish
and it is not a provider-visible reply.

For delete or recall, the provider mirror is updated immediately and a
short-lived tombstone blocks late re-mirroring. A pending actor event can be
removed before the actor sees it. If the event's work already completed, the
gateway appends a `signal.entry.removed` lifecycle event instead. Consuming
that lifecycle event cancels checkbacks anchored to the removed entry, applies
the AI-message deletion mapping, and completes — it produces no model-visible
note. The deletion mapping works on `ai_gateway_messages` rows, located through
the identity chain (`signal_gateway_entries` / `actor_events.source_event_id` →
`metadata.actor_event_id` → the event's loop chain): chain-tail rows after the
last compaction are hard-deleted; historical rows and rows already covered by a
compaction are no-op in v1. SignalsGateway does not derive a retraction note and
never infers deletion of prior assistant output.

For `/steer`, the adapter/shared parser recognizes a visible command entry. The
gateway mirrors the visible entry and appends
`ActorEvent(type = command.steer)` as the actor-facing event according to
command admission. The session actor may consume that event through the same
resolver path used for `im.message.addressed`; that resolver mapping is static
runtime code keyed by `ActorEvent.type`, not database state or user
configuration. Checkpoint consumption and revision fencing belong to the
session actor runtime; the AI output itself commits inside AIGateway.

For daily session reset, the control plane enqueues `session.reset_due` for due
active sessions at the installation's AppConfigure timezone boundary. The
default boundary is 04:30 local time in `system.timezone`. This is a session
lifecycle actor event, not a visible text command and not worker-owned timer
behavior. It is deliberately queued in the same `{agent_uid, session_id}` actor
event journal so earlier work for that session finishes first. When the actor
runtime reaches the reset event, it closes the current active session state,
creates the successor active session state, completes the reset event, and
prevents stale session-local system-event rows from crossing into the successor
session. Real channel observations are different: an open ambient
`im.message.may_intervene` batch may straddle the reset boundary because it is
room context, not old session-local background work.

## Inbound IM Batching

Inbound IM batching is the place where provider-message bursts become actor
events. It is not a worker concern. The worker receives one normal actor event
whose `data.entry` already contains merged text and attachments. The optional
`data.entries` list is provenance and lifecycle material; a worker must not need
to read it to understand the user request or ambient observation.

A pending inbound batch is keyed by the accepting route and provider
conversation scope:

```text
{agent_uid, binding_name, signal_channel_id, provider_thread_id}
```

The key is thread-scoped, but the batch keeps the ordered provider entries and
their sender-contiguous runs. Addressed upgrade is always scoped to a sender
run, not to the whole room batch. This prevents a neutral multi-person room
conversation from being converted into one person's user request just because a
later message mentions the bot.

Pending batch outcomes:

- `im.message.addressed`: one requester sender's turn to the agent.
- `im.message.may_intervene`: a neutral room/thread observation that policy lets
  the agent inspect.
- no actor event: mirror-only or ignored traffic whose batch never became
  addressed.

Addressed triggers:

- any IM direct message;
- a structured group mention or provider-native invocation of the bot.

Neutral messages are group messages with no bot mention and no non-bot mention.
They may be retained in the pending batch so a following addressed trigger can
pull the sender's continuous same-turn context into an addressed batch. A
neutral message that mentions another human is not safe to inherit into a bot
request.

Addressed batch rules:

- A batch has one requester sender.
- After a group sender opens addressed input, that same sender's neutral
  follow-up, further bot mention, and attachments join the batch while it is
  open.
- If that same sender sends a message containing a non-bot structured mention,
  close the current addressed batch first. The new message is routed again; if
  it also mentions the bot, it may open a new addressed batch.
- If another sender sends a message while an addressed batch is open, close the
  addressed batch first. The other sender's message is routed from the start.
- If a neutral multi-sender batch later receives a bot mention, only the final
  matching sender-contiguous run can upgrade to addressed. Earlier runs close as
  ambient or no-op according to policy.
- Hitting the 8-message or normal text-budget boundary may split one human turn
  into consecutive addressed batches, but the next same-sender continuation does
  not become ambient just because the system limit forced the split.

Addressed timing:

- normal text waits 0.6 seconds after the last included provider message;
- long text near 3000 characters waits 2 seconds, so client-split continuations
  can arrive;
- image, file, audio, and video messages wait 1.2 seconds so related
  attachments can arrive together;
- mixed messages use the longest applicable wait for the last provider message.

Addressed size limits:

- normal batches hold at most 8 provider messages;
- normal accumulated text budget is 4000 characters;
- a single provider message is never split or truncated to satisfy that budget;
- long-text continuations may soft-exceed the normal text budget inside the long
  text window, but implementation should still keep a defensive hard cap so one
  burst cannot grow without bound;
- attachments stay attached to their source provider entry and are not dropped
  because text hit a budget.

Ambient batch rules:

- Only unaddressed group traffic can become ambient.
- Only `unaddressed_group_message_policy = may_intervene` creates
  `im.message.may_intervene` when a neutral batch closes.
- `record_only` mirrors entries and closes without an actor event.
- `ignore`/addressed-only group traffic may keep a short wait-for-addressing
  buffer, but if the batch closes without an addressed trigger, it creates no
  long-lived mirror row and no actor event.
- Ambient is room/thread context and may include multiple senders. It should not
  be reinterpreted as one user's request.
- Ambient should use a slower quiet window than addressed traffic. The default
  v1 target is roughly 10-15 seconds of quiet, with a hard cap around 5 minutes
  for busy rooms, so room-intervention checks do not burn tokens every minute in
  active channels.
- An addressed trigger has priority over an ambient timer. When a bot mention
  arrives while a neutral batch is waiting, the gateway first splits the batch
  into the sender run that can become addressed and the remaining neutral
  observation that may close as ambient or no-op.

Provider-side removal while batching:

- If the source provider entry is still only in a pending inbound batch, remove
  it from the batch. Empty batches close without an actor event. Non-empty
  batches recompute outcome, merged entry text/attachments, reply anchor, and
  due time.
- If the closed batch already produced an actor event that is in-flight but not
  completed, abort the active delivery and retry the same logical batch revision
  without the removed entry. If nothing remains, abort without retry.
- If the actor event's work already completed, do not rewrite history.
  Append the normal `signal.entry.removed` lifecycle input.

## End-To-End Flow

Ingress path:

```text
adapter callback
  -> load binding by binding_key
  -> construct typed IngressFact
  -> validate durable JSON payloads
  -> evaluate CEL admission filter
  -> classify route, binding policy, and command admission
  -> transaction:
       - tombstone check/update
       - mirror effect by signal_entry_key
       - pending inbound batch effect for IM entries
       - actor event effect only when a batch closes or a non-IM event is direct
  -> return accepted, recorded, ignored, filtered, or error
  -> external layer may provider-ack after commit
  -> ActorRuntime may publish/replay the ready actor event from the journal
```

Malformed payloads must fail before provider ack unless a future adapter first
stages the raw input durably. In particular, actor event payloads, outbox
payloads, and provider mirror JSON fields must be JSON-serializable before
insert. Runtime values such as processes, functions, references, tuples,
arbitrary structs, and non-boolean atoms are not stringified into durable state.

Outbound has two paths. Streamed AI replies — the normal chat answer — are
delivered live and never pass through the outbox:

```text
AIGateway publishes live chunk / terminal events (process messages)
  -> AIReplyPreview sends the provider preview message on the first chunk
  -> edits the same provider message as chunks arrive
  -> on the terminal complete event: finalize the provider message
  -> on confirmed final send/edit:
       - upsert signal_gateway_entries by signal_entry_key
       - set signal_gateway_entries.ai_message_id to the final ai_gateway_messages row
```

Explicit side effects — attachments, cards, dividers, reactions, command
feedback, schedule-delivered output — go through the durable outbox:

```text
control plane commits a signal_gateway_outbox row by outbox_key
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
SignalsGateway. If the route writes an actor event, it also means the event has
been durably accepted into `actor_events`. It does not mean the actor fabric
delivered it, a worker accepted a turn, or the agent finished the work.
Provider send failure stays on `signal_gateway_outbox` (for explicit effects)
or is compensated by the recovery scan (for streamed replies); neither revokes
the accepted actor event.

SignalsGateway does not own execution scheduling. One-active-turn fencing, actor
epochs, revision checks, agent computer crash recovery, and checkpoint
consumption belong to the actor store and Elixir control plane. ZeroMQ is the
live actor fabric between the Elixir control plane and agent computer workers.
It may carry journal-backed event delivery and nudge/progress traffic, but
durable signal recovery, fencing, and provider-visible side-effect truth remain
in `actor_events`, `actor_event_deliveries`, `ai_gateway_messages`, and
`signal_gateway_outbox`.

## Provider Mirror Contract

`signal_gateway_channels` and `signal_gateway_entries` are provider mirror tables. They are the
current provider-visible or provider-delivered mirror of accepted observable
facts and confirmed provider-visible outbound effects. `signal_gateway_entries` is also
long-lived input material for recall/search and future long-term memory. These
tables are not routing state, actor transcript, provider truth, or a durable
actor queue.

The mirror does not record which binding saw which channel. Binding-specific
handling is answered by the route that accepted the ingress event, the
`actor_events` row written by that route, and that row's lifecycle fields
(`input_state`, `completed_at`). A mirror-only entry is simply a mirrored entry
with no actor event for that ingress route.

The provider mirror is updated by:

- accepted provider-backed IngressFacts;
- confirmed successful provider-visible outbox sends.

The provider mirror is not updated by:

- actor runtime messages;
- failed or unsupported outbox attempts;
- live streamed-reply chunks — only the confirmed final send/edit mirrors;
- ignored group traffic;
- raw provider audit trails.

`signal_gateway_channels.id` is the adapter-normalized provider channel id. It is not
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
actor events. Choose channel granularity from the user story:

- an IM DM or group chat is normally one signal channel;
- a GitHub issue or pull request is normally one signal channel;
- a webhook endpoint is one signal channel only when all occurrences share one
  work context;
- a webhook carrying an object id should usually map each object to its own
  signal channel.

`signal_gateway_channels` stores:

- `id`;
- `kind`, such as `im_dm`, `im_group`, `webhook_endpoint`, `issue`,
  `alert_stream`, or `unknown`;
- `reply_mode`: `none`, `channel`, or `entry`;
- optional name;
- visibility when the provider exposes it;
- metadata and raw provider payload;
- timestamps.

`signal_gateway_entries` stores one row per `(signal_channel_id, source_entry_id)` and
uses that pair as its primary key. `source_entry_id` means the
adapter-normalized entry id stored in the mirror; it is not necessarily the raw
provider id. `thread_id` is not provider mirror identity; thread scope stays in
`actor_events` and outbox as `provider_thread_id`, where batching and provider
delivery need it.

`signal_gateway_entries.ai_message_id` is a nullable backref column with a partial
index. When a streamed AI reply's final send or edit succeeds, the mirror row
records the `ai_gateway_messages.id` of the final output it delivered. The
column is not part of the primary key — mirror identity stays the provider
entry identity. Intermediate streaming chunks never write `signal_gateway_entries`;
only the confirmed final reply does. The recovery scan uses this column to find
completed AI outputs that never reached the provider.

`signal_gateway_entries` also reserves recall/search fields. These fields are part of
the mirror row because later full-text and vector recall need a stable searchable
document identity even when provider ids or normalized payload shapes evolve:

- `document_id`: stable opaque id for recall/search indexes. It is not provider
  identity and does not replace `(signal_channel_id, source_entry_id)`.
- `search_text`: flattened human-visible content for full-text search.
- `metadata_text`: flattened searchable side fields, such as author, title,
  link labels, or provider metadata selected for recall.
- `content_hash`: hash of recall-relevant content used to detect whether
  search/vector indexes need refresh.

Vector storage, embedding profiles, ranking, and re-embedding workers belong to
the recall/search subsystem. SignalsGateway only reserves the stable entry-side
fields that subsystem will need.

`signal_gateway_entries` must not be treated as TTL runtime state. Memory/search
retention, redaction, delete, and recall behavior are product/privacy policy,
not actor-runtime cleanup. Actor-runtime recovery tables may be compacted; this
provider observation surface is the durable source that memory systems can build
from.

For providers that do not expose a message-like entry id, the adapter must
derive a `source_entry_id` stable enough for provider redelivery. A webhook
provider's event id is usually the right value. If a provider has no stable
event id, the adapter should make that limitation explicit and avoid claiming
stronger latest-state guarantees than it can keep.

Provider mirror behavior:

- Receive upserts entry text, formatted content, attachments, links, author,
  mentions, metadata, raw payload, and provider time.
- Deletes and recalls write a short-lived tombstone and physically delete the
  current provider mirror entry. Physical deletion does not imply rewriting
  actor transcript history.
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
- Provider time is not prompt time. Model-visible history and its timestamps
  belong to AIGateway's `ai_gateway_messages` projection; provider time never
  orders model history.
- `gateway_time` is used for tombstone TTLs, pending batch timers, retry
  backoff, and first/last-seen bookkeeping.
- `actor_time` belongs to actor runtime state and does not order provider
  mirroring.

`ignore` intentionally does not mirror unaddressed IM group entries. The mirror
matches what Ankole chose to observe for that binding; it is not a universal
provider audit log.

## Ingress Policy And Effects

For each `IngressFact`, SignalsGateway applies binding policy and writes the
needed effects in one transaction. One input can update the provider mirror,
append or cancel `actor_events` rows, refresh a tombstone, and then accept
or reject the provider callback.

Common cases:

| Input case | Effects |
| --- | --- |
| Unaddressed IM group + `ignore` / addressed-only | Short pending wait for an addressed trigger; if none arrives, no mirror row and no actor event |
| Unaddressed IM group + `record_only` | Mirror entry, pending batch may later upgrade to addressed; otherwise no actor event |
| Unaddressed IM group + `may_intervene` | Mirror entry, pending neutral batch closes as `im.message.may_intervene` unless it upgrades to addressed |
| DM or structured mention | Mirror entry, pending batch closes as one `im.message.addressed` |
| Webhook accepted for agent work | Mirror entry, append the source/event-defined ActorEvent |
| Webhook mirror-only | Mirror entry, no actor event |
| Recognized visible command such as `/steer` | Mirror visible command entry, append `command.steer` under command admission |
| Schedule fired | Append the schedule-defined event (`check_back_later.wakeup` or `cron.fire`) with explicit `session_id` |
| Provider-side removal before receive | Write tombstone so a late receive is dropped |
| Provider-side removal while actor event pending | Refresh tombstone, physically delete the current mirror entry, cancel/remove the pending actor event |
| Provider-side removal after work completed | Refresh tombstone, physically delete the current mirror entry, append `signal.entry.removed`; consuming it cancels anchored checkbacks, applies the AI-message deletion mapping, and completes — no model-visible note |

This is the only place where binding policy turns ingress facts into actor
events. `record_only` means mirror effect only; it is not an event type and it
does not create an actor-side receipt.

There is no separate `record_and_signal` gateway mode. The Ankole term for that
path is the accepted actor event path: the provider mirror is recorded and the
same transaction appends `actor_events`.

Gateway behavior uses existing facts instead of writing a separate per-entry
lifecycle table:

- `ignore`/addressed-only keeps only short pending batch state for unaddressed
  IM group entries. If the batch never upgrades to addressed, it writes no
  mirror row and no actor event.
- `record_only` and other mirror-only receives write the mirror row and stop.
- any provider-backed non-IM receive that appends an actor event writes
  `actor_events` before ack.
- IM receives update or close pending inbound batches before ack; closed batches
  that choose actor delivery write exactly one `actor_events` row.
- work completion is recorded on the event row itself: AIGateway's terminal
  commit — or the worker's noop marker — sets `actor_events.completed_at` in
  the same transaction that commits the final output and clears the live
  delivery. There is no separate consumption table.
- provider-side removal refreshes the tombstone first, then checks
  `actor_events` state (`input_state`, `completed_at`, live deliveries) to
  decide whether to remove the pending event, append a lifecycle event, or only
  update the mirror.

`unaddressed_group_message_policy` is an IM-like group-channel binding policy,
not a Feishu/Lark-specific rule. It only applies after the binding route has
classified the message as not explicitly directed to the agent.

`record_only` updates the mirror, then stops. It creates no actor event, no
`actor_events` row, no resolver selection, no scheduling metadata, and no
change to any AI-visible state.

`record_only` still needs IngressFact idempotency. The mirror uses
`(signal_channel_id, source_entry_id)` plus provider time for latest-state
idempotency. If a provider route needs callback redelivery de-dupe beyond that,
it may store a processed source-event key, but that key is not entry lifecycle.
Do not create an actor event just to get idempotency.

DM entries are always explicit for the target binding. IM group entries become
explicit when the adapter exposes a structured mention, reply-to-bot,
application command, or provider-native bot invocation. Plain text containing
`@` is not enough unless the adapter normalized it into a structured fact that
the binding route treats as explicit.

`may_intervene` allows a closed neutral inbound batch to create
`ActorEvent(type = im.message.may_intervene)`. The gateway folds unaddressed
observations for the same channel/thread into a pending batch so the actor
judges a room scene instead of one isolated message. If a later message in that
pending batch explicitly addresses the bot, the addressed trigger takes
priority and the eligible sender run closes as addressed instead.

The same phrase appears at three levels with different meanings:
`unaddressed_group_message_policy = may_intervene` is the binding policy;
`ActorEvent.type = im.message.may_intervene` is the semantic event delivered to
the actor; the actor runtime has code that maps that type to its intervention
judgment path.

Webhook entries normally update the mirror and append the source/event-defined
ActorEvent. A binding or source event definition may still classify webhook
entries as mirror-only when the source is meant for history or recall rather
than immediate agent work.

Internal facts such as schedule fires bypass SignalsGateway ingress and the
provider mirror unless they explicitly carry a signal channel. The owning
control-plane subsystem appends the `actor_events` row directly, uses
`source_event_id` for idempotency, and must provide an explicit `session_id`.
The durable event shape is still the same actor-facing envelope; the entry point
is not an internal SignalsGateway binding.

Clarify-reply routing for unmentioned group messages is not implemented in v1.
Until a runtime-owned clarify registry is added and wired into ingress,
unmentioned group replies follow normal unaddressed group policy.

## Actor Events

SignalsGateway writes a small CloudEvents-style envelope into `actor_events`.
The envelope is a shape convention, not an external runtime dependency. `type`
is the ActorEvent semantic type chosen by binding policy and command
classification; it is not the IngressFact kind.

Envelope fields:

- `specversion = "1.0"`
- `id`: `source_event_id` and enqueue idempotency key
- `source`: `signal://<adapter>/<encoded_channel_id>` for channel-scoped
  events, or `internal://<binding_name>/<session_id>` for internal events
- `subject`: `signal_gateway_entries:<source_entry_id>` or
  `signal_actions:<action_id>` for provider-backed events; internal events may
  use a source-specific subject such as a schedule fire id, or omit it
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

SignalsGateway writes only actor-facing events to `actor_events`:

- `im.message.addressed`: one closed addressed IM batch representing one
  requester sender's turn to the agent. The worker sees one merged `data.entry`;
  `data.entries` preserves provider-message provenance.
- `im.message.may_intervene`: unaddressed IM group input that the binding lets
  the agent inspect; it is created only when a neutral pending batch closes
  under `unaddressed_group_message_policy = may_intervene`.
- webhook and action events: type is chosen by source/event definition code;
  binding policy decides whether that event is admitted, ignored, or mirror-only.
- `command.*`: visible text command events. Individual command types choose their
  consumption path through code keyed by `ActorEvent.type`; `command.steer` may
  use the same path as `im.message.addressed`.
- `session.reset_due`: control-plane session lifecycle barrier. It is enqueued
  by scheduler/workflow code for a specific session and waits behind earlier
  actor work instead of interrupting it.
- `signal.entry.removed`: written only when the original event's work already
  completed. Consuming it cancels checkbacks anchored to the removed entry,
  applies the AI-message deletion mapping (see Core User Stories), and
  completes the lifecycle event. It must not start a normal model run, treat the
  removal as a human command, or delete prior assistant output beyond that
  mapping. It produces no model-visible note.

Lifecycle events are deterministic only at the state-transition boundary: the
runtime decides whether to cancel pending work or to apply the removal mapping
to already-stored AI output. Model history is affected only through that
mapping: hard-deleted tail rows disappear from history, while historical and
compaction-covered removals are no-op in v1. If a future audit path writes a
retracted row, projection skips it; no replacement text is generated for the
model.
`session.reset_due` is stricter session lifecycle: it produces no model input
and does not invoke the LLM.

Provider reactions, `record_only` entries, ignored entries, streaming deltas,
and agent outbound effects are not actor events. GitHub issues, pull requests,
comments, and review comments should map into the same generic receive/delete
shapes unless a provider-specific shape is truly required.

For IM actor events, `payload.data.entry` is the worker-facing snapshot:
merged text, merged durable attachments, one reply anchor, and the channel/thread
metadata the existing worker path expects. `payload.data.entries` is the ordered
list of source provider entries. It is used for provenance, deletion/recall,
reply-anchor recalculation, and debugging. It must not become the only place
where the worker can understand the user input.

`actor_events` is a generic work-item journal. The current runtime routes every
event type to one executor: the AIGateway/agent-computer handler, which runs
the Responses tool loop. A future executor — for example a DAG workflow
runtime — would receive the same kind of actor event but must own its own
durable run tables; only events routed to the AI handler write
`ai_gateway_messages`.

## Code Contracts Vs Stored State

Some gateway behavior must be durable state because it crosses process crashes
or provider retries. Some behavior should stay in code because making it
database-driven would create a second control plane without a user story.

Stored state:

- provider mirror rows: `signal_gateway_channels` and `signal_gateway_entries`;
- short-lived tombstones for provider-removal races;
- `actor_events` rows: durable lifecycle work items. A row stays after its work
  completes; `completed_at` records the completion, and there is no separate
  consumption table;
- `signal_gateway_outbox` rows until provider-visible side effects resolve;
- route-level binding config such as adapter id, credential reference, filters,
  and `unaddressed_group_message_policy`.

SignalsGateway does not store a separate processed-ingress-events table.
Actor event redelivery is de-duped by the `actor_events` unique key
`(agent_uid, binding_name, source_event_id)`. Mirror-only redelivery is
de-duped by `signal_gateway_entries` using the adapter's stable source entry key.

Code contracts:

- `ActorEvent.type -> actor consumption path`, including `command.steer` using
  the addressed IM path and `command.compress` consuming as a control-plane
  compaction command;
- IM pending-batch finalization rules for addressed, ambient, and no-op
  outcomes;
- command parser and command admission for `/new`, `/compress`, `/retry`,
  `/steer`, and `/stop`;
- public adapter context methods such as `emitEntry` and `emitAction`;
- internal constructors for accepted `IngressFact` and outbox adapter contracts;
- the CloudEvents-style envelope shape written to `actor_events`;
- strict JSON normalization for durable actor event, outbox, and mirror
  payloads;
- source/event definitions that map webhook/action facts to ActorEvent types.

Do not store `resolver_key`, per-entry `observed_only` rows, binding-channel
observation rows, or entry-lifecycle rows just to make implementation routing
look configurable. Do not let arbitrary binding rows define new ActorEvent type
semantics either; bindings may choose routes and admission policy, while event
semantics live in code. If a future product story needs such configurability, it
should introduce that story explicitly instead of smuggling it into gateway
state.

## Background Jobs And TTL Cleanup

TTL cleanup is one SignalsGateway use case of the broader control-plane
background-job runtime. The background-job runtime is an Ankole-wide
infrastructure choice, not a SignalsGateway submodule. SignalsGateway should say
what periodic or deferred work it needs and what guarantees that work needs; it
must not make the gateway tables or actor event semantics depend on the job
runtime.

TTL-like storage needs a resident cleanup path:

- `signal_gateway_input_tombstones`: delete rows after `tombstoned_until`.
- completed `actor_events` rows are not TTL delivery state. They are durable
  lifecycle facts; any long-term retention policy belongs to the actor store,
  not to SignalsGateway cleanup.

`signal_gateway_entries` is deliberately absent from this TTL list. It is long-lived
provider observation and memory/search substrate. Provider-side removal may
remove or redact content through explicit product/privacy semantics, but
background runtime cleanup must not treat it like actor delivery state.

ActorRuntime tables such as `actor_event_deliveries`,
`actor_session_activations`, worker heartbeat projections, and sticky placement
rows are different: they are recovery-window runtime state. Their unlogged
storage choice and row cleanup rules belong to the actor store/runtime design,
not SignalsGateway.

Oban is the default choice for that Ankole-wide background-job runtime because
future work will need persisted enqueue, retries, uniqueness/idempotency,
scheduled jobs, cron-like recurring jobs, operational visibility, and
Postgres-backed coordination. This choice does not make Oban part of
SignalsGateway's data model. Oban jobs may operate on SignalsGateway tables,
but they do not replace `actor_events`, `signal_gateway_outbox`, or provider
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
session boundary and is not duplicated into `signal_gateway_entries`.

Events without a signal channel, such as schedule fires, must carry an
explicit `session_id`. They can append `actor_events` rows without creating a
`signal_gateway_channels` row or `signal_gateway_entries` mirror row. Unless they deliberately
carry a channel, they do not enter the provider mirror.

The actor runtime owns session scheduling, fencing, and turn recovery;
conversation history, compaction, and the final AI output live in AIGateway's
message log. Runtime state may include binding name and provider realm id, but
SignalsGateway should not create a separate session for provider thread or
ActorEvent type.

Daily reset is represented as `ActorEvent(type = session.reset_due)`. The event
is queued against the current `session_key` because its ordering relative to
already accepted work matters. The control-plane scheduler uses AppConfigure
`system.timezone` to decide when local 04:30 has arrived and writes the boundary
time into the event payload for idempotency and diagnostics. Runtime execution of
the event does not re-interpret freshness: when `session.reset_due` reaches the
head of the session queue, ActorRuntime rolls the current active session. It does
not change provider mirror identity and it does not require a gateway-owned queue
separate from `actor_events`. The current default actor identity remains:

```text
actor_id = {agent_uid, session_id}
```

Daily reset does not make the channel forget what is happening in the room.
`im.message.may_intervene` is a real provider observation, not a heartbeat,
cron, exec, or other stale system-event notice. An open ambient batch is allowed
to keep collecting room observations across the reset boundary and later
materialize into the successor active session. That continuity is intentional:
it gives the agent a better scene for intervention after the reset instead of
cutting a live group conversation at an arbitrary clock edge.

Visible `/new` remains a `command.new` event because it is a user-facing command.
Daily reset should not reuse `command.new`: current commands may have
interrupt/nudge semantics, while `session.reset_due` is a barrier that waits
until prior work is finished before applying the reset.

## Commands

The adapter or shared parser recognizes visible text command events on
text-bearing `entry.received` IngressFacts:

- `/new`
- `/compress`
- `/retry`
- `/steer`
- `/stop`

Command classification produces `ActorEvent(type = command.*)` as the
actor-facing event for recognized command entries. The typed command payload
looks like:

```json
{
  "name": "steer",
  "raw": "/steer be concise",
  "argsText": "be concise"
}
```

SignalsGateway does not execute undo, steering, retry, stop, or
assistant-output recall semantics. The actor event classifies the semantic
ingress; the session actor runtime decides what the command means and records
execution state in actor-runtime rows, not in the parsed command payload.

Command actor events are direct events. They do not enter IM burst batching,
and they do not rewrite queue order. When a generation is already running,
ActorRuntime uses the command runtime policy below. That priority is a runtime
scheduling rule, not a SignalsGateway queue rule: the actor event journal still
keeps `queue_sequence` as open-queue append order.

| Command | ActorEvent type | Runtime policy | Executor |
| --- | --- | --- | --- |
| `/stop` | `command.stop` | `control_now`: cancel the active generation and send a control signal; it does not start a second turn | Control plane |
| `/retry` | `command.retry` | `control_now`: cancel an active generation, or re-run a completed event from its last `complete` row; it does not start a second turn | Control plane |
| `/new` | `command.new` | `control_now`: roll the session window, cancelling the active generation when needed | Control plane |
| `/steer` | `command.steer` | `checkpoint_nudge`: stays in the actor event queue, and while a turn is active may be delivered to the worker as `mailbox_updated` for checkpoint consumption | Worker turn |
| `/compress` | `command.compress` | `control_now`: run a control-plane compaction; no worker turn starts | Control plane (AIGateway compaction) |

`/compress` folds an older prefix of chat history into one summary while
keeping the recent tail verbatim. A visible entry may be `/compress` or
`/compress <focus>`, and command admission turns it into
`ActorEvent(type = command.compress)`. The control plane executes it: AIGateway
summarizes with the agent's `light` model profile (falling back to `primary`)
and writes a compaction artifact plus `type = "checkpoint"` row; the user then
gets fixed command feedback through the outbox. No worker turn runs and no
worker RPC is involved. The summary is previous chat history, not an
environment fact and not a system prompt rule. Later runs stop provider-visible
history traversal at the checkpoint, load the artifact output, and replay the
artifact's copied retained tail (see `docs/design-docs/AIGateway.md`,
Compaction).

`/steer` is a typed command event like `/new`, `/compress`, `/retry`, and
`/stop`. The command remains `ActorEvent(type = command.steer)` even when its
resolver path is equivalent to `im.message.addressed`. If the session actor is
running, the Elixir control plane may send a ZeroMQ `mailbox_updated` carrying
the single already-journaled steer event, and the agent computer may consume it
at a checkpoint. Those control messages are nudges: any cross-boundary event
delivery must reference an already journaled actor event and must not carry an
undurable provider payload. SignalsGateway must not model steering as a second
control queue.

The `/steer` command event completes when ActorRuntime successfully sends or
queues that `mailbox_updated` nudge for the active turn. That completion is a
receive acknowledgement for the command, not proof that the current model call
or a later tool round incorporated the steer. If the active turn reaches a
terminal commit first, the delivery may be superseded while the command event
stays complete. This is a deliberate latency tradeoff for active human guidance;
transport delivery and model incorporation remain separate runtime facts.

`/undo` is not a command. If a user wants to retract input, the provider removal
lifecycle event is the supported path.

Command parsing trims leading bot mentions for mentioned commands, allows
multi-line arguments, and normalizes full-width spaces and digits before
matching. A full-width slash remains user text.

## Actor Event Handoff

There is no durable gateway-owned queue separate from `actor_events`. Accepted
agent-relevant signals are written into `actor_events` in the same transaction
that updates the provider mirror and tombstone state. The row is a durable
lifecycle work item: it covers the crash recovery gap after provider ack and
before actor fabric delivery and worker acceptance, and it stays after the work
completes. Completion is recorded as the `completed_at` timestamp on the same
row; a completed event is history, not garbage.

SignalsGateway does not lock a whole session while an actor turn is running. New
`actor_events` rows for the same `session_id`, including follow-up messages and
`command.steer`, can still be appended durably. The actor runtime owns when to
publish/replay them through the actor fabric, whether to checkpoint early, and
how to fence overlapping work.

The actor store owns the physical `actor_events` and `actor_event_deliveries`
schema. SignalsGateway owns the signal payload and idempotency contract it
writes. Actor event payloads should be minimal dispatch snapshots, not raw
provider payload copies. Heavy raw data, attachments, and long-lived searchable
content should stay in `signal_gateway_entries`, attachment/blob storage, or the
AIGateway message log after the work completes.

Completing an actor event is the commit boundary, and it happens in AIGateway.
Worker acceptance over the actor fabric is a separate delivery fact in
`actor_event_deliveries`, not completion. When the final `response.create` of
an event's tool loop reaches its terminal state, AIGateway's commit transaction
verifies the delivery fence (activation/epoch/revision), rejects the commit if
a provider-removal tombstone canceled the event, marks the final
`ai_gateway_messages` row `complete`, sets `actor_events.completed_at`, clears
the live delivery, and inserts any explicit outbox intents (such as reply
attachments) — all in one transaction. An event with no meaningful output
completes through the worker's `turn_noop_completed` marker instead; the
control plane sets `completed_at` and creates nothing else.

There is no user-message materialization step. The human input of an event
travels inside the first `response.create` of the loop and is stored as
request-side input items in that run row's `content`. No separate user-message
row exists anywhere.

Required logical actor event metadata:

- `agent_uid`, `binding_name`
- `session_id`
- `source_event_id`
- optional `signal_channel_id`, `provider_thread_id`, `source_entry_id`
- `type`
- `available_at`
- `queue_sequence`: the per-session append order
- `input_state`: `open` or `dead_letter`
- `completed_at`: set once when the work finishes
- optional `dead_letter_at`
- `sender_key`
- `payload` as a minimal dispatch snapshot

For closed IM batches, `source_entry_id` is the reply anchor, normally the
last source provider entry in the batch. It is not the full source set. The
payload or adjacent runtime metadata must preserve all source provider entry ids
and the logical batch revision so provider-side removal can update pending or
in-flight work without pretending each source message was a separate actor
event.

SignalsGateway must provide enough data for the actor store to assign
`queue_sequence`, evaluate readiness, and later correlate provider-side removal
with the accepted event. It does not decide worker placement, actor epoch,
ZeroMQ route, send outcome, worker acceptance, or completion. Those facts
belong to `actor_event_deliveries`, `actor_session_activations`, and — for the
AI output itself — `ai_gateway_messages` rows located through
`metadata.actor_event_id`.

The actor event idempotency key is `(agent_uid, binding_name,
source_event_id)`. For provider-backed events, the adapter must map the
provider's stable event id to `source_event_id`; provider entry ids such as
message ids are mirror/reply anchors, not event idempotency keys. For internal
events, `source_event_id` comes from the configured source, such as a schedule
fire id.

`sender_key` is the adapter-normalized stable sender identity used inside
pending IM batches and, for addressed batches, to identify the requester sender.
It must prefer the normalized principal or platform subject when available, then
fall back to the provider author id. Display names must not be used as sender
identity. Direct non-IM events set `available_at = now` and do not need pending
batch state.

A completed `actor_events` row is not a third long-lived content copy beside
`signal_gateway_entries` and the AIGateway message log: its payload stays a minimal
dispatch snapshot, and the durable content lives in the mirror and in
`ai_gateway_messages`. The row itself stays because its lifecycle fields answer
questions no other table should answer.

Provider-side removal handling reads those fields directly from the row:
a pending event (`input_state = 'open'`, `completed_at IS NULL`) can be removed
or cancelled; a completed event (`completed_at` set) produces a
`signal.entry.removed` lifecycle event; a mirror-only entry has no event row
and only updates the provider mirror. There is no separate entry-lifecycle
store and no consumption table to consult.

The completion transaction must verify the source actor event has not been
canceled by provider-side removal after the worker read it. If the event was
canceled, the commit is rejected as stale and must not mark the output
`complete`, set `completed_at`, or write outbox rows for that event.

Actor event readiness is still code-defined, but IM batching is complete before
the actor event is handed to ActorRuntime. `available_at` means "this already
formed actor event may now be delivered"; it is not the mechanism that decides
which provider messages belong together. The default v1 IM batching rules live
in SignalsGateway's pending inbound batch finalizer. Webhook events, lifecycle
events, command events, and action events are direct events and are ready
immediately by default unless their event definition says otherwise.

ActorRuntime picks work with a singular ready query (`next_ready_event`): the
candidates are rows with `input_state = 'open' AND completed_at IS NULL`, in
`queue_sequence` order, excluding sessions that already have a live delivery.
One worker execution handles exactly one actor event. There is no batching of
several events into one execution and no accepted-ids list anywhere in the
protocol.

Runtime command readiness does not mean FIFO execution under an active
generation. A control command that targets the active turn may be processed
before earlier ordinary ready events so the user can stop, retry, steer, or
roll the current generation without waiting for the blocked content queue. Once
the active turn is fenced off or completed, ordinary events resume in broker
sequence.

For `/steer`, "processed" means accepted for the active turn and pushed through
`mailbox_updated` when such a live turn exists. It does not create a second
ordinary message behind the running turn, and it does not wait for worker
acceptance before marking the command event complete.

The reset barrier is part of the `session.reset_due` runtime contract. If the
session still has a live generation or live delivery when this event reaches the
head of the ready set, ActorRuntime should leave the reset event open and report
that it is waiting for the running work to finish. Later events for the same
session must not pass the barrier.

That barrier is about actor event execution order. It must discard stale
session-local system work such as schedule and exec notices when the reset
rolls the session, but it should not discard or split ambient room observations
solely because their batch spans the clock boundary.

Pending inbound batching is represented by short-lived gateway state, not by a
set of already-created actor events with synchronized `available_at` values.
When the batch closes, the gateway writes at most one actor event for the
closed portion. ActorRuntime should not re-batch addressed IM rows by reading a
contiguous same-sender prefix; doing so would merge batches that SignalsGateway
already split by user story.

The database may index pending batches by agent uid, binding name, signal
channel id, and provider thread id. That index is only for batching and
provider-delivery lookup; it is not a domain concept. The session boundary
remains channel-level; thread scope affects batching and provider delivery.

In other words, IM batching is an ingress-time classification window:

```text
provider entries -> pending inbound batch -> addressed | ambient | no actor event
ActorEvent.available_at -> delivery time for the already-formed event
```

Provider-side removal follows the facts already stored in `signal_gateway_entries`,
`signal_gateway_input_tombstones`, `actor_events` (its `input_state` and
`completed_at` fields), and `ai_gateway_messages` refs. It must not create a
separate entry-lifecycle table.

Provider delete and recall share the same lifecycle logic. The provider's raw
name may be retained as diagnostic metadata, but the lifecycle event type after
the original event's work has completed is always `signal.entry.removed`.

Every provider-side removal writes or refreshes the short-lived tombstone before
state-specific handling. This prevents provider retry or late receive from
recreating a mirrored entry after the user removed it.

| Transition | Effect |
| --- | --- |
| `unseen + removal` | Write `tombstoned_until`; late receive is dropped |
| `tombstoned_until + receive` | Drop receive, do not re-mirror, do not wake |
| `accepted receive + event still open` | Pending actor event exists in `actor_events` |
| `accepted receive + event completed` | Original event's work finished (`completed_at` set) |
| `mirror-only receive + removal` | Refresh tombstone and physically delete the provider mirror entry |
| `pending inbound batch + removal` | Refresh tombstone, physically delete the provider mirror entry when present, remove the source entry from the pending batch, and recompute outcome |
| `open actor event + removal` | Refresh tombstone, physically delete the provider mirror entry, cancel/remove the open actor event |
| `in-flight actor event + removal` | Refresh tombstone, physically delete the provider mirror entry, abort the active delivery, retry the same logical batch revision without the removed source entry when anything remains, and reject stale commits from the old revision |
| `completed actor event + removal` | Refresh tombstone, physically delete the provider mirror entry, append `signal.entry.removed`; consuming it cancels anchored checkbacks and applies the AI-message deletion mapping — no model-visible note |

This distinction matters most for historical removal. If the original event is
still pending or is the trigger for an unfinished generation, cancellation
prevents new output from being based on withdrawn content. If the event's work
already completed, the removal acts only through the AI-message deletion
mapping: chain-tail rows after the last compaction are hard-deleted from the
message log; historical rows and compaction-covered rows are no-op in v1. No
note is written for future model turns. A provider-visible assistant message is
removed only through an explicit later output intent, never inferred from the
user-side removal.

`signal_gateway_input_tombstones` is the short-lived storage for the
`tombstoned_until` state. Its primary key is `(agent_uid, binding_name,
signal_channel_id, source_entry_id)`, so a removal in one channel cannot
suppress a same-id entry in another channel. The receive and tombstone paths use
a transaction-scoped advisory lock over a `hashtext` key derived from
`signal_channel_id` and `source_entry_id`; whichever side wins commits before
the other observes state. Rare hash collisions only serialize unrelated entries
briefly.

## Outbound And Recovery Boundary

The outbox carries explicit provider-visible side effects committed by the
Elixir control plane: posts, replies, edits, deletes, reactions, cards,
dividers, non-streamed system notifications, command feedback,
schedule/checkback visible output, and outbound reply attachments. Streamed AI
replies do not pass through the outbox; they are delivered live (see Streamed
AI Reply Delivery below). SignalsGateway does not infer that a removed user
entry should remove prior agent output. The committed intent is the
`signal_gateway_outbox` row itself; there is no second actor-outbox table that
the gateway later copies from.

Outbox rows name their origins with the standard identity layers:
`source_actor_event_id` points at the actor event whose work produced the
effect, and `ai_message_id` points at the `ai_gateway_messages` row when the
effect delivers or references model output. Both are traceable joins, not part
of the outbox key.

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
  accepted actor event.

Rich card-like output should remain protocol-first. A portable interactive
output payload and a provider-native escape hatch, such as a Lark-native card,
are both valid `card` payloads when the adapter declares support. Every such
payload must include fallback visible text so the provider mirror, notification
surfaces, and unsupported clients retain a meaningful current-state mirror.

Outbox rows store retry counters, last attempt/error fields, provider send
started time, recovery state, idempotency key, and the created source entry id.
If a process restarts after `platform_send_started_at`, the dispatcher first
attempts adapter reconciliation when a `created_source_entry_id` exists. If the
adapter cannot prove idempotency or reconciliation, the row becomes
`unknown_after_send` instead of blindly replaying a possibly delivered entry.
Adapters that support idempotent sends must reuse the same idempotency key
across retries.

The gateway does not promise provider side-effect exactly-once unless the
provider/adapter can support idempotency or reconciliation. It does promise not
to fake provider mirror state before confirmed provider success.

Final AI content truth belongs to `ai_gateway_messages`, owned by AIGateway.
SignalsGateway owns only the delivery of that content and the mirror of what
was delivered. The rule for whether a user-side removal should also delete bot
output stays outside the gateway.

## Streamed AI Reply Delivery

The normal chat answer is streamed. Its delivery deliberately uses no Redis, no
streaming-delivery state table, and no periodic chunk scanning. The design is
"durable facts in PostgreSQL, live signals as process messages":

- `ai_gateway_messages` is the content truth. AIGateway writes it.
- Live chunks are in-process publish/subscribe messages from AIGateway. They
  are preview signals and are never persisted.
- `signal_gateway_entries.ai_message_id` is the delivery proof: it is set only after a
  confirmed final provider send or edit.

`AIReplyPreview` is a per-event process that SignalsGateway starts when an
IM-visible actor event begins generating (both the immediate ingress path and
the batch finalizer start it). It subscribes to the event's live chunk and
terminal events:

- on the first chunk, it sends the provider preview message. The Feishu/Lark
  adapter may use a streaming card when its chat config enables that behavior;
- as chunks arrive, it edits the same provider message, throttled;
- on the terminal `complete` event of the loop's final round (the round without
  a `function_call`), it finalizes: the provider message is replaced with the
  durable final content. Intermediate rounds that end in a `function_call` keep
  the preview open;
- on a failed terminal, it stops. Error output is not rendered to the provider
  in the current policy; the preview handler simply terminates and writes no
  mirror.

Preview continuity is best-effort, not a durable guarantee. The provider-side
preview message id is transient delivery state; it is never written back into
`ai_gateway_messages`. If the preview process dies mid-stream, the user may see
a stale preview until recovery delivers the final content.

Only the confirmed final send or edit writes the mirror: `signal_gateway_entries` is
upserted with the same normalized shape used for inbound entries, keyed by the
provider entry identity `(signal_channel_id, source_entry_id)`, with
`ai_message_id` set to the final row's id. If the provider does not return an
entry id, no mirror row is written — the gateway never synthesizes a provider
identity — and the recovery scan compensates later. Intermediate chunks never
touch `signal_gateway_entries`.

`RecoveryScan` is the catch-up path for finals that never reached the provider
(preview process died, provider send failed, control plane restarted). It runs
as a single control-plane process on startup and on a periodic bounded scan.
Its eligibility predicate is pushed down into SQL and shared with
`AIReplyPreview`'s IM-visibility predicate, so live and recovery paths agree on
what should be visible:

- `type = "message"`, `status = "complete"`, and the row is the chain tail of
  its event (no `function_call` in content);
- the actor event is IM-visible by policy;
- the final content has non-empty visible text;
- no `signal_gateway_entries` row with this `ai_message_id` exists yet.

Matching rows get their final IM reply sent (or re-sent). The scan waits out a
grace window before touching recent rows, and re-checks best-effort before and
after sending. There is deliberately no database or advisory-lock mutex around
the resend: in the current single-instance deployment it would not make
delivery exactly-once, and it would add a coordination layer with no owner. A
multi-instance deployment adds an explicit claim as part of that design.

The resulting guarantee is explicit: streamed IM delivery is at-least-once and
best-effort. A reply can be delivered twice in rare crash windows, and a
preview can go stale, but a completed reply is never silently lost while the
scan runs, and durable content is never wrong. Error terminals are not
delivered at all in the current policy — a failed generation leaves no new
provider message; retry surfaces the answer through a fresh actor event.

## Feishu/Lark Adapter Boundary

The Lark plugin uses one shared long-connection consumer per `domain + app_id`.
Feishu/Lark long-connection delivery is cluster-mode, not broadcast-mode:
opening multiple clients for the same app id can split events randomly. Chat
ingress and identity realtime sync therefore share the same connection owner for
that app key.

Different app ids are different bot accounts. If multiple Feishu/Lark bot
accounts sit in the same group and are connected to different agents, Ankole
must run one long-connection client per app id. Each app view can produce its
own accepted actor event. The provider mirror only shares storage when the
adapter-normalized channel id and source entry id are identical; if the
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
applies binding policy, writes accepted ActorEvents into `actor_events`, and
lets ActorRuntime publish or replay the ready event through the actor fabric.

The chat-channel config includes the same `domain` field as identity-provider
config. A Feishu app and a Lark app with the same `app_id` are different
connection realms. Chat and identity realtime sync can share a connection only
when both use the same `domain + app_id`.

For a shared app, chat consumers should be included before identity realtime
sync opens or reuses the connection, and identity consumers should be included
before its startup full sync. Otherwise Feishu/Lark's non-broadcast delivery can
route events away from the runtime path that needs them.

### Identity Provider Directory Sync

Directory sync is an identity-provider capability, not a SignalsGateway binding
policy. The generic capabilities are `directory_full_sync` and
`directory_realtime_sync` on the `principals.identity_provider` adapter
declaration. A provider that does not declare `directory_full_sync` must not get
full-sync jobs just because its config happens to contain `sync.contacts`.

The common config switch is `sync.contacts`. It means "sync the provider
directory" as one unit; Ankole does not expose separate `sync.users` and
`sync.departments` switches. For Lark, the full sync entry point is
`sync_directory/3`: it pages contact users and departments with `sync.pageSize`,
upserts users into Principal platform-subject identity, upserts provider-owned
department groups and external bindings, and refreshes users' department group
memberships.

Full directory sync always runs in Oban through
`Ankole.IdentityProviders.Jobs.SyncProvider`. It is enqueued by these edges:

- saving an enabled identity provider whose `sync.contacts` is true, including
  first setup, later console edits, and re-saving credentials;
- the console manual "run full sync" action for a saved provider whose adapter
  declares `directory_full_sync`;
- control-plane startup, via a one-shot boot edge that scans enabled providers;
- `Ankole.IdentityProviders.Jobs.EnqueueDirectorySyncs`, a periodic wake edge
  that scans enabled providers and enqueues due full-sync jobs.

The periodic wake edge is not itself the six-hour guarantee. It may run more
often, but the inserted `SyncProvider` job uses Oban uniqueness over
`provider_id + reason + source` for the configured full-sync interval. The
interval is AppConfigure-owned at
`principals.identity_providers.directory_full_sync_interval_hours`, with a
default of 6 hours.

Realtime directory sync is incremental and provider-specific. For Lark it uses
the same `domain + app_id` long-connection owner as chat ingress, because the
provider's long-connection delivery is cluster-mode. The Lark identity consumer
starts only when `sync.contacts == true` and `sync.websocket == true`; the
validator normalizes `sync.websocket` to false when contacts sync is disabled.
The Lark plugin reconciles connections once on control-plane boot and
identity-provider save also requests an immediate realtime reconciliation, so a
provider added during first setup can start listening for incremental contact
events without a control-plane restart.
Contact user events can upsert platform-subject facts directly. Events that
cannot safely be merged incrementally, such as missing identity information or
`contact.scope.updated_v3`, enqueue a full directory sync instead of guessing.

None of these sync paths create signal entries, actor events, inbound batches,
or outbox rows. They write Principal/AuthZ-owned identity facts through the
host-owned bridge. Chat ingress may use those facts for attribution later, but
directory sync itself is outside the provider mirror and actor event journal.

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
- Message recall uses Lark's `im.message.recalled_v1`, mapped to `entry_removed`.
  SignalsGateway writes a tombstone, physically deletes the mirror entry, and
  writes the lifecycle event only if the original event's work already
  completed.
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
generic mirror semantics. `signal_gateway_entries` remains the long-lived observed-fact
surface and latest-state mirror Ankole can build from; it is not expected to
converge to provider state for lifecycle changes that the provider never emits
and the adapter never fetches through an official API.

## Edge Cases

The gateway user-story surface includes these contract cases:

- `ignore` ignores non-mentioned IM group entries and does not update the
  provider mirror unless a short pending batch later upgrades the entry into an
  addressed batch.
- `record_only` mirrors unaddressed IM group entries and does not wake the
  agent unless the same pending batch later upgrades an eligible sender run into
  addressed input.
- `may_intervene` mirrors unaddressed IM group entries and emits
  `im.message.may_intervene` only when the neutral batch closes as ambient.
- Literal `@Agent` text is not a structured mention.
- DM entries route as explicit input.
- Structured group mentions route as explicit input even when
  `unaddressed_group_message_policy = ignore`.
- Webhook entries update the mirror and append an ActorEvent by the source/event
  definition unless the binding or source event definition classifies them as
  mirror-only.
- A channel with `reply_mode = none` can still create an actor event; it just
  cannot receive provider-visible outbox reply.
- Clarify-reply routing for unmentioned group messages is not implemented in v1;
  those entries follow normal unaddressed group policy.
- One closed addressed IM batch represents one requester sender's turn.
- A neutral same-sender group message followed by a bot mention can become one
  addressed batch.
- If a neutral multi-sender batch later receives a bot mention, only the final
  matching sender-contiguous run can upgrade to addressed; earlier runs close as
  ambient or no-op.
- A different sender breaks an open addressed batch.
- A non-bot structured mention in an addressed follow-up closes the current
  addressed batch before the new message is routed.
- Same channel with different provider threads keeps the same session actor.
- Different channels produce different session actors.
- Provider-side removal while a receive is still in a pending inbound batch removes that
  source entry from the batch and recomputes the batch outcome.
- Provider-side removal while a closed batch is in-flight aborts the active delivery and
  retries the same logical batch without the removed source entry when anything
  remains.
- Every provider-side removal creates or refreshes a tombstone so stale receives are
  ignored.
- Removal tombstones are scoped by signal channel.
- Provider-side removal of a `record_only` entry updates the provider mirror but does not wake
  the agent.
- Provider-side removal of an entry whose work already completed writes a
  `signal.entry.removed` lifecycle event; consuming it cancels anchored
  checkbacks and applies the AI-message deletion mapping. It does not start a
  normal model run, produces no model-visible note, and does not delete
  provider-visible agent output unless an explicit delete intent is committed.
- Raw reaction keys survive mirroring and re-mirroring.
- Source entry ids are scoped by signal channel id, so same-looking ids in
  different channels do not collide.
- Same physical provider channel and entry facts may share one mirror row when
  the adapter has stable matching provider ids; actor event idempotency remains
  route-scoped, so mirror dedupe does not suppress an accepted actor event.
- Removal handling reads the event's lifecycle directly from the row:
  `input_state` and `completed_at` distinguish pending work from completed
  work. No consumption marker exists.
- The completion transaction must reject an actor event canceled by
  provider-side removal after the worker read it.
- GitHub-like webhook facts map to generic receive/removal shapes.
- Final outbound posts are mirrored only after provider success.
- Provider outbound failure marks the outbox row failed while the accepted actor
  event remains durable.
- Agent returned reaction, divider, and card intents execute only through
  declared adapter capabilities.
- `/undo` is treated as normal text, not a typed command.
- `/new`, `/compress`, `/retry`, `/steer`, and `/stop` are typed command
  actor events under command admission.
- Outbox edit, reply, idempotency, and reconciliation options are passed through
  the adapter contract.

## Invariants

- Signal binding identity is agent uid plus binding name.
- A binding does not define provider channel identity or actor session identity.
- Rule-based delivery routing is not the v1 user configuration surface.
- Routeable actor events do not depend on `signal_gateway_channels` or
  `signal_gateway_entries` primary keys.
- Provider mirror identity is signal channel id plus source entry id,
  not agent uid or binding name.
- Binding-channel observation is not a gateway identity.
- Entry lifecycle is not a gateway identity; provider-removal behavior is
  derived from tombstones, the provider mirror, `actor_events`
  (`input_state`, `completed_at`), and `ai_gateway_messages` refs.
- Actor event idempotency identity is agent uid, binding name, and
  source event id.
- Tombstone identity includes signal channel id because source entry ids are
  not globally unique.
- Provider mirror dedupe and actor event idempotency are separate; re-mirroring
  an entry must not suppress the accepted actor event write for the current
  binding.
- `ignore` does not mirror ignored IM group traffic.
- Inbound edit events are not supported by the current gateway contract.
- A provider-side removal refreshes a tombstone and updates current provider
  mirror/search projection; stored AI output changes only through the deletion
  mapping, and provider-visible agent output is never removed by inference.
- Explicit provider-visible side effects execute only through
  `signal_gateway_outbox` rows. Streamed AI replies are delivered live through
  `AIReplyPreview` and mirrored into `signal_gateway_entries` with `ai_message_id`;
  they never pass through the outbox.
- Provider send failure belongs to the outbox row for explicit effects, and to
  the recovery scan for streamed replies; neither revokes the accepted actor
  event.
- HTTP webhook ack is not a provider-visible reply.
- ZeroMQ is the live actor fabric between the Elixir control plane and agent
  computer workers, not durable signal storage or provider-visible outbox truth.
- Live AI-reply previews are progress hints, not final output truth.
- Provider-specific gaps are adapter limitations, not reasons to widen generic
  gateway semantics.
