# Feishu adapter

The Feishu integration is a trusted BullX plugin under `plugins/feishu`. It
contributes two extension declarations: a `:"bullx.gateway.adapter"` source for
Signals Gateway inbound and outbound transport, and a Feishu
`:"bullx.principals.login_provider"` implementation for Human Principal OIDC
login. The plugin uses the existing `packages/feishu_openapi` SDK and does not
port the old `BullXGateway`, `BullXAccounts`, or Jido-era architecture.

## Scope

This design covers the Feishu/Lark plugin adapter:

- plugin placement, metadata, extension declarations, and plugin-owned runtime
  configuration;
- Gateway source configuration, connectivity checks, WebSocket source
  supervision, card-action callbacks, inbound normalization, account gating, and
  outbound send, edit, and stream delivery;
- built-in BullX direct commands implemented over Feishu messages for local
  connectivity and Principal activation: `/ping`, `/preauth <code>`, and
  `/web_auth`;
- Feishu OIDC browser login for Human Principals through a Principal login
  provider hook;
- Feishu-specific content mapping, actor normalization, error mapping,
  telemetry, logging, security, tests, and implementation handoff.

This design depends on `docs/design-docs/Plugins.md`,
`docs/design-docs/Principal.md`, and `docs/design-docs/SignalsGateway.md` for
the host contracts. It specializes those contracts for Feishu instead of
redefining them.

## Goals

- Keep Feishu out of BullX core modules by shipping it as one plugin under
  `plugins/feishu`.
- Expose Feishu transport through the Gateway adapter extension point with
  inbound and outbound support.
- Expose Feishu Human login through a Principal-owned login-provider extension
  point.
- Reuse `FeishuOpenAPI` for OpenAPI calls, token fetch, envelope decoding,
  WebSocket event push, and card-action callback handling.
- Keep Gateway actor data channel-local until `BullX.Principals` resolves,
  creates, or activates a Human Principal.
- Preserve Gateway transport boundaries: Feishu may produce normalized Signals
  and execute authorized Deliveries, but it does not create Admission, Work,
  Intents, Effects, Outcomes, or Brain facts.
- Keep provider secrets, access tokens, raw provider payloads, private adapter
  config, and OAuth codes out of telemetry, logs, error details, receipts, and
  dead-letter summaries. Normalized Gateway content may enter Signals,
  Deliveries, Mailbox jobs, and replayable dead letters according to the Gateway
  contract; those storage surfaces are operator-sensitive.

## Non-goals

- Do not add Feishu modules under `lib/bullx/` or `lib/bullx_web/` except for
  generic host surfaces needed by plugin hooks.
- Do not recreate old `BullXGateway`, `BullXAccounts`, RFC 0002/0003, or Jido
  abstractions.
- Do not add runtime plugin installation, hot plugin enablement, hook priority,
  or plugin-specific persistence tables.
- Do not implement a general OAuth/OIDC framework beyond the Principal
  login-provider hook required for this plugin.
- Do not persist Feishu user access tokens, refresh tokens, app tickets, raw
  events, raw callback bodies, or downloaded media as durable BullX facts.
- Do not make Feishu setup UI, route topology, or app marketplace behavior the
  source of Gateway or Principal architecture.
- Do not publish Feishu lifecycle, app ticket, presence, typing, or modal-close
  events as Signals by default.
- Do not support Feishu marketplace apps in the first implementation. The first
  plugin version supports self-built Feishu/Lark apps.

## Cleanup plan

- **Dead code to delete:** none. The current branch has no live Feishu adapter.
  Do not copy deleted legacy namespaces or compatibility shims into the new
  branch.
- **Duplicate logic to merge:** do not introduce Feishu-specific HTTP,
  signature, token, cache, or identity infrastructure when `FeishuOpenAPI`,
  `BullX.Cache`, `BullX.Gateway`, and `BullX.Principals` already own those
  concerns.
- **Existing utilities and patterns to reuse:** use `BullX.Plugins.Plugin`,
  `BullX.Gateway.Adapter`, `BullX.Gateway.SourceConfig`,
  `BullX.Gateway.publish/2`, `BullX.Gateway.normalize_inbound/4`,
  `BullX.Principals`, `BullX.Config`, `BullX.Cache`, `BullX.I18n`,
  `BullX.Ext`, `BullX.Retry`, and `FeishuOpenAPI`.
- **Code paths and contracts changing:** add `plugins/feishu`, a Principal
  login-provider extension contract if it is not already present, Feishu
  plugin configuration declarations, Feishu Gateway adapter modules, optional
  generic Web login routes that dispatch through the Principal login-provider
  hook, Feishu locale keys, and focused tests.
- **Invariants that must remain true:** plugin state is reconstructible;
  PostgreSQL remains durable truth; Gateway actors remain channel-local;
  Principal matching owns Human identity decisions; plaintext activation and
  login codes are never stored; Feishu tokens, secrets, and raw provider
  payloads never enter Gateway payloads; outbound Delivery is assumed already
  authorized before the Gateway invokes Feishu.
- **Verification command:** run focused Feishu, Gateway adapter, Principal login
  provider, and Web login tests, then run `bun precommit`.

## Existing context

`docs/design-docs/Plugins.md` defines plugins as compile-time trusted Mix
projects discovered from `plugins/*`. The plugin host registers declarations
from all discovered plugins and starts children only for enabled plugins.

`docs/design-docs/SignalsGateway.md` defines Gateway adapters as plugin
extensions under `:"bullx.gateway.adapter"`. Gateway configured sources live in
`bullx.gateway.sources`, not a provider-specific table. A configured source is
identified by `{adapter, channel_id}` after case folding. For Feishu,
`channel_id` is the source slug and must be globally unique inside the BullX
Installation because it can be used as both the Gateway source id and the
Principal OIDC login provider id.

`docs/design-docs/Principal.md` defines Human login and channel identity through
`BullX.Principals`. Feishu channel actors use
`principal_external_identities(kind = channel_actor)`. Feishu OIDC login uses
`principal_external_identities(kind = login_subject)`. The adapter supplies
trusted external identity claims; `BullX.Principals` decides whether they bind,
create, activate, or reject a Human Principal.

The old main-branch Feishu RFC remains useful only for Feishu mechanics:
WebSocket event push, card callbacks, `/preauth`, `/web_auth`, `/ping`, OIDC
userinfo normalization, Feishu content mapping, streaming cards, error mapping,
and safe logging. Its old namespace, account model, Gateway model, setup model,
and RFC dependencies are not implementation sources for this branch.

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
        point: :"bullx.gateway.adapter",
        id: "feishu",
        module: Feishu.GatewayAdapter
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
end
```

The plugin should not start a plugin-wide supervisor child in the first
implementation. Gateway source listeners start through
`Feishu.GatewayAdapter.source_child_spec/1` under
`BullX.Gateway.SourceSupervisor`. This keeps the transport failure boundary in
Gateway source supervision instead of making the plugin host a transport
supervisor.

The login-provider extension id `"feishu"` names the implementation type, not
the persisted Principal provider value for Feishu OIDC identities. At runtime,
each enabled Feishu source with OIDC enabled exposes its source slug
(`channel_id`) as the login provider id.

Suggested module ownership:

| Module | Responsibility |
| --- | --- |
| `Feishu.Plugin` | Plugin metadata, config modules, and extension declarations. |
| `Feishu.Config` | Plugin-owned `BullX.Config` declarations and config casters. |
| `Feishu.GatewayAdapter` | `BullX.Gateway.Adapter` implementation. |
| `Feishu.Source` | Runtime Feishu source config normalization and redaction. |
| `Feishu.Channel` | Per-source WebSocket runtime process and SDK dispatcher wiring. |
| `Feishu.EventMapper` | Feishu event and card-action payload normalization. |
| `Feishu.ContentMapper` | Feishu message and card content to Gateway content blocks. |
| `Feishu.DirectCommand` | Feishu transport implementation of built-in `/ping`, `/preauth`, and `/web_auth` direct commands. |
| `Feishu.Delivery` | Feishu send, edit, upload, reply fallback, and CardKit calls. |
| `Feishu.StreamingCard` | Streaming card state, throttled updates, and finalization. |
| `Feishu.OIDCProvider` | Principal login-provider callback implementation. |
| `Feishu.Error` | SDK and Feishu API error normalization. |

Do not add a `Feishu.API` wrapper in the first implementation. Adapter modules
call `FeishuOpenAPI.get/3`, `post/3`, `patch/3`, `upload/3`, and `download/3`
directly and route failures through `Feishu.Error`.

## Runtime configuration

Operators enable the plugin through `bullx.enabled_plugins`:

```json
["feishu"]
```

Feishu credentials live in plugin configuration so the plugin can declare the
secret shape before any Gateway source is enabled. The first implementation uses
one encrypted credential-profile map:

| Accessor | DB key | Secret | Default |
| --- | --- | --- | --- |
| `credentials!/0` | `bullx.plugins.feishu.credentials` | yes | `{}` |
| `oidc_state_ttl_seconds!/0` | `bullx.plugins.feishu.oidc_state_ttl_seconds` | no | `600` |

`credentials` is a JSON object keyed by credential id. Each value contains a
self-built Feishu/Lark app credential. Domain selection stays in the Gateway
source config so the same credential profile can be reused by a disabled draft
or by a source whose domain is being edited:

```json
{
  "default": {
    "app_id": "cli_xxx",
    "app_secret": "secret_xxx"
  }
}
```

The whole credentials map is encrypted by `BullX.Config`. It must not appear in
Gateway source config, Signals, Oban args, telemetry, logs, receipts, or dead
letters.

Each Feishu source has its own effective app credential through
`config.credential_id`. Operators may choose one credential profile per source
or deliberately reuse a credential profile across sources. The source slug
remains the identity namespace even when two sources share a credential profile.
The same source entry may serve as both the Signals Gateway source and the
Principal OIDC login provider instance. In that normal case, it shares the same
`channel_id` source slug, `credential_id`, Feishu app id, and Feishu app secret
for WebSocket/card transport and OIDC login.

Gateway source entries live in `bullx.gateway.sources`. A Feishu source uses the
standard source shape:

```json
{
  "adapter": "feishu",
  "channel_id": "main",
  "enabled": true,
  "config": {
    "credential_id": "default",
    "domain": "feishu",
    "tenant_key": "tenant_xxx",
    "bot_open_id": "ou_bot_xxx",
    "oidc": {
      "enabled": true,
      "redirect_uri": "https://bullx.example.com/sessions/oidc/main/callback",
      "scopes": ["openid", "profile", "email", "phone"]
    },
    "message_context_ttl_seconds": 2592000,
    "card_action_dedupe_ttl_seconds": 900,
    "direct_command_dedupe_ttl_seconds": 300,
    "inline_media_max_bytes": 524288,
    "stream_update_interval_ms": 100
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
    "details": {"adapter": "feishu", "domain": "feishu"}
  }
}
```

`channel_id` is a BullX configured source slug. It is globally unique inside
the Installation and stable across config edits because it identifies the
Gateway source and, when `config.oidc.enabled` is true, the Feishu OIDC login
provider instance. It is not a Feishu chat id, tenant id, user id, or external
room id. Feishu chat ids become `scope_id` in Gateway inputs and Deliveries.

`Feishu.GatewayAdapter.connectivity_check/1` validates one normalized
`BullX.Gateway.SourceConfig` without starting `FeishuOpenAPI.WS.Client`,
registering a listener, publishing a Signal, or writing source config. It
loads the referenced credential profile, constructs a `FeishuOpenAPI` client,
fetches or forces a tenant access token, and returns only redacted operator
metadata.

Success shape:

```elixir
{:ok,
 %{
   status: :ok,
   adapter: "feishu",
   channel_id: "main",
   capabilities: [:inbound, :send, :edit, :stream, :cards],
   details: %{"domain" => "feishu", "transport" => "websocket"}
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

Connectivity responses must never include `app_secret`, tenant access tokens,
OAuth codes, user access tokens, refresh tokens, raw callback bodies, or raw
event payloads.

## Gateway adapter contract

`Feishu.GatewayAdapter` implements `BullX.Gateway.Adapter`.

| Callback | Feishu behavior |
| --- | --- |
| `config_schema/0` | Describes source config fields, defaults, and redaction rules. |
| `normalize_config/1` | Casts persisted source JSON into adapter runtime config. |
| `public_config/1` | Returns an operator-facing redacted source projection. |
| `capabilities/0` | Declares WebSocket inbound, card-action callbacks, send, edit, stream, and supported content kinds. |
| `connectivity_check/1` | Validates credential and source reachability without side effects. |
| `source_child_spec/1` | Starts one source listener for an enabled source, or returns `:ignore` for disabled/passive source shapes. |
| `normalize_inbound/3` | Converts exactly one Feishu event or callback into one normalized Gateway input. |
| `deliver/2` | Executes `:send` and `:edit` Deliveries. |
| `stream/3` | Executes `:stream` Deliveries with Feishu CardKit. |

Capabilities should include:

```elixir
%{
  inbound_modes: [:websocket, :callback],
  outbound_ops: [:send, :edit, :stream],
  content_kinds: [:text, :image, :audio, :video, :file, :card],
  stream_strategy: :native
}
```

The Gateway core rejects unsupported operations and malformed carrier shapes
before invoking Feishu. Feishu still validates provider-specific payloads,
target ids, card formats, media constraints, and Feishu API responses.

## Inbound source runtime

For each enabled Feishu source, `source_child_spec/1` starts a source-local
runtime boundary:

```text
BullX.Gateway.SourceSupervisor
└── Feishu.Channel
    └── FeishuOpenAPI.WS.Client
```

`Feishu.Channel` owns the normalized source config, SDK client, event
dispatcher, card action handler, source-local startup logs, and source-local
dedupe/cache key prefixes. It uses `BullX.Cache` for TTL state:

- message context for recall, reaction, reply, and card-action correlation;
- card-action callback dedupe;
- direct-command result dedupe.

Cache entries are reconstructible. If a source restarts and loses message
context, Feishu may call provider APIs to recover missing message details. If
provider recovery fails, the adapter publishes the event with available stable
Feishu ids and safe fallback content rather than inventing missing facts.

Feishu uses long-connection WebSocket event push for normal inbound events. The
SDK authenticates the connection and decodes pushed event frames. The adapter
does not support Feishu webhook event-subscription inbound mode and does not
collect webhook `Verification Token` or `Encrypt Key` values.

Interactive card callbacks may arrive through an HTTP route or callback mount.
They are not Feishu event-subscription webhooks and must not require webhook
`Verification Token` or `Encrypt Key`. The Web boundary must identify
`{adapter = "feishu", channel_id}` from a trusted route mount, host, header, or
signed callback config before invoking the adapter. After source lookup, the
callback path uses the same `normalize_inbound/3` and
`BullX.Gateway.publish/2` path as WebSocket events. The exact Phoenix route
topology belongs to the Web boundary.

## Inbound normalization

Feishu normalized inputs must satisfy `BullX.Gateway.InboundInput`. A Feishu
message input has this shape:

```elixir
%{
  "adapter" => "feishu",
  "channel_id" => "main",
  "occurrence_key" => "feishu:main:event:evt_xxx",
  "time" => "2026-05-13T00:00:00Z",
  "content" => [
    %{"kind" => "text", "body" => %{"text" => "hello"}}
  ],
  "event" => %{
    "type" => "message",
    "name" => "feishu.im.message.receive_v1",
    "version" => 1,
    "data" => %{
      "message_id" => "om_xxx",
      "chat_type" => "p2p"
    }
  },
  "actor" => %{
    "id" => "feishu:ou_xxx",
    "display" => "Alice",
    "bot" => false,
    "profile" => %{
      "email" => "alice@example.com",
      "open_id" => "ou_xxx"
    },
    "metadata" => %{"tenant_key" => "tenant_xxx"}
  },
  "scope_id" => "oc_xxx",
  "thread_id" => nil,
  "refs" => [
    %{"kind" => "feishu.message", "id" => "om_xxx"}
  ],
  "reply_channel" => %{
    "adapter" => "feishu",
    "channel_id" => "main",
    "scope_id" => "oc_xxx",
    "thread_id" => nil,
    "reply_to_external_id" => "om_xxx"
  },
  "provenance" => %{
    "event_id" => "evt_xxx",
    "event_type" => "im.message.receive_v1",
    "app_id" => "cli_xxx"
  }
}
```

`occurrence_key` uses Feishu's event id when Feishu provides one. If a Feishu
event has no native stable event id, the adapter derives the key from immutable
Feishu fields such as event type, message id, actor open id, action tag, emoji,
and provider timestamp. The adapter must not use the Gateway Signal id as the
occurrence key.

### Actor identity

Feishu actor ids are channel-local external ids. User-origin events use
`external_id = "feishu:#{open_id}"`. `open_id` is required for Principal
binding. If a payload includes only `user_id` or `union_id`, the adapter should
resolve `open_id` through Feishu before publishing or activating. If `open_id`
cannot be resolved, the adapter rejects the event with a redacted error and
does not create a Principal binding.

Trusted profile fields may include `display_name`, `avatar_url`, `email`,
`phone`, `open_id`, `union_id`, and `user_id`. The adapter normalizes email by
lowercasing and trimming. It normalizes phone candidates to E.164 before passing
them to `BullX.Principals`; malformed or ambiguous phone values are omitted.
User-editable display names are presentation data, not identity proof.

Self-sent bot messages are filtered before content parsing, Principal matching,
direct-command handling, or publishing. Feishu events whose sender type is
`bot` or `app` and whose sender matches the configured or resolved bot identity
are ignored.

### Event mapping

Feishu maps provider events onto the seven Gateway event types:

| Feishu source | Gateway `event.type` | Notes |
| --- | --- | --- |
| `im.message.receive_v1` | `message` or `slash_command` | Slash-command parsing happens after text normalization; built-in direct commands implemented by this adapter are intercepted before publish. |
| Message update events | `message_edited` | `event.data.target_external_id` is the Feishu message id. |
| Message recall events | `message_recalled` | Use message cache or provider lookup for missing chat context. |
| Reaction create/delete events | `reaction` | `event.data.action` is `"added"` or `"removed"`. |
| Interactive card callback | `action` | Card values stay in `event.data.values`. |
| Explicit app or timer trigger, if later enabled | `trigger` | Disabled by default in the first implementation. |

Provider-specific names stay in `event.name`, for example
`feishu.im.message.receive_v1` or `feishu.card.action`. Gateway core must not
maintain a Feishu event-name allowlist.

### Content mapping

Text and post messages produce text content blocks. Mentions of the BullX bot
may be removed from the primary text while mention metadata remains in
`refs` or `event.data`.

Images, audio, video, and files produce native content blocks with
`fallback_text`. Small downloaded media may be embedded as `data:` URIs when
under `inline_media_max_bytes`. Large or unavailable media uses a stable
`feishu://message-resource/...` URI with Feishu ids in `refs`. No local
filesystem path enters a Signal.

Interactive card messages produce card content:

```elixir
%{
  "kind" => "card",
  "body" => %{
    "format" => "feishu.card",
    "fallback_text" => "card",
    "payload" => sanitized_card_json
  }
}
```

Sticker, emotion, and emoji-only messages produce deterministic text fallback.
The adapter must not publish empty content for a user-origin event.

## Principal account gate

Before publishing normal user-origin duplex events, Feishu calls
`BullX.Principals.match_or_create_human_from_channel/1` with the normalized
channel actor:

```elixir
%{
  "adapter" => "feishu",
  "channel_id" => "main",
  "external_id" => "feishu:ou_xxx",
  "profile" => %{
    "display_name" => "Alice",
    "email" => "alice@example.com",
    "open_id" => "ou_xxx"
  },
  "metadata" => %{
    "source" => "feishu_im",
    "tenant_key" => "tenant_xxx",
    "chat_id" => "oc_xxx",
    "chat_type" => "p2p"
  }
}
```

Result handling:

| Principal result | Adapter behavior |
| --- | --- |
| `{:ok, _principal, _identity}` | Publish the normalized Gateway input. |
| `{:error, :activation_required}` | Send a localized activation-required reply when appropriate and do not publish. |
| `{:error, :principal_disabled}` | Send a localized denied reply when configured and do not publish. |
| `{:error, reason}` | Treat as a provider-processing failure and do not acknowledge success unless the provider requires a safe terminal response. |

The resolved Principal id is never injected into the Gateway Signal. Runtime,
Router, Agent, Brain, Admission, and Work consumers continue to receive
channel-local actor data unless a later design adds a Principal-aware Signal
contract.

In group chats, activation-required replies must not include activation codes,
login auth codes, or OIDC links that reveal account state. The reply should ask
the user to message the bot privately. In `p2p` chats, the adapter may include
localized `/preauth <code>` and `/web_auth` guidance.

## Direct commands

Direct commands are built-in BullX channel commands implemented by messaging
adapters. In this design, the Feishu adapter handles the shared `/ping`,
`/preauth`, and `/web_auth` command names before publishing slash-command
Signals. The command contract is not Feishu-specific; another messaging adapter
can implement the same names with its own transport, actor normalization, and
delivery mechanics.

For Feishu, direct commands run after transport verification, source lookup,
self-sent bot filtering, command parsing, and direct-command dedupe. Only
`/ping`, `/preauth`, and `/web_auth` are intercepted by the Feishu adapter.
Other normalized text messages that start with `/` publish as Gateway
`slash_command` inputs after Principal account gating.

### `/ping`

`/ping` is a manual connectivity command. It works in `p2p` and group chats,
does not require Principal activation, and does not call
`BullX.Principals.match_or_create_human_from_channel/1`.

The adapter builds a Gateway external Delivery with `op = :send`, the current
`{adapter, channel_id}`, the Feishu chat id as `scope_id`, and the current
message id as `reply_to_external_id`. It calls `BullX.Gateway.deliver/1`; the
direct-command path depends on the Gateway outbound API instead of calling
Feishu message APIs directly. The localized reply body is `PONG!` in bundled
locales.

The adapter acknowledges the Feishu event only after Gateway accepts the
Delivery or after a duplicate direct-command result is found.

### `/preauth <code>`

`/preauth <code>` consumes a BullX activation code and creates a new Human
Principal with the current Feishu actor as the first channel binding.

Flow:

1. Reject group chats with a localized DM-only instruction and do not consume
   the code.
2. Normalize the Feishu actor and trusted profile.
3. Call `BullX.Principals.consume_activation_code(code, channel_input)`.
4. Submit one localized Feishu reply as a Gateway external Delivery through
   `BullX.Gateway.deliver/1`.
5. Do not publish the command as a Gateway Signal.

Result mapping:

| Principal result | Feishu reply key |
| --- | --- |
| `{:ok, _principal, _identity}` | `gateway.feishu.auth.activation_success` |
| `{:error, :invalid_or_expired_code}` | `gateway.feishu.auth.activation_code_invalid` |
| `{:error, :already_bound}` | `gateway.feishu.auth.already_linked` |
| `{:error, :principal_disabled}` | `gateway.feishu.auth.denied` |
| any other `{:error, _}` | `gateway.feishu.auth.activation_failed` |

The direct-command result cache stores the reply result by Feishu event id for
the configured short TTL so transport retries do not send duplicate activation
replies.

### `/web_auth`

`/web_auth` issues a built-in channel-auth login code for an already bound
active Human Principal. It is separate from Feishu OIDC login and uses the
Principal login-auth-code table.

Flow:

1. Reject group chats with a localized DM-only instruction and do not issue a
   code.
2. Normalize the Feishu actor and trusted profile.
3. Call `BullX.Principals.issue_login_auth_code("feishu", channel_id, "feishu:#{open_id}")`.
4. Render a localized reply containing the short-lived code and the generic Web
   login URL.
5. Submit the reply as a Gateway external Delivery through
   `BullX.Gateway.deliver/1`.
6. Do not publish the command as a Gateway Signal.

Result mapping:

| Principal result | Feishu reply key |
| --- | --- |
| `{:ok, code}` | `gateway.feishu.auth.web_auth_created` |
| `{:error, :not_bound}` | `gateway.feishu.auth.web_auth_not_bound` |
| `{:error, :principal_disabled}` | `gateway.feishu.auth.denied` |
| `{:error, :not_human}` | `gateway.feishu.auth.web_auth_not_bound` |
| any other `{:error, _}` | `gateway.feishu.auth.web_auth_failed` |

## Principal OIDC login provider

`Feishu.OIDCProvider` implements the Principal login-provider hook for Human
browser login. The host extension point is
`:"bullx.principals.login_provider"`. The extension id `"feishu"` identifies
the provider implementation type. It is not the concrete provider id stored in
Principal login-subject identities. For Feishu, the concrete provider id is the
configured source slug, which is the source `channel_id`.

If this hook does not exist yet, implementation adds the minimal host contract
and registry lookup needed by this plugin.

Suggested host behavior:

```elixir
defmodule BullX.Principals.LoginProvider do
  @callback authorization_url(BullX.Gateway.SourceConfig.t(), map()) ::
              {:ok, %{url: String.t(), state: map()}} | {:error, map()}

  @callback callback(BullX.Gateway.SourceConfig.t(), map(), map()) ::
              {:ok, map()} | {:error, map()}
end
```

The generic Web login controller receives a provider id from the login route.
For Feishu, that provider id is the source slug. The controller loads the
enabled Gateway source by that slug, verifies `adapter = "feishu"` and
`config.oidc.enabled = true`, resolves the Feishu login-provider
implementation, asks it for an authorization URL, signs provider state with
Phoenix token infrastructure, and redirects the browser. The callback verifies
the signed state, calls the provider callback, passes the returned login
subject to `BullX.Principals.match_or_create_human_from_login_subject/1`,
renews the Phoenix session on success, and stores the Principal id in the
session.

Feishu authorization state includes:

```elixir
%{
  "provider" => "main",
  "adapter" => "feishu",
  "channel_id" => "main",
  "return_to" => "/",
  "issued_at" => 1_715_558_400,
  "nonce" => "random"
}
```

The state `provider` and `channel_id` both refer to the source slug and must
match. The `adapter` value selects the Feishu implementation.

The callback flow is:

1. Verify signed state, source slug, adapter, nonce, age, and local `return_to`.
2. Exchange `code` through `FeishuOpenAPI.Auth.user_access_token/3`.
3. Fetch userinfo through `FeishuOpenAPI.get(client, "/open-apis/authen/v1/user_info", user_access_token: access_token)`.
4. Normalize a Principal login subject:

   ```elixir
   %{
     "provider" => "main",
     "external_id" => "feishu:ou_xxx",
     "profile" => %{
       "display_name" => "Alice",
       "email" => "alice@example.com",
       "phone" => "+8613800000000",
       "avatar_url" => "https://...",
       "open_id" => "ou_xxx",
       "union_id" => "on_xxx",
       "user_id" => "u_xxx"
     },
     "metadata" => %{
       "adapter" => "feishu",
       "channel_id" => "main",
       "app_id" => "cli_xxx",
       "tenant_key" => "tenant_xxx",
       "domain" => "feishu"
     }
   }
   ```

5. Discard the Feishu user access token and refresh token after userinfo
   retrieval.

`provider = "main"` above is the configured source slug. Multiple Feishu or
Lark organizations may be configured at the same time as different enabled
sources, each with its own slug, app id, secret, domain, tenant metadata, and
OIDC setting. The Principal login-subject identity namespace is therefore the
source slug, not the connector type `"feishu"` and not the Feishu app id. The
login subject `external_id` uses the source-local Feishu `open_id`, for example
`feishu:#{open_id}`. `adapter`, `app_id`, `tenant_key`, `domain`, and
`channel_id` stay in metadata for audit and operator diagnostics.

Feishu channel actors remain channel-local and keep
`external_id = "feishu:#{open_id}"` under the `channel_actor` identity kind.
Principal matching owns any binding between that channel actor and the
source-scoped Feishu login subject. If userinfo lacks `open_id`, the login
fails closed without creating or binding a Principal.

`BullX.Principals` owns the binding and creation decision. The OIDC provider
must not write `principal_external_identities` directly. On
`{:error, :not_bound}`, the Web surface should direct the user to activate from
Feishu with `/preauth`. On `{:error, :principal_disabled}` or
`{:error, :not_human}`, it fails closed.

## Outbound delivery

Feishu outbound delivery executes already-authorized Gateway external
Deliveries. The plugin does not decide whether an Agent may speak in a Feishu
chat, edit a message, or stream a card. Governance and upstream Runtime decide
that before submitting a Delivery to Gateway.

`Feishu.GatewayAdapter.deliver/2` handles `:send` and `:edit`.
`Feishu.GatewayAdapter.stream/3` handles `:stream`.

### Send

Targeting rules:

- `delivery.scope_id` is the Feishu chat id.
- `delivery.thread_id` is passed when the Feishu endpoint supports thread
  targeting.
- `delivery.reply_to_external_id` sends a Feishu reply when present.
- Without `reply_to_external_id`, the adapter sends to `scope_id`.

The adapter uses `delivery.id` as the Feishu idempotency UUID for message
create and reply APIs when Feishu supports that parameter. It returns Feishu
message ids in `external_message_ids` and `primary_external_id`.

Content rules:

- `text` sends Feishu text or post content.
- `card` with `format = "feishu.card"` or `format = "feishu.card.v2"` sends an
  interactive card.
- `image`, `file`, `audio`, and `video` upload native media when the content
  URI is readable and provider limits permit it.
- Unsupported rich combinations degrade to one localized or fallback text
  message when possible.

If Feishu reports that a reply target was recalled or missing, including known
codes `230011` and `231003`, the adapter retries once as a normal chat send to
`delivery.scope_id`. A successful fallback returns a degraded outcome with a
warning such as `"reply_target_missing_sent_to_scope"`. If `scope_id` is
missing, the adapter returns a payload error.

### Edit

`delivery.target_external_id` is required for edit. Feishu supports editing
text/post message content and interactive card content in the first
implementation. Unsupported edit content returns a non-retryable payload or
unsupported error. Missing or uneditable target messages map to payload,
unsupported, or not-found errors, not network errors.

### Stream

Feishu streaming uses CardKit. The adapter creates a card with one streaming
text element, sends it, consumes Gateway stream chunks, updates
`cardElement.content` with increasing sequence numbers and UUIDs, throttles
updates by `stream_update_interval_ms`, and finalizes the card with streaming
disabled.

Supported chunk shapes:

- `binary()` appends text.
- `%{text: binary()}` or `%{"text" => binary()}` appends text.
- `%{replace_text: binary()}` or `%{"replace_text" => binary()}` replaces the
  accumulated text.

If `stream/3` receives absent or non-enumerable stream content, including a
dead-letter replay that cannot reconstruct the live stream, it returns:

```elixir
{:error, %{"kind" => "payload", "message" => "stream content is not replayable"}}
```

On stream error or cancellation, the adapter attempts one final card update with
localized failure text and then returns the original normalized error to
Gateway.

## Error mapping

`Feishu.Error` maps SDK and Feishu API failures into Gateway adapter error maps.
All returned errors are JSON-neutral and string-keyed:

```elixir
%{
  "kind" => "rate_limit",
  "message" => "Feishu API rate limited",
  "details" => %{
    "retry_after_ms" => 3000,
    "code" => 99_991_400,
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
| Invalid content, missing target, malformed callback, stream replay without content | `payload` |
| Unsupported Feishu operation or content with no fallback | `unsupported` |
| Stream cancellation observed by the adapter | `stream_cancelled` |
| Unknown Feishu API error | `unknown` |

`details` may include Feishu `code`, `log_id`, retry hints, and redacted
endpoint context. It must not include secrets, tokens, raw message bodies,
OAuth codes, raw callback payloads, or private card values.

Adapters do not emit Gateway-owned error kinds such as `"contract"` or
`"adapter_restarted"` unless Gateway core defines that mapping for adapter
contract violations.

## Telemetry and logs

Feishu emits telemetry under:

```text
[:bullx, :feishu, :source, :start]
[:bullx, :feishu, :ws, :connect]
[:bullx, :feishu, :event, :received]
[:bullx, :feishu, :event, :mapped]
[:bullx, :feishu, :event, :ignored]
[:bullx, :feishu, :event, :publish, :start]
[:bullx, :feishu, :event, :publish, :stop]
[:bullx, :feishu, :event, :publish, :exception]
[:bullx, :feishu, :direct_command, :handled]
[:bullx, :feishu, :delivery, :start]
[:bullx, :feishu, :delivery, :stop]
[:bullx, :feishu, :delivery, :exception]
[:bullx, :feishu, :oidc, :callback]
```

Safe metadata includes `adapter`, `channel_id`, `event_type`, `event_id`,
`scope_id`, `delivery_id`, `chat_type`, and sanitized Feishu API `code` or
`log_id`.

Logs are part of the manual-run contract. Startup, WebSocket connection,
inbound mapping, direct-command handling, publish result, outbound delivery, and
OIDC callback paths should emit safe structured log lines. Logs must not include
secrets, access tokens, refresh tokens, OAuth codes, raw message bodies, raw
callback payloads, or private card values.

## I18n

All human-facing Feishu text uses `BullX.I18n` and the application-global
locale. The adapter does not choose locale from Feishu tenant, user profile,
`Accept-Language`, or browser settings.

Add at least these keys in supported locales:

```toml
[gateway.feishu.auth]
activation_required = "..."
activation_success = "..."
activation_code_invalid = "..."
activation_failed = "..."
already_linked = "..."
web_auth_created = "..."
web_auth_not_bound = "..."
web_auth_failed = "..."
login_not_bound = "..."
denied = "..."
direct_command_dm_only = "..."

[gateway.feishu.ping]
pong = "PONG!"

[gateway.feishu.delivery]
fallback_text = "..."
stream_generating = "..."
stream_failed = "..."
stream_cancelled = "..."
reply_target_missing_sent_to_scope = "..."

[gateway.feishu.errors]
unsupported_message = "..."
profile_unavailable = "..."
```

Tests must fail if a key used by the adapter is missing in any bundled locale.

## Security and privacy

Feishu transport authenticity stays adapter-owned. WebSocket event push relies
on `FeishuOpenAPI.WS.Client` and SDK event decoding. Card-action callbacks are
handled through Feishu card-action callback APIs after the Web boundary
identifies the configured source. They do not use Feishu event-subscription
webhook `Verification Token` or `Encrypt Key` values.

The adapter must:

- drop self-sent bot messages before publish;
- reject `/preauth` and `/web_auth` in group chats without consuming or issuing
  secrets;
- validate OIDC state, nonce, source id, age, and local `return_to`;
- discard Feishu user tokens after userinfo retrieval;
- keep Feishu access tokens, refresh tokens, app secrets, OAuth codes, raw
  callback bodies, and raw event payloads out of logs and persisted Gateway
  records;
- keep provider credential values in `BullX.Config` secret storage;
- keep Gateway actor ids channel-local and avoid writing Principal ids into
  Signals.

Feishu outbound delivery may be customer-facing. The adapter assumes the
Delivery already passed Governance or another upstream authorization boundary.
The adapter must not add a shortcut that lets direct Feishu API calls bypass
Gateway outbound validation for business effects.

## Failure behavior

Provider verification failures, malformed callbacks, missing required Feishu
fields, missing credential profiles, and unsupported content fail closed. They
produce redacted telemetry and safe logs.

For inbound events, the adapter acknowledges Feishu only when one of these
conditions is true:

- the event was intentionally ignored, such as a self-sent bot message;
- an adapter-local direct command completed or a duplicate direct-command result
  was found;
- `BullX.Gateway.publish/2` returned accepted;
- the provider requires a terminal response for a non-retryable malformed event
  and retry would not help.

For outbound Delivery, Feishu errors follow the Gateway retry and terminal
outcome contract. Retryable errors include rate limiting, network failures,
timeouts, and temporary provider unavailability. Auth, permission, payload,
unsupported, and malformed-target errors are terminal unless Feishu supplies a
specific retry hint.

Process-local state is reconstructible. If `Feishu.Channel` restarts, it
reconnects WebSocket transport and rebuilds cache entries opportunistically.
Gateway and Principal durable facts remain in PostgreSQL.

## Alternatives considered

| Alternative | Decision |
| --- | --- |
| Port the old main-branch RFC directly | Rejected. It is tied to old Gateway, Accounts, setup, and Jido-era assumptions. |
| Add Feishu directly under BullX core | Rejected. The plugin system is the selected integration boundary. |
| Use a top-level `BullXFeishu` app outside `plugins/*` | Rejected. The source boundary should be the plugin Mix project. |
| Add a Feishu-specific OIDC controller and account code path | Rejected. Principal login-provider hooks keep provider logic behind a typed extension point. |
| Persist Feishu user tokens for later API calls | Rejected. The first implementation only needs userinfo for login and discards tokens. |
| Put resolved Principal ids into Gateway Signals | Rejected. Gateway actor data stays channel-local; Principal-aware routing needs a later design. |
| Use HTTP webhook event push for normal events | Rejected. WebSocket event push is the Feishu source listener; HTTP is used only for card-action callback routes. |

## Implementation handoff

### Goal

Implement the Feishu plugin as one trusted plugin that exposes both Gateway
transport and Principal OIDC login, while preserving the current Plugin,
Gateway, and Principal boundaries.

### Context pointers

- `AGENTS.md`
- `docs/design-docs/Plugins.md`
- `docs/design-docs/Principal.md`
- `docs/design-docs/SignalsGateway.md`
- `docs/design-docs/Cache.md`
- `lib/bullx/gateway/adapter.ex`
- `lib/bullx/gateway/source_config.ex`
- `lib/bullx/gateway/sources.ex`
- `lib/bullx/principals.ex`
- `lib/bullx/principals/authn.ex`
- `lib/bullx/plugins/plugin.ex`
- `packages/feishu_openapi/README.md`
- `packages/feishu_openapi/lib/feishu_openapi/`

### Constraints

- Put plugin code under `plugins/feishu`.
- Use plugin id `"feishu"` and Gateway adapter id `"feishu"`.
- Use `BullX.Principals`, not `BullXAccounts`.
- Use `BullX.Gateway`, not `BullXGateway`.
- Use `bullx.gateway.sources`, not `bullx.gateway.adapters`.
- Use the Feishu source slug as the Principal OIDC `login_subject.provider`;
  `"feishu"` is the adapter and login-provider implementation id.
- Use `BullX.Cache`, not adapter-owned ETS tables or direct Cachetastic calls.
- Use `FeishuOpenAPI`; do not add another Feishu dependency.
- Store plugin secrets through `BullX.Config`; do not persist Feishu tokens.
- Do not change `BullX.Runtime.Supervisor` or add Jido dependencies.
- Do not add Principal ids to Gateway Signals.

### Tasks

1. Add the Feishu plugin skeleton.
   Owns: `plugins/feishu/mix.exs`, `Feishu.Plugin`, plugin tests.
   Depends on: none.
   Acceptance: BullX discovers plugin id `"feishu"` and both extension
   declarations when the plugin is compiled.
   Verify: plugin discovery and registry tests.

2. Add Feishu plugin configuration.
   Owns: `Feishu.Config`, config casters, secret-key tests.
   Depends on: Task 1.
   Acceptance: `bullx.plugins.feishu.credentials` is secret, validates the
   credential-profile map, and supports source config lookup without logging
   credentials.
   Verify: config and secret writer tests.

3. Add the Principal login-provider host contract if missing.
   Owns: `BullX.Principals.LoginProvider`,
   `BullX.Principals.LoginProviders`, generic Web login dispatch if needed.
   Depends on: Plugin registry.
   Acceptance: an enabled Feishu source slug can be used as the Web login
   provider id and dispatched to the Feishu login-provider implementation.
   Verify: registry and controller tests with a fake provider.

4. Implement `Feishu.OIDCProvider`.
   Owns: `Feishu.OIDCProvider`, OIDC state/profile tests.
   Depends on: Tasks 2 and 3.
   Acceptance: authorization URL generation and callback normalization produce
   a valid Principal login subject with provider set to the source slug,
   discard tokens, and fail closed without `open_id`.
   Verify: fake `FeishuOpenAPI` or `Req.Test` callback tests.

5. Implement `Feishu.GatewayAdapter` config, capabilities, and connectivity.
   Owns: `Feishu.GatewayAdapter`, `Feishu.Source`, `Feishu.Error`.
   Depends on: Task 2.
   Acceptance: adapter callbacks satisfy `BullX.Gateway.Adapter`,
   capabilities are precise, and connectivity check returns only safe metadata.
   Verify: adapter unit tests.

6. Implement inbound runtime and normalization.
   Owns: `Feishu.Channel`, `Feishu.EventMapper`, `Feishu.ContentMapper`,
   cache key helpers.
   Depends on: Task 5.
   Acceptance: WebSocket and card-action payloads normalize to valid Gateway
   inputs for message, edited message, recalled message, reaction, action, and
   slash-command events.
   Verify: event-mapping tests and a `BullX.Gateway.publish/2` integration test
   with a fake Router.

7. Implement Principal account gate and direct commands.
   Owns: `Feishu.DirectCommand`, locale keys.
   Depends on: Tasks 4, 6, and the Gateway outbound API slice.
   Acceptance: normal user-origin events call Principal matching before publish;
   `/ping` bypasses Principal; `/preauth` consumes activation codes only in
   `p2p`; `/web_auth` issues login auth codes only for bound active Humans.
   Verify: focused direct-command tests with Principal fixtures.

8. Implement outbound send, edit, and stream.
   Owns: `Feishu.Delivery`, `Feishu.StreamingCard`, outbound error mapping.
   Depends on: Task 5 and the Gateway outbound API slice.
   Acceptance: send/edit/stream return Gateway-compatible sent, degraded, or
   error results; reply fallback and stream failure behavior match this design.
   Verify: outbound tests with fake SDK responses.

9. Add telemetry, logs, and locale coverage.
   Owns: Feishu modules and locale files.
   Depends on: Tasks 4 through 8.
   Acceptance: safe telemetry/log metadata exists for startup, inbound,
   direct-command, publish, delivery, and OIDC callback paths; locale tests fail
   on missing keys.
   Verify: telemetry/log capture tests and locale key tests.

### Done when

- `plugins/feishu` compiles as a BullX plugin.
- The plugin registers `:"bullx.gateway.adapter"` id `"feishu"`.
- The plugin registers the Feishu `:"bullx.principals.login_provider"`
  implementation, and enabled Feishu source slugs route to it as concrete login
  provider ids.
- Feishu source config and plugin credentials validate through `BullX.Config`.
- `Feishu.GatewayAdapter.connectivity_check/1` verifies app credentials without
  starting a source listener or leaking secrets.
- Enabled Feishu sources start one WebSocket listener under
  `BullX.Gateway.SourceSupervisor`.
- Feishu inbound events normalize into valid Gateway inputs and publish through
  `BullX.Gateway.publish/2`.
- Built-in direct commands implemented by the Feishu adapter behave as
  specified and do not publish Runtime slash-command Signals.
- Feishu OIDC callback logs in or creates only Human Principals according to
  `BullX.Principals` matching rules.
- Feishu outbound send, edit, and stream paths produce Gateway-compatible
  outcomes or adapter error maps.
- Focused tests and `bun precommit` pass.

Implementation should stop and ask if a change would require persistent Feishu
tokens, marketplace app support, new Principal types, Principal ids in Signals,
Gateway route topology as a Feishu-specific contract, a new credential store,
or a supervision boundary outside the plugin and Gateway source supervisors.

## Acceptance criteria

- Feishu is implemented only as the `plugins/feishu` plugin.
- The plugin exposes both required hooks:
  `:"bullx.gateway.adapter"` and `:"bullx.principals.login_provider"`.
- The adapter uses `packages/feishu_openapi`; no new Feishu dependency is added.
- Feishu source config uses `bullx.gateway.sources`.
- Feishu secrets are declared by plugin config and encrypted by `BullX.Config`.
- Gateway actor ids use `feishu:<open_id>` and remain channel-local.
- Normal user-origin events are gated by `BullX.Principals` before publish.
- Feishu OIDC produces `login_subject` identity input and never writes Principal
  external identities directly.
- Feishu OIDC uses the configured source slug as the `login_subject` provider
  and source-local `feishu:<open_id>` external ids so multiple Feishu/Lark
  organizations can be configured at the same time.
- Feishu access tokens and refresh tokens are discarded after OIDC userinfo
  retrieval.
- `/preauth` and `/web_auth` are rejected in group chats without consuming or
  issuing secrets.
- `/ping` works before activation and does not require Principal matching.
- Send, edit, and stream delivery use Gateway outbound contracts and safe error
  maps.
- Self-sent bot messages are filtered before publish.
- Raw provider payloads, secrets, and tokens do not enter telemetry, logs, error
  details, receipts, or dead-letter summaries. Normalized Gateway content may
  enter Gateway carrier and replay surfaces according to the Gateway contract.
- No Jido dependency, old `BullXGateway`, old `BullXAccounts`, or legacy Feishu
  compatibility shim is introduced.
- `bun precommit` passes.
