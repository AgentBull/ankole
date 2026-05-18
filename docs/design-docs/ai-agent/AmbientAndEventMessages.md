# AIAgent ambient and event messages

AIAgent ambient and event message handling belongs inside the AIAgent runtime.
After EventBus routes an Event to a `target_type = "ai_agent"` Target, the
AIAgent first decides whether the input is explicitly addressed to this Agent,
is an ambient IM utterance in a scene the Agent observes, or is an unsupported
Event type. EventBus, TargetSession, and Channel Adapters do not decide whether
an AIAgent remembers an ambient utterance, intervenes in a conversation, or sends
a visible reply.

This design keeps ambient observation separate from visible replies. An
unmentioned group message may become durable Conversation / Message context for
later use, but it does not by itself become provider dialogue and does not
publicly reply. Proactive intervention is allowed only when the Agent profile
explicitly enables it, a short-lived ambient batch recognizer asks for it, and
the normal AIAgent generation, ACL, Budget, and outbound delivery boundaries
allow a reply.

## Scope

This design defines:

- How an AIAgent handles addressed IM Events, ambient IM Events, and other
  CloudEvents types after EventBus has routed them to the AIAgent Target.
- The AIAgent profile fields that control unmentioned group-message behavior.
- The durable Message roles and kinds used for ambient observation and proactive
  intervention.
- The Redis-backed ambient batch policy for timely intervention checks.
- Ambient brief generation, ambient reference recall, and the boundary between
  ambient context sources and Core prompt rendering.
- Failure behavior, implementation ownership, and acceptance checks for this
  policy.

## Non-goals

This design does not define:

- EventBus acceptance, CloudEvents validation, RoutingContext projection, Event
  Routing Rule matching, TargetSession side-channel storage, TargetSession job
  ownership, or TargetSession output streams.
- Channel Adapter listen-mode configuration, provider acknowledgement timing,
  signature verification, raw payload parsing, mention detection, or outbound
  rendering.
- The complete Conversation / Message schema, active-branch rendering,
  tool-call/tool-result pairing, generation lease, or Core Agentic Loop contract.
- System prompt section ordering, stable-prefix boundaries, or provider prompt
  caching.
- Business handling for webhook, market, system, operations, or domain-state
  Events. This AIAgent policy safely ignores unsupported routed Event types.
- Long-term Brain ingestion, Brain ontology, memory ranking, or cross-Agent
  recall.

## Event classes

From the AIAgent runtime's point of view, a routed Event falls into one of three
classes:

| Class | CloudEvents `type` | AIAgent behavior |
| --- | --- | --- |
| Addressed utterance | `bullx.im.message.addressed` | Persist as `role = user, kind = normal` or `kind = command`, then run the normal Agentic Loop. |
| Ambient utterance | `bullx.im.message.ambient` | Persist as `role = im_ambient, kind = normal`, then follow the Agent profile's ambient policy. |
| Unsupported Event | Any other type | Record allowlisted safety telemetry and return success without writing a user Message or invoking a model. |

Direct messages, group messages that mention the Agent, and provider-native
directed interactions are addressed utterances. Their differences affect
`reply_channel`, conversation key, TargetSession scope, and message meta context;
they do not create separate AIAgent runtimes.

Ambient utterances are ordinary IM group or channel messages that do not
explicitly mention the current Agent. Channel Adapters may emit these Events
only when the source is configured to observe all messages, but the adapter does
not decide whether the Agent stores, recalls, intervenes, or replies.

Unsupported routed Events are not treated as user input. They are not converted
into pseudo-dialogue, do not create Work, and do not call the model in this
design.

## Ambient Conversation session

Ambient utterances belong to an active ambient Conversation session identified
by the Agent and the normalized IM scene. The session is not split by ambient
speaker actor. The same ambient utterance is not copied into multiple per-actor
Conversations.

Addressed utterances may use per-actor Conversation isolation when the Agent
profile asks for it. Ambient utterances do not use the ambient speaker as the
conversation isolation actor because the observed scene, not the individual
speaker, is the context being preserved.

The normalized IM scene must come from normalized Event data or already
committed Conversation metadata. AIAgent code must not infer the scene from raw
provider payload.

## Profile fields

`agents.profile` is the Principal-owned JSONB storage mechanism for Agent
profile data. The AIAgent runtime owns the validation and semantics of the
fields in this section.

`agents.profile.ai_agent.unmentioned_group_messages` controls ambient utterance
behavior:

| Value | Behavior |
| --- | --- |
| `observe_only` | Default. Persist unmentioned group messages for later context. Never proactively intervene. |
| `may_intervene` | Persist unmentioned group messages and allow the Agent to proactively speak when a short-lived recognizer decides the batch is relevant to the Agent's mission. |

Recommended product wording:

| Setting | Description |
| --- | --- |
| Group messages that do not mention the Agent: observe only | Record group messages that do not mention the Agent for later context. The Agent will not proactively reply. |
| Group messages that do not mention the Agent: may intervene | Record group messages that do not mention the Agent and allow the Agent to speak when the messages are relevant to its long-term mission. |

`agents.profile.ai_agent.ambient_intent_system_prompt` is an optional string
with default `""`. It is used only in the ambient intent recognizer system
prompt to clarify how the Agent's `mission` should affect proactive
intervention. It does not replace `mission`, does not enter the normal main
model system prompt, is not written as a Conversation Message, and does not
affect EventBus routing.

## Message persistence

Addressed utterances are persisted in the current Conversation:

- Normal text or multimodal input becomes `role = user, kind = normal`.
- AIAgent built-in commands become `role = user, kind = command` and enter the
  Core command path.

Ambient utterances are persisted in the active ambient Conversation for the same
Agent and normalized IM scene:

- The observed message becomes `role = im_ambient, kind = normal`.
- When proactive intervention is selected, the runtime writes an additional
  `role = im_ambient, kind = introspection` Message.

`im_ambient normal` is durable transcript, but it is not normal provider
dialogue. It is read by later ambient reference recall, long-term memory
ingestion, and ambient intervention checks. It never directly triggers a visible
reply.

`im_ambient introspection` is an AIAgent-generated user-like trigger. It records
that the Agent should let the main model consider intervening in the current
scene because a batch of ambient messages appears relevant to the Agent's
mission. Core renders this Message through the normal user-like input path and
owns generation, tool use, ACL, Budget, visible delivery, and error handling.

Inbound Event-derived Messages must deduplicate by `target_session_entry_id`.
An `im_ambient introspection` Message is not directly derived from one
TargetSession side-channel entry, so it must use a deterministic ambient batch
idempotency key or equivalent metadata.

## Observe-only mode

`observe_only` is the minimal ambient policy:

1. Persist `bullx.im.message.ambient` as `role = im_ambient, kind = normal`.
2. Generate `metadata.brief` when the ambient brief rule applies.
3. Do not call the main model.
4. Do not call the ambient intent recognizer.
5. Do not write an assistant Message.
6. Do not send a visible reply to the observed scene.

This mode lets the Agent preserve context for later addressed turns without
turning ordinary group chatter into Agent speech.

## May-intervene mode

`may_intervene` persists `im_ambient normal` first, then runs a short-lived batch
recognizer. The batch exists to decide whether the Agent should intervene while
the scene is still fresh. It is not an eventually-consistent work queue.

Batch state uses Redis short-lived runtime state. The implementation must not
add a PostgreSQL ambient batch table, an Oban scheduled job, a Scheduler delayed
Event, or an EventBus re-entry path to guarantee stale batch processing.

Batching rules:

- The batch key is scoped to the active ambient Conversation session and must at
  least include `agent_principal_id`, `ambient_conversation_id`, and the
  normalized IM scene.
- A batch never crosses ambient Conversation sessions.
- A new ambient message after the previous session ended enters the new active
  ambient Conversation and uses a new batch key.
- The first ambient message in a batch sets `due_at = first_seen_at + 30s`.
- Ambient messages for the same active ambient Conversation session within that
  30 second window join the same batch.
- Later messages do not extend `due_at`; an active group must not keep the Agent
  from ever deciding whether to intervene.
- Batch creation captures one session-level `reply_channel` transport hint from
  the active ambient Conversation session. Later messages in the same batch do
  not participate in `reply_channel` selection and must not overwrite that hint.
- The recognizer uses `compression_model`. If `compression_model` is null, it
  uses `main_model`.
- The batch worker must apply a freshness guard. If processing starts after the
  short grace window, it discards the batch instead of running a late recognizer.

The ambient intent recognizer input includes:

- The current 30 second ambient batch.
- Ambient background from Ambient Reference Recall.
- Nearby addressed Conversation context, including recent
  `role = user, kind = normal` and `role = assistant` Messages from the related
  Conversation when available.
- The Agent profile `mission`.
- The non-empty `ambient_intent_system_prompt`, when present.

The recognizer output only decides whether to write `im_ambient introspection`.
V1 uses a structured boolean result, not a score threshold:

```json
{
  "intervene": true,
  "reason_summary": "The team is discussing an account risk that matches the Agent mission."
}
```

`intervene` is required. `reason_summary` is optional, short, and safe to store
in introspection metadata. Invalid recognizer output is treated as
`{"intervene": false}` with content-free diagnostic telemetry. The recognizer
does not send replies, execute tools, write assistant Messages, modify EventBus
state, or modify Channel Adapter state.

When the recognizer decides not to intervene, the batch ends. When it decides to
intervene, the runtime writes `role = im_ambient, kind = introspection` with
batch metadata:

- deterministic batch idempotency key;
- batch time range;
- ordered source Message ids or snippets;
- short trigger-reason summary;
- the session-level `reply_channel` hint captured when the batch was created.

After writing the introspection Message, the worker invokes the AIAgent Core
internal generation runner with runtime context `source = ambient_batch`, absent
TargetSession identifiers, and the captured `reply_channel` hint. Core still
owns generation lease, Conversation active-state checks, ACL, Budget, tool
policy, visible reply decisions, and outbound delivery.

If the ambient Conversation has no usable `reply_channel`, Core may persist an
internal result when its normal rules allow it, but it must not send a visible
reply to the observed scene.

### Redis batch state

Redis ambient batch state is weak runtime state. It serves near-real-time
intervention; it is not business truth, audit truth, or a recoverable work
queue. This is the same kind of engineering posture as TargetSession output
stream buffers: Redis improves live behavior, while committed business facts
remain in PostgreSQL.

The implementation reuses BullX's Redis runtime dependency and configuration. A
generic `BullX.Cache` facade does not expose sorted-set or atomic-script
semantics; the AIAgent runtime may add an AIAgent-owned Redis helper for this
batch state, but that helper is not a business storage layer.

Recommended Redis keys:

```text
ai_agent:ambient_batch:{agent_principal_id}:{ambient_conversation_id}:meta
ai_agent:ambient_batch:{agent_principal_id}:{ambient_conversation_id}:items
ai_agent:ambient_batches:due
```

`meta` stores batch id, Agent id, ambient Conversation id, IM scene key, first
seen time, due time, session-level reply-channel hint, and the short profile
snapshot version captured at batch creation. `items` stores normalized ambient
snippets for the 30 second window. `due` is a sorted set ordered by `due_at` so
the ambient batch worker can find ready batches.

Processing flow:

1. After persisting `im_ambient normal`, the runtime builds the ambient
   Conversation-session batch key and a normalized snippet.
2. If `meta` does not exist, a Redis atomic script creates `meta`, sets TTL,
   adds the batch key to `due`, and appends the snippet to `items`.
3. If `meta` already exists, the script only appends the snippet to `items` and
   refreshes the short TTL. It must not rewrite `due_at`.
4. The ambient batch worker polls `due` at a short interval for
   `due_at <= now`.
5. The worker takes a Redis processing lock to prevent two nodes from processing
   the same batch.
6. The worker reads `meta` and `items`. If either key is missing, Redis is
   unavailable, the batch is past the freshness guard, or the ambient
   Conversation has ended, the worker cleans residual keys and stops.
7. The worker calls the recognizer with Redis snippets, ambient reference
   recall, addressed Conversation context, `mission`, and
   `ambient_intent_system_prompt`.
8. If intervention is needed, the worker writes `im_ambient introspection` with
   the deterministic batch idempotency key.
9. The worker invokes Core generation with `source = ambient_batch`, absent
   TargetSession identifiers, and the captured Conversation-session
   `reply_channel` hint.
10. The worker cleans `meta`, `items`, the `due` entry, and the processing lock.

The TTL must be clearly longer than the 30 second window and freshness guard.
The default recommendation is 90 seconds. TTL is cleanup, not retry guarantee.

The default freshness guard is `due_at + 10s`. It is a runtime constant unless a
product need requires exposing it. It is not a business SLA.

Redis key loss, Redis flush, Redis outage, worker crash past the freshness
guard, or ambient Conversation closure may drop one proactive intervention
opportunity. Already persisted `im_ambient normal` Messages remain available for
later ambient reference recall when a human explicitly addresses the Agent.

The ambient batch worker is an AIAgent runtime component. It is not an EventBus
Target, does not create a TargetSession, and must not hold unreconstructible
long-term state. Restart behavior is limited to scanning Redis for batches that
still exist, are not past the freshness guard, and still belong to an active
ambient Conversation.

Daily reset does not manage Redis pending batches and does not keep an ambient
Conversation alive for a pending batch. If reset closes the ambient Conversation
before the batch is due, the worker drops the batch during the active-state
recheck. If the worker already wrote `im_ambient introspection` and entered Core
generation, subsequent races follow Core's generation lease and Conversation
active-state checks.

Because the batch worker does not invoke a TargetSession, proactive ambient
intervention uses final Channel Adapter outbound delivery only. It does not
create a TargetSession output stream and does not call TargetSession stream
helpers. Proactive streaming requires an explicit EventBus re-entry design.

## Ambient brief

When a single `role = im_ambient, kind = normal` text content exceeds 1000
characters, the AIAgent uses `compression_model` to generate a brief of at most
200 words and stores it on the same Message at `metadata.brief`.

Brief boundaries:

- The brief summarizes one ambient Message for reading and recall.
- It does not create another Message.
- It does not rewrite the original `content`.
- It is not a `kind = summary` Message.
- It is not conversation-context compression.
- Brief generation failure records safe diagnostics and falls back to the
  original `content`.

Ambient reference recall and the ambient intent recognizer render ambient
messages with `metadata.brief` first. They read `content` only when the brief is
missing or empty.

## Ambient Reference Recall

Ambient Reference Recall gives later Agent turns enough context for group-chat
references, omissions, and continuity. It is used when:

- Core renders a current `role = user, kind = normal` Message.
- Core renders `role = im_ambient, kind = introspection`.
- The ambient intent recognizer evaluates whether to intervene.

Recall scope:

- Read only Messages for the same `agent_principal_id`.
- Read only `role = im_ambient, kind = normal` Messages for the same normalized
  IM scene.
- May cross `conversation_id`.
- Must not cross Agent.
- Must not infer scene identity from raw provider payload.

Recall algorithm:

1. For the Message currently being rendered, find the previous
   `role = assistant` Message on the current branch when one exists.
2. If there is a previous assistant Message, select the most recent 10
   `role = im_ambient, kind = normal` Messages for the same Agent and IM scene
   between that assistant Message and the current Message.
3. If there is no previous assistant Message, select the most recent 10 ambient
   Messages for the same Agent and IM scene before the current Message.
4. If the previous selection has results, take its earliest Message timestamp,
   look back one hour, and select all ambient Messages for the same Agent and IM
   scene in that one-hour window.
5. Return the union of the recent-10 set and the one-hour window set in
   chronological order.

The return value is a message meta context source, not normal Conversation
history. Core must render it as clearly labeled background context so the model
does not mistake observed group speech for the current user directly addressing
the Agent.

## Message meta context boundary

This design owns only the source and recall rules for ambient context. Provider
input rendering belongs to Core's `BullX.AIAgents.MessageContextBuilder`.

Ambient context handed to the builder includes:

- source kind `ambient_reference_context`;
- normalized IM scene identifier;
- ordered ambient snippets;
- per-snippet safe sender display name, `sent_at`, brief-first content, and
  source Message id.

The builder decides how to render these snippets as leading context blocks for
the current user-like Message. AIAgent ambient handling must not bypass the
builder by concatenating prompt text directly, and ambient context must not enter
the System Prompt Builder stable prefix.

## Visible reply boundary

`role = im_ambient, kind = normal` never directly triggers visible reply. It is
only an observation record.

Only `unmentioned_group_messages = "may_intervene"` can create
`role = im_ambient, kind = introspection`, and only that Message can enter the
proactive intervention path. Even then, a visible reply requires all normal Core
conditions:

- generation produces assistant output;
- ACL and Budget allow the action;
- a usable `reply_channel` exists;
- Channel Adapter outbound delivery or the relevant stream boundary completes
  according to its own contract.

TargetSession completion does not mean a group-chat reply was delivered.
Adapter delivery result remains a transport-boundary result.

## Failure behavior

- Unsupported Event type: record allowlisted safety telemetry and return success.
  Do not write a user Message, call a model, create Work, or send a reply.
- Ambient Message persistence failure: return a retryable persistence error so
  the TargetSession can retry according to normal infrastructure behavior.
- Brief generation failure: keep the original `im_ambient normal` Message, record
  safe diagnostics, and continue.
- Redis batch state missing, Redis unavailable, batch past freshness guard, or
  ambient Conversation ended: drop this proactive intervention opportunity,
  record allowlisted telemetry, and keep the already persisted ambient Messages.
- Batch recognizer failure: record safe diagnostics, do not write
  `im_ambient introspection`, and do not retry an expired batch.
- Invalid recognizer output: treat as no intervention and record safe
  diagnostics.
- Main model or visible delivery failure after proactive intervention: Core owns
  the normal generation, streaming, persistence, and delivery failure path.

Logs and telemetry must not include raw provider payloads, full CloudEvents,
credentials, private AuthZ internals, or unredacted message content.

## Implementation

Goal: implement AIAgent ambient and unsupported Event handling so addressed IM
Events enter the normal user turn, ambient IM Events are observed or considered
for proactive intervention according to the Agent profile, and other routed
Event types are safely ignored without being disguised as user input.

Context pointers:

- `docs/design-docs/ai-agent/Core.md`
- `docs/design-docs/ai-agent/SystemPromptBuilder.md`
- `docs/design-docs/ai-agent/ContextCompressionAndCaching.md`
- `docs/design-docs/eventbus/ChannelAdapter.md`
- `docs/design-docs/eventbus/Core.md`
- `docs/design-docs/eventbus/Persistence.md`
- `docs/design-docs/eventbus/StreamingOutput.md`
- `docs/design-docs/Cache.md`
- `docs/design-docs/Principal.md`

Constraints:

- Keep ambient policy inside AIAgent runtime. Do not move it into EventBus,
  TargetSession, or Channel Adapter.
- Channel Adapter only normalizes IM inputs into
  `bullx.im.message.addressed` or `bullx.im.message.ambient` Events.
- Do not implement business semantics for unsupported world Events in this
  design.
- Do not render `im_ambient normal` as ordinary provider dialogue.
- Do not let `im_ambient normal` trigger visible reply.
- Do not put ambient context into the System Prompt Builder stable prefix.
- Do not create PostgreSQL batch tables, Oban scheduled jobs, Scheduler delayed
  Events, or EventBus re-entry paths for stale ambient batches.
- Do not create TargetSession output streams from the Redis ambient batch worker.
- Do not change EventBus or TargetSession supervision boundaries for this
  policy.

Implementation steps:

1. Extend AIAgent profile casting and validation.
   - Owns: `unmentioned_group_messages` and `ambient_intent_system_prompt`.
   - Acceptance: `unmentioned_group_messages` defaults to `observe_only` and
     accepts only `observe_only` or `may_intervene`; `ambient_intent_system_prompt`
     defaults to `""` and is used only by the ambient intent recognizer.

2. Implement Event type branching.
   - Owns: `bullx.im.message.addressed`, `bullx.im.message.ambient`, and the
     unsupported Event path.
   - Acceptance: addressed IM Events enter the normal user turn; unsupported
     Events emit safe telemetry and return success without model calls.

3. Implement `im_ambient normal` persistence and brief generation.
   - Owns: ambient Message persistence, `target_session_entry_id` dedupe,
     `metadata.brief`, and failure fallback.
   - Acceptance: ambient text over 1000 characters gets a 200-word-or-shorter
     brief when the model succeeds; brief failure does not lose the original
     Message.

4. Implement `observe_only`.
   - Owns: the ambient short path.
   - Acceptance: writes only `im_ambient normal`; does not call the main model,
     recognizer, or visible delivery.

5. Implement `may_intervene` batch recognition.
   - Owns: Redis-backed 30 second batch state, due worker, freshness guard,
     recognizer input, boolean structured output validation, introspection
     idempotency, and Core generation handoff.
   - Acceptance: same-session ambient messages are batched without extending
     `due_at`; recognizer uses `compression_model` or falls back to `main_model`;
     invalid recognizer output is treated as no intervention; batch creation
     captures a single session-level `reply_channel` hint; Redis loss or stale
     processing drops only the proactive opportunity.

6. Implement Ambient Reference Recall.
   - Owns: same Agent / same IM scene queries, cross-Conversation read,
     brief-first rendering, and deterministic ordering.
   - Acceptance: recall can cross `conversation_id`, never crosses Agent or IM
     scene, and prefers `metadata.brief`.

7. Integrate Core prompt rendering.
   - Owns: passing ambient recall results to
     `BullX.AIAgents.MessageContextBuilder`.
   - Acceptance: `role = user, kind = normal` and
     `role = im_ambient, kind = introspection` receive clearly labeled ambient
     background without reimplementing recall inside Core.

8. Enforce the visible reply boundary.
   - Owns: proactive intervention reply gating.
   - Acceptance: `im_ambient normal` cannot public-reply; `im_ambient
     introspection` still passes through Core ACL, Budget, `reply_channel`, and
     Channel Adapter final outbound delivery; the Redis worker does not create a
     TargetSession output stream.

Stop and ask if implementation needs:

- EventBus fan-out of one ambient Event to multiple Targets.
- Channel Adapter access to AIAgent profile fields to decide whether to
  intervene.
- AIAgent inference from raw provider payload for mentions, group scope, or IM
  scene identity.
- Unsupported world Events to trigger business processing, Work creation, Brain
  ingestion, or model calls.
- Ambient context in the System Prompt Builder stable prefix.
- Copying the same ambient Event or Message into multiple per-actor
  Conversations.
- Daily reset to scan, renew, or wait for Redis pending batches.
- A PostgreSQL table, Oban scheduled job, Scheduler delayed Event, or EventBus
  re-entry path for 30 second ambient batches.
- Redis-loss recovery that reruns missed proactive intervention checks.
- `im_ambient normal` to directly trigger visible reply.

Done when:

- `bullx.im.message.addressed` enters the normal user turn, and DM versus group
  mention differences do not create separate AIAgent runtimes.
- `bullx.im.message.ambient` in `observe_only` writes only
  `role = im_ambient, kind = normal`.
- `bullx.im.message.ambient` in `may_intervene` uses a Redis-backed 30 second
  active ambient Conversation-session batch to decide whether to write
  `role = im_ambient, kind = introspection`.
- Redis ambient batch state is weak runtime state; loss, expiry, or ambient
  Conversation closure drops only one proactive opportunity and never replays
  stale intervention.
- The ambient intent recognizer uses `compression_model`, with fallback to
  `main_model`, and receives `mission`, `ambient_intent_system_prompt`, ambient
  recall, and addressed Conversation context.
- Long ambient text stores a brief on `metadata.brief`, not as a summary Message.
- Ambient Reference Recall can cross `conversation_id` but not Agent or IM scene,
  and prefers `metadata.brief`.
- Ambient context reaches provider input only through Core's message meta context
  builder.
- Unsupported Event types log safe telemetry, call no model, and do not become
  user Messages.
- `im_ambient normal` never public-replies; `im_ambient introspection` can enter
  proactive intervention only through normal Core reply controls.
- Before implementing this design in the main repo, `bun precommit` passes.
