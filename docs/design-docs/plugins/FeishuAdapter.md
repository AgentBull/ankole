# Feishu / Lark Adapter

The Feishu / Lark Control Plane Plugin connects a Feishu or international Lark
self-built app to Ankole. It has two separate jobs:

- chat ingress and provider-visible output through SignalsGateway;
- optional login and contact-directory sync through Principals.

Those two jobs may use the same app credentials, but they are not one shared
provider configuration. Chat setup and identity-provider setup are separate
save boundaries. Sharing credentials is a convenience, not a storage object.

The adapter is a trusted first-party Elixir/OTP Control Plane Plugin. It does
not run inside an Agent Computer. Agent Computer only starts after SignalsGateway has accepted
an actor event into PostgreSQL and the control plane wakes the session actor.
For the system map and the gateway contract this adapter plugs into, see
`docs/README.md` and `docs/design-docs/SignalsGateway.md`.

## Names

The stable external names are:

- Control Plane Plugin ID: `lark-adapter`;
- SignalsGateway adapter id: `lark`;
- identity-provider adapter id: `lark`;
- default chat binding name: `lark`;
- default platform-subject provider namespace: `lark-main`;
- display name: `Lark / Feishu`.

Ankole should keep those external names unless there is an explicit migration
story. `feishu` can appear as the domain value for China Feishu, but it should
not silently replace the adapter id or platform namespace.

This document describes only the Control Plane Plugin adapter contract. Provider setup,
gateway routing, the actor event journal, provider mirror, and identity storage
remain owned by their Ankole subsystems.

## Control Plane Plugin Declaration

The Control Plane Plugin declaration should expose:

- Control Plane Plugin ID `lark-adapter`;
- a SignalsGateway adapter declaration with id `lark`;
- the SignalsGateway adapter's complete `outbound_capabilities` list, which is
  the sole capability source used to construct its outbound contract;
- a Principals identity-provider adapter declaration with id `lark`;
- setup field metadata for chat binding config and identity-provider config;
- schema and field metadata for encrypted config values; the persistence key is
  owned by the setup path, SignalsGateway, or Principals rather than by a shared
  provider object;
- supervised children needed for the shared long-connection runtime.

The adapter declarations are references to host-owned contracts. The Control Plane Plugin does
not own `signal_gateway_bindings`, `signal_gateway_channels`, `signal_gateway_entries`,
`actor_events`, `signal_gateway_outbox_entries`, Principal rows, or AuthZ grants.

The supervised runtime may keep a connection registry keyed by `domain + appId`.
That registry is process state and should be rebuildable from active
configuration after restart.

The Elixir implementation should use `libs/feishu_openapi` as the provider
library. That means the Control Plane Plugin owns the Feishu/Lark-specific normalization:
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
concrete `emit_*` adapter-facing APIs. It must not construct `ActorEvent`
directly.

## User Stories

An operator connects one agent binding to one Feishu/Lark self-built app. The
operator provides app credentials, chooses Feishu or Lark domain, chooses how
unaddressed group messages behave, and grants the CardKit permissions required
for assistant output. CardKit is the primary Feishu/Lark AI-reply surface, not
an optional second-phase enhancement. A plain message is a failure fallback,
not a parallel product mode.

A human sends the agent a DM or a structured group mention. The adapter
normalizes the provider message into a SignalsGateway entry receive fact.
SignalsGateway mirrors the visible message and appends `im.message.addressed`.
The agent's streamed answer is delivered live through the gateway's AI-reply
preview as one logical CardChain of CardKit JSON 2.0 cards. A normal answer has
one card; content that exceeds a safe card budget seals the current card and
continues in an ordered tail card without discarding Markdown. The adapter never
posts a temporary text reply and later replaces it with a card. That preview is
only transient progress. When Agent Computer explicitly reports `turn_completed`,
SignalsGateway writes the adopted final CardKit finalize-or-create operation as
a durable outbox operation; provider success is then mirrored into
`signal_gateway_entries` with the final Response backref.
Explicit side effects — attachments, reactions, dividers, command feedback —
still execute through `signal_gateway_outbox_entries` rows.

A group has normal conversation near the agent. The binding policy decides
whether those unaddressed messages are ignored, mirrored only, or delivered as
`im.message.may_intervene`. The adapter only reports whether the provider gave
a real structured mention; it does not decide the final actor-delivery policy.

One Feishu/Lark group contains several bot accounts, and each bot account is
connected to a different agent binding. Each bot account is a different
Feishu/Lark app id, so the runtime must keep one long connection for each app.
The same human message may therefore arrive once per bot account. Actor event
delivery remains per accepting binding. The provider mirror shares storage only
when the provider exposes the same normalized channel id and message id under
those app views; if the ids differ, Ankole stores separate mirror entries rather
than guessing that they are the same physical message.

A human clicks a button in a Feishu/Lark card. The adapter emits an action fact
through `emit_action`. It is an explicit user action, not a fake text message.
The default ActorEvent type is `signal.action.invoked` unless the source maps it
to a narrower code-defined type.

A user recalls a message. The adapter emits a removal fact with provider
lifecycle kind `recalled`. SignalsGateway deletes the mirrored entry, refreshes
the tombstone, and removes the pending actor event when possible. If the
event's work already completed, the gateway appends a `signal.entry.removed`
lifecycle event; consuming it cancels checkbacks anchored to the recalled entry
and applies the AI-message deletion mapping (chain-tail hard delete, `retracted`
for audit-needed rows, otherwise no-op — see
`docs/design-docs/SignalsGateway.md`). No note is produced for later model
turns. The adapter must not infer that prior assistant output should also be
removed.

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
- `userName`: display name for adapter-authored output, not an identity key.

The setup UI does not ask for a bot identity. The bot's own `open_id` is
resolved automatically from `bot/v3/info` at connection time (using the app
credentials) and kept only in the process-local consumer config as
`runtimeBotOpenId`, where it routes group `@`-mentions to this binding. An
explicit `botOpenId` / `botUserId` override is still accepted in the stored
config for advanced cases, but operators are not expected to supply one.

The setup UI may present these group-message labels:

| Setup value | SignalsGateway binding policy | Meaning |
| --- | --- | --- |
| `addressed_only` | `ignore` | DMs and structured mentions are accepted; unaddressed group messages are dropped. |
| `observe_all` | `record_only` | Unaddressed group messages update the provider mirror but do not wake the agent. |
| `may_intervene` | `may_intervene` | Unaddressed group messages update the mirror and append `im.message.may_intervene`. |

The generic `signal_gateway_bindings` default can remain conservative, but Feishu/Lark
setup should write `record_only` when the setup value is `observe_all`.

The identity-provider adapter config is separate:

- `appId`;
- `appSecret`;
- `domain`;
- `oidc.enabled`, default `true`;
- `oidc.scopes`, default `["contact:user.employee_id:readonly"]`;
- `sync.contacts`, default `true`;
- `sync.websocket`, default `true`;
- `sync.pageSize`, default `50`, valid range `1..50`.

`sync.contacts` is the single directory-sync switch. It covers both users and
departments; Ankole does not expose separate `sync.users` or
`sync.departments` flags.

Production OIDC needs a public base URL so Feishu/Lark can redirect back to the
installation. If OIDC is disabled, login callbacks for that provider fail
closed.

Ankole setup does not create external provider apps. The operator creates the
Feishu/Lark self-built app in the provider console, subscribes the required
official events, and enters the resulting credentials in Ankole setup. Setup may
validate credentials, but it should not create or register the external app for
the operator.

## Agent Computer Lark capability

One digital employee uses one Feishu/Lark application. A newly saved chat
binding stores its encrypted config under
`signals_gateway.lark.bindings.<agent_uid>`; the save path rejects a second
enabled Lark binding for the same agent and rejects an app id already assigned
to another agent. Assignment validation and persistence are serialized by one
adapter-scoped transaction advisory lock, so concurrent saves cannot both pass
the one-agent/one-app checks. The config row and binding commit together; the
AppConfigure cache is published only after that transaction commits. Existing
bindings remain readable through their persisted `config_ref` until they are
saved again.

An available Lark binding also gives that agent bot-only `lark-cli` capability.
Agent Computer is a trusted first-party worker. The adapter uses the binding's
app credentials in the control plane, then contributes only the app ID and
tenant token required by the CLI through the existing `worker_env.resolve`
path:

- `LARKSUITE_CLI_APP_ID`;
- `LARKSUITE_CLI_TENANT_ACCESS_TOKEN`;
- `LARKSUITE_CLI_BRAND`;
- `LARKSUITE_CLI_DEFAULT_AS=bot`;
- `LARKSUITE_CLI_STRICT_MODE=bot`.

The pinned CLI derives its OpenAPI host from the brand and cannot inherit a
custom binding `baseURL`. Such a binding remains valid for signal delivery, but
cannot provide compatible CLI credentials to the Worker.

The CLI's environment credential provider does not mint a tenant token from
`appID/appSecret`. During the existing once-per-Turn `worker_env.resolve`, the
control plane therefore reuses `FeishuOpenAPI.TokenManager` and projects its
cached tenant token. Bot calls need the app ID and token but not the app secret,
so WorkerEnv does not include the secret. Concurrent misses are already
coalesced by that manager; there is no per-command refresh, separate token
broker, or Worker callback.

Binding-derived variables are not Console-editable WorkerEnv rows and merge
after operator-managed rows. The environment is resolved once when a Turn
starts; Ankole adds no command-level token broker or refresh protocol. Lark
skills execute the CLI through one-shot commands. A persistent interactive
terminal retains the environment from its creation Turn and is not a supported
Lark execution path. A configured available binding whose active adapter cannot
resolve fails that WorkerEnv request instead of silently starting the Turn
without its Lark identity; a residual binding for an inactive Control Plane Plugin is ignored.

The `lark` Agent Plugin owns `lark-im`, `lark-office-suite`, and `lark-oa`.
Its global default is disabled, while all three member Skills default to
enabled. Operators enable the parent and its members through the same Agent
Library global defaults and per-Agent overrides used by every other Agent
Plugin. Signal bindings never change those settings.

Enabling the Agent Plugin makes the Skills model-visible; successful provider
calls still require a compatible active binding so WorkerEnv can project the
bot credentials described above. This runtime prerequisite is reported by the
actual CLI call and is not another enablement system. The Agent Computer build
validator reads the three Skills from `app/library/agent-plugins/lark/skills`.

`lark-oa` covers Task, OKR, and attendance. The pinned `lark-cli` v1.0.69
Approval catalog is user-only, so Approval is not exposed or relabeled as a bot
capability.

## Runtime Connection

Feishu/Lark long-connection delivery is cluster-style: multiple live consumers
for the same `domain + appId` can split events unpredictably. The Control Plane Plugin must
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

- the Control Plane Plugin starts a local unique `Registry` for connection owners;
- the Control Plane Plugin starts a `DynamicSupervisor` for per-app connection owners;
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
the host. On restart, the Control Plane Plugin reconciles those configurations and starts one
owner for each distinct key that is still needed.

The per-key connection owner builds an immutable
`FeishuOpenAPI.Event.Dispatcher` from all active consumers for that key: chat
receive/recall/reaction/card handlers when chat ingress is enabled, and contact
handlers when identity realtime sync is enabled. If a later setup change adds or
removes a consumer for the same key, Control Plane Plugin runtime reconciliation restarts that
one connection owner with a newly built dispatcher rather than trying to mutate
the dispatcher inside a running `FeishuOpenAPI.WS.Client`.

Fatal provider configuration errors should stop only the per-key owner and mark
the affected runtime unavailable. Nonfatal transport loss is handled by
`FeishuOpenAPI.WS.Client` reconnect. After each successful WebSocket upgrade the
client sends the `pbbp2` application-level ping immediately, then follows the
provider-supplied interval; its proto2 envelope includes all required scalar
fields even when their values are zero. Separately, every RFC 6455 ping from the
provider is answered with a transport pong that echoes the same payload. The
supervised child should avoid a tight restart loop on fatal credential or
permission errors. One practical shape is to wrap the WebSocket child spec with
transient restart semantics for fatal shutdowns while letting unexpected
crashes restart normally.

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
registers all official event types the Control Plane Plugin claims to support. WebSocket
frames are trusted decoded payloads: webhook verification token and encrypt-key
checks do not apply to those frames. HTTP webhook or HTTP card callback surfaces,
if enabled later, must verify signatures before mutating the raw request body.

The host, not `FeishuOpenAPI`, owns admission policy, durable idempotency,
tombstones, micro-batching, the actor event journal, and outbox. Transport reconnection,
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
host-only temporary state in provider mirror, actor event, or outbox payloads.

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

Full directory sync first materializes provider departments as static Principal
groups named `<provider_id>:department:<department_id>` and writes
`principal_group_external_bindings` for those departments. User sync then
refreshes provider-owned department memberships from each contact user's
department ids. When a department binding records a parent department id, AuthZ
also materializes the known ancestor department groups for that user.

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

`provider_thread_id` names the thread that already contains the message, so
only provider-marked replies (`root_id`/`parent_id`) carry one; a top-level
message has `provider_thread_id = nil`. The adapter must not fall back to the
message's own id: that would give every top-level message a distinct
inbound-batch key, so same-sender bursts could never merge and channel-scoped
debounce would never engage. DMs follow the same rule.

Direct reply identity is separate from thread identity. The adapter maps
`parent_id`, then `upper_message_id`, then a non-self `root_id` fallback to
`reply_to_source_entry_id`. SignalsGateway resolves that target and decides
whether it was authored by the current agent; Lark code does not fetch parent
content or inherit parent attachments through a second semantic path.

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

- `source_event_id` from Feishu/Lark websocket `event_id`;
- `source_entry_id` from Feishu/Lark message id;
- `signal_channel_id` from chat id;
- `provider_thread_id` from chat id plus root id for provider-marked replies,
  nil for top-level messages;
- `reply_to_source_entry_id` from the exact parent/upper message id, with the
  provider root as a non-self fallback;
- channel kind, normally `im_dm` or `im_group`;
- `reply_mode = entry` for IM chats that support anchored reply;
- text and a simple markdown-formatted representation;
- author id/name/bot/self flags;
- structured mention flag from the provider, not from plain text;
- provider send time;
- attachments, links, mentions, metadata, and raw payload reference.

DMs are explicit input. The adapter directly marks structured mentions and
provider-native invocations. SignalsGateway additionally makes a group reply
explicit when `reply_to_source_entry_id` resolves to an entry authored by the
current agent. Plain text containing an `@` character is not enough, and an
unresolved reply target is not assumed to be the bot.

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
`ActorEvent(type = command.compress)` and runs entirely in the control plane:
AIGateway summarizes the older history prefix with the agent's `light` model
profile (falling back to `primary`), keeps the recent tail inside a compaction
artifact, and writes a `type = "checkpoint"` row that points at that artifact.
The user gets fixed command feedback through the outbox. No worker turn starts
and no RPC is involved.

For mentioned commands, the adapter or shared parser strips only a provider
confirmed structured mention prefix before matching. Full-width spaces and
full-width digits normalize before matching. A full-width slash remains normal
text. Multi-line command arguments are allowed. `/undo` is not a command.

`/steer` is a command event like `/new`, `/compress`, `/retry`, and `/stop`.
It produces `ActorEvent(type = command.steer)`. The actor may consume that
event through the same addressed-message path used for `im.message.addressed`,
but the event is not first rewritten into an ordinary visible message.
When a turn is already running, ActorRuntime may acknowledge the command after
its `mailbox_updated` nudge is sent or queued for that turn. Feishu/Lark adapter
code must not treat that acknowledgement as proof that the model incorporated
the steer; worker acceptance and model consumption are separate runtime facts.

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

Before SignalsGateway mirrors the entry or writes the actor event, attachments
must be materialized into durable references or file paths visible to the agent
computer. Live adapter closures, FeishuOpenAPI client structs, and host-only
temp paths must not enter the provider mirror or actor event payloads.

SignalsGateway validates durable JSON with Ankole's own JSON adapter through
the strict `JSONPayload` path. The sanitizer is only for `last_error`, logging,
and short error previews. It must not be used to "fix" attachment descriptors or
other mirror/event/outbox payloads.

The adapter also supports a user-facing backfill path for common Feishu/Lark
usage: a user first sends a file or image, then mentions the agent in a later
text message such as "看上面的文件" or "please read the previous file". When the
message is a structured group mention, has no direct resources, and its text
matches the recent-attachment intent, the adapter looks back about two minutes
in the same chat, finds a previous same-sender message, and attaches up to three
usable resources from that earlier message. If lookup fails, ingress continues
without backfilled attachments.

An explicit provider reply is not this heuristic. SignalsGateway resolves the
exact `reply_to_source_entry_id` from the accepting binding's durable inbound
snapshot and projects its already-materialized attachments under
`data.entry.reply_to`. A mention-only reply to a parent file therefore exposes
the file to the Agent Computer without downloading it again, while another
agent binding in the same group cannot borrow an attachment it never observed.

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

Reactions update only the provider mirror. They do not append an actor event.

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

- `source_entry_id = message_id`;
- `signal_channel_id = lark:<chat_id>`;
- `provider_thread_id = lark:<chat_id>:<root_id>` when the recall payload marks
  a reply, nil otherwise;
- lifecycle kind `removed`, with provider lifecycle kind `recalled`;
- provider time from recall, update, or create time when available.

That provider time is mirror/lifecycle ordering data only. Model-visible
history and its timestamps belong to AIGateway's `ai_gateway_messages` log;
provider time never orders model history.

The adapter submits the fact through `emit_entry_removed`. It does not create
the tombstone or the lifecycle actor event itself.

SignalsGateway hard-deletes the mirrored entry because `signal_gateway_entries` is the
current provider-visible mirror, not actor transcript history. The tombstone
prevents a late receive from recreating the entry.

Feishu/Lark recall is not the same as agent-output recall. The actor may later
commit an explicit outbox delete, but the adapter and gateway must not infer it.

## Outbound

The Feishu/Lark module adapter should implement
`Ankole.SignalsGateway.OutboxAdapter` for provider-visible output. Real modules
implement `send/1`; `reconcile/1` is optional and is used only for recovery of a
durable `sending` outbox row. The Control Plane Plugin declaration supplies capabilities, and
`SignalsGateway.Adapters` combines that declaration with the module callbacks.
Test map adapters remain self-contained and do not need to implement the
behaviour.

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
the `signal_gateway_outbox_entries.idempotency_key` row value that the adapter passes to
Feishu/Lark when the provider API supports it. Streaming preview policy is owned
only by SignalsGateway; AIGateway publishes generic conversation-scoped
Response events and does not interpret Actor metadata. Preview writes are
transient adapter calls, while the adopted final card send or edit is a durable
`card` outbox operation.

`send/1` and `reconcile/1` must return only `{:ok, map}`, `{:error, reason}`, or
`:unknown`. Other return values are adapter bugs and are normalized into
adapter errors. The success map may include values such as
`created_source_entry_id`, `raw_payload`, `provider_time`, or `recovery_state`,
but any durable map field must already be JSON-serializable.

Text output posts to the chat with `receive_id_type = chat_id`. Reply output
uses Feishu/Lark message reply when the outbox provides a target entry or the
thread root id is usable. Outbox idempotency keys are passed through as provider
UUIDs when the Feishu/Lark API supports them. Feishu limits that UUID to 50
characters, so the adapter preserves a short key verbatim and deterministically
hashes a longer key into a 50-character provider value. The full Ankole key
remains unchanged in the durable outbox row.

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
- an optional one-field free-text clarification form as a top-level body
  element, never nested in a choice column set;
- optional custom-text hint above choices;
- answered/expired/cancelled/superseded state as grey status text;
- selected choices with visible selected text;
- locked choices as disabled buttons once the interaction is no longer open.

Choice callback values keep the interaction version, interaction id, control
id, selected option id, and provider-safe option value. A form submit keeps the
same locator fields and names its one input; the adapter copies CardKit's
`form_value` into the managed callback value before SignalsGateway validates it.
The adapter does not collapse either answer into display text.

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

This section is the conformance contract for direct CardKit delivery. An
adapter that still implements preview as ordinary text send/edit does not
satisfy it, even if a standalone CardKit experiment succeeds.

Feishu/Lark assistant output uses one evolving logical CardChain per visible
Agent Turn. Its usual shape is one CardKit JSON 2.0 card. When the cumulative
Markdown crosses the safe per-card budget, completed prefix cards become
immutable and the active tail continues streaming. The chain is a work surface,
not a transcript of model events. At any time it should answer three human
questions: whether the request was received, what is happening or still needed,
and what result or next action is available. Continuity matters more than
animation, so the same chain moves from working to terminal state instead of
posting a trail of status messages.

CardKit is the first visible surface. The adapter never starts with a text
placeholder and replaces it with a card later. A short creation debounce may
avoid flashing a working shell for a sub-second answer; if the turn finishes
during that window, its first visible object is the finalized CardKit card.
Plain markdown is reserved for terminal delivery recovery after CardKit itself
cannot be delivered.

### Interaction principles

Human attention, agency, and trust are the design constraints:

- Show progress only when it reduces uncertainty. Token motion and every
  function call are not useful progress by themselves.
- Preserve the answer as the dominant surface. Status, plan, evidence, and
  receipts support the answer instead of competing with it.
- Expose a control only when it changes real system state. Internal Agent todo
  items must not look like user-owned checkboxes.
- Distinguish a claim, the evidence used to support it, and a side effect that
  actually happened. A successful tool invocation is not automatically a
  successful user outcome.
- Use progressive disclosure. The current step stays visible; verbose activity
  and diagnostics live in collapsible panels or an authorized trace.
- End with unambiguous closure. A terminal card never continues to look busy,
  and it does not retain transient reasoning merely to demonstrate effort.

### Visible lifecycle

The preview lifecycle belongs to SignalsGateway's `AIReplyPreview` process.
Response terminal events do not decide that the Agent Turn is finished.
`turn_completed`, explicit stop, an interaction request, or the owned failure
path moves the visible card into a terminal or waiting state.

| State | Visible treatment | Allowed transition |
| --- | --- | --- |
| `debouncing` | No provider message for at most 500ms. | Open a working card, or create the final card directly. |
| `working` | Compact status, optional plan, streamed answer, and folded activity. | Complete, fail, stop, or ask for input. |
| `awaiting_input` | Streaming is closed; the question and real buttons plus an optional free-text form become primary. | The first valid callback records one answer; a newer conversation event supersedes it. Both transitions lock the controls. |
| `completed` | Final answer and useful result blocks remain; process detail is folded or removed. | No further model updates. |
| `failed` | Preserve useful partial output, label it incomplete, and offer a retry when safe. | A retry starts a new Agent Turn. |
| `stopped` | Preserve useful partial output and show `已停止`. | Continue or retry starts a new Agent Turn. |
| `scheduled` | Show a durable receipt describing what will run and when. | The later run reports through its own event or turn. |

The stable working-card skeleton uses short CardKit element ids such as
`state`, `plan`, `thought`, `answer`, `results`, `receipts`, `activity`,
`actions`, and `meta`. Stable ids let the renderer update one semantic region
without rebuilding unrelated content. Empty regions are omitted rather than
rendered as headings with no content.

The order is status, current plan, transient thought, answer, rich results,
side-effect receipts, folded activity, actions, and a quiet metadata footer.
Once answer text exists, the status visually recedes. The footer may show
elapsed time and source count; model name, tokens, and raw tool names are debug
information and do not belong in the normal card.

### Reasoning and activity

If the upstream model API explicitly emits provider-visible reasoning text, the
working card may stream that original text into a collapsible `思考草稿` panel.
It is labeled as provisional and may change. This rule does not synthesize or
request hidden chain-of-thought from a model that did not expose it.

The `thought` element exists only while `working`. It is deleted before
`awaiting_input`, `completed`, `failed`, or `stopped` is rendered, rather than
merely collapsed. The presentation layer must not copy it into the terminal
outbox payload, message mirror, search index, card summary, or fallback text.
Long reasoning uses a bounded rolling display so it cannot consume the card's
content budget. An authorized sealed trace may retain other redacted
diagnostics, but it does not retain or link to this reasoning projection.

Because a provider card outlives its Preview process, visible thought is a
leased state. Creating the `thought` element also records an idempotent cleanup
deadline in the PostgreSQL preview checkpoint. Normal finalization clears that
marker; owner restart, turn expiry, or recovery removes the element and closes
streaming. CardKit's automatic stream close is not sufficient because it would
leave the last thought text visible.

Function calling is projected as compact human-readable activity, not raw
protocol. Tool-owned descriptions expose only the detail that helps a person
understand current work: file operations keep at most `parent/basename`, command
operations keep a semantic verb plus command family without flags or operands,
and skill operations keep the skill name without its source path. Internal todo
calls update the plan without adding a duplicate activity row. Parallel calls
keep their individual rows while the folded header names the latest call and the
active count. Raw names, arguments, outputs, provider payloads, and stack traces
remain in the authorized trace after redaction.

While a reply is working, its execution plan is expanded. The activity panel is
folded when that plan exists and expanded when it is the only progress surface;
the folded title still names the current activity. A completed plan folds so the
answer becomes the visual focus, and ordinary successful activity remains live
progress rather than terminal history.

A side-effecting tool leaves a terminal receipt only after its owning subsystem
confirms the effect. The receipt states what changed, where, and whether a
follow-up is pending. Read-only tools normally disappear into the answer or a
source count. Tool failure remains visible only when it changes the result or
the user can act on it; otherwise the agent may recover without creating alarm
noise.

### Todo and memory semantics

The Agent's internal todo tool is a live plan, not a user task list. It emits a
full, revisioned `plan.snapshot` keyed by stable item ids. The card shows the
current item, `x / y` progress, at most a few surrounding items, and one
in-progress marker. Repeated todo calls replace the snapshot instead of
appending logs. At completion, a successful internal plan becomes one folded
execution summary; incomplete or failed items remain visible only when they
explain a limitation or require user action.

An internal todo never uses CardKit checker controls. A checker is appropriate
only for a real user-owned task whose callback updates the durable task through
an authorized, idempotent command. In that case it is a product interaction,
not a visual rendering of the model's scratchpad.

Memory reads show a restrained live state such as `正在回忆相关上下文` only
after a latency threshold. On success, the answer may say that relevant memory
was used or show a small source count; it does not expose embeddings, similarity
scores, raw search queries, or internal ids.

Memory creation, correction, and deletion are consequential side effects, so a
terminal receipt states exactly what was remembered, updated, or forgotten and
its scope. Any `查看`, `更正`, or `删除` action carries a durable memory id,
expected revision, principal context, and idempotency key. The callback
re-authorizes the acting Principal; a visually present button is never treated
as authority.

The same projection rule applies across common tool classes:

| Semantic work | While it runs | What may remain at terminal |
| --- | --- | --- |
| Internal todo | Current item and bounded plan context. | Folded completion summary, or an actionable incomplete item. |
| Memory lookup | Delayed, quiet recall status. | Optional source count; no internal retrieval data. |
| Memory mutation | `正在更新记忆` with the affected scope. | Confirmed create, update, or delete receipt. |
| Search or read | A status only when latency is noticeable. | Sources that materially support the answer. |
| Computation | Human description of the calculation. | Typed table, chart, or concise result with units. |
| Artifact creation | Artifact name and meaningful generation stage. | Preview plus open/download action. |
| External write | Target and pending state without claiming success. | Confirmed effect receipt or actionable failure. |
| Deferred work | Schedule or BackgroundAgentJob receipt and current state. | Durable receipt or owner-wakeup result, never an indefinite spinner or Agent Plugin-specific artifact interpretation. |

### Component policy

Components are selected from typed presentation data. The renderer never
scrapes arbitrary Markdown, tool stdout, or model JSON to guess that a table,
chart, form, or action should exist, and the model never emits trusted CardKit
JSON directly.

- **Markdown** is the default answer and explanation surface. Preserve standard
  headings, lists, links, tables, and fenced code blocks. During an incomplete
  fence or table, the preview renderer buffers at a safe boundary or supplies a
  display-only closing delimiter; the exact final Markdown replaces it.
- **Collapsible panels** contain transient thought, detailed activity, sources,
  or an execution summary. The answer itself is never hidden inside one.
- **Buttons** are reserved for stop, retry, approve, clarify, open artifact, or
  open an authorized trace. Use one primary action and a small number of
  secondary actions. Clarification and approval controls appear only after
  streaming is closed. A stop button may remain available while working, but
  its callback closes streaming before it changes or updates card state.
- **Tables** render typed, comparison-oriented results with a bounded row and
  column count. Large data becomes an attached artifact with a small preview.
  Generic tool output is never poured into a table.
- **Charts** render typed numeric series with units, labels, provenance, and a
  textual takeaway. Prefer one decisive chart over a dashboard, and provide a
  text or table fallback for clients where the chart is inaccessible.
- **Forms** require an owned, authorized callback contract. The runtime
  clarification form contains exactly one required, bounded, non-secret text
  input and a submit button; choices remain separate buttons. Generic
  multi-field forms are not inferred from model output.
- **Images** show a generated artifact or evidence that materially improves the
  answer. Typed image results already carry an uploaded Feishu image key. For a
  remote HTTP(S) Markdown image, the adapter resolves redirects, classifies
  every hop with the shared kernel URL classifier, downloads the image, uploads
  it to Feishu, and replaces only the rendered URL with the resulting image key.
  This resolution is always available: `security.ssrf_filter` controls whether
  private and intranet targets are rejected, defaults to `false`, and never
  permits cloud metadata endpoints. The durable checkpoint stores the URL-to-key
  result so a restart does not fetch or upload the same image again. A failed
  image remains ordinary Markdown instead of failing the answer.
- **Column sets** group a few comparable metrics or actions and must degrade
  cleanly to a single mobile column. Tables and forms are not nested in them.
- **Recycling containers** are not part of the direct runtime renderer while
  they remain a card-builder/template capability rather than a CardKit Card
  JSON component. The renderer does not introduce a second template pipeline
  merely to obtain that layout.

### Provider-neutral presentation

Raw model events do not carry enough meaning to produce this UI. Agent Computer
therefore emits turn-fenced, renderer-safe presentation events around owned
tool execution. They use the existing worker progress transport, including the
full TurnRef, rather than inventing durable control-plane state in the worker.
Useful event kinds include:

- `turn.phase` and `reasoning.delta` for transient state;
- `plan.snapshot` for internal todo state;
- `tool.activity` for a safe human summary and phase;
- `memory.lookup` and `memory.mutation_receipt` for memory semantics;
- `result.table`, `result.chart`, and `artifact.available` for typed results;
- `interaction.request` for an owned clarification or approval; and
- `effect.receipt` for a confirmed external side effect.

Every event carries a stable operation or call id, phase, revision, and semantic
projection. The control plane fences stale turns and merges the events into a
provider-neutral `ReplyPresentation` snapshot. Lark maps that snapshot to
CardKit; adapters without rich output render its fallback text. Tool-specific
code owns the safe projection because only that code knows which arguments,
results, and effects are meaningful.

When an internal wakeup rather than a provider-visible message triggers the
Agent turn, SignalsGateway may add a bounded `trigger_context` to the same
presentation. BackgroundAgentJob completion is delivered through this owner
turn; the adapter never reads Agent Plugin files or interprets an Agent Plugin-specific
result contract. A failed Job renders its bounded failure context as a Markdown
blockquote before the Agent answer on the first CardKit card. The quote is
derived from the durable ActorEvent, not authored through the model prompt, and
survives preview recovery and terminal outbox delivery without becoming part of
the model answer or repeating on later cards.

Live progress may remain ephemeral, but terminal rich output cannot depend on a
Preview process surviving. At `turn_completed` the worker supplies, or the
control plane reconstructs from durable domain truth, a bounded terminal
`ReplyPresentation`. The durable outbox stores that provider-neutral snapshot
and `fallback_visible_text`. CardKit JSON is a rendering of that truth, not the
only copy of it. Transient `reasoning.delta` content is explicitly excluded.

Clarification availability is also provider-neutral. The source ActorEvent
checkpoint stores each interaction as `pending`, `answered`, or `superseded`.
SignalsGateway changes that state under the actor-session lock before CardKit
renders it. An answered card disables all choice buttons and removes the form;
a superseded card does the same and explains that the conversation continued.
CardKit callback delivery and card mutation order cannot override this state.

### Recovery boundary

Card recovery is conditional process recovery, not infrastructure durability.
Ankole promises to reuse the same provider card after its own worker or control
plane process crashes when PostgreSQL still contains the preview checkpoint and
Feishu/Lark still retains the card entity. Temporary PostgreSQL or provider
unavailability is recovered when the cost is low: checkpoint writes and final
outbox delivery wait and retry, while CardKit operations resume after the
provider returns. Permanent database state loss, provider card deletion, and
provider-side state corruption remain outside same-card recovery. Redis failure
would have the same boundary, so adding Redis would not improve this guarantee.

Temporary unavailability and permanent state loss are different cases:

- During a PostgreSQL outage, a live owner may keep a bounded in-memory preview
  and retry its checkpoint. If that owner also crashes before PostgreSQL accepts
  the checkpoint, losing the uncommitted preview state is allowed.
- During a Feishu/Lark outage, PostgreSQL retains the provider identities,
  checkpoint, and terminal outbox intent. Preview updates pause after a bounded
  fast retry budget; terminal delivery continues at low frequency after that
  budget rather than becoming a silent permanent failure.
- When the provider returns, an existing card is updated or finalized in place.
  A missing, expired, recalled, or otherwise unusable card becomes a new
  finalized CardKit message linked to the same terminal outbox intent.

The live text, reasoning, and tool-event stream remains in-process. PostgreSQL
stores only a bounded recovery checkpoint: provider identities, AIGateway
conversation identity, CardKit sequence allocation, stream deadline, structural
presentation state, reply-interaction state, and a coalesced answer snapshot. It
does not store every token or raw reasoning. Losing changes since the last
checkpoint is acceptable; the next cumulative answer update or terminal
`ReplyPresentation` repairs the card. Reply-interaction terminal state is the
exception: checkpoint merge preserves it monotonically across stale CardKit
writes and schedules a corrective refresh.

A worker crash normally does not kill the control-plane Preview owner, so the
same `CardSession` stays attached while ActorRuntime retries the open
ActorEvent. A control-plane crash does kill that owner. On boot, preview
recovery follows the existing PostgreSQL event pattern:

1. `LISTEN` for preview-checkpoint changes and commit the subscription;
2. snapshot open ActorEvents that already have an active preview checkpoint;
3. adopt each eligible card through the current ActorRuntime owner and recover
   any pending logical mutation with its exact CardKit sequence and UUID; and
4. use later notifications only as wakeups, always reading current row state.

`LISTEN/NOTIFY` is not the recovery log. Notifications can be missed while the
listener is down, which is why subscription is followed by a database snapshot
and every wakeup re-reads PostgreSQL. Phoenix.PubSub remains the local live-delta
fanout. Neither mechanism needs Redis Streams because exact replay of transient
preview deltas is outside the guarantee.

### Provider constraints

The renderer treats CardKit's limits as product behavior rather than late API
errors:

- [Streaming CardKit](https://open.feishu.cn/document/cardkit-v1/streaming-updates-openapi-overview)
  requires Card JSON 2.0 and a Feishu/Lark 7.20-or-newer client. Older clients
  show the platform upgrade fallback, so installation diagnostics must state
  that client requirement instead of pretending that the rich answer rendered.
- One card accepts at most ten CardKit mutations per second and streaming mode
  automatically closes after ten minutes. The session coalesces below that
  rate and begins an orderly terminal or continuation transition before the
  deadline.
- [Card creation](https://open.feishu.cn/document/cardkit-v1/card/create)
  requires `update_multi = true`, permits one send per card entity, and keeps
  the entity operable for 14 days. A card therefore has shared visible state;
  per-user authorization still happens on every callback.
- Card JSON stays below 30KB and 200 total elements. Containers stay within five
  levels, and every mutable `element_id` uses only letters, digits, and
  underscores, starts with a letter, and is at most 20 characters.
- Every component, content, batch, and settings mutation shares one strictly
  increasing positive int32 `sequence`. One logical retry reuses its UUID but
  never allocates a second sequence.
- An open streaming card cannot directly update itself through an interaction
  callback. The callback path first closes streaming through CardKit, then
  records and renders the authorized interaction result.

### CardKit session and update flow

`AIReplyPreview` owns the turn lifecycle and calls an explicit adapter preview
contract: open, apply a semantic presentation revision, and finalize. The Lark
adapter owns one serialized CardChain session per logical reply. It is the only
owner that assigns CardKit sequence numbers, seals prefix cards, advances the
active tail, or mutates elements and settings; status, answer, rollover, and
finalization writes may not race through independent tasks.

With `FeishuOpenAPI`, the initial REST flow is:

1. `POST cardkit/v1/cards` with `type = "card_json"` and the working or final
   Card JSON;
2. send or reply an `im/v1/messages` interactive message whose content is
   `{type: "card", data: {card_id}}`;
3. apply cumulative answer text with
   `PUT cardkit/v1/cards/:card_id/elements/:id/content`;
4. patch one element for a local semantic change, or use a batch update when
   card structure changes;
5. when the answer crosses the page budget, close the current card, persist its
   source range, create and send the next continuation card, then continue only
   on that active tail; and
6. close streaming in its own ordered mutation, perform any best-effort stale
   element cleanup, then batch-render the terminal structure with later
   sequence numbers.

The card send prefers a reply anchored to the trigger message. If the trigger
was recalled, it falls back to a chat-level card post for the known
withdrawn/not-found errors. It passes `reply_in_thread: false` so the answer
stays in the normal chat surface.

The process-recoverable preview checkpoint contains at least its schema version,
ordered card ledger, active-tail index, each provider `card_id` and `message_id`,
per-page answer byte range and digest, AIGateway conversation id, streaming
state, stream deadline, resolved Markdown image map, last checkpointed
`ReplyPresentation` without reasoning, retry UUID, and a CardKit sequence
high-water mark, plus any durable reply-interaction states. It lives with the
ActorEvent preview state, not in AIGateway metadata. Before each coalesced
provider mutation, the session atomically
persists its purpose, content digest, next sequence, and UUID under the
ActorEvent row lock. A retry or process restart with the same logical mutation
reuses that exact sequence and UUID; a changed mutation receives the next
sequence. Gaps are valid, sequence reuse is not.

Answer text is cumulative. Prefix growth on the active tail uses the content API
for CardKit's typewriter behavior; a correction replaces that tail element.
Crossing the page budget first closes the old tail, persists its exact source
prefix, creates the next card, and sends it as a normal top-level continuation.
Only the active tail carries transient thought, progress, rich results, or
actions. A later answer that rewrites an already sealed prefix cannot be made
visually consistent, so terminal delivery sends one complete durable fallback
rather than silently leaving contradictory cards. Status and plan updates are
semantic snapshots. The session coalesces rapid revisions, flushes on natural
boundaries, and stays comfortably below CardKit's per-card update limit rather
than treating that limit as a target.

The provider can briefly reject a newly created `card_id` as not visible yet.
The adapter retries only that known invalid-card-id race, using 250ms, 750ms,
1500ms, 3000ms, and 5000ms with the same logical UUID. Other errors are
classified explicitly. If the initial send fails, preview attempts stop for the
turn instead of retrying on every delta; durable terminal delivery remains
active.

Provider failures map to recovery actions rather than one generic retry count:

- Network failures, timeouts, rate limits, retryable server errors such as
  `300120`, and ambiguous acknowledgements retry the same logical mutation with
  the same UUID and sequence. Preview pauses after its fast retry budget, while
  the terminal outbox intent remains pending with capped low-frequency backoff.
- When streaming has timed out or closed (`200850` or `300309`), an active turn
  reopens streaming before continuing. A terminal turn updates and finalizes the
  active tail without typewriter effects.
- A missing or expired card entity (`200740` or `200750`) cannot satisfy
  same-card recovery. Terminal delivery creates a new finalized card from the
  persisted outbox intent and records the replacement provider identities.
- Authentication, permission, and invalid-payload failures are
  operator-actionable rather than transient. Preview stops, while terminal
  delivery retains a visible blocked intent that configuration repair can wake;
  it does not discard the answer.

An ambiguous CardKit acknowledgement may leave PostgreSQL conservatively
recording a transient element that Feishu never created. Terminal cleanup
therefore treats provider error `300314` for a missing `element_id` as an
idempotent delete outcome. Cleanup is sequenced separately from terminal answer,
state, result, and action mutations, so one absent optional element cannot
reject the durable result.

The renderer keeps a soft budget below the provider maximum, currently 24KB and
160 elements. Answer Markdown is segmented at semantic or Unicode-safe
boundaries into approximately 12KB source pages; fenced code receives
display-only closing and reopening fences while the durable source remains
byte-for-byte lossless. Optional thought and activity disappear first, then
oversized typed detail and plan summaries degrade before the answer. It never
truncates the final answer silently. Before CardKit's streaming lifetime is
exhausted, it removes leased thought and may close streaming; if the provider
closes the stream first, a later delta reopens streaming on the active tail with
a higher persisted sequence. Plain-text chunks are reserved for deterministic
provider failure or an impossible sealed-prefix rewrite, not normal long output.

### Terminal delivery and recovery

Finalization is a provider operation with an observable commit point:

1. flush the exact final answer and required rich results;
2. close streaming mode;
3. batch-render the terminal status, receipts, metadata, and actions while
   deleting `thought` and other transient regions;
4. record provider acknowledgement against the durable outbox entry; and
5. mirror the final Response only after durable delivery succeeds.

If final content is confirmed but closing or terminal decoration fails, recovery
continues on the same CardChain without posting a duplicate answer. If the
active preview card is missing or cannot be finalized, the durable AI-reply
operation creates and sends a new finalized CardKit card. A deterministic CardKit-specific
rejection may then degrade to a new plain-markdown message when ordinary message
delivery is still available. Generic provider unavailability does not cycle
through both formats; it leaves the same durable intent pending. Preview code
never posts this fallback, so errors such as an expired message-edit window
cannot lose the result or create a burst of duplicates.

Retryable provider unavailability keeps a durable AI-reply outbox entry pending
with capped low-frequency backoff. It does not become a silent permanent failure
only because the generic `max_attempts` budget was exhausted. A permanent
contract, authentication, or authorization error moves the entry to an
operator-visible blocked state; a relevant configuration change explicitly
wakes it for another attempt. Preview updates may stop retrying much earlier
because their latest cumulative snapshot and terminal reply supersede missed
intermediate frames.

This policy extends the existing outbox instead of adding a broker. The commit
path marks terminal assistant delivery with an explicit durable-AI-reply
delivery class. Its existing payload, idempotency key, attempt counter,
`next_attempt_at`, error, and recovery fields carry the retry. For this class,
`max_attempts` ends only the fast retry phase and enters capped long-tail retry;
generic side effects keep their finite retry ceiling. An operator-actionable
failure may reuse `failed` with no deadline plus structured recovery state, so a
new status value is not required merely to implement the recovery guarantee.

A completed card shows the exact answer, useful results, effect receipts, and a
whitespace-collapsed summary of about 80 characters. A stopped card preserves
useful partial output and shows `已停止`. When `/stop` or `/new` cancels an
active turn that already owns a preview, SignalsGateway commits that stopped
presentation through the durable AI-reply outbox and finalizes the same card;
the cancelled worker's later completion is fenced. A failed card preserves
useful partial output, marks it incomplete, and exposes a safe retry when
appropriate. Empty final output displays `（无内容）`. Failing to close streaming
mode is a recoverable provider-delivery defect, not a successful finalization.

CardKit entities always use `update_multi = true` as required by the create API.
Callbacks acknowledge promptly, verify Principal authority and expected
revision, record an idempotent command, and perform slow work asynchronously.
Streaming is closed before the callback updates the card, accepted controls
become disabled, and duplicate or stale callbacks return the current state
without repeating a side effect.

Card Markdown and action values are sanitized at the renderer boundary. The
model cannot create trusted mentions or callback commands. Remote Markdown
images pass through the adapter-owned resolver and shared SSRF classifier; the
model never supplies a Feishu upload credential or bypasses URL validation.
Visual state is not conveyed by color alone, interactive
elements have useful labels, images have alt text, and the layout is tested in
both desktop and narrow mobile clients. Diagnostic trace links are authorized by
sealed trace tokens rather than user-agent checks. Those traces do not
restore transient `reasoning.delta` content after the working state ends.

### Verification contract

Provider-independent tests prove semantic merging, stale-turn fencing, plan
snapshot replacement, reasoning removal at every non-working state, action
authorization, Markdown byte-lossless pagination, URL/image policy, and
fallback-text parity. A recording CardKit client proves one serialized mutation
stream, ordered multi-card continuation, strictly increasing sequence values
across restart, UUID reuse on an ambiguous tail send, content-budget
degradation, and finalize-without-duplicate recovery.

Environment-backed Feishu tests cover a fast final answer, long Markdown with
partial code fences, parallel tools, todo revision, memory read and mutation,
typed table/chart/image output, clarification buttons and free-form replies,
stop, provider
disconnect, control-plane process restart while thought is visible, worker
restart, the ten-minute boundary, a recalled trigger, and a finalization error
that must fall back to a new message. The test passes only when the user sees a
terminal result and SignalsGateway mirrors that same Response; a green provider
call alone is not sufficient.

Recovery tests leave PostgreSQL and Feishu intact, kill and restart the worker
or control-plane owner, then require reuse of the same `card_id`. They also hold
Feishu unavailable across both the fast retry budget and the generic outbox
attempt budget, then require eventual terminal delivery after recovery. A short
outage resumes the existing card; a stream timeout or close (`200850` or
`300309`) reopens or finalizes that card; a missing or expired card (`200740` or
`200750`) creates exactly one replacement final card. Permanent PostgreSQL data
loss, permanent provider-state loss, and exact replay of uncheckpointed preview
deltas remain outside this contract.

## Identity Provider

The identity-provider adapter supports:

- OIDC authorization URL construction;
- OIDC code exchange;
- user-info hydration through contact user lookup when possible;
- full directory sync for users, department groups, external bindings, and
  department memberships;
- realtime contact change handling on the shared long connection when enabled.

When `sync.websocket` is false, the identity-provider adapter should not open or
attach to the shared long connection.

Saving an enabled provider with `sync.contacts == true` enqueues a full
directory sync, whether the save happens during first setup or later console
editing. Control-plane startup also enqueues a full sync for enabled
contacts-sync providers. When `sync.websocket == true`, the Lark adapter's
connection reconciler is invoked immediately after save and once at boot, so
the incremental contact-event listener does not require a manual server restart
after setup.

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

Feishu/Lark receive facts update `signal_gateway_channels` and `signal_gateway_entries` through
SignalsGateway. Confirmed successful outbox sends update the mirror afterwards.
Failed or unsupported outbox attempts do not fake mirror state.

The adapter must normalize the same physical provider channel and message to
the same `signal_channel_id` and `source_entry_id` when the provider gives
stable ids. If the provider gives different ids under different app views, the
adapter stores separate mirror rows rather than guessing.

The mirror does not record which binding has seen a channel. Binding-specific
handling is represented by the accepting route, the actor event row (its
`input_state` and `completed_at`), and outbox rows.

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
  `emit_action`; it never creates an ActorEvent directly.
- Platform subjects converge on `provider + user_id` whenever `user_id` exists.
- `open_id` and `union_id` are metadata or fallback evidence, not the normal
  human Principal key.
- Card actions are action events, not fake text messages.
- Reactions update mirror state only.
- Recalls hard-delete provider mirror entries and refresh tombstones; stored AI
  output changes only through the deletion mapping.
- Provider recall does not imply assistant-output delete.
- Commands are typed actor events, including `command.steer`.
- The adopted final assistant reply is always a durable outbox operation and
  mirrors into `signal_gateway_entries` with `ai_message_id` only after
  confirmed provider success; the adapter never synthesizes a provider entry
  id. Preview deltas are transient and prove neither final delivery nor Turn
  completion.
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
