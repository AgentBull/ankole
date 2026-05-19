# Feishu Adapter Plugin

The Feishu integration is a trusted BullX plugin under `plugins/feishu`. It
registers a Feishu EventBus Channel Adapter and a Principal-owned Feishu browser
login provider. Its Channel Adapter verifies Feishu/Lark transport input,
normalizes provider occurrences into decoded CloudEvents JSON, calls
`BullX.EventBus.accept/2`, and exposes optional Feishu outbound delivery and
CardKit stream transport. It does not evaluate Event Routing Rules, create
TargetSessions, invoke Targets, authorize side effects, or persist business
facts. Its browser login provider hands verified Feishu identities to
`BullX.Principals`; it is not part of EventBus transport.

Feishu uses the existing `packages/feishu_openapi` SDK directly. The plugin does
not add another Feishu client layer, a Feishu-specific Event routing layer, or a
provider-owned identity system.

## Scope

This design covers the Feishu adapter plugin:

- plugin placement, extension declarations, plugin-owned source configuration,
  and plugin-owned credential configuration;
- Feishu/Lark WebSocket event push, optional card-action callbacks, source
  listener supervision, connectivity checks, inbound normalization, direct
  channel commands, and provider acknowledgement behavior;
- Feishu channel actor evidence and Principal activation/login handoff;
- the Feishu-side EventBus handoff needed for an AIAgent multi-turn
  conversation path;
- Feishu OIDC browser login through a Principal login-provider extension;
- Feishu outbound send, edit, media upload, reply fallback, and CardKit stream
  transport;
- Feishu-specific content mapping, error mapping, telemetry, logging, security,
  privacy, tests, and implementation handoff.

This design depends on:

- `docs/design-docs/Plugins.md` for trusted plugin discovery, enabled plugin
  configuration, extension declarations, config modules, and plugin children;
- `docs/design-docs/eventbus/ChannelAdapter.md` for the common adapter contract;
- `docs/design-docs/eventbus/CommandTarget.md` for normalized command Event and
  Command Target boundaries;
- `docs/design-docs/eventbus/Core.md` for `BullX.EventBus.accept/2`,
  CloudEvents validation, and normalized payload shape;
- `docs/design-docs/eventbus/Matcher.md` for `RoutingContext`,
  `routing_facts`, Event Routing Rule priority, Blackhole, and scope/window
  policy;
- `docs/design-docs/eventbus/StreamingOutput.md` for output stream buffers that
  Feishu CardKit transport may consume;
- `docs/design-docs/Principal.md` for channel actor matching, activation codes,
  login subjects, and channel-auth login codes.

## Goals

- Keep Feishu out of BullX core modules by shipping it as one plugin under
  `plugins/feishu`.
- Register the Feishu Channel Adapter through
  `:"bullx.event_bus.channel_adapter"`.
- Reuse `FeishuOpenAPI` for OpenAPI calls, token fetch, WebSocket event push,
  card-action decoding, OIDC token exchange, uploads, downloads, and error
  context.
- Use stable CloudEvents `(source, id)` for provider redelivery idempotency.
- Keep Feishu actor evidence channel-local unless `BullX.Principals` resolves it
  into a trusted `actor.principal`.
- Keep EventBus transport boundaries intact: Feishu may produce Events and
  execute upstream-approved transport requests, but it does not choose Targets,
  create Work, approve actions, or decide business success.
- Keep app secrets, Feishu access tokens, OAuth codes, bearer-like callback
  handles, and private secrets out of Events, `routing_facts`, `reply_channel`,
  Oban job args, telemetry, logs, stream metadata, and safe errors.

## Non-goals

- Do not add Feishu modules under `lib/bullx/` or `lib/bullx_web/` except for
  generic host surfaces required by plugin or Principal extension contracts.
- Do not add provider-specific EventBus tables, route tables, durable raw event
  logs, or adapter-owned business records.
- Do not route on raw Feishu payloads, CloudEvents extension attributes,
  `subject`, nested provider carrier names, message text, or card private data.
- Do not add runtime plugin installation, hot plugin enablement, hook priority,
  plugin dependency graphs, or a Feishu-specific plugin lifecycle.
- Do not persist Feishu user access tokens, refresh tokens, raw callback bodies,
  raw WebSocket frames, downloaded media bytes, or app tickets as BullX business
  facts.
- Do not support Feishu marketplace apps in the first implementation. The first
  plugin version supports self-built Feishu/Lark apps.
- Do not make Feishu setup UI, OAuth route topology, or app marketplace behavior
  the source of EventBus or Principal architecture.

## Plugin shape

The plugin app id is `:feishu`, the plugin id is `"feishu"`, and the directory
is `plugins/feishu`. The plugin entry module is `Feishu.Plugin`.

```elixir
defmodule Feishu.Plugin do
  use BullX.Plugins.Plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.event_bus.channel_adapter",
        id: "feishu",
        module: Feishu.ChannelAdapter,
        opts: %{provider: "feishu"}
      },
      %{
        point: :"bullx.principals.login_provider",
        id: "feishu",
        module: Feishu.OIDCProvider,
        opts: %{adapter: "feishu", kind: :oidc}
      }
    ]
  end

  @impl BullX.Plugins.Plugin
  def config_modules, do: [Feishu.Config]

  @impl BullX.Plugins.Plugin
  def children(_enabled_plugin_config), do: [Feishu.SourceSupervisor]
end
```

`:"bullx.event_bus.channel_adapter"` is the EventBus-owned transport extension
point. The Channel Adapter extension id `"feishu"` must match
`data.channel.adapter` in normalized Events.

`:"bullx.principals.login_provider"` is a Principal-owned extension point for
browser login providers. The extension id `"feishu"` names the provider
implementation type. The concrete login provider id for one Feishu organization
is the enabled Feishu source id, not the string `"feishu"` and not the Feishu
app id.

Suggested module ownership:

| Module | Responsibility |
| --- | --- |
| `Feishu.Plugin` | Plugin metadata, config modules, extension declarations, and plugin children. |
| `Feishu.Config` | Plugin-owned `BullX.Config` declarations and source/credential casters. |
| `Feishu.Source` | Runtime source normalization, credential lookup, redacted public projection, and connectivity checks. |
| `Feishu.SourceSupervisor` | Enabled-source supervision under the plugin failure boundary. |
| `Feishu.Channel` | Per-source WebSocket runtime process and SDK dispatcher wiring. |
| `Feishu.ChannelAdapter` | `BullX.EventBus.ChannelAdapter` implementation and public adapter boundary. |
| `Feishu.EventMapper` | Feishu event and card-action payload normalization into CloudEvents. |
| `Feishu.ContentMapper` | Feishu message/card/media mapping into BullX content blocks. |
| `Feishu.CardActionController` | HTTP card-action callback verification and adapter handoff. |
| `Feishu.CommandNormalizer` | Safe slash-text command parsing and command routing facts for Feishu messages. |
| `Feishu.Outbound` | Feishu send, edit, upload, and reply fallback. |
| `Feishu.StreamingCard` | CardKit stream consumption and throttled card updates. |
| `Feishu.OIDCProvider` | Principal login-provider callback implementation. |
| `Feishu.Error` | SDK and Feishu API error normalization. |

Do not add a `Feishu.API` wrapper in the first implementation. Adapter modules
call `FeishuOpenAPI.get/3`, `post/3`, `patch/3`, `upload/3`, `download/3`,
`FeishuOpenAPI.Auth`, `FeishuOpenAPI.WS.Client`, and card-action helpers
directly, then route failures through `Feishu.Error`.

## Runtime configuration

Feishu is in the default enabled plugin list. If an operator overrides
`bullx.enabled_plugins`, the override is the complete enabled list and must
include the Feishu plugin id to keep this plugin active:

```json
["feishu", "bullx_telegram"]
```

Feishu configuration lives under the plugin namespace:

```text
bullx.plugins.feishu.credentials
bullx.plugins.feishu.eventbus_sources
bullx.plugins.feishu.oidc_state_ttl_seconds
```

Initial declarations:

| Accessor | DB key | Secret | Default |
| --- | --- | --- | --- |
| `credentials!/0` | `bullx.plugins.feishu.credentials` | yes | `{}` |
| `eventbus_sources!/0` | `bullx.plugins.feishu.eventbus_sources` | no | `[]` |
| `oidc_state_ttl_seconds!/0` | `bullx.plugins.feishu.oidc_state_ttl_seconds` | no | `600` |

`credentials` is a JSON object keyed by credential id. Each value contains a
self-built Feishu/Lark app credential:

```json
{
  "default": {
    "app_id": "cli_xxx",
    "app_secret": "secret_xxx",
    "verification_token": "optional_card_callback_token",
    "encrypt_key": "optional_card_callback_encrypt_key"
  }
}
```

The credentials map is encrypted by `BullX.Config`. It must not appear in
Events, source public projections, `routing_facts`, `reply_channel`, Oban job
args, stream metadata, telemetry, logs, safe errors, or operator receipts.
`verification_token` is required only when the HTTP card-action callback route
is enabled for a source. `encrypt_key` is optional and is used when Feishu
sends encrypted callback bodies.

`eventbus_sources` is a JSON array of Feishu source entries:

```json
[
  {
    "id": "main",
    "enabled": true,
    "credential_id": "default",
    "domain": "feishu",
    "connected_realm_ref": "feishu:tenant_xxx",
    "tenant_key": "tenant_xxx",
    "bot_open_id": "ou_bot_xxx",
    "bot_user_id": "u_bot_xxx",
    "web_login_disabled": false,
    "oidc": {
      "enabled": true,
      "redirect_uri": "https://bullx.example.com/sessions/oidc/main/callback",
      "scopes": ["openid", "profile", "email", "phone"]
    },
    "message_context_ttl_seconds": 2592000,
    "card_action_dedupe_ttl_seconds": 900,
    "inline_media_max_bytes": 524288,
    "stream_update_interval_ms": 100
  }
]
```

The source `id` is the stable adapter-local source id. It becomes
`data.channel.id` in Events and `channel_id` in Principal channel-actor
references. When `oidc.enabled` is true, the same source id is also the concrete
Principal login provider id. It is not a Feishu chat id, tenant id, user id, bot
id, credential id, OAuth client id, or display label.

`domain` stays in source configuration because it describes the deployment
target for one source. `credential_id` selects the app id and app secret from
the encrypted credential map. Multiple sources may share one credential profile,
but their source ids remain distinct identity namespaces.

## Connectivity check

`Feishu.Source.connectivity_check/1` validates one normalized source without
starting a WebSocket listener, publishing an Event, changing source config, or
writing Principal data. It loads the referenced credential profile, constructs a
`FeishuOpenAPI` client, fetches or validates a tenant access token, and returns
only redacted operator metadata.

Success shape:

```elixir
{:ok,
 %{
   status: :ok,
   adapter: "feishu",
   source_id: "main",
   capabilities: [:inbound, :send, :edit, :stream, :cards, :oidc],
   details: %{
     "domain" => "feishu",
     "transport" => "websocket",
     "connected_realm_ref" => "feishu:tenant_xxx"
   }
 }}
```

Failure shape:

```elixir
{:error,
 %{
   "kind" => "auth" | "config" | "network" | "rate_limit" | "unknown",
   "message" => "safe operator-facing summary",
   "details" => %{}
 }}
```

Connectivity responses must never include app secrets, tenant access tokens,
OAuth codes, user access tokens, refresh tokens, raw callback bodies, raw event
payloads, message bodies, card private data, or downloaded media.

## Channel Adapter contract

`Feishu.ChannelAdapter` implements `BullX.EventBus.ChannelAdapter`.

| Callback | Feishu behavior |
| --- | --- |
| `normalize_inbound/2` | Converts one Feishu occurrence into one decoded CloudEvent, returns `:ignore`, or returns a safe error. |
| `capabilities/0` | Declares Feishu WebSocket inbound, card actions, send, edit, stream, supported content kinds, and OIDC support. |
| `deliver/4` | Executes upstream-approved send, edit, reaction, or callback response transport when supported. |
| `consume_stream/4` | Consumes an EventBus output stream and mirrors chunks to a Feishu CardKit message. |

Capabilities should include:

```elixir
%{
  inbound_modes: [:websocket, :card_action_callback],
  outbound_ops: [:send, :edit, :stream],
  content_kinds: [:text, :image, :audio, :video, :file, :card],
  features: [:reply, :threads, :principal_channel_actor, :oidc_login]
}
```

EventBus core validates the decoded CloudEvent passed to `accept/2`. Feishu
still validates provider-specific payloads, source config, target ids, media
constraints, card formats, and Feishu API responses.

`content_kinds` is a coarse transport capability list. Inbound decoded
CloudEvents still use `NormalizedCloudEvent` content part types such as
`image_url`, `video_url`, `file`, `card`, and `action`.

## Source runtime

For each enabled source, `Feishu.SourceSupervisor` starts a source-local runtime
boundary:

```text
Feishu.SourceSupervisor
  -> Feishu.Channel
     -> FeishuOpenAPI.WS.Client
```

`Feishu.Channel` owns the normalized source config, SDK client, event
dispatcher, card-action dispatcher wiring when enabled, source-local startup
logs, and source-local cache key prefixes.

Source process state is reconstructible. If a listener restarts, it reloads
source configuration, reconnects the WebSocket transport, rebuilds SDK state,
and relies on provider redelivery plus EventBus `(source, id)` dedupe. Cache
entries are runtime convenience only.

Feishu uses long-connection WebSocket event push for normal inbound events. The
SDK authenticates the connection and decodes pushed event frames. The first
implementation does not support Feishu event-subscription webhooks as normal
inbound transport.

Card actions may arrive through WebSocket event push or an HTTP callback
surface. HTTP callback routing belongs to the Web boundary. If a card-action
HTTP route is enabled, the route must identify the Feishu source, verify the
callback with Feishu card-action semantics before trusting the payload, and call
the same adapter normalization and `BullX.EventBus.accept/2` handoff used by
WebSocket occurrences.

The first HTTP callback route is:

```text
POST /eventbus/feishu/sources/:source_id/card_actions
```

The Web boundary preserves the raw request body for Feishu signature
verification, loads the enabled source by `source_id`, verifies the body through
`FeishuOpenAPI.CardAction.verify_and_decode/3`, and passes only the resulting
`%FeishuOpenAPI.CardAction{}` to the adapter. Raw decoded maps are not trusted
as card actions.

## Inbound normalization

Feishu normalizes one provider occurrence into one decoded string-keyed
CloudEvents JSON object. Provider batches are split before handoff, and
`BullX.EventBus.accept/2` is called once per occurrence.

CloudEvents attributes:

- `specversion` is `"1.0"`.
- `id` is a stable Feishu occurrence id inside the source. Use Feishu event id
  when present. Otherwise derive from immutable fields such as event type,
  message id, actor open id, card action id, action tag, emoji, and provider
  timestamp.
- `source` is a stable URI-like source string such as
  `feishu://main/tenant_xxx`. It must include enough source context to make
  `(source, id)` unique inside the Installation.
- `type` is a normalized BullX Event type such as
  `bullx.im.message.addressed`, `bullx.im.message.ambient`,
  `bullx.message.edited`, `bullx.message.recalled`,
  `bullx.reaction.changed`, `bullx.action.submitted`, or
  `bullx.command.invoked`.
- `time` is the Feishu occurrence time when trusted; otherwise it is adapter
  receive time.
- `datacontenttype` is `"application/json"`.
- `data` is the BullX normalized payload from
  `eventbus/NormalizedCloudEvent.md`.

Example message Event:

```json
{
  "specversion": "1.0",
  "id": "evt_xxx",
  "source": "feishu://main/tenant_xxx",
  "type": "bullx.im.message.addressed",
  "subject": "Feishu message om_xxx",
  "time": "2026-05-17T10:00:00Z",
  "datacontenttype": "application/json",
  "data": {
    "content": [
      {
        "type": "text",
        "text": "hello"
      }
    ],
    "channel": {
      "adapter": "feishu",
      "id": "main",
      "kind": "dm"
    },
    "scope": {
      "id": "oc_xxx",
      "thread_id": null
    },
    "actor": {
      "external_account_id": "feishu:ou_xxx",
      "display_name": "Alice",
      "principal": {
        "id": "optional-principal-id",
        "type": "human"
      }
    },
    "refs": [
      {
        "kind": "feishu.message",
        "id": "om_xxx"
      }
    ],
    "reply_channel": {
      "adapter": "feishu",
      "channel_id": "main",
      "scope_id": "oc_xxx",
      "thread_id": null,
      "reply_to_external_id": "om_xxx"
    },
    "routing_facts": {
      "provider_event_type": "im.message.receive_v1",
      "chat_type": "p2p",
      "content_kind": "text",
      "connected_realm_ref": "feishu:tenant_xxx"
    },
    "raw_ref": {
      "kind": "feishu.event",
      "id": "evt_xxx"
    }
  }
}
```

`subject` is display/debug text only. Feishu must not depend on it for routing.
Provider-specific matching data belongs in `data.routing_facts` or another
normalized field exposed by `RoutingContext`.

`raw_ref` is not a matcher surface. It may contain stable Feishu ids, a
provider raw reference, or a provider raw snapshot when the adapter needs it.
Credentials and bearer-like values still must not enter Events, telemetry, logs,
safe errors, Oban args, or stream metadata.

## Actor identity

Feishu actor ids are channel-local external ids. User-origin Events use:

```text
data.actor.external_account_id = "feishu:" <> open_id
```

`open_id` is required for Principal channel actor matching. If a payload
includes only `user_id` or `union_id`, the adapter should resolve `open_id`
through Feishu before publishing, activating, or issuing channel-auth login
codes. If `open_id` cannot be resolved for a user-origin Event, the adapter
fails closed with a safe error and does not create a Principal binding.

Trusted profile fields may include `display_name`, `avatar_url`, `email`,
`phone`, `open_id`, `union_id`, and `user_id`. The adapter lowercases and trims
email. It normalizes phone candidates to E.164 before passing them to
`BullX.Principals`; malformed or ambiguous phone values are omitted.
User-editable display names are presentation data, not identity proof.

Self-sent bot messages are ignored before content parsing, command
classification, Principal matching, or EventBus handoff. Feishu Events whose
sender type is
`bot` or `app` and whose sender matches the configured or resolved bot identity
must not re-enter EventBus as user Events. The self-sent check uses
`bot_open_id` when present and falls back to `bot_user_id` for payloads that do
not include the bot open id.

## Principal account gate

Before accepting normal user-origin message Events, Feishu calls
`BullX.Principals.match_or_create_human_from_channel/1` with the normalized
channel actor:

```elixir
%{
  adapter: :feishu,
  channel_id: "main",
  external_id: "feishu:ou_xxx",
  profile: %{
    "display_name" => "Alice",
    "email" => "alice@example.com",
    "open_id" => "ou_xxx"
  },
  metadata: %{
    "connected_realm_ref" => "feishu:tenant_xxx",
    "tenant_key" => "tenant_xxx",
    "chat_id" => "oc_xxx",
    "chat_type" => "p2p"
  }
}
```

Result handling:

| Principal result | Feishu behavior |
| --- | --- |
| `{:ok, principal, _identity}` | Normalize the Event, set `data.actor.principal` to the Principal id and type, and call `BullX.EventBus.accept/2`. |
| `{:error, :activation_required}` | Send localized activation guidance when appropriate and do not call EventBus. |
| `{:error, :principal_disabled}` | Send a localized denied reply when appropriate and do not call EventBus. |
| `{:error, reason}` | Treat as provider processing failure, emit safe telemetry, and do not call EventBus. |

Command-shaped input is not automatically a normal conversation message. When
Feishu classifies an accepted slash-text command as `bullx.command.invoked`, the
adapter may publish the command Event with actor evidence and
`data.actor.principal = null` if no active Principal binding exists yet.
System commands such as `/command` and `/status`, and AIAgent-owned slash
commands such as `/new`, `/stop`, and `/steer`, use that path. Channel
activation and login commands such as `/preauth` and `/web_auth` are
adapter-local entry points and may be handled before EventBus. For EventBus
commands, the adapter still does not choose the command handler, decide command
authorization, or write command business facts.

Principal resolution is identity evidence, not authorization. Downstream
Principal, AuthZ, Governance, Capability, Target, and business layers still
decide permission, budget, approval, and side effects.

In group chats, activation-required replies must not include activation codes,
login auth codes, or OIDC links that reveal account state. The reply should ask
the user to message the bot privately. In `p2p` chats, the adapter may include
localized `/preauth <code>` and `/web_auth` guidance.

## Event mapping

Feishu maps provider occurrences to normalized BullX Event types:

| Feishu occurrence | Normalized `type` | Notes |
| --- | --- | --- |
| `im.message.receive_v1` | `bullx.im.message.addressed`, `bullx.im.message.ambient`, or `bullx.command.invoked` | Accepted EventBus slash-style text commands become command Events. Adapter-local `/preauth` and `/web_auth` are handled before EventBus. Addressed text becomes an addressed IM Event; observed unmentioned group text becomes an ambient IM Event only when the source listens to all messages. |
| Message update | `bullx.message.edited` | `refs` includes the Feishu message id. |
| Message recall | `bullx.message.recalled` | Use source cache or provider lookup for missing chat context. |
| Reaction create/delete | `bullx.reaction.changed` | `routing_facts.reaction_action` is `added` or `removed`. |
| Interactive card action | `bullx.action.submitted` | CloudEvent id uses Feishu callback token when present; otherwise it is derived from message id, action id, and actor open id. Sanitized action values stay in `data.content` as structured Event facts. Routing facts include only stable non-private action identifiers. |

Provider-specific names stay in `routing_facts.provider_event_type`, for example
`im.message.receive_v1` or `card.action`. EventBus core must not maintain a
Feishu event-name allowlist.

## Content mapping

Text and post messages produce text content blocks. Mentions of the BullX bot
may be removed from the primary text while stable mention references remain in
`refs` or normalized metadata. Sticker, emotion, and emoji-only messages
produce deterministic text fallback.

Images produce `image_url` content blocks with `fallback_text`. Audio, video,
and generic files produce `file` or `video_url` content blocks with
`media_type` and `fallback_text`. Small downloaded media may be embedded as
`data:` URIs only when under `inline_media_max_bytes` and when doing so does not
violate provider or operator policy. Large or unavailable media uses a stable
`feishu://message-resource/...` URI plus Feishu ids in `refs`. No local
filesystem path enters an Event.

Interactive card messages produce card content with safe fallback text for
AIAgent transcript rendering:

```elixir
%{
  "type" => "card",
  "format" => "feishu.card",
  "fallback_text" => safe_card_summary,
  "payload" => sanitized_card_json
}
```

Card-action callbacks produce `action` content. `text` is the safe
human-readable transcript summary; `action_id` and sanitized `values` remain
structured Event facts and must not be expanded into ordinary dialogue text.
When an Event Routing Rule sends `bullx.action.submitted` to an AIAgent Target,
AIAgent uses only this text projection as the user-turn transcript.

The adapter must not publish empty `data.content` for a user-origin Event. If a
machine-only provider occurrence has no user-facing body, the adapter
synthesizes a short text block so the EventBus payload contract remains valid.

## Channel command normalization

Feishu distinguishes EventBus commands from adapter-local channel commands. When
an accepted Feishu text message begins with a slash command token, the adapter
normalizes it as `bullx.command.invoked` instead of an IM message Event, except
for adapter-local channel commands described below. English `/command` and
`/status`, localized aliases such as Chinese `/命令` and `/状态`, and
AIAgent-owned slash commands all use the same normalized command Event shape.

`/preauth <code>` and `/web_auth` are channel activation/login commands. The
Feishu adapter handles them locally through Principal/Auth services and safe
Feishu replies, because they may need to run before a Principal binding exists
and may use provider-private reply context. They are not published to EventBus
as `bullx.command.invoked`.

Command normalization runs after source lookup, transport verification,
self-sent bot filtering, attention policy, and safe command-token parsing.
Feishu stores only matcher-oriented facts in `data.routing_facts`:

- `command_name`, the canonical English command name without the leading slash;
- `command_namespace`, when the command grammar or source configuration defines
  one;
- `command_surface = "slash_text"`;
- `command_args_kind`, such as `none` or `text`;
- `attention_reason`.

Command argument text may appear in normalized content only when the relevant
command design allows it. Activation codes, login codes, callback secrets, and
provider credentials must not enter EventBus `routing_facts`, telemetry, or logs.

The Event Routing Rule decides the Target for EventBus commands. System command
routes for `/command` and `/status` target `target_type = "command"` through
code-owned built-ins merged into the runtime route table. AIAgent conversation
commands such as canonical `/new`, `/stop`, and `/steer` can match an explicit
`target_type = "ai_agent"` command route. If no explicit command route matches,
EventBus command fallback may route the original `bullx.command.invoked`
CloudEvent through the addressed-message route for the same chat and thread.
Localized `/新会话` is an alias for canonical `/new`, not a separate routing
concept. The Feishu adapter must not mutate Conversation, Message, or generation
lease state directly.

Provider redelivery of the same EventBus command message reuses the same
CloudEvents `(source, id)` based on the Feishu message occurrence. Duplicate
visible replies are prevented by EventBus dedupe and Command Target idempotency,
not by an adapter-local command execution cache. Adapter-local `/preauth` and
`/web_auth` flows use their own Principal/Auth idempotency and safe reply rules.

## AIAgent conversation path

This path checks that the Feishu adapter composes with EventBus, Event Routing
Rules, an `ai_agent` Target, LLMProvider, ToolSet execution, and outbound or
stream transport. It is not adapter-owned business logic. Feishu does not choose
the Target, create TargetSessions, call the model, persist Conversation
Messages, or decide whether an AIAgent may speak in a chat.

1. An operator enables one Feishu source. The plugin starts its source runtime
   and registers the `"feishu"` Channel Adapter.
2. The operator creates or enables an Agent Principal, gives that AIAgent a
   model spec such as `openai_proxy:gpt-5.4`, enables any required ToolSets, and
   grants the relevant Human Principals access through AuthZ.
3. The operator creates Event Routing Rules for Feishu message Events, and may
   also route `bullx.action.submitted` when card actions should continue the
   same AIAgent Conversation. Matching rules use `target_type = "ai_agent"` and
   `target_ref = <agent principal id>`. Each rule chooses the TargetSession
   scope/window fields for the Feishu chat, thread, or action surface.
4. A Human Principal sends a message to the Feishu bot. The adapter verifies the
   provider occurrence, drops self-sent bot messages, records actor evidence,
   normalizes the occurrence into a decoded CloudEvents JSON object with
   `data.content`, `data.channel`, `data.scope`, `data.actor`, `data.refs`,
   `data.reply_channel`, and `data.routing_facts`, then calls
   `BullX.EventBus.accept/2`.
5. EventBus validates the Event, applies the first matching Event Routing Rule,
   creates or reuses the TargetSession, appends one side-channel entry, ensures
   the TargetSession worker exists, and returns accepted or duplicate handoff
   status. The Feishu adapter acknowledges Feishu after that handoff result; it
   does not wait for AIAgent execution.
6. The AIAgent Target handles the side-channel entry, derives its
   `conversation_key` from normalized channel/scope/thread inputs, deduplicates
   the inbound Message by `target_session_entry_id`, renders prompt context from
   its own Conversation state and profile, resolves the model through
   LLMProvider, and runs its model/tool loop.
7. If the model calls a BullX-owned tool such as `web.search`, AIAgent records
   the assistant tool call, executes the tool through its Core dispatcher with
   Principal and idempotency context, records matching tool results, and gives
   provider-valid tool results to the next model turn.
8. When final assistant content exists, AIAgent records it as Conversation
   history. If its reply policy allows visible output and `data.reply_channel`
   is usable, it asks the Feishu adapter to send via `deliver/4` or consume an
   EventBus output stream via `consume_stream/4`.
9. A later Feishu message in the same chat/thread repeats the same transport and
   EventBus path. A new TargetSession may be created, but AIAgent can still
   derive the same conversation key and continue from its own active
   Conversation branch.
10. Canonical `/new` and localized `/新会话` remain AIAgent conversation
    controls when routed to AIAgent-owned command handling or left as ordinary
    AIAgent text. The Feishu adapter must not mutate Conversation, Message, or
    generation lease state.

The path is complete only when the chosen AIAgent runtime, model provider,
ToolSets, Event Routing Rule, and Feishu outbound mode are implemented. The
adapter side of the guarantee is the normalized Event handoff plus optional
delivery/stream transport.

## Feishu OIDC login provider

`Feishu.OIDCProvider` implements the Principal login-provider hook for Human
browser login. If the host hook is missing when this design is implemented, add
the minimal Principal-owned behavior and registry lookup required for this
plugin.

Suggested host behavior:

```elixir
defmodule BullX.Principals.LoginProvider do
  @callback authorization_url(source :: map(), opts :: map()) ::
              {:ok, %{url: String.t(), state: map()}} | {:error, map()}

  @callback callback(source :: map(), params :: map(), state :: map()) ::
              {:ok, login_subject :: map()} | {:error, map()}
end
```

The Web login controller receives a provider id from the login route. For
Feishu, that provider id is the enabled source id. The controller loads the
source, verifies `adapter = "feishu"` and `oidc.enabled = true`, resolves the
Feishu login-provider implementation, asks it for an authorization URL, signs
provider state with Phoenix token infrastructure, and redirects the browser.

Callback flow:

1. Reject the source when `web_login_disabled = true`.
2. Verify signed state, source id, adapter, nonce, age, and local `return_to`.
3. Exchange the Feishu authorization `code` through
   `FeishuOpenAPI.Auth.user_access_token/3`.
4. Fetch userinfo through the SDK with the returned user access token.
5. Normalize a Principal login subject.
6. Discard the Feishu user access token and refresh token.
7. Pass the login subject to `BullX.Principals` for matching and session
   establishment.

Login subject shape:

```elixir
%{
  provider: "main",
  external_id: "feishu:ou_xxx",
  profile: %{
    "display_name" => "Alice",
    "email" => "alice@example.com",
    "phone" => "+8613800000000",
    "avatar_url" => "https://...",
    "open_id" => "ou_xxx",
    "union_id" => "on_xxx",
    "user_id" => "u_xxx"
  },
  metadata: %{
    "adapter" => "feishu",
    "channel_id" => "main",
    "app_id" => "cli_xxx",
    "tenant_key" => "tenant_xxx",
    "domain" => "feishu",
    "connected_realm_ref" => "feishu:tenant_xxx"
  }
}
```

`provider = "main"` is the Feishu source id. Multiple Feishu or Lark
organizations may be configured as different sources, each with its own source
id, app credential, domain, tenant metadata, and OIDC setting. The Principal
`login_subject` provider namespace is therefore the source id, not `"feishu"`
and not the Feishu app id.

If userinfo lacks `open_id`, login fails closed without creating or binding a
Principal. `Feishu.OIDCProvider` must not write `principal_external_identities`
directly. On `{:error, :not_bound}`, the Web surface should direct the user to
activate from Feishu with `/preauth <code>`. On `{:error, :principal_disabled}`
or `{:error, :not_human}`, it fails closed.

## Outbound delivery

Feishu outbound delivery executes upstream-approved transport requests. The
adapter does not decide whether an AIAgent, Workflow, Human, Capability, or
business layer may speak in a Feishu chat, edit a Feishu message, upload media,
or stream a card. Principal, AuthZ, Budget, policy, approval, and durable
business-record checks happen before the adapter is called.

`Feishu.ChannelAdapter.deliver/4` supports send and edit in the first
implementation.

Targeting rules:

- `reply_channel.scope_id` is the Feishu chat id.
- `reply_channel.thread_id` is passed when the Feishu endpoint supports thread
  targeting.
- `reply_channel.reply_to_external_id` sends a Feishu reply when present.
- Without `reply_to_external_id`, the adapter sends to `scope_id`.

Content rules:

- `text` sends Feishu text or post content.
- `card` with `format = "feishu.card"` or `format = "feishu.card.v2"` sends an
  interactive card.
- `image_url`, `video_url`, `image`, and `file` upload native media when the
  content URI or embedded data is readable and provider limits permit it.
- Unsupported rich combinations degrade to one localized or fallback text
  message when possible. If no safe fallback exists, the adapter returns a
  non-retryable safe error.

If Feishu reports that a reply target was recalled or missing, including known
codes such as `230011` or `231003`, the adapter may retry once as a normal chat
send to `reply_channel.scope_id`. A successful fallback returns a degraded result
with a warning such as `"reply_target_missing_sent_to_scope"`. If `scope_id` is
missing, the adapter returns a payload error.

Edit requires the target Feishu message id. Feishu supports editing text/post
message content and interactive card content in the first implementation.
Unsupported edit content returns a non-retryable payload or unsupported error.
Missing or uneditable target messages map to payload, unsupported, or not-found
errors, not network errors.

## CardKit stream transport

Feishu streaming uses CardKit through `Feishu.ChannelAdapter.consume_stream/4`.
The adapter consumes the EventBus stream buffer APIs; it does not create stream
chunks, inspect Target internals, infer business completion, or write
Conversation transcripts.

Flow:

1. Create or update a Feishu card with one streaming text element.
2. Call `resume_stream/2` with the upstream `stream_id` and last delivered
   offset.
3. Emit buffered chunks in offset order.
4. When `follow?` is true, call `follow_stream/3` and mirror chunk pointer
   callbacks into Feishu card updates.
5. Throttle provider updates by `stream_update_interval_ms`.
6. On terminal stream status, finalize the card with streaming disabled.

The adapter treats client disconnect, Feishu update failure, and provider rate
limit as transport consumer behavior. It does not stop the stream producer. If a
stream cannot be resumed because Redis runtime state is missing or expired, the
adapter returns a safe unavailable or no-content result.

On stream error or cancellation observed by the adapter, Feishu attempts one
final card update with localized failure text and then returns the original
normalized safe error to the caller.

## Error mapping

`Feishu.Error` maps SDK and Feishu API failures into JSON-neutral, string-keyed
safe errors:

```elixir
%{
  "kind" => "rate_limit",
  "message" => "Feishu API rate limited",
  "details" => %{
    "retry_after_ms" => 3000,
    "code" => 99991400,
    "log_id" => "..."
  }
}
```

Mapping rules:

| Condition | Error kind |
| --- | --- |
| HTTP 429 or Feishu rate-limit code | `rate_limit` |
| HTTP 401/403, rejected app credentials, rejected tenant token | `auth` |
| Missing Feishu permission or app scope | `permission` |
| Timeout, DNS, TLS, WebSocket disconnect, temporary provider outage | `network` or `provider_unavailable` |
| Invalid source config or missing credential profile | `config` |
| Invalid content, missing target, malformed callback, unavailable stream content | `payload` |
| Unsupported Feishu operation or content with no fallback | `unsupported` |
| Missing or disabled Principal where required | `principal` |
| Unknown Feishu API error | `unknown` |

`details` may include Feishu `code`, `log_id`, retry hints, redacted endpoint
context, and safe source diagnostics. It must not include secrets, tokens,
OAuth codes, raw message bodies, raw callback payloads, private card values,
attachment bytes, full Events, or stream chunks.

The adapter must not invent EventBus core errors such as
`%BullX.EventBus.InvalidEvent{}` or `%BullX.EventBus.AppendFailed{}`. It may
return those values only when `BullX.EventBus.accept/2` returned them.

## Telemetry and logs

Feishu uses the Channel Adapter telemetry prefix from `ChannelAdapter.md` and
may add provider-specific suffixes under the same namespace:

- `[:bullx, :event_bus, :adapter, :source, :started]`
- `[:bullx, :event_bus, :adapter, :event, :received]`
- `[:bullx, :event_bus, :adapter, :event, :ignored]`
- `[:bullx, :event_bus, :adapter, :event, :normalized]`
- `[:bullx, :event_bus, :adapter, :event, :accept, :start]`
- `[:bullx, :event_bus, :adapter, :event, :accept, :stop]`
- `[:bullx, :event_bus, :adapter, :delivery, :start]`
- `[:bullx, :event_bus, :adapter, :delivery, :stop]`
- `[:bullx, :event_bus, :adapter, :stream, :start]`
- `[:bullx, :event_bus, :adapter, :stream, :stop]`
- `[:bullx, :event_bus, :adapter, :feishu, :oidc, :callback]`
- `[:bullx, :event_bus, :adapter, :feishu, :command, :normalized]`

Allowed metadata includes adapter id, plugin id, source id, provider event type,
normalized Event type, hashed Event source, hashed Event id, scope id, thread
id, actor external id hash, provider request id, ignore reason, EventBus
acceptance status, Event Routing Rule id, TargetSession id, stream id, offset,
diagnostic code, retry delay, Feishu API code, Feishu `log_id`, and provider
HTTP status code.

Logs are part of the manual-run contract. Startup, WebSocket connection,
inbound mapping, command normalization, EventBus acceptance, outbound delivery,
stream consumption, and OIDC callback paths should emit safe structured log
lines. Logs must not include secrets, tokens, OAuth codes, raw message bodies,
raw callback payloads, private card values, attachment bytes, full
`reply_channel`, full Events, or stream chunks.

## I18n

All human-facing Feishu text uses `BullX.I18n` and the application-global
locale. The adapter does not choose locale from Feishu tenant, user profile,
`Accept-Language`, or browser settings.

Add at least these keys in supported locales:

```toml
[eventbus.feishu.auth]
activation_required = "..."
denied = "..."
login_not_bound = "..."

[eventbus.feishu.delivery]
fallback_text = "..."
stream_generating = "..."
stream_failed = "..."
stream_cancelled = "..."
reply_target_missing_sent_to_scope = "..."

[eventbus.feishu.errors]
unsupported_message = "..."
profile_unavailable = "..."
```

Tests must fail if a key used by the adapter is missing in any bundled locale.

## Security and privacy

Feishu transport authenticity is adapter-owned. WebSocket event push relies on
`FeishuOpenAPI.WS.Client` authentication and SDK frame decoding. HTTP
card-action callbacks, when enabled, must be verified by card-action callback
semantics before the payload is trusted.

The adapter must:

- drop self-sent bot messages before EventBus handoff;
- preserve channel, scope, chat type, actor, and safe command facts so
  adapter-local `/preauth <code>` and `/web_auth` handlers can reject group-chat
  use without consuming or issuing secrets;
- reject Feishu OIDC login when source-level web login is disabled;
- verify HTTP card-action callback raw bodies before converting them to
  `%FeishuOpenAPI.CardAction{}`;
- validate OIDC state, nonce, source id, age, and local `return_to`;
- discard Feishu user tokens after userinfo retrieval;
- keep Feishu access tokens, refresh tokens, app secrets, OAuth codes, raw
  callback bodies, raw event payloads, unsanitized card private values, and
  attachment bytes out of Events, telemetry, logs, errors, stream metadata, and
  provider receipts;
- keep provider credential values in `BullX.Config` secret storage;
- keep provider ids as external evidence and let `BullX.Principals` own durable
  identity decisions.

Feishu outbound delivery may be customer-facing. The adapter assumes the
transport request already passed the necessary upstream authorization and
business-record boundaries. The adapter must not add a shortcut that lets
direct Feishu API calls bypass the adapter delivery contract for business
effects.

## Failure behavior

Provider verification failures, malformed callbacks, missing required Feishu
fields, missing credential profiles, and unsupported content fail closed. They
produce redacted telemetry and safe logs.

For inbound occurrences, the adapter acknowledges Feishu only when one of these
conditions is true:

- the occurrence was intentionally ignored, such as a self-sent bot message;
- `BullX.EventBus.accept/2` returned accepted, duplicate, or accepted_ignored;
- the provider requires a terminal response for a non-retryable malformed
  occurrence and retry would not produce a valid Event.

Retryable errors include rate limiting, network failures, timeouts, temporary
provider unavailability, and transient EventBus append failures when the
provider supports retry. Auth, permission, payload, unsupported, malformed
target, invalid event shape, and no-match outcomes are terminal unless Feishu or
EventBus supplies a specific retry hint.

Process-local state is reconstructible. If `Feishu.Channel` restarts, it
reconnects WebSocket transport and rebuilds cache entries opportunistically.
EventBus and Principal durable facts remain in PostgreSQL. Feishu cache loss
must not invent missing business facts.

## Implementation handoff

### Goal

Implement the Feishu adapter plugin as one trusted plugin that exposes Feishu
EventBus Channel Adapter transport and Feishu Principal browser login while
preserving the current Plugin, EventBus, Channel Adapter, StreamingOutput, and
Principal boundaries.

### Context pointers

- `AGENTS.md`
- `docs/Architecture.md`
- `docs/design-docs/Plugins.md`
- `docs/design-docs/Principal.md`
- `docs/design-docs/eventbus/ChannelAdapter.md`
- `docs/design-docs/eventbus/CommandTarget.md`
- `docs/design-docs/eventbus/Core.md`
- `docs/design-docs/eventbus/Matcher.md`
- `docs/design-docs/eventbus/StreamingOutput.md`
- `packages/feishu_openapi/README.md`
- `packages/feishu_openapi/lib/feishu_openapi/`

### Constraints

- Put plugin code under `plugins/feishu`.
- Use plugin id `"feishu"` and Channel Adapter id `"feishu"`.
- Use `BullX.EventBus.ChannelAdapter`, not a provider-specific routing
  contract.
- Use `BullX.EventBus.accept/2`, not a second publish path.
- Use plugin config keys under `bullx.plugins.feishu.*`.
- Use the Feishu source id as `data.channel.id`, Principal `channel_id`, and
  concrete Feishu OIDC `login_subject.provider`.
- Use `BullX.Principals`, not provider-owned account tables.
- Use `FeishuOpenAPI`; do not add another Feishu dependency.
- Store plugin secrets through `BullX.Config`; do not persist Feishu user
  tokens.
- Do not change EventBus matcher, TargetSession side-channel behavior,
  TargetSession Oban job behavior, Target dispatch, or business persistence to
  fit Feishu.
- Do not add Principal ids to Events unless they came from `BullX.Principals`.
- Do not add plugin-specific persistence tables unless a later design proves
  source state cannot be reconstructed.

### Tasks

1. Add the Feishu plugin skeleton.
   - Owns: `plugins/feishu/mix.exs`, `Feishu.Plugin`, plugin tests.
   - Depends on: plugin host implementation.
   - Acceptance: BullX discovers plugin id `"feishu"` and both extension
     declarations when the plugin is compiled.
   - Verify: plugin discovery and registry tests.

2. Add Feishu plugin configuration.
   - Owns: `Feishu.Config`, source/credential casters, redaction helpers, and
     secret-key tests.
   - Depends on: Task 1.
   - Acceptance: `bullx.plugins.feishu.credentials` is secret,
     card-action verification secrets stay in credential profiles,
     `eventbus_sources` validates enabled sources, source ids are stable, and
     public projections never reveal credentials.
   - Verify: config and secret writer tests.

3. Add the Principal login-provider host contract if missing.
   - Owns: `BullX.Principals.LoginProvider`,
     `BullX.Principals.LoginProviders`, and generic Web login dispatch only if
     the current Web slice needs it.
   - Depends on: plugin registry.
   - Acceptance: an enabled Feishu source id can be used as the Web login
     provider id and dispatched to `Feishu.OIDCProvider`.
   - Verify: registry and controller tests with a fake provider.

4. Implement `Feishu.OIDCProvider`.
   - Owns: `Feishu.OIDCProvider`, OIDC state/profile tests.
   - Depends on: Tasks 2 and 3.
   - Acceptance: authorization URL generation and callback normalization produce
     a valid Principal login subject with provider set to the source id,
     discard tokens, respect source-level web login disablement, and fail
     closed without `open_id`.
   - Verify: fake `FeishuOpenAPI` or `Req.Test` callback tests.

5. Implement Feishu source connectivity and adapter capabilities.
   - Owns: `Feishu.Source`, `Feishu.ChannelAdapter`, `Feishu.Error`.
   - Depends on: Task 2.
   - Acceptance: capabilities are precise, connectivity checks credentials
     without starting source listeners, and responses contain only safe metadata.
   - Verify: source and adapter unit tests.

6. Implement inbound runtime and normalization.
   - Owns: `Feishu.SourceSupervisor`, `Feishu.Channel`,
     `Feishu.EventMapper`, `Feishu.ContentMapper`,
     `Feishu.CardActionController`, and the generic raw-body reader needed for
     callback signature verification.
   - Depends on: Task 5.
   - Acceptance: WebSocket and card-action occurrences normalize to valid
     decoded CloudEvents for message, edited message, recalled message,
     reaction, action, and command Events.
   - Verify: event-mapping tests and `BullX.EventBus.accept/2` integration tests
     with a fake EventBus or route table.

7. Implement Principal account gate and command normalization.
   - Owns: `Feishu.CommandNormalizer`, locale keys, Principal fixtures.
   - Depends on: Tasks 4 and 6.
   - Acceptance: normal user-origin Events call Principal matching before
     EventBus acceptance; accepted EventBus slash-text commands normalize to
     `bullx.command.invoked` with actor evidence, optional `actor.principal`, and
     command routing facts; `/preauth` and `/web_auth` run as adapter-local
     channel activation/login commands.
   - Verify: focused command-normalization and Principal integration tests.

8. Implement outbound send and edit.
   - Owns: `Feishu.Outbound`, content rendering, media upload, reply fallback,
     and outbound error mapping.
   - Depends on: Task 5.
   - Acceptance: send/edit return adapter-compatible sent, degraded, or safe
     error results; reply fallback behavior matches this design.
   - Verify: outbound tests with fake SDK responses.

9. Implement CardKit stream consumption.
   - Owns: `Feishu.StreamingCard`.
   - Depends on: EventBus streaming APIs from `StreamingOutput.md`.
   - Acceptance: Feishu consumes buffered chunks first, follows live pointer
     notifications, throttles card updates, finalizes terminal cards, and does
     not inspect Target internals or write transcripts.
   - Verify: stream transport tests with fake stream buffer and fake Feishu SDK.

10. Add telemetry, logs, locale coverage, and privacy tests.
    - Owns: Feishu modules and locale files.
    - Depends on: Tasks 4 through 9.
   - Acceptance: safe telemetry/log metadata exists for startup, inbound,
      command normalization, EventBus acceptance, delivery, streaming, and OIDC paths;
      locale tests fail on missing keys; secrets and raw payloads never appear
      in logs or safe errors.

### Stop and ask

Implementation should stop and ask if a change would require:

- routing on data that cannot be normalized into `routing_facts` or another
  explicit `RoutingContext` field;
- provider raw payload retention that needs a new retention, redaction, or access
  control rule;
- provider acknowledgement waiting for Target execution or business
  persistence;
- persistent Feishu user tokens, refresh tokens, app tickets, marketplace app
  support, or a new credential store;
- authorization, approval, or business-record decisions inside the adapter;
- EventBus route topology, TargetSession behavior, or Target internals as a
  Feishu-specific contract;
- source supervision outside plugin children;
- plugin-specific persistence tables.

### Done when

- `plugins/feishu` compiles as a BullX plugin.
- The plugin registers `:"bullx.event_bus.channel_adapter"` id `"feishu"`.
- The plugin registers the Feishu `:"bullx.principals.login_provider"`
  implementation, and enabled Feishu source ids route to it as concrete login
  provider ids.
- Feishu source config and plugin credentials validate through `BullX.Config`.
- Connectivity checks verify app credentials without starting a source listener
  or leaking secrets.
- Enabled Feishu sources start WebSocket listeners under plugin supervision.
- Feishu card-action HTTP callbacks verify raw request bodies before adapter
  handoff.
- Feishu inbound occurrences normalize into valid decoded CloudEvents and call
  `BullX.EventBus.accept/2`.
- Accepted Feishu slash-text commands publish `bullx.command.invoked` Events
  with command routing facts and no adapter-owned EventBus command business side
  effects. System commands match built-in Command Target routes; AIAgent-owned
  commands may use explicit AIAgent command routes or EventBus command fallback
  to the matching addressed route.
- Feishu `/preauth` and `/web_auth` run as adapter-local channel
  activation/login commands and do not publish EventBus command Events.
- Feishu OIDC callback logs in or creates only Human Principals according to
  `BullX.Principals` matching rules.
- Feishu outbound send, edit, and stream paths produce adapter-compatible
  outcomes or safe errors.
- Self-sent bot messages are filtered before EventBus handoff.
- Raw provider payloads, secrets, tokens, OAuth codes, unsanitized private card
  values, attachment bytes, and stream chunks do not enter telemetry, logs,
  safe errors, Events, `routing_facts`, `reply_channel`, Oban args, or stream
  metadata.
- No provider-owned routing layer, provider-owned identity system, or Feishu
  compatibility shim is introduced.

Verification commands:

```bash
mix format --check-formatted
# focused tests for plugin discovery, config, Principal login provider,
# source connectivity, inbound normalization, command normalization, delivery,
# stream transport, telemetry, logging, and locale coverage
MIX_ENV=test mix compile --warnings-as-errors
bun precommit
```
