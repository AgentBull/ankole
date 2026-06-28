# Feishu / Lark Adapter

The Feishu / Lark plugin connects a Feishu or international Lark self-built app
to Ankole. It has two separate jobs:

- chat ingress and provider-visible output through SignalsGateway;
- optional login and contact-directory sync through Principals.

Those two jobs may use the same app credentials, but they are not one shared
provider configuration. Chat setup and identity-provider setup are separate
save boundaries. Sharing credentials is a convenience, not a storage object.

The adapter is a trusted first-party Elixir plugin. It does not run inside an
agent computer. The agent computer only starts after SignalsGateway has accepted
an input into PostgreSQL and the control plane wakes the session actor.

## Names

The stable external names are:

- plugin package id: `lark-adapter`;
- SignalsGateway adapter id: `lark`;
- identity-provider adapter id: `lark`;
- default chat binding name: `lark`;
- default platform-subject provider namespace: `lark-main`;
- display name: `Lark / Feishu`.

Ankole should keep those external names unless there is an explicit migration
story. `feishu` can appear as the domain value for China Feishu, but it should
not silently replace the adapter id or platform namespace.

This document describes only the Ankole plugin contract. Provider setup,
gateway routing, actor mailbox, provider mirror, and identity storage remain
owned by their Ankole subsystems.

## Plugin Declaration

The plugin declaration should expose:

- plugin id `lark-adapter`;
- a SignalsGateway adapter declaration with id `lark`;
- a Principals identity-provider adapter declaration with id `lark`;
- setup field metadata for chat binding config and identity-provider config;
- schema and field metadata for encrypted config values; the persistence key is
  owned by the setup path, SignalsGateway, or Principals rather than by a shared
  provider object;
- supervised children needed for the shared long-connection runtime.

The adapter declarations are references to host-owned contracts. The plugin does
not own `signal_bindings`, `signal_channels`, `signal_entries`,
`actor_mailbox`, `signal_gateway_outbox`, Principal rows, or AuthZ grants.

The supervised runtime may keep a connection registry keyed by `domain + appId`.
That registry is process state and should be rebuildable from active
configuration after restart.

The Elixir implementation should use `libs/feishu_openapi` as the provider
library. That means the plugin owns the Feishu/Lark-specific normalization:
event envelope routing, message shape parsing, sender id extraction, structured
mention detection, resource descriptors, card-action payload mapping, and
provider error classification.

`FeishuOpenAPI.WS.Client` supplies the long-lived WebSocket transport,
fragment reassembly, ping/reconnect handling, trusted decoded event dispatch,
and `event` / `card` frame routing. `FeishuOpenAPI.Event.Dispatcher` supplies
handler registration by official event type. `FeishuOpenAPI.CardAction` supplies
HTTP card-callback verification if the product later exposes such a callback
surface. The Ankole adapter must still turn those decoded provider payloads into
the same SignalsGateway `IngressFact` inputs described below by calling the
concrete `emit_*` adapter-facing APIs. It must not construct `ActorInput`
directly.

## User Stories

An operator connects one agent binding to one Feishu/Lark self-built app. The
operator provides app credentials, chooses Feishu or Lark domain, chooses how
unaddressed group messages behave, and decides whether the adapter should use
streaming cards for assistant output.

A human sends the agent a DM or a structured group mention. The adapter
normalizes the provider message into a SignalsGateway entry receive fact.
SignalsGateway mirrors the visible message, appends `im.message.addressed`, and
the actor later replies only through explicit `signal_gateway_outbox` rows.

A group has normal conversation near the agent. The binding policy decides
whether those unaddressed messages are ignored, mirrored only, or delivered as
`im.message.may_intervene`. The adapter only reports whether the provider gave
a real structured mention; it does not decide the final actor-delivery policy.

One Feishu/Lark group contains several bot accounts, and each bot account is
connected to a different agent binding. Each bot account is a different
Feishu/Lark app id, so the runtime must keep one long connection for each app.
The same human message may therefore arrive once per bot account. Actor input
delivery remains per accepting binding. The provider mirror shares storage only
when the provider exposes the same normalized channel id and message id under
those app views; if the ids differ, Ankole stores separate mirror entries rather
than guessing that they are the same physical message.

A human clicks a button in a Feishu/Lark card. The adapter emits an action fact
through `emit_action`. It is an explicit user action, not a fake text message.
The default ActorInput type is `signal.action.invoked` unless the source maps it
to a narrower code-defined type.

A user recalls a message. The adapter emits a removal fact with provider
lifecycle kind `recalled`. SignalsGateway
deletes the mirrored entry, refreshes the tombstone, removes pending actor input
when possible, and writes lifecycle input only if the original input already
reached actor state. That lifecycle input becomes a runtime note for later LLM
context. The worker renders that note inside the current/latest user message
`<agent_environment_info>` block, not as a system-prompt extension. It does not
rewrite historical transcript rows. The adapter must not infer that prior
assistant output should also be removed.

An admin also enables Lark login and directory sync. That uses the
identity-provider adapter and Principals. It converges on the same
`platform_subject` identities that chat ingress observes, but it does not own
SignalsGateway routing or outbox state.

A browser user signs in with Feishu/Lark OIDC. The login flow proves the external
user and upserts the same platform subject used by chat and directory sync. It
does not grant console access by itself. Normal login still requires AuthZ to
find an active human admin, while first-run setup uses the same authenticated
human as the candidate for root initialization.

## Setup Fields

The chat adapter config uses this shape:

- `appId`: required Feishu/Lark app id;
- `appSecret`: required secret, stored encrypted by AppConfigure;
- `domain`: `feishu` or `lark`, default `feishu`;
- `group_message_mode`: setup value, default `observe_all`;
- `platformSubjectNamespace`: default `lark-main`;
- `userName`: display name for adapter-authored output, not an identity key;
- `streamingEnabled`: default `true`;
- `streamUpdateIntervalMs`: default `800`;
- `streamBufferThreshold`: default `24`.

The setup UI may present these group-message labels:

| Setup value | SignalsGateway binding policy | Meaning |
| --- | --- | --- |
| `addressed_only` | `ignore` | DMs and structured mentions are accepted; unaddressed group messages are dropped. |
| `observe_all` | `record_only` | Unaddressed group messages update the provider mirror but do not wake the agent. |
| `may_intervene` | `may_intervene` | Unaddressed group messages update the mirror and append `im.message.may_intervene`. |

The generic `signal_bindings` default can remain conservative, but Feishu/Lark
setup should write `record_only` when the setup value is `observe_all`.

The identity-provider adapter config is separate:

- `appId`;
- `appSecret`;
- `domain`;
- `oidc.enabled`, default `true`;
- `oidc.scopes`, default `["contact:user.employee_id:readonly"]`;
- `sync.users`, default `true`;
- `sync.departments`, default `true`;
- `sync.websocket`, default `true`;
- `sync.pageSize`, default `50`, valid range `1..50`.

Production OIDC needs a public base URL so Feishu/Lark can redirect back to the
installation. If OIDC is disabled, login callbacks for that provider fail
closed.

Ankole setup does not create external provider apps. The operator creates the
Feishu/Lark self-built app in the provider console, subscribes the required
official events, and enters the resulting credentials in Ankole setup. Setup may
validate credentials, but it should not create or register the external app for
the operator.

## Runtime Connection

Feishu/Lark long-connection delivery is cluster-style: multiple live consumers
for the same `domain + appId` can split events unpredictably. The plugin must
therefore keep exactly one live long-connection consumer for each
`domain + appId` inside the installation.

Different `domain + appId` keys are independent bot accounts and require
independent long-connection clients. If three agents are connected to three
different Feishu/Lark bot accounts in the same group, Ankole should run three
provider clients, not one collapsed client. If the same app id is accidentally
opened twice, the provider may deliver some events to one client and some events
to the other; from the user's point of view, messages appear to disappear from
one runtime path.

The OTP-native runtime shape is one supervised connection owner per
`domain + appId`:

- the plugin starts a local unique `Registry` for connection owners;
- the plugin starts a `DynamicSupervisor` for per-app connection owners;
- the connection key is the normalized tuple `{domain, appId}`; `appSecret` is
  validated against that key but is not part of the process identity;
- each connection owner is named through the registry with that key;
- each connection owner starts exactly one `FeishuOpenAPI.WS.Client` with the
  dispatcher built for that key;
- different keys are different children under the same dynamic supervisor, so
  one app reconnecting or failing does not take down another app.

Concrete module names can stay implementation-local, but the shape should be
equivalent to `ConnectionRegistry`, `ConnectionSupervisor`, and a per-key
`ConnectionOwner`.

Startup and reuse should be idempotent. The caller first looks up the
connection owner in the registry. If it is absent, it calls
`DynamicSupervisor.start_child/2` with the per-key child spec. If two callers
race, the registry-backed name makes one start win and the other receive the
already-started pid; both outcomes mean "use this existing connection".

The registry is a local process registry, not durable state. It is the runtime
way to prevent two local owners for the same `domain + appId`. The durable truth
is still the active chat binding and identity-provider configuration read from
the host. On restart, the plugin reconciles those configurations and starts one
owner for each distinct key that is still needed.

The per-key connection owner builds an immutable
`FeishuOpenAPI.Event.Dispatcher` from all active consumers for that key: chat
receive/recall/reaction/card handlers when chat ingress is enabled, and contact
handlers when identity realtime sync is enabled. If a later setup change adds or
removes a consumer for the same key, plugin runtime reconciliation restarts that
one connection owner with a newly built dispatcher rather than trying to mutate
the dispatcher inside a running `FeishuOpenAPI.WS.Client`.

Fatal provider configuration errors should stop only the per-key owner and mark
the affected runtime unavailable. Nonfatal transport loss is handled by
`FeishuOpenAPI.WS.Client` reconnect. The supervised child should avoid a tight
restart loop on fatal credential or permission errors. One practical shape is to
wrap the WebSocket child spec with transient restart semantics for fatal
shutdowns while letting unexpected crashes restart normally.

Chat ingress and identity realtime sync share the same connection owner when
they use the same `domain + appId`. If the same key is
configured with different `appSecret` values, startup fails for that runtime
path because Ankole cannot know which secret is correct.

The connection registry is process state, but the guarantee is installation
level. A future multi-node deployment needs a lease or ownership rule so only
one node owns a given `domain + appId` long connection at a time.

Startup order matters for a shared app. Chat consumers should be included before
identity realtime sync opens or reuses the connection owner. Identity consumers
should be included before contact full sync starts, so new contact increments
can be observed while startup reconciliation handles older facts.

The adapter should start `FeishuOpenAPI.WS.Client` with a dispatcher that
registers all official event types the plugin claims to support. WebSocket
frames are trusted decoded payloads: webhook verification token and encrypt-key
checks do not apply to those frames. HTTP webhook or HTTP card callback surfaces,
if enabled later, must verify signatures before mutating the raw request body.

The host, not `FeishuOpenAPI`, owns admission policy, durable idempotency,
tombstones, micro-batching, actor mailbox, and outbox. Transport reconnection,
fragment reassembly, and provider request retries are library concerns; they
must not become Ankole's durable queue.

The provider app must be configured so both mentioned and unmentioned group
messages reach the long connection when the product wants `record_only` or
`may_intervene`. The adapter cannot apply group-message policy to events the
provider never sends.

Raw decoded provider events should be retained in mirror metadata or raw
payload references when available, without changing the actor-facing event
model. Those raw fields must already be JSON-serializable durable values. Do not
store `FeishuOpenAPI` structs, processes, functions, references, tuples, or
host-only temporary state in provider mirror, mailbox, or outbox payloads.

If the dispatcher cannot register the official receive, recall, reaction, card,
or contact handlers required by the configured capabilities, startup should
fail for that adapter runtime instead of silently running without those facts.

The chat adapter is a WebSocket/long-connection adapter. A generic HTTP webhook
handler for the chat surface should reject normal delivery, because the runtime
path is the long connection.

For the optional HTTP card callback surface, provider ack should happen only
after signature verification and durable gateway acceptance, unless a future
implementation first writes a durable staging record. Malformed callback payloads
must fail before ack; they must not be acknowledged and then silently dropped.

## Provider Identity

For human and bot attribution, the chat adapter records a platform subject
before accepting an inbound message, action, or reaction.

The canonical platform subject id is Feishu/Lark `user_id` when available. The
adapter records it under `provider = platformSubjectNamespace`, usually
`lark-main`.

`open_id`, `union_id`, `tenant_key`, app id, sender type, and source are
metadata. They help later debugging and merging, but they should not split a
person into another Principal when `user_id` exists.

Bot senders are special. If Feishu/Lark reports a bot sender without `user_id`,
the adapter uses a typed subject id `bot:<open_id>`. Non-bot senders without
a usable `user_id` fail closed instead of falling back to `open_id`.

Card actions and reactions use the operator `userId`. If the operator id is
missing, the adapter logs and ignores that action or reaction rather than
creating an unactionable actor identity.

Message author fields such as `isBot` and `isMe` are preserved as metadata for
the actor and mirror. Identity normalization by itself does not silently drop a
message just because the sender is bot-like.

Identity-provider sync writes the same kind of platform subject facts for
directory users. It maps Feishu/Lark `user_id` to the provider external id,
prefers `enterprise_email` over `email`, normalizes phone only when the provider
already supplies a valid external phone format, records department ids, and
keeps `open_id`, `union_id`, `tenant_key`, employee number, and job title in
metadata.

Contact full sync must not treat a provider permission gap as an authoritative
empty directory. Empty pages, missing scope, forbidden responses, or known Lark
field-validation failures are skipped with a warning or full-sync request,
depending on the path.

## Channel And Thread Identity

The adapter-normalized channel id shape is:

```text
lark:<encoded_chat_id>
```

The adapter-normalized provider thread id shape is:

```text
lark:<encoded_chat_id>:<encoded_root_id>
```

SignalsGateway stores the channel id as `signal_channel_id` and the thread id
as `provider_thread_id`. The default actor session is channel-level, not
thread-level. Thread id participates in provider reply anchoring and
micro-batch scope; it does not create a separate session actor by itself.

For a normal message, `root_id` is the provider root id when present; otherwise
the adapter uses the message id. For a DM opened by user id, the thread id is
`lark:<user_id>:` and the adapter treats it as a DM.

The signal channel should represent the physical Feishu/Lark chat when the
provider exposes stable chat ids. The adapter may include domain or tenant data
inside the normalized id if real provider evidence shows raw ids can collide
across realms. It should include app id only when the provider ids are actually
app-scoped.

Channel information lookup is best-effort. The adapter may cache chat names and
DM/group flags, but ingress should continue with the stable chat id when the
provider lookup fails.

## Inbound Events

The chat adapter accepts these provider event families through
`FeishuOpenAPI.Event.Dispatcher`:

- message receive, `im.message.receive_v1`;
- message recall, `im.message.recalled_v1`;
- reaction created, `im.message.reaction.created_v1`;
- reaction deleted, `im.message.reaction.deleted_v1`;
- card action, through a long-connection `card` frame routed as
  `card.action.trigger`, or through the optional HTTP card callback verifier
  when that surface is explicitly enabled;
- contact user and department changes for the identity-provider adapter:
  `contact.user.created_v3`, `contact.user.updated_v3`,
  `contact.user.deleted_v3`, `contact.department.created_v3`,
  `contact.department.updated_v3`, `contact.department.deleted_v3`, and
  `contact.scope.updated_v3`.

The adapter declares inbound capabilities for:

- `entry_receive`;
- `entry_removed`;
- `reaction_add`;
- `reaction_remove`;
- `action_event`.

Message receive normalizes:

- `ingress_event_id` from Feishu/Lark websocket `event_id`;
- `provider_entry_id` from Feishu/Lark message id;
- `signal_channel_id` from chat id;
- `provider_thread_id` from chat id plus root id;
- channel kind, normally `im_dm` or `im_group`;
- `reply_mode = entry` for IM chats that support anchored reply;
- text and a simple markdown-formatted representation;
- author id/name/bot/self flags;
- structured mention flag from the provider, not from plain text;
- provider send time;
- attachments, links, mentions, metadata, and raw payload reference.

DMs are explicit input. Group messages are explicit only when the provider gives
a structured mention, reply-to-bot, slash/app invocation, or another
adapter-owned signal that the binding treats as directed to the agent. Plain
text containing an `@` character is not enough.

Visible slash-command handling has two layers. The adapter owns
provider-specific text extraction: it must preserve the visible text, structured
mentions, and any exact visible mention prefixes needed to remove the bot name
without treating a plain `@` as a real mention. The command grammar itself is
code-defined by SignalsGateway or a shared parser, not by Feishu/Lark config and
not by database rows.

Recognized visible commands are classified after explicit IM admission:

- `/new`
- `/compress`
- `/retry`
- `/steer`
- `/stop`

`/compress` is a visible command event. It produces
`ActorInput(type = command.compress)`. The control plane does not generate the
summary; when the command reaches the worker, the worker uses the `light` model
profile, reads history through RuntimeFabric RPC, summarizes the older prefix
while keeping the recent tail verbatim, and commits the summary through
`conversation.summary.commit`.

For mentioned commands, the adapter or shared parser strips only a provider
confirmed structured mention prefix before matching. Full-width spaces and
full-width digits normalize before matching. A full-width slash remains normal
text. Multi-line command arguments are allowed. `/undo` is not a command.

`/steer` is a command event like `/new`, `/compress`, `/retry`, and `/stop`.
It produces `ActorInput(type = command.steer)`. The actor may consume that
event through the same addressed-message path used for `im.message.addressed`,
but the event is not first rewritten into an ordinary visible message.

Unsupported or empty message bodies should not be converted into prompt-visible
fallback text. If an inbound provider payload cannot produce a usable message
fact, the adapter logs and rejects or ignores it according to the provider path.

Inbound edit events are not part of the Feishu/Lark adapter contract. The
current model only implements official events the adapter subscribes to. Do not
add an `updated` event path until Feishu/Lark exposes it in the actual app
event-subscription surface and the adapter can test it.

## Attachments

Inbound Lark resources become attachment descriptors first. Supported resource
types are image, file, audio, and video. Unsupported resource types are ignored.

The adapter records durable provider download metadata:

- provider `lark`;
- source message id;
- file key;
- download type, `image` or `file`;
- original resource type;
- optional file name;
- optional cover image key;
- optional duration.

Before SignalsGateway mirrors the entry or writes actor mailbox, attachments
must be materialized into durable references or file paths visible to the agent
computer. Live adapter closures, FeishuOpenAPI client structs, and host-only
temp paths must not enter the provider mirror or actor mailbox.

SignalsGateway validates durable JSON with Ankole's own JSON adapter through
the strict `JsonPayload` path. The sanitizer is only for `last_error`, logging,
and short error previews. It must not be used to "fix" attachment descriptors or
other mirror/mailbox/outbox payloads.

The adapter also supports a user-facing backfill path for common Feishu/Lark
usage: a user first sends a file or image, then mentions the agent in a later
text message such as "看上面的文件" or "please read the previous file". When the
message is a structured group mention, has no direct resources, and its text
matches the recent-attachment intent, the adapter looks back about two minutes
in the same chat, finds a previous same-sender message, and attaches up to three
usable resources from that earlier message. If lookup fails, ingress continues
without backfilled attachments.

## Actions And Reactions

Card action handling:

- verifies and decodes HTTP callback bodies with `FeishuOpenAPI.CardAction`
  when the action arrives through an HTTP callback surface;
- treats long-connection `card` frames as trusted decoded frames from
  `FeishuOpenAPI.WS.Client`;
- resolves the source card message and root id from `open_message_id`,
  message lookup, or the closest provider message id available;
- records the operator as a platform subject using `user_id` / `userId`;
- emits `emit_action` with action id, action value, message id, thread id, user,
  and raw event.

The action value may be a string or JSON-encoded provider value. The adapter
should normalize it into a JSON-compatible value or preserve it as a string. It
should not rewrite it into ordinary message text.

Reaction handling:

- resolves chat/root information for the target message when the provider event
  omits chat id;
- records the operator as a platform subject using `userId`;
- maps Feishu/Lark emoji types to normalized names when known;
- emits `emit_reaction` with added/removed state, target entry id, operator key,
  normalized emoji, raw emoji key, and raw event.

Reactions update only the provider mirror. They do not append ActorInput.

Known Feishu/Lark emoji keys should map to stable normalized names for common
cases such as thumbs up, thumbs down, heart, smile, laugh, clap, fire, eyes,
OK, check, cross, question, and exclamation. Unknown emoji keys should round
trip as raw provider keys rather than being dropped.

## Recall

Recall uses the official Feishu/Lark recall event. The adapter extracts message
id, chat id, root id when present, recall time, and raw payload.

The Feishu/Lark app must subscribe to the recall event in the provider console.
If the app is not subscribed, Ankole cannot observe the recall and must not
pretend it has a latest-state guarantee for that lifecycle fact.

The normalized recall fact uses:

- `provider_entry_id = message_id`;
- `signal_channel_id = lark:<chat_id>`;
- `provider_thread_id = lark:<chat_id>:<root_id or message_id>`;
- lifecycle kind `removed`, with provider lifecycle kind `recalled`;
- provider time from recall, update, or create time when available.

That provider time is mirror/lifecycle ordering data. It is not prompt
`send_at`; worker prompt time is derived from `ai_agent_messages.inserted_at`
through `conversation.history.resolve`.

The adapter submits the fact through `emit_entry_removed`. It does not create
the tombstone or lifecycle ActorInput itself.

SignalsGateway hard-deletes the mirrored entry because `signal_entries` is the
current provider-visible mirror, not actor transcript history. The tombstone
prevents a late receive from recreating the entry.

Feishu/Lark recall is not the same as agent-output recall. The actor may later
commit an explicit outbox delete, but the adapter and gateway must not infer it.

## Outbound

The Feishu/Lark module adapter should implement
`Ankole.SignalsGateway.OutboxAdapter` for provider-visible output. Real modules
implement `capabilities/0` and `send/1`; `reconcile/1` is optional and is used
only for recovery of a durable `sending` outbox row. Test map adapters do not
need to implement the behaviour.

The SignalsGateway outbox capability allowlist for this adapter is:

- `post_entry`;
- `reply_entry`;
- `edit_entry`;
- `delete_entry`;
- `outbound_reconciliation`;
- `add_reaction`;
- `remove_reaction`;
- `divider`;
- `card`.

`outbound_idempotency` and `streaming` are not capability names. Idempotency is
the `signal_gateway_outbox.idempotency_key` row value that the adapter passes to
Feishu/Lark when the provider API supports it. Streaming is controlled by
`streamingEnabled` and the card-output implementation, while the provider-visible
surface is still the `card` outbox operation.

`send/1` and `reconcile/1` must return only `{:ok, map}`, `{:error, reason}`, or
`:unknown`. Other return values are adapter bugs and are normalized into
adapter errors. The success map may include values such as `provider_entry_id`,
`raw_payload`, `provider_time`, or `recovery_state`, but any durable map field
must already be JSON-serializable.

Text output posts to the chat with `receive_id_type = chat_id`. Reply output
uses Feishu/Lark message reply when the outbox provides a target entry or the
thread root id is usable. Outbox idempotency keys are passed through as provider
UUIDs when the Feishu/Lark API supports them.

Regular text and card replies should stay in the normal chat surface. They
should not request provider thread-only delivery. Streaming-card replies may
pass `reply_in_thread: false` when the provider API requires the flag to avoid a
thread-only surface.

If a reply target was recalled or no longer exists, and the provider returns the
known "message withdrawn / message does not exist" errors, the adapter falls
back to a normal chat-level post. This keeps the agent's answer visible while
losing only the quoted reply anchor. Other provider errors are not swallowed.

Card output has two valid payload families:

- portable interactive output rendered into Feishu/Lark Card JSON 2.0;
- provider-native Lark card payloads.

Every card payload must carry fallback visible text for mirror/search and
unsupported surfaces. Card edits use the provider card patch API when editing a
card; text edits use message update.

Portable interactive cards render:

- `schema = "2.0"` and `config.update_multi = true`;
- optional title as a plain-text card header;
- main content as plain text or Lark markdown;
- optional fact rows as bold labels plus values;
- markdown fact labels and values with `*`, `_`, backtick, and bracket escaping;
- optional choice responses as direct button elements in `body.elements`, not
  wrapped in a provider action container;
- optional custom-text hint above choices;
- answered/expired/cancelled/superseded state as grey status text;
- selected choices with visible selected text;
- locked choices as disabled buttons once the interaction is no longer open.

Choice button callback values keep the interaction version, interaction id,
control id, selected option id, and provider-safe option value. The adapter does
not collapse those values into display text.

The portable action value version is
`ankole.interactive_output.action.v1`. The card button name is the control id.
The callback value must be the structured action object, not a localized label.
An answered card renders every choice disabled, and the chosen option's visible
text appends `(selected)`. State text should match Bun behavior:
`Answered: <response>`, `Expired`, `Cancelled`, or `Superseded`.

Provider-native card payloads pass through their `card` JSON unchanged except
for strict JSON durability validation. They still need row-level
`fallback_visible_text`; mirror/search and unsupported surfaces use that
fallback, not a best-effort card stringify.

When posting a card, the adapter sends `msg_type = "interactive"` with either
the rendered card JSON or a CardKit card reference. Normal card replies must not
set provider thread-only delivery. If the reply target is gone, the adapter
falls back to a chat-level card post only for the known withdrawn/not-found
provider errors.

Divider output uses Feishu system messages with a provider-native divider
payload. Divider text is trimmed and capped to Feishu's compact system-message
width; when truncation happens, the adapter logs a warning and stores the
shortened provider-visible text.

File output uploads each file, then sends file messages. If the outbox payload
also contains leading markdown text, the adapter sends that text before the file
parts. Per-part idempotency suffixes keep the text and each file distinct.
Provider file type is inferred from filename or MIME type, falling back to
`stream`.

File type inference should map PDF, Word, Excel, PowerPoint, MP4, and OPUS to
the corresponding Feishu file types. Unknown files use `stream`.

Delete output recalls the target provider message. Reaction output maps
normalized emoji names back to Feishu/Lark emoji types.

Outbound reconciliation uses provider message lookup. It returns whether the
message exists, whether it is deleted, the provider message id, the recovered
thread id when available, and raw provider response. SignalsGateway uses this
only for outbox recovery; it does not make reconciliation a second mirror write
path before provider success is confirmed.

## Streaming Cards

When streaming is enabled, the adapter may stream an assistant answer through a
Feishu/Lark CardKit card. With `FeishuOpenAPI`, this is a REST flow:

1. `POST cardkit/v1/cards` with `type = "card_json"` and the initial card JSON;
2. send or reply an `im/v1/messages` interactive message whose content is
   `{type: "card", data: {card_id}}`;
3. update the status element with `PATCH cardkit/v1/cards/:card_id/elements/:id`;
4. update cumulative answer text with
   `PUT cardkit/v1/cards/:card_id/elements/:id/content` when the new text is a
   suffix of the last confirmed text;
5. replace the markdown element with `PATCH .../elements/:id` when the final
   text is not a suffix of the preview;
6. close streaming mode on finish with
   `PATCH cardkit/v1/cards/:card_id/settings`.

The initial status text is `思考中…` in the provider card. If a trace URL is
present, the card includes a `查看推理` button that opens the sealed trace link.
That button is a direct Card JSON 2.0 button element with `open_url` behavior,
not an action-wrapper element.

The card send prefers a reply anchored to the trigger message when possible. If
the trigger was recalled, it falls back to a chat-level card post just like
normal replies. Streaming replies pass `reply_in_thread: false` so the answer
stays in the normal chat surface.

Streaming updates are best-effort progress, not final output truth. The adapter
throttles updates by interval, accumulated new characters, and natural text
boundaries. It keeps sequence numbers strictly increasing across element and
settings writes. It merges overlapping text deltas into cumulative text, so a
late suffix update does not duplicate already shown content.

The provider can briefly reject a newly created `card_id` as not visible yet.
The adapter retries only that known invalid-card-id race, using the same retry
budget as Bun: 250ms, 750ms, 1500ms, 3000ms, and 5000ms. Other provider errors
are not hidden behind that retry rule.

Provider write failures during streaming are isolated. Preview writes may fail
and later writes may recover. `finish` reports whether the final text was
confirmed. Final output truth still belongs to the actor store and
`signal_gateway_outbox`.

On finish, cancelled output displays `已停止`, failed output displays `出错了`,
and empty final text displays `（无内容）`. Failing to disable card streaming mode
after final text is a visual blemish, not a state rollback.

Streaming-card markdown should convert fenced code blocks into line-wise inline
code because Feishu/Lark card markdown does not reliably accept ordinary fenced
blocks in that update path.

The final CardKit summary is a whitespace-collapsed preview capped at about 80
characters. It is only provider UI metadata; it is not the answer body.

Reasoning trace links inside cards are authorized by sealed trace tokens. The
adapter does not rely on user-agent checks to decide whether the link is valid.

## Identity Provider

The identity-provider adapter supports:

- OIDC authorization URL construction;
- OIDC code exchange;
- user-info hydration through contact user lookup when possible;
- department full sync;
- user full sync;
- realtime contact change handling on the shared long connection when enabled.

When `sync.websocket` is false, the identity-provider adapter should not open or
attach to the shared long connection.

OIDC and contact sync are Principal/AuthZ concerns. They do not create
SignalsGateway bindings and do not decide message admission.

OIDC authorization builds the provider URL from app id, redirect URI, requested
scopes, and state. The admin-auth host stores the in-flight provider id, state,
nonce, return path, and redirect URI in a short-lived sealed cookie. The
Feishu/Lark adapter exchanges the returned code for a user token, reads user
info, then hydrates the user from Contact API when possible so the resulting
subject is the same `user_id` used by directory sync.

The normal admin-login callback then upserts the provider user through the
identity-provider service and asks AuthZ whether the resolved Principal is an
active human admin. Authentication alone is not enough. A disabled human, an
agent Principal, or a human who is not in the built-in admin group fails closed.

First-run setup uses the same callback path but a separate setup OIDC state
cookie. If that state matches, the authenticated platform subject is upserted
and passed to root initialization. AuthZ/setup owns the race-safe root-admin
claim; Principals only supplies the human Principal.

Admin sessions, setup sessions, OIDC state cookies, and one-time setup
activation codes are AuthN/setup state. They are not Principal rows and not
SignalsGateway rows.

Contact events handled by the shared dispatcher include user create/update/delete,
department create/update/delete, and contact-scope updates. Missing ids on user
or department events should request a full sync instead of inventing a partial
identity.

Directory full sync is authoritative only for users this identity provider has
previously managed. A `platform_subject` row first created by chat observation
must not be disabled merely because a later directory snapshot does not contain
that user. Departments are different: they have no chat-observation path, so a
missing provider department binding can be removed under the provider's own
scope.

## Provider Mirror Behavior

Feishu/Lark receive facts update `signal_channels` and `signal_entries` through
SignalsGateway. Confirmed successful outbox sends update the mirror afterwards.
Failed or unsupported outbox attempts do not fake mirror state.

The adapter must normalize the same physical provider channel and message to
the same `signal_channel_id` and `provider_entry_id` when the provider gives
stable ids. If the provider gives different ids under different app views, the
adapter stores separate mirror rows rather than guessing.

The mirror does not record which binding has seen a channel. Binding-specific
handling is represented by the accepting route, the mailbox input, outbox rows,
and actor-store consumed-input markers.

Because Feishu/Lark message edits are not delivered by the current adapter
contract, mirrored entries can become stale after a user edits a message in the
provider. That is a provider limitation, not a SignalsGateway queue failure.

## Invariants

- Chat adapter and identity-provider adapter are separate contracts.
- There is no shared provider-configuration table or merged setup object.
- The long connection is shared per `domain + appId`, not per actor session.
- Different app ids require different long-connection clients.
- The long connection belongs to the control-plane/provider ingress runtime,
  not to the agent computer.
- Group-message policy is a SignalsGateway binding policy, not a Feishu-only
  rule.
- Setup value `observe_all` maps to Ankole `record_only`, not to actor wakeup.
- The adapter calls `emit_entry`, `emit_entry_removed`, `emit_reaction`, and
  `emit_action`; it never creates ActorInput directly.
- Platform subjects converge on `provider + user_id` whenever `user_id` exists.
- `open_id` and `union_id` are metadata or fallback evidence, not the normal
  human Principal key.
- Card actions are action inputs, not fake text messages.
- Reactions update mirror state only.
- Recalls hard-delete provider mirror entries and refresh tombstones without
  rewriting actor transcript history.
- Provider recall does not imply assistant-output delete.
- Commands are typed ActorInputs, including `command.steer`.
- Feishu/Lark OIDC is AuthN input to Principals and AuthZ, not a SignalsGateway
  routing rule.
- Feishu/Lark reply-target-gone fallback is adapter behavior, not a generic
  outbox guarantee.
- Outbox adapter capabilities use the fixed SignalsGateway allowlist; streaming
  and idempotency are config/row behavior, not extra capability atoms.
- Durable payloads must be strict JSON values before provider ack or durable
  staging; sanitizer output is only for logs, `last_error`, and error previews.
- Outbox adapter return values are limited to `{:ok, map}`, `{:error, reason}`,
  or `:unknown`.
- Provider mirror updates happen only for accepted inbound facts and confirmed
  provider-visible outbound success.
- FeishuOpenAPI reconnects, request retries, and frame reassembly are not
  Ankole durable state.
