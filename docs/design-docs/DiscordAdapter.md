# Discord adapter

The Discord integration is a trusted BullX plugin under `plugins/discord`. It
contributes two extension declarations: a `:"bullx.gateway.adapter"` source for
Signals Gateway inbound and outbound transport, and a Discord
`:"bullx.principals.login_provider"` implementation for Human Principal OAuth2
browser login. The plugin uses the `Kraigie/nostrum` Bot client as a stateless
Bot/Gateway API and does not port the old `BullXGateway`, `BullXAccounts`, or
RFC 0015 namespaces.

## Scope

This design covers the Discord plugin adapter:

- plugin placement, metadata, extension declarations, and plugin-owned runtime
  configuration;
- Gateway source configuration, connectivity checks, Discord Gateway
  WebSocket source supervision via Nostrum, native application command sync,
  inbound normalization, attention filtering, account gating, auto-threading,
  and outbound send, edit, and stream delivery;
- built-in BullX direct commands implemented over Discord
  messages/interactions for local connectivity and Principal activation:
  `/ping`, `/preauth <code>`, and `/web_auth`;
- the Discord-specific `/ask` native application command and automatic
  BullX-owned Discord thread creation for guild-channel entry points;
- Discord OAuth2 browser login for Human Principals through a Principal
  login-provider hook;
- Discord-specific content mapping, actor normalization, message splitting,
  multi-message streaming, error mapping, telemetry, logging, security, tests,
  and implementation handoff.

This design depends on [Plugins.md](Plugins.md), [Principal.md](Principal.md),
and [SignalsGateway.md](SignalsGateway.md) for the host contracts. It
specializes those contracts for Discord instead of redefining them. It mirrors
[FeishuAdapter.md](FeishuAdapter.md) for the login-provider shape and
[TelegramAdapter.md](TelegramAdapter.md) for the messaging-adapter shape, so
the three plugins can be reviewed side by side.

## Goals

- Keep Discord out of BullX core modules by shipping it as one plugin under
  `plugins/discord`.
- Expose Discord transport through the Gateway adapter extension point with
  inbound and outbound support.
- Expose Discord Human login through a Principal-owned login-provider
  extension point so multiple Discord applications may coexist.
- Reuse `Kraigie/nostrum` for Discord Bot/Gateway WSS, REST, and per-bot
  supervision, with BullX owning transport lifecycle.
- Keep Gateway actor data channel-local until `BullX.Principals` resolves,
  creates, or activates a Human Principal.
- Preserve Gateway transport boundaries: Discord may produce normalized
  Signals and execute authorized Deliveries, but it does not create Admission,
  Work, Intents, Effects, Outcomes, or Brain facts.
- Keep bot tokens, OAuth client secrets, OAuth codes, OAuth access/refresh
  tokens, raw provider payloads, private adapter config, and Principal
  activation/login codes out of telemetry, logs, error details, receipts, and
  dead-letter summaries. Normalized Gateway content may enter Signals,
  Deliveries, Mailbox jobs, and replayable dead letters according to the
  Gateway contract; those storage surfaces are operator-sensitive.
- Filter guild-channel noise at the adapter edge through an explicit attention
  policy so unrelated guild messages never reach the Signals carrier.
- Offer a Discord-shaped chat surface for guild interaction through `/ask` and
  BullX-owned threads, scoped so a thread is the conversation, not a sub-key
  of a parent channel.

## Non-goals

- Do not add Discord modules under `lib/bullx/` or `lib/bullx_web/` except for
  generic host surfaces needed by plugin hooks.
- Do not recreate old `BullXGateway`, `BullXAccounts`, RFC 0002/0003, RFC
  0015, `BullXDiscord` namespace, or Jido abstractions.
- Do not add runtime plugin installation, hot plugin enablement, hook
  priority, or plugin-specific persistence tables.
- Do not persist Discord OAuth access tokens, refresh tokens, raw events, raw
  callback bodies, downloaded attachments, or BullX-owned thread membership
  as durable BullX facts.
- Do not implement native media upload (`sendMessage` attachments, embeds
  beyond default link previews) in the first version. Non-text outbound
  content degrades to `fallback_text`.
- Do not implement Discord reactions, message recall, channel-post,
  callback-component (buttons/select menus), modal, voice, business, or
  shipping events as Signals by default.
- Do not bulk-overwrite Discord global application commands. Application
  command sync is selective reconciliation only.
- Do not maintain an adapter-owned ETS cache when `BullX.Cache` already owns
  adapter cache state.
- Do not implement a generic OAuth/OIDC framework beyond the Principal
  login-provider hook required for this plugin.
- Do not auto-create Discord threads from DMs or from messages already inside
  Discord threads.
- Do not put resolved Principal ids into Gateway Signals.

## Cleanup plan

- **Dead code to delete:** none. The current branch has no live Discord
  adapter. Do not copy deleted legacy namespaces or compatibility shims into
  the new branch.
- **Duplicate logic to merge:** do not introduce Discord-specific HTTP, retry,
  cache, or identity infrastructure when `BullX.Cache`, `BullX.Gateway`,
  `BullX.Principals`, `BullX.Retry`, and Nostrum already own those concerns.
- **Existing utilities and patterns to reuse:** use `BullX.Plugins.Plugin`,
  `BullX.Gateway.Adapter`, `BullX.Gateway.SourceConfig`,
  `BullX.Gateway.publish/2`, `BullX.Gateway.normalize_inbound/4`,
  `BullX.Principals`, `BullX.Principals.LoginProvider`, `BullX.Config`,
  `BullX.Cache`, `BullX.I18n`, `BullX.Ext`, `BullX.Retry`, `Nostrum`, and
  `Req`.
- **Code paths and contracts changing:** add `plugins/discord`, Discord plugin
  configuration declarations, Discord Gateway adapter modules, Discord
  login-provider module, Discord locale keys, and focused tests.
- **Invariants that must remain true:** plugin state is reconstructible;
  PostgreSQL remains durable truth; Gateway actors remain channel-local;
  Principal matching owns Human identity decisions; plaintext activation and
  login codes are never stored; bot tokens, OAuth secrets, OAuth codes, and
  raw provider payloads never enter Gateway payloads; outbound Delivery is
  assumed already authorized before the Gateway invokes Discord; BullX-owned
  thread membership is reconstructible from Discord channel metadata.
- **Verification command:** run focused Discord, Gateway adapter, Principal
  login provider, and Web login tests, then run `bun precommit`.

## Existing context

[Plugins.md](Plugins.md) defines plugins as compile-time trusted Mix projects
discovered from `plugins/*`. The plugin host registers declarations from all
discovered plugins and starts children only for enabled plugins.

[SignalsGateway.md](SignalsGateway.md) defines Gateway adapters as plugin
extensions under `:"bullx.gateway.adapter"`. Gateway configured sources live
in `bullx.gateway.sources`. A configured source is identified by
`{adapter, channel_id}` after case folding. For Discord, `channel_id` is the
source slug and must be globally unique inside the BullX Installation because
it can be used as both the Gateway source id and the Principal OAuth2 login
provider id.

[Principal.md](Principal.md) defines Human login and channel identity through
`BullX.Principals`. Discord channel actors use
`principal_external_identities(kind = channel_actor)`. Discord OAuth2 login
uses `principal_external_identities(kind = login_subject)`. The adapter
supplies trusted external identity claims; `BullX.Principals` decides whether
they bind, create, activate, or reject a Human Principal.

The old main-branch RFC 0015 and `lib/bullx_discord/` modules remain useful
only for Discord mechanics: Nostrum bot supervision, READY-time bot identity
resolution, application command safe reconciliation, attention policy and
ignore-reason taxonomy, `/ask` plus auto-threading, thread-as-scope mapping,
thread-ownership resolution without BullX-owned persistence, OAuth2 token
exchange and userinfo fetching, multi-message streaming, ephemeral
interaction responses, allowed-mentions safe defaults, and error mapping.
Their old namespace (`BullXDiscord`), `BullXAccounts` calls, `BullXGateway`
calls, top-level controller (`BullXWeb.DiscordAuthController`), Gateway
`adapters` config shape, and Hex-pinned `Nostrum 0.11.0-dev` Git ref are not
implementation sources for this branch.

## Plugin shape

The plugin app id is `:discord`, the plugin id is `"discord"`, and the
directory is `plugins/discord`. The plugin entry module is `Discord.Plugin`.

```elixir
defmodule Discord.Plugin do
  use BullX.Plugins.Plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.gateway.adapter",
        id: "discord",
        module: Discord.GatewayAdapter
      },
      %{
        point: :"bullx.principals.login_provider",
        id: "discord",
        module: Discord.OAuth2Provider,
        opts: %{adapter: "discord", kind: :oauth2}
      }
    ]
  end

  @impl BullX.Plugins.Plugin
  def config_modules, do: [Discord.Config]
end
```

The plugin should not start a plugin-wide supervisor child in the first
implementation. Gateway source listeners start through
`Discord.GatewayAdapter.source_child_spec/1` under
`BullX.Gateway.SourceSupervisor`. This keeps the transport failure boundary
in Gateway source supervision instead of making the plugin host a transport
supervisor.

The login-provider extension id `"discord"` names the implementation type,
not the persisted Principal provider value for Discord OAuth2 identities. At
runtime, each enabled Discord source with OAuth2 login enabled exposes its
source slug (`channel_id`) as the login provider id.

Suggested module ownership:

| Module | Responsibility |
| --- | --- |
| `Discord.Plugin` | Plugin metadata, config modules, and extension declarations. |
| `Discord.Config` | Plugin-owned `BullX.Config` declarations and config casters. |
| `Discord.GatewayAdapter` | `BullX.Gateway.Adapter` implementation. |
| `Discord.Source` | Runtime Discord source config normalization and redaction. |
| `Discord.Supervisor` | Per-source one-for-all supervisor wrapping `Discord.Channel` and the Nostrum bot subtree. |
| `Discord.Channel` | Per-source `GenServer`: holds normalized config, dispatches Nostrum events, resolves bot identity at READY, owns cache and command-sync wiring. |
| `Discord.Consumer` | Nostrum `Consumer` implementation; forwards events to `Discord.Channel`. |
| `Discord.EventMapper` | Discord `MESSAGE_CREATE` and `INTERACTION_CREATE` payload normalization to Gateway inputs. |
| `Discord.ContentMapper` | Discord message content (text/attachments/embeds/stickers) to Gateway content blocks; outbound text rendering and chunking. |
| `Discord.AttentionPolicy` | Guild-channel attention filter (DM, mention, application command, BullX-owned thread, allowlists, free-response). |
| `Discord.ApplicationCommands` | Safe selective reconciliation of BullX-owned global application commands. |
| `Discord.DirectCommand` | Built-in `/ping`, `/preauth`, and `/web_auth` direct-command handler over text messages and native interactions. |
| `Discord.AskCommand` | `/ask` native application command handler: ephemeral acknowledgement, auto-threading, slash-command publish. |
| `Discord.ThreadOwnership` | BullX-owned Discord thread resolution via cache and Discord channel metadata. |
| `Discord.Delivery` | Send and edit outbound execution; safe allowed-mentions; reply-target fallback. |
| `Discord.Streamer` | Multi-message accumulating streamer with throttled edits and final reconciliation. |
| `Discord.OAuth2Provider` | Principal login-provider callback implementation. |
| `Discord.Error` | Nostrum and Discord HTTP error normalization. |

Adapter modules call `Nostrum.Api.Self`, `Nostrum.Api.Message`,
`Nostrum.Api.Channel`, `Nostrum.Api.Thread`, `Nostrum.Api.Interaction`, and
`Nostrum.Api.ApplicationCommand` directly under
`Nostrum.Bot.with_bot/2`. OAuth2 token exchange and userinfo fetching call
`Req` directly. Failures route through `Discord.Error`.

The plugin must not start a `Nostrum` application-global supervisor; each
source declares its own `Nostrum.Bot` child under `Discord.Supervisor`.

## Runtime configuration

Operators enable the plugin through `bullx.enabled_plugins`:

```json
["discord"]
```

Discord credentials live in plugin configuration so the plugin can declare
the secret shape before any Gateway source is enabled. The first
implementation uses one encrypted credential-profile map:

| Accessor | DB key | Secret | Default |
| --- | --- | --- | --- |
| `credentials!/0` | `bullx.plugins.discord.credentials` | yes | `{}` |
| `oauth2_state_ttl_seconds!/0` | `bullx.plugins.discord.oauth2_state_ttl_seconds` | no | `600` |

`credentials` is a JSON object keyed by credential id. Each value contains
one Discord application credential triple:

```json
{
  "default": {
    "application_id": "123456789012345678",
    "bot_token": "MTIzNDU2.ABC.xyz",
    "client_secret": "secret_xxx"
  }
}
```

The whole credentials map is encrypted by `BullX.Config`. It must not appear
in Gateway source config, Signals, Oban args, telemetry, logs, receipts, or
dead letters. `client_secret` may be omitted on a credential profile when no
source under that profile enables OAuth2 login; the adapter validates the
combination at source normalization time.

Each Discord source has its own effective application credential through
`config.credential_id`. Operators may choose one credential profile per
source or reuse a credential profile across sources. The source slug remains
the identity namespace even when two sources share a credential profile.

> **Per-token Gateway constraint:** Discord rejects concurrent Gateway
> connections from the same bot token without sharding coordination. Two
> sources sharing the same `credential_id` therefore cannot both run their
> own bot Gateway connection. The adapter detects this at startup by
> tracking active bot tokens per node and refuses to start a second bot with
> a `config` error. Operators who need multiple BullX sources for the same
> Discord application must either share one source for the relevant channels
> or wait for shard coordination in a later version.

Gateway source entries live in `bullx.gateway.sources`. A Discord source uses
the standard source shape:

```json
{
  "adapter": "discord",
  "channel_id": "main",
  "enabled": true,
  "config": {
    "credential_id": "default",
    "bot_user_id": null,
    "oauth2": {
      "enabled": true,
      "redirect_uri": "https://bullx.example.com/sessions/oauth2/main/callback",
      "scopes": ["identify", "email"]
    },
    "message_context_ttl_seconds": 2592000,
    "direct_command_dedupe_ttl_seconds": 300,
    "thread_ownership_cache_ttl_seconds": 86400,
    "stream_update_interval_ms": 1000,
    "stream_chunk_soft_limit": 1850,
    "auto_thread": {
      "enabled": true,
      "auto_archive_duration_minutes": 1440,
      "no_thread_channel_ids": []
    },
    "attention": {
      "allowed_channel_ids": [],
      "ignored_channel_ids": [],
      "ignored_thread_ids": [],
      "require_mention": true,
      "free_response_channel_ids": []
    },
    "application_commands": {
      "sync_policy": "safe"
    }
  },
  "outbound_retry": {
    "max_attempts": 3,
    "base_ms": 250,
    "max_ms": 10000
  },
  "connectivity": {
    "fingerprint": "sha256:redacted-config-fingerprint",
    "checked_at": "2026-05-14T00:00:00Z",
    "status": "ok",
    "max_age_seconds": 86400,
    "details": {"adapter": "discord", "transport": "gateway"}
  }
}
```

`channel_id` is a BullX configured source slug. It is globally unique inside
the Installation and stable across config edits because it identifies the
Gateway source and, when `config.oauth2.enabled` is true, the Discord OAuth2
login provider instance. It is not a Discord application id, bot user id,
guild id, channel id, or thread id. Discord channel and thread ids become
`scope_id` in Gateway inputs and Deliveries.

`bot_user_id` is optional persisted state; if absent or stale, the adapter
resolves it from the Nostrum `READY` event at startup and updates the
in-memory source config. Persisted `bot_user_id` is only used as an early
preflight hint for mention stripping; it must match the resolved READY user
id (case-insensitive) before the source publishes any inbound event.

`Discord.GatewayAdapter.connectivity_check/1` validates one normalized
`BullX.Gateway.SourceConfig` without starting a Nostrum bot, registering a
listener, publishing a Signal, or writing source config. It loads the
referenced credential profile, calls `GET /users/@me` and `GET
/oauth2/applications/@me` with the bot token, verifies the bot token belongs
to the configured application id, validates the OAuth2 client secret is
present when `oauth2.enabled` is true, validates the application command
sync policy, and returns only redacted operator metadata. Connectivity also
records that **Message Content Intent** is required for the bot to receive
guild message content; operators must enable it on the Discord developer
portal.

Success shape:

```elixir
{:ok,
 %{
   status: :ok,
   adapter: "discord",
   channel_id: "main",
   capabilities: [:inbound, :send, :edit, :stream, :threads, :application_commands],
   details: %{
     "transport" => "gateway",
     "application_id" => "123456789012345678",
     "bot_user_id" => "234567890123456789",
     "credential" => "verified",
     "message_content_intent_required" => true,
     "application_commands_sync_policy" => "safe"
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

Connectivity responses must never include `bot_token`, `client_secret`, raw
`GET /users/@me` bodies, OAuth tokens, or internal retry state.

## Gateway adapter contract

`Discord.GatewayAdapter` implements `BullX.Gateway.Adapter`.

| Callback | Discord behavior |
| --- | --- |
| `config_schema/0` | Describes source config fields, defaults, and redaction rules. |
| `normalize_config/1` | Casts persisted source JSON into adapter runtime config. |
| `public_config/1` | Returns an operator-facing redacted source projection. |
| `capabilities/0` | Declares Discord Gateway WSS inbound, application-command inbound, send, edit, stream, threads, application commands, and supported content kinds. |
| `connectivity_check/1` | Validates credential, application identity, and intent requirements without starting a bot. |
| `source_child_spec/1` | Starts one source listener for an enabled source, or returns `:ignore` for disabled sources. |
| `normalize_inbound/3` | Converts exactly one Discord `MESSAGE_CREATE` or `INTERACTION_CREATE` event into one normalized Gateway input. |
| `deliver/2` | Executes `:send` and `:edit` Deliveries. |
| `stream/3` | Executes `:stream` Deliveries with multi-message accumulation. |

Capabilities should be:

```elixir
%{
  inbound_modes: [:gateway_ws, :interaction],
  outbound_ops: [:send, :edit, :stream],
  content_kinds: [:text, :image, :audio, :video, :file, :card],
  stream_strategy: :edit_accumulate,
  features: [:threads, :application_commands, :ephemeral_replies]
}
```

`content_kinds` includes the full Gateway set so non-text Deliveries are not
rejected at the Gateway core boundary; the adapter renders them as text with
`body.fallback_text`. Native attachment upload is out of scope for the first
version, so degraded outcomes carry a `<kind>_degraded_to_fallback_text`
warning. `features: [:threads]` declares Discord thread targeting;
`:application_commands` declares native command registration;
`:ephemeral_replies` declares ephemeral interaction acknowledgements.

The Gateway core rejects unsupported operations and malformed carrier shapes
before invoking Discord. Discord still validates provider-specific payloads,
target ids, attachment limits, and Discord API responses.

## Inbound source runtime

For each enabled Discord source, `source_child_spec/1` starts a source-local
runtime boundary. The `BullX.Gateway.Adapter.source_child_spec/1` contract
returns a single child spec, so `Discord.Channel` and the `Nostrum.Bot`
subtree are wrapped in a per-source supervisor:

```text
BullX.Gateway.SourceSupervisor
└── Discord.Supervisor (one per source)
    ├── Discord.Channel
    └── Nostrum.Bot (per-bot supervised subtree)
        ├── shard supervisor
        └── consumer dispatcher
```

`Discord.Supervisor` is a `:one_for_all` supervisor. If either child
crashes, both restart so cache state stays consistent with the Gateway
connection state.

`Discord.Channel` owns the normalized source config, source-local dispatch,
bot identity resolution, application-command sync, source-local startup
logs, and source-local dedupe/cache key prefixes. `Nostrum.Bot` owns the
Discord Gateway WSS shard, heartbeats, sequence numbers, and resumption
state. The Nostrum `Discord.Consumer` looks up the channel by Nostrum bot
name and dispatches every event into `Discord.Channel.handle_event/2`; the
channel runs mapping, attention filtering, direct-command interception,
auto-threading, Principal gating, and Gateway publish.

`Discord.Channel` uses `BullX.Cache` for TTL state:

- message context for reply/recall/reaction correlation when later versions
  need it (first version keeps the cache minimal);
- direct-command result dedupe keyed by Discord message id (text
  direct-command path) or interaction id (native interaction path);
- BullX-owned thread ownership keyed by `{source_channel_id, thread_id}`.

Cache entries are reconstructible. If a source restarts and loses
direct-command dedupe state, the next idempotent direct command may resend
the same reply once; `/preauth` activation codes are single-use, so a
duplicate retry returns "already linked" or "invalid code" rather than
re-binding. If a source restarts and loses thread-ownership state, the next
in-thread message resolves ownership through a bounded Discord REST channel
fetch and re-caches the result.

At startup `Discord.Channel`:

1. Resolves the bot user id and bot username from the Nostrum `:READY`
   event. The channel waits for `:READY` before publishing any inbound
   event; events that arrive earlier are dropped with a logged warning.
2. Validates the resolved `application_id` matches the configured one and
   the configured `bot_user_id` (if persisted).
3. Runs `Discord.ApplicationCommands.sync/1` to reconcile BullX-owned global
   application commands when `application_commands.sync_policy = "safe"`.
   Sync failures log a warning but do not crash the source; inbound and
   outbound paths continue working.
4. Begins event dispatch.

Required Discord Gateway intents include `GUILDS`, `GUILD_MESSAGES`,
`DIRECT_MESSAGES`, and `MESSAGE_CONTENT`. The `MESSAGE_CONTENT` intent is
privileged and must be enabled on the Discord developer portal; the
connectivity check documents this requirement.

Webhook ingress for Discord interactions is **not** used in the first
version. All inbound events arrive over the bot's Gateway WSS connection,
including application command invocations, which Discord delivers as
`INTERACTION_CREATE` Gateway events when the bot subscribes for them.

## Inbound normalization

Discord normalized inputs must satisfy `BullX.Gateway.InboundInput`. A
Discord message input has this shape:

```elixir
%{
  "adapter" => "discord",
  "channel_id" => "main",
  "occurrence_key" => "discord:main:message:9876543210",
  "time" => "2026-05-14T00:00:00Z",
  "content" => [
    %{"kind" => "text", "body" => %{"text" => "hello"}}
  ],
  "event" => %{
    "type" => "message",
    "name" => "discord.message_create",
    "version" => 1,
    "data" => %{
      "guild_id" => "111222333444555666",
      "discord_channel_id" => "777888999000111222",
      "message_id" => "9876543210",
      "thread_kind" => nil,
      "attention_reason" => "mention",
      "event_type" => "message_create"
    }
  },
  "actor" => %{
    "id" => "discord:234567890123456789",
    "display" => "Alice",
    "bot" => false,
    "profile" => %{
      "global_name" => "Alice",
      "username" => "alice",
      "avatar_url" => "https://cdn.discordapp.com/avatars/...",
      "user_id" => "234567890123456789"
    },
    "metadata" => %{"guild_id" => "111222333444555666"}
  },
  "scope_id" => "777888999000111222",
  "thread_id" => nil,
  "refs" => [
    %{"kind" => "discord.message", "id" => "9876543210"},
    %{"kind" => "discord.channel", "id" => "777888999000111222"},
    %{"kind" => "discord.guild", "id" => "111222333444555666"},
    %{"kind" => "discord.user", "id" => "234567890123456789"}
  ],
  "reply_channel" => %{
    "adapter" => "discord",
    "channel_id" => "main",
    "scope_id" => "777888999000111222",
    "thread_id" => nil,
    "reply_to_external_id" => "9876543210"
  },
  "provenance" => %{
    "event_id" => "9876543210",
    "event_type" => "message_create",
    "application_id" => "123456789012345678"
  }
}
```

`occurrence_key` uses Discord's message id for `MESSAGE_CREATE` events and
the interaction id for `INTERACTION_CREATE` events. Both are stable and
unique within the bot's scope. For `MESSAGE_UPDATE` events the key is
`"discord:#{channel_id}:edit:#{message_id}:#{edited_timestamp}"`, which
distinguishes successive edits to the same message and keeps the edit
Signal distinct from the original `MESSAGE_CREATE` Signal. The adapter
must not use the Gateway Signal id as the occurrence key.

Discord snowflake ids are JSON-encoded as strings inside Gateway inputs to
keep the carrier JSON-neutral and avoid 64-bit integer issues. The adapter
parses them back to integers when calling Nostrum.

### Actor identity

Discord actor ids are channel-local external ids. User-origin events use
`external_id = "discord:#{user_id}"`. `user_id` is required for Principal
binding. Discord always supplies `user.id` for non-webhook messages; webhook
authors and system messages are ignored.

Trusted profile fields may include `display_name`, `global_name`,
`username`, `avatar_url`, `locale`, and `user_id`. The adapter computes
`display_name` as the first non-empty value of `global_name`, `username`,
`"discord:#{user_id}"`. Discord does not expose email or phone to bots over
the Gateway, so the Principal channel input has no `email` or `phone`
fields; those arrive only through OAuth2 login. User-editable display names
are presentation data, not identity proof.

Self-sent bot messages are filtered before content parsing, Principal
matching, direct-command handling, or publishing. Discord messages whose
`author.bot == true` and whose `author.id` matches the resolved bot user id
are ignored. Messages from other bots and webhook messages are also ignored
in the first version.

### Event mapping

Discord maps the allowed Gateway events onto the Gateway event types:

| Discord event | Gateway `event.type` | Notes |
| --- | --- | --- |
| `MESSAGE_CREATE` (text) | `message` or `slash_command` | Slash-command parsing happens after text normalization; built-in direct commands implemented by this adapter are intercepted before publish. Non-direct `/...` text passes attention policy and publishes as `slash_command`. |
| `MESSAGE_CREATE` (attachment/embed/sticker) | `message` | Content blocks describe the media; primary text uses message content or generated fallback. |
| `MESSAGE_UPDATE` (user edit) | `message_edited` | Filtered to user edits (`edited_timestamp` present and non-null); attention policy and self-author filter still apply. `event.data.target_external_id` is the Discord message id; `refs` includes the edited message. |
| `INTERACTION_CREATE` (type `2` application command, name in `ping/preauth/web_auth`) | direct command | Intercepted; not published. |
| `INTERACTION_CREATE` (type `2` application command, name `ask`) | `slash_command` | Published with `event.name = "discord.application_command"`; ephemeral acknowledgement is sent before publish. |
| `INTERACTION_CREATE` (other types) | ignored | Components, modals, autocomplete, and ping interactions are not part of the first version. |

Channel posts, message recall (`MESSAGE_DELETE`), reactions, thread member
updates, guild member updates, voice events, and presence events are not
normalized in the first version and are dropped after telemetry.

`MESSAGE_UPDATE` filter rules sit before attention policy and event
mapping:

1. `edited_timestamp` absent or `null` → ignore as `non_user_edit`. Discord
   fires `MESSAGE_UPDATE` for embed/link-preview refreshes, pin/unpin, and
   crossposting flag changes; these are not user edits and would create
   `message_edited` Signals that consumers cannot meaningfully react to.
2. `author.bot == true` and `author.id == bot_user_id` → ignore as
   `bot_author`. Self-edits by the bot (including streaming edits) must not
   loop back into the inbound surface.
3. Post-edit `content` empty after bot-mention stripping → ignore as
   `edit_content_empty`.
4. The post-edit message runs through attention policy the same way a
   `MESSAGE_CREATE` would. If the edited message no longer satisfies
   attention (for example, the user removed the bot mention), the update is
   ignored with the usual ignore reason. Owned-thread membership still
   triggers `"owned_thread"` even when the edit removes the mention.

When all four checks pass, the adapter publishes a `message_edited`
Gateway input with the post-edit content blocks, the edited message id as
`event.data.target_external_id` and in `refs`, and the same `scope_id`
mapping rules as `MESSAGE_CREATE`. Partial `MESSAGE_UPDATE` payloads that
include `edited_timestamp` but no `content` are treated as
`edit_content_empty` rather than triggering a Discord REST fetch; the
adapter does not chase partial updates in the first version.

Provider-specific names stay in `event.name`, for example
`discord.message_create`, `discord.application_command`. Gateway core must
not maintain a Discord event-name allowlist.

### Scope, threads, and channel types

`scope_id` is the user-visible conversation surface where BullX is expected
to respond. Discord threads have their own channel id, so a thread is the
scope; it is not modeled as a parent channel plus a sub-key.

| Discord chat surface | Scope mapping |
| --- | --- |
| DM | `scope_id = dm_channel_id`, `thread_id = nil`. |
| Guild text channel (no auto-threading triggered) | `scope_id = channel_id`, `thread_id = nil`. |
| Guild voice text, guild news channel | `scope_id = channel_id`, `thread_id = nil`. Channel-post-only news channels are ignored on inbound. |
| BullX-created thread | `scope_id = thread_channel_id`, `thread_id = nil`. |
| Existing public/private thread or forum post | `scope_id = thread_channel_id`, `thread_id = nil`. |

Parent guild, channel, and thread metadata belongs in `event.data` and
`refs`, not in `scope_id`. This contract means BullX Runtime sessions follow
the visible Discord conversation: a BullX-owned thread is its own
conversation, and parent-channel ordering does not leak into thread session
identity.

`thread_id` is always `nil` for Discord because a Discord thread is modeled
as the scope.

### Attention policy

Inbound Discord events are filtered before publish. The policy returns one
of `"dm"`, `"mention"`, `"application_command"`, `"owned_thread"`,
`"free_response"`, or an ignore reason. Filter order for `MESSAGE_CREATE`:

1. `author.bot == true` and `author.id == bot_user_id` → ignore as
   `bot_author`.
2. `author.bot == true` (any other bot) or webhook author → ignore as
   `bot_author`.
3. `channel_id` in `attention.ignored_channel_ids` → ignore as
   `ignored_channel`.
4. Message thread id (when the message is in a thread) in
   `attention.ignored_thread_ids` → ignore as `ignored_thread`.
5. `attention.allowed_channel_ids` non-empty and `channel_id` not in it,
   AND the message channel is not a BullX-owned thread → ignore as
   `outside_allowlist`. (Allowlist applies to the parent channel; once
   ownership is established for a thread, allowlist no longer applies inside
   it.)
6. `guild_id == nil` (DM) → `"dm"`.
7. Message mentions the bot user id → `"mention"`.
8. Message is in a Discord thread, and `Discord.ThreadOwnership.owned?/3`
   returns `true` → `"owned_thread"`.
9. `channel_id` in `attention.free_response_channel_ids`, or
   `attention.require_mention == false` → `"free_response"`.
10. Otherwise → ignore as `unmentioned_guild_message` or
    `thread_ownership_unresolved` when ownership resolution failed.

Filter order for `INTERACTION_CREATE`:

1. `attention.ignored_channel_ids` or `attention.ignored_thread_ids`
   matching → ignore.
2. `attention.allowed_channel_ids` non-empty and channel not in it → ignore
   as `outside_allowlist`.
3. Otherwise → `"application_command"`. Native application commands always
   express explicit intent.

The attention reason lives in `event.data.attention_reason`. It is
operator-visible diagnostic data, not an authorization signal.

`attention.require_mention: false` enables a global free-response mode
inside non-ignored, non-allowlisted-out channels. Operators should pair this
with `free_response_channel_ids` and/or `allowed_channel_ids` rather than
opening it Installation-wide.

### Content mapping

Inbound content mapping precedence:

1. **Plain text** (`message.content` non-empty after bot-mention stripping)
   → one `:text` block:

   ```elixir
   %{"kind" => "text", "body" => %{"text" => "hello"}}
   ```

   Bot mentions are stripped before publish; mention metadata stays in
   `refs`. Empty content after stripping is rejected as a payload error
   and not published.

2. **Attachments** (`message.attachments`) → an optional caption text block
   followed by one native media block per attachment:

   ```elixir
   %{
     "kind" => "image",
     "body" => %{
       "url" => "discord://attachment/<channel_id>/<attachment_id>",
       "fallback_text" => "[image]"
     }
   }
   ```

   Mapping rules:

   | Discord content type / hint | Block `kind` |
   | --- | --- |
   | `image/*` content type | `:image` |
   | `audio/*` content type | `:audio` |
   | `video/*` content type | `:video` |
   | Any other content type | `:file` |
   | `message.stickers` (any) | `:image` per sticker |

   `fallback_text` is the localized `gateway.discord.media.<kind>` value.
   Discord attachment cdn URLs are time-limited; the adapter records only
   the stable `discord://attachment/<channel_id>/<attachment_id>` URI inside
   Gateway content, and resolves the cdn URL on demand through Nostrum.
   `refs` records the stable Discord channel and attachment ids.

3. **Embeds** (`message.embeds`) → one `:text` block when the embed has a
   `description` or `title`; the adapter does not normalize embed field
   structures into Gateway content in the first version. Empty embeds are
   skipped.

4. **Stickers without content type** → one `:text` block with the sticker
   name as fallback through `gateway.discord.media.sticker`.

5. **`/ask` interaction** → one `:text` block built from the required
   `prompt` option.

The adapter must not publish empty content for a user-origin event.

`discord://attachment/<channel_id>/<attachment_id>` URIs are channel-local
opaque references. The adapter does not download bytes at normalization
time; downloads happen on-demand only when a consumer requests them.

## Principal account gate

Before publishing normal user-origin duplex events, Discord calls
`BullX.Principals.match_or_create_human_from_channel/1` with the normalized
channel actor:

```elixir
%{
  "adapter" => "discord",
  "channel_id" => "main",
  "external_id" => "discord:234567890123456789",
  "profile" => %{
    "display_name" => "Alice",
    "global_name" => "Alice",
    "username" => "alice",
    "avatar_url" => "https://cdn.discordapp.com/avatars/...",
    "user_id" => "234567890123456789"
  },
  "metadata" => %{
    "source" => "discord_gateway",
    "guild_id" => "111222333444555666",
    "discord_channel_id" => "777888999000111222"
  }
}
```

Result handling:

| Principal result | Adapter behavior |
| --- | --- |
| `{:ok, _principal, _identity}` | Run auto-threading if applicable, then publish the normalized Gateway input. |
| `{:error, :activation_required}` | Send a localized activation-required reply when appropriate and do not publish. |
| `{:error, :principal_disabled}` | Send a localized denied reply when configured and do not publish. |
| `{:error, reason}` | Treat as a provider-processing failure and do not acknowledge success unless the provider requires a safe terminal response. |

The resolved Principal id is never injected into the Gateway Signal.
Runtime, Router, Agent, Brain, Admission, and Work consumers continue to
receive channel-local actor data unless a later design adds a
Principal-aware Signal contract.

In guild channels and threads, activation-required replies must not include
activation codes, login auth codes, or links that reveal account state. The
reply directs the user to message the bot privately. For `/ask`
interactions, the activation prompt is an ephemeral interaction response.
For mention-based guild messages, the prompt is a localized reply to the
triggering Discord message. DMs receive a normal DM reply that may include
`/preauth <code>` and `/web_auth` guidance.

## Direct commands

Direct commands are built-in BullX channel commands implemented by messaging
adapters. In this design, the Discord adapter handles the shared `/ping`,
`/preauth`, and `/web_auth` command names before publishing slash-command
Signals. The command contract is not Discord-specific; another messaging
adapter can implement the same names with its own transport, actor
normalization, and delivery mechanics.

For Discord, direct commands run after Gateway event reception,
self-sent-bot filtering, attention classification, and direct-command
dedupe lookup. Only `/ping`, `/preauth`, and `/web_auth` are intercepted by
the Discord adapter. Other normalized text messages that start with `/` and
pass attention policy publish as Gateway `slash_command` inputs after
Principal account gating. `/ask` is handled separately in its own section
below because it is registered as a native application command.

A direct command may arrive through two transports:

- **Plain text message** (`MESSAGE_CREATE` with `/ping`, `/preauth <code>`,
  or `/web_auth`) — reply is delivered as a Gateway external Delivery via
  `BullX.Gateway.deliver/1` to the triggering channel as a reply.
- **Native application command interaction** (`INTERACTION_CREATE` for the
  registered `/ping`, `/preauth`, or `/web_auth` commands) — reply is sent
  as an **ephemeral** interaction response (`flags = 64`) directly via
  Nostrum, so account-state and code values are visible only to the
  invoking user. This is a Discord-specific deviation from the Gateway
  outbound path because Discord interaction tokens are short-lived and only
  the original interaction id can produce an ephemeral response.

The interaction-response deviation is allowed only for `/ping`, `/preauth`,
and `/web_auth`. All other Discord outbound delivery still goes through
`BullX.Gateway.deliver/1`.

### `/ping`

`/ping` is a manual connectivity command. It works in DMs and guild
channels (when addressed via mention or native command), does not require
Principal activation, and does not call
`BullX.Principals.match_or_create_human_from_channel/1`.

For text transport, the adapter builds a Gateway external Delivery with
`op = :send`, the current `{adapter, channel_id}`, the Discord channel id
as `scope_id`, and the current message id as `reply_to_external_id`. The
localized reply body is `PONG!` in bundled locales.

For interaction transport, the adapter responds with an ephemeral `PONG!`.

The adapter acknowledges the Discord event only after Gateway accepts the
Delivery, the ephemeral interaction response succeeds, or a duplicate
direct-command result is found.

### `/preauth <code>`

`/preauth <code>` consumes a BullX activation code and creates a new Human
Principal with the current Discord actor as the first channel binding.

Flow:

1. Reject guild channels and guild threads with a localized DM-only
   instruction and do not consume the code. The reply is ephemeral for
   interactions; for text it goes through the Gateway outbound path.
2. Normalize the Discord actor and trusted profile.
3. Call `BullX.Principals.consume_activation_code(code, channel_input)`.
4. Submit one localized Discord reply (ephemeral interaction response or
   Gateway external Delivery, depending on transport).
5. Do not publish the command as a Gateway Signal.

Result mapping:

| Principal result | Discord reply key |
| --- | --- |
| `{:ok, _principal, _identity}` | `gateway.discord.auth.activation_success` |
| `{:error, :invalid_or_expired_code}` | `gateway.discord.auth.activation_code_invalid` |
| `{:error, :already_bound}` | `gateway.discord.auth.already_linked` |
| `{:error, :principal_disabled}` | `gateway.discord.auth.denied` |
| any other `{:error, _}` | `gateway.discord.auth.activation_failed` |

The direct-command result cache stores the reply result by Discord message
id (text path) or interaction id (interaction path) for the configured
short TTL so transport retries do not send duplicate activation replies. A
duplicate id returns the cached result without re-running
`consume_activation_code/2`.

### `/web_auth`

`/web_auth` issues a built-in channel-auth login code for an already bound
active Human Principal. It is separate from Discord OAuth2 login and uses
the Principal login-auth-code table.

Flow:

1. Reject guild channels and guild threads with a localized DM-only
   instruction and do not issue a code.
2. If `config.oauth2.enabled == false` and the Installation has no other
   OAuth2 path for this source, the adapter still issues a channel-auth
   code; the operator-visible Web login URL is the generic
   `/sessions/new` page.
3. Normalize the Discord actor and trusted profile.
4. Call `BullX.Principals.issue_login_auth_code("discord", channel_id, "discord:#{user_id}")`.
5. Render a localized reply containing the short-lived code and the generic
   Web login URL.
6. Submit the reply as an ephemeral interaction response or Gateway
   external Delivery, depending on transport.
7. Do not publish the command as a Gateway Signal.

Result mapping:

| Principal result | Discord reply key |
| --- | --- |
| `{:ok, code}` | `gateway.discord.auth.web_auth_created` |
| `{:error, :not_bound}` | `gateway.discord.auth.web_auth_not_bound` |
| `{:error, :principal_disabled}` | `gateway.discord.auth.denied` |
| `{:error, :not_human}` | `gateway.discord.auth.web_auth_not_bound` |
| any other `{:error, _}` | `gateway.discord.auth.web_auth_failed` |

The login auth code never enters telemetry, logs, error details, receipts,
or dead letters. Only its issuance outcome is recorded.

## `/ask` native application command and auto-threading

`/ask <prompt:string>` is the Discord-shaped entry point for opening a
BullX conversation in a guild. It is registered as a Discord native
application command and is published as a Gateway `slash_command` input
after Principal gating.

`/ask` is **not** a direct command; the BullX answer flows from Runtime
back to Discord through the normal Gateway outbound path.

Flow for `/ask` in a guild text channel:

1. `Discord.AskCommand` receives the `INTERACTION_CREATE` event.
2. Attention policy classifies it as `"application_command"`.
3. The actor is normalized and run through Principal account gate. If
   activation is required, the adapter responds with an ephemeral
   activation-required prompt and does not publish.
4. The adapter sends an ephemeral acknowledgement
   (`gateway.discord.ask.accepted`) so Discord's three-second
   interaction-response window is satisfied immediately.
5. If `auto_thread.enabled == true` and the channel is a guild text channel
   not listed in `auto_thread.no_thread_channel_ids`, the adapter creates a
   BullX-owned Discord thread from the channel with an `auto_archive_duration`
   set from config. The thread name is derived from the trimmed first ~80
   characters of the prompt. If thread creation fails, the adapter replies
   with a localized error (`gateway.discord.errors.thread_create_failed`)
   and does not publish.
6. The adapter caches the created thread as BullX-owned in
   `Discord.ThreadOwnership` and rewrites the input `scope_id` to the
   thread channel id.
7. The adapter publishes a `slash_command` Gateway input. The reply will
   arrive in the thread through normal Gateway outbound.

Flow for `/ask` in a DM or inside an existing thread: the same as above
without thread creation. `scope_id` is the DM channel id or the existing
thread channel id.

The `/ask` interaction id is recorded as the `occurrence_key` and in
`refs`. The created thread id is recorded in `refs` so consumers can
reconstruct the thread relationship.

### Thread ownership

`Discord.ThreadOwnership.owned?(thread_channel_id, source, cache)` decides
whether an inbound message inside a Discord thread should bypass mention
requirements.

Resolution order:

1. Cache hit on `{source.channel_id, thread_channel_id}` → return cached
   `boolean`.
2. Cache miss → call `Nostrum.Api.Channel.get(thread_channel_id)`. A thread
   is BullX-owned when:
   - the channel type is a Discord thread type (`10`, `11`, or `12`); and
   - `owner_id` equals the resolved `bot_user_id`.
   The result is cached for `thread_ownership_cache_ttl_seconds`.
3. Resolution error (network, 404, permission) → return
   `:thread_ownership_unresolved` so attention policy falls closed.

`Discord.ThreadOwnership.mark_owned/3` is called immediately after the
adapter creates a thread, so the next message inside the thread short-circuits the cache without a REST call.

Thread ownership is **not** persisted to PostgreSQL. The risk is that
another feature reusing the same Discord bot could create a thread with the
same owner and be treated as BullX-owned. That is acceptable in the first
implementation because the Discord adapter is the only component creating
threads with this bot. If that changes, the new feature must introduce an
explicit Discord-side marker or a separately approved generic Gateway
scope-state table.

## Native application command sync

The adapter registers four BullX-owned global application commands:

| Name | Description | Options |
| --- | --- | --- |
| `ping` | Check BullX Discord connectivity | none |
| `preauth` | Link this Discord account to BullX | `code: string` (required) |
| `web_auth` | Create a BullX web login code | none |
| `ask` | Ask BullX in a Discord thread | `prompt: string` (required) |

`Discord.ApplicationCommands.sync/1` runs on `:READY` and reconciles only
BullX-owned command names:

1. List existing global application commands for the configured
   `application_id`.
2. For each desired command:
   - Create it if missing.
   - Edit it only if the relevant fields (`name`, `description`, `type`,
     normalized `options`) differ.
3. Delete commands whose name is in the BullX-owned set
   (`ping/preauth/web_auth/ask`) but that are no longer desired.
4. **Never** bulk-overwrite the application's global command list. Discord
   applications can host commands registered by other features outside
   BullX (other bots' codepaths, manual operator-registered commands); bulk
   replace would erase them.

Sync policy values:

- `"safe"` (default): runs the selective reconciliation above on every
  `:READY`. Failures log a warning; inbound and outbound paths continue
  working.
- `"off"`: skips sync entirely. Operators must register commands manually
  or accept that native command UX is unavailable; `/ping`, `/preauth`, and
  `/web_auth` text-message paths still work.

Application command sync uses `Nostrum.Api.ApplicationCommand` under
`Nostrum.Bot.with_bot/2`.

## Principal OAuth2 login provider

`Discord.OAuth2Provider` implements the Principal login-provider hook for
Human browser login. The host extension point is
`:"bullx.principals.login_provider"`. The extension id `"discord"`
identifies the provider implementation type. It is not the concrete
provider id stored in Principal login-subject identities. For Discord, the
concrete provider id is the configured source slug, which is the source
`channel_id`.

Discord OAuth2 is OAuth 2.0, not OIDC: there is no `id_token`. Userinfo is
obtained from `GET /users/@me` with the access token as Bearer credential.
This still fits the generic `BullX.Principals.LoginProvider` behaviour,
which expects `authorization_url/2` and `callback/3` to return a normalized
login subject map.

The generic Web login controller receives a provider id from the login
route. For Discord, that provider id is the source slug. The controller
loads the enabled Gateway source by that slug, verifies
`adapter = "discord"` and `config.oauth2.enabled = true`, resolves the
Discord login-provider implementation, asks it for an authorization URL,
signs provider state with Phoenix token infrastructure, and redirects the
browser. The callback verifies the signed state, calls the provider
callback, passes the returned login subject to
`BullX.Principals.match_or_create_human_from_login_subject/1`, renews the
Phoenix session on success, and stores the Principal id in the session.

Discord authorization state includes:

```elixir
%{
  "provider" => "main",
  "adapter" => "discord",
  "channel_id" => "main",
  "return_to" => "/",
  "issued_at" => 1_715_558_400,
  "nonce" => "random"
}
```

The state `provider` and `channel_id` both refer to the source slug and
must match. The `adapter` value selects the Discord implementation.

Authorization URL:

```text
https://discord.com/oauth2/authorize?
  client_id=<application_id>&
  redirect_uri=<redirect>&
  response_type=code&
  scope=identify%20email&
  state=<signed_state>
```

The callback flow is:

1. Verify signed state, source slug, adapter, nonce, age, and local
   `return_to`.
2. Exchange `code` at `https://discord.com/api/oauth2/token` with
   `client_id`, `client_secret`, `grant_type=authorization_code`,
   `redirect_uri`, and `code`.
3. Fetch userinfo at `https://discord.com/api/users/@me` with the access
   token as `Authorization: Bearer ...`.
4. Normalize a Principal login subject:

   ```elixir
   %{
     "provider" => "main",
     "external_id" => "discord:234567890123456789",
     "profile" => %{
       "display_name" => "Alice",
       "global_name" => "Alice",
       "username" => "alice",
       "email" => "alice@example.com",
       "avatar_url" => "https://...",
       "user_id" => "234567890123456789"
     },
     "metadata" => %{
       "adapter" => "discord",
       "channel_id" => "main",
       "application_id" => "123456789012345678",
       "verified_email" => true,
       "locale" => "en-US"
     }
   }
   ```

5. Discard the Discord user access token and refresh token after userinfo
   retrieval.

`provider = "main"` above is the configured source slug. Multiple Discord
applications may be configured at the same time as different enabled
sources, each with its own slug, application id, bot token, client secret,
and OAuth2 setting. The Principal login-subject identity namespace is the
source slug, not the connector type `"discord"` and not the Discord
application id. The login subject `external_id` uses the source-local
Discord `user_id`, for example `discord:#{user_id}`. `adapter`,
`application_id`, and `channel_id` stay in metadata for audit and operator
diagnostics.

Discord channel actors remain channel-local and keep
`external_id = "discord:#{user_id}"` under the `channel_actor` identity
kind. Principal matching owns any binding between that channel actor and
the source-scoped Discord login subject.

Profile rules:

- `display_name` is the first non-empty of `global_name`, `username`.
- `email` is included **only** when Discord returns `verified == true` and
  a non-empty `email`. Unverified Discord emails are dropped from the
  login subject.
- `avatar_url` is built from `id` and `avatar` hash only when both are
  present.
- `locale` is metadata, not a BullX locale selector.

If userinfo lacks `id`, the login fails closed without creating or binding
a Principal.

`BullX.Principals` owns the binding and creation decision. The OAuth2
provider must not write `principal_external_identities` directly. On
`{:error, :not_bound}`, the Web surface directs the user to activate from
Discord with `/preauth`. On `{:error, :principal_disabled}` or
`{:error, :not_human}`, it fails closed.

## Outbound delivery

Discord outbound delivery executes already-authorized Gateway external
Deliveries. The plugin does not decide whether an Agent may speak in a
channel, edit a message, or stream. Governance and upstream Runtime decide
that before submitting a Delivery to Gateway.

`Discord.GatewayAdapter.deliver/2` handles `:send` and `:edit`.
`Discord.GatewayAdapter.stream/3` handles `:stream`.

Discord snowflake ids appear in Delivery fields as strings (matching the
carrier shape). The adapter parses them back to integers before calling
Nostrum.

### Allowed mentions

Every outbound `Discord.Delivery` call uses safe `allowed_mentions`:

```elixir
%{"parse" => ["users"], "replied_user" => true}
```

This disables `@everyone` and role mentions by default. User mentions and
the replied-user notification are allowed because they are how Discord
conversations normally work; without them, mentioned users would not see
the reply.

### Message length limits

Discord measures message content in UTF-16 code units, with a hard limit of
2000 units per message. The soft limit for streaming is
`stream_chunk_soft_limit` (default 1850) to leave room for in-flight edits.

`Discord.ContentMapper.split_message/2` walks codepoints, treating
codepoints above `0xFFFF` as two UTF-16 units. Splitting walks codepoints,
not graphemes, because counting graphemes would mis-count surrogate pairs
and break long Asian-script or emoji-heavy messages.

### Send

Targeting rules:

- `delivery.scope_id` is the Discord channel id or thread channel id
  (snowflake string).
- `delivery.thread_id` is always `nil` for Discord because a Discord thread
  is the scope.
- `delivery.reply_to_external_id`, when present, is passed via Discord
  `message_reference` with `fail_if_not_exists: false`.

Content rules:

- `text` sends `POST /channels/<id>/messages` with the rendered text. Text
  exceeding 2000 UTF-16 units splits into multiple message creates. The
  adapter returns all created message ids in `external_message_ids`;
  `primary_external_id` is the first message id.
- `image`, `audio`, `video`, `file`, and `card` degrade to one text-only
  send with `body.fallback_text`. The outcome includes a warning of the
  form `"<kind>_degraded_to_fallback_text"` so Runtime can observe the
  degrade. Native attachment upload is out of scope for the first version.

If Discord reports that a reply target was recalled or missing (HTTP 404
on the create call against the referenced message), the adapter retries
once as a normal channel send without `message_reference`. A successful
fallback returns a degraded outcome with a warning
`"reply_target_missing_sent_to_scope"`. If `scope_id` is missing, the
adapter returns a payload error.

### Edit

`delivery.target_external_id` is required for edit. Discord supports
editing message content via `PATCH /channels/<id>/messages/<id>` in the
first version. Editing embeds, components, or attachments is not in scope.

Edited content exceeding 2000 UTF-16 units returns a payload error rather
than silently truncating, unless the edit is part of an active streaming
context where the streamer is responsible for splitting (see Stream
below).

Discord's "message is not modified" or no-op responses are treated as
success with a warning `"message_unchanged"`, not an error.

Missing or uneditable target messages map to payload, unsupported, or
not-found errors, not network errors. Editing another user's message
returns a permission error.

### Stream

Discord streaming uses multi-message accumulation with throttled edits and
final reconciliation. The state machine matches RFC 0015 / `bullx_discord/
streamer.ex` in mechanics, with current naming.

State:

```elixir
%{
  delivery: %BullX.Gateway.Delivery{...},
  source: %Discord.Source{...},
  current_text: "",
  message_ids: [],     # ordered list of created Discord message ids
  last_update_at: nil, # monotonic ms timestamp of last edit/send
  warnings: []
}
```

Chunk shapes accepted from the Gateway stream:

- `binary()` appends text.
- `%{text: binary()}` or `%{"text" => binary()}` appends text.
- `%{replace_text: binary()}` or `%{"replace_text" => binary()}` replaces
  the accumulated text and forces a flush.

For each accepted chunk:

1. Update `current_text` accordingly.
2. Split `current_text` into chunks at `stream_chunk_soft_limit` UTF-16
   units per chunk.
3. If `length(chunks) > length(message_ids)`, edit the last existing
   message to its corresponding chunk and then create the missing tail
   chunks without `message_reference` (reply references only apply to the
   first message in the stream).
4. Otherwise, if `now - last_update_at >= stream_update_interval_ms` or the
   chunk forced a flush, edit the last existing message with its
   corresponding chunk.

On stream end:

1. `current_text` empty → return a payload error
   (`"stream content is absent"`).
2. Re-split and reconcile: edit every existing message to its current
   chunk, create any missing tail chunks, and `DELETE` any extra messages
   beyond the final chunk count.
3. Return a `sent` outcome with `external_message_ids` set to the final
   message list and `primary_external_id` set to the first message id.

If `stream/3` receives absent or non-enumerable stream content (including
a dead-letter replay that cannot reconstruct the live stream), it returns:

```elixir
{:error, %{"kind" => "payload", "message" => "stream content is not replayable"}}
```

On stream exception or cancellation, the adapter attempts one final edit
of the last existing message with localized failure text
(`gateway.discord.delivery.stream_failed` or `stream_cancelled`), then
returns the original normalized error to Gateway.

Discord rate-limit responses (HTTP 429 with `retry_after`) are honored
inline by the streamer with `BullX.Retry` up to a configured bound. Longer
waits return a retryable transport error so Gateway core can apply its
outbound retry budget.

The streamer does not strip `message_reference` from the first message;
reply parameters apply only to message 0. Subsequent split messages use
bare creates.

## Error mapping

`Discord.Error` maps Nostrum, Discord HTTP, and `Req` failures into Gateway
adapter error maps. All returned errors are JSON-neutral and string-keyed:

```elixir
%{
  "kind" => "rate_limit",
  "message" => "Discord API rate limited",
  "details" => %{
    "retry_after_ms" => 3000,
    "http_status" => 429,
    "discord_code" => 20028
  }
}
```

Mapping rules:

| Condition | Error kind |
| --- | --- |
| HTTP 429 or Discord rate-limit response | `rate_limit` |
| HTTP 401, invalid bot token, invalid OAuth credentials | `auth` |
| HTTP 403, missing Discord permission, bot lacks guild access | `permission` |
| HTTP 404 on edit/reply target | `payload` (mapped to "not_found" semantics for Gateway terminal handling) |
| Timeout, DNS, TLS, Gateway WSS disconnect, transient 5xx | `network` or `provider_unavailable` |
| Invalid source config, missing credential profile, application id mismatch | `config` |
| Invalid content, missing target, malformed interaction option, stream replay without content | `payload` |
| Unsupported edit kind, unsupported event surface, content with no fallback | `unsupported` |
| Stream cancellation observed by the adapter | `stream_cancelled` |
| Unknown Discord/Nostrum error | `unknown` |

`details` may include `http_status`, `discord_code`, `retry_after`, and
redacted endpoint context. It must not include the bot token, client
secret, OAuth tokens, OAuth codes, raw message or interaction bodies,
plaintext activation/login codes, or private interaction values.

Adapters do not emit Gateway-owned error kinds such as `"contract"` or
`"adapter_restarted"` unless Gateway core defines that mapping for adapter
contract violations.

## Telemetry and logs

Discord emits telemetry under:

```text
[:bullx, :discord, :source, :start]
[:bullx, :discord, :gateway, :ready]
[:bullx, :discord, :gateway, :reconnect]
[:bullx, :discord, :application_commands, :sync]
[:bullx, :discord, :event, :received]
[:bullx, :discord, :event, :ignored]
[:bullx, :discord, :event, :mapped]
[:bullx, :discord, :event, :publish, :start]
[:bullx, :discord, :event, :publish, :stop]
[:bullx, :discord, :event, :publish, :exception]
[:bullx, :discord, :direct_command, :handled]
[:bullx, :discord, :ask, :acknowledged]
[:bullx, :discord, :thread, :created]
[:bullx, :discord, :thread, :ownership_resolved]
[:bullx, :discord, :delivery, :start]
[:bullx, :discord, :delivery, :stop]
[:bullx, :discord, :delivery, :exception]
[:bullx, :discord, :stream, :flush]
[:bullx, :discord, :oauth2, :callback]
```

Safe metadata includes `adapter`, `channel_id`, `application_id`,
`bot_user_id`, `guild_id`, `discord_channel_id`, `thread_channel_id`,
`message_id`, `interaction_id`, `event_type`, `delivery_id`,
`attention_reason`, command name, and sanitized HTTP `status` or
`discord_code`.

Logs are part of the manual-run contract. Startup, bot READY, application
command sync, inbound mapping, attention decisions, direct-command
handling, `/ask` acknowledgement, thread creation, publish result,
outbound delivery, stream flush, and OAuth2 callback paths should emit
safe structured log lines. Logs must not include the bot token, client
secret, OAuth tokens, OAuth codes, raw message/interaction bodies, raw
message text beyond what already lives in normalized content, plaintext
activation/login codes, or private interaction values.

## I18n

All human-facing Discord text uses `BullX.I18n` and the
application-global locale. The adapter does not choose locale from Discord
user `locale`, guild preferred locale, `Accept-Language`, or browser
settings.

Add at least these keys in supported locales:

```toml
[gateway.discord.auth]
activation_required = "..."
activation_success = "..."
activation_code_invalid = "..."
activation_failed = "..."
already_linked = "..."
web_auth_created = "..."
web_auth_not_bound = "..."
web_auth_failed = "..."
web_auth_disabled = "..."
login_not_bound = "..."
denied = "..."
direct_command_dm_only = "..."

[gateway.discord.ping]
pong = "PONG!"

[gateway.discord.ask]
accepted = "..."

[gateway.discord.delivery]
fallback_text = "..."
stream_generating = "..."
stream_failed = "..."
stream_cancelled = "..."
reply_target_missing_sent_to_scope = "..."

[gateway.discord.media]
image = "..."
audio = "..."
video = "..."
file = "..."
sticker = "..."

[gateway.discord.errors]
unsupported_message = "..."
profile_unavailable = "..."
thread_create_failed = "..."
```

Tests must fail if a key used by the adapter is missing in any bundled
locale.

## Security and privacy

Discord transport authenticity stays adapter-owned. The Gateway WSS
connection is authenticated by the bot token through Nostrum's session
identification handshake. OAuth2 token exchange and userinfo fetching run
over TLS to `discord.com` with the client secret in the token request
body, never in a query string.

The adapter must:

- drop self-sent bot messages and other bots' messages before publish;
- ignore webhook messages and system messages;
- reject `/preauth` and `/web_auth` in guild channels and guild threads
  without consuming or issuing secrets;
- send `/preauth`, `/web_auth`, and unauthorized-command rejections as
  ephemeral interaction responses when invoked via native interaction, so
  account-linking status and channel-auth codes are not visible to other
  guild members;
- validate OAuth2 state, nonce, source id, age, and local `return_to`;
- discard Discord user access and refresh tokens after userinfo retrieval;
- never include unverified Discord emails in the login subject;
- keep bot tokens, OAuth client secrets, OAuth codes, OAuth tokens, raw
  event payloads, and raw callback bodies out of logs and persisted
  Gateway records;
- keep provider credential values in `BullX.Config` secret storage;
- keep Gateway actor ids channel-local and avoid writing Principal ids
  into Signals;
- refuse to start a second Discord Gateway connection against the same bot
  token on the same node;
- apply safe `allowed_mentions` defaults to every outbound message and
  every interaction reply.

Discord outbound delivery may be customer-facing. The adapter assumes the
Delivery already passed Governance or another upstream authorization
boundary. The adapter must not add a shortcut that lets direct Discord API
calls bypass Gateway outbound validation for business effects. The
ephemeral-interaction reply path is restricted to the three documented
direct commands plus the `/ask` ephemeral acknowledgement; it is not a
general bypass.

## Failure behavior

Provider authentication failures, malformed events, missing required
Discord fields, missing credential profiles, and unsupported content fail
closed. They produce redacted telemetry and safe logs.

For inbound events, the adapter acknowledges Discord (advances Nostrum's
session sequence and considers the event handled) only when one of these
conditions is true:

- the event was intentionally ignored (self-sent bot, ignored channel,
  outside allowlist, unmentioned guild message, unsupported event surface,
  unresolved thread ownership);
- an adapter-local direct command completed or a duplicate direct-command
  result was found;
- `BullX.Gateway.publish/2` returned accepted;
- the event is structurally malformed and retry would not help (a payload
  error).

For outbound Delivery, Discord errors follow the Gateway retry and
terminal outcome contract. Retryable errors include rate limiting
(`retry_after` honored inline up to a bound, then surfaced as retryable),
network failures, timeouts, and temporary provider unavailability. Auth,
permission, payload, unsupported, and malformed-target errors are terminal
unless Discord supplies a specific retry hint.

Process-local state is reconstructible. If `Discord.Channel` or the
Nostrum bot subtree restarts, `Discord.Supervisor` restarts both
together; the Gateway WSS connection reconnects through Nostrum's normal
resumption protocol, cache entries rebuild opportunistically, and thread
ownership re-resolves from Discord channel metadata on demand. Gateway and
Principal durable facts remain in PostgreSQL.

If the Nostrum bot reports a fatal Gateway authentication failure
(invalid token), the supervisor crashes and operator alerts observe the
condition rather than silently retrying.

## Alternatives considered

| Alternative | Decision |
| --- | --- |
| Port the old main-branch RFC 0015 directly | Rejected. It is tied to old Gateway, Accounts, Web controller topology, `Nostrum 0.11.0-dev` Git pin, and adapter-array config shape that no longer fits the Plugin/Gateway/Principal boundaries. |
| Add Discord directly under BullX core | Rejected. The plugin system is the selected integration boundary. |
| Use a top-level `BullXDiscord` app outside `plugins/*` | Rejected. The source boundary should be the plugin Mix project. |
| Use plugin id `bullx_discord` + `BullxDiscord.*` namespace | Rejected. `Discord.*` is free; the Telegram detour was forced by `visciang/telegram` taking the root namespace, which does not apply here. |
| Build a new `packages/discord_api` to mirror `packages/feishu_openapi` | Rejected for the first version. Discord Gateway WSS, sharding, heartbeat, and resumption are non-trivial; Nostrum already implements them and exposes per-bot supervision. A BullX-owned package can be added later if needed. |
| Use Nostrum's application-global bot configuration | Rejected. Transport lifecycle belongs to `BullX.Gateway.SourceSupervisor`. Each source declares its own `Nostrum.Bot` child under `Discord.Supervisor`. |
| Support multiple BullX sources sharing one Discord bot token | Rejected for the first version. Discord rejects concurrent Gateway connections without shard coordination; the adapter detects and refuses. Shard coordination is a later design. |
| Bulk-overwrite Discord application commands | Rejected. Discord applications may host commands registered outside BullX; bulk overwrite would erase them. Sync is selective reconciliation by BullX-owned names only. |
| Drop `/ask` and auto-threading for parity with Feishu/Telegram | Rejected. Native slash commands and threaded conversations are the dominant Discord interaction pattern in busy guilds; dropping them visibly degrades the Discord experience. The adapter accepts the cost of `Discord.AskCommand`, `Discord.ThreadOwnership`, and the auto-thread branch in the consumer. |
| Drop `MESSAGE_UPDATE` for parity with old RFC 0015 inbound surface | Rejected. Telegram v1 publishes `edited_message` as `message_edited`; aligning Discord keeps the cross-adapter event surface coherent and lets Runtime consumers reason about edits uniformly. Filtering rules guard against Discord's non-user `MESSAGE_UPDATE` fires (embed refresh, pin) so the cost stays bounded. |
| Persist BullX-owned thread membership in PostgreSQL | Rejected. Thread ownership is adapter-local Discord state, reconstructible from Discord channel `owner_id`. A bounded `BullX.Cache` entry plus REST fallback resolves it without a Discord-specific schema. |
| Model BullX-owned threads as `scope_id = parent_channel_id, thread_id = thread_channel_id` | Rejected. A Discord thread has its own channel id and is the visible conversation; mapping it as a sub-key of the parent channel would tangle Runtime session identity with the parent channel and break per-thread ordering. |
| Drop OAuth2 login for v1 in favor of `/preauth` + `/web_auth` only | Rejected. Discord OAuth2 is real OAuth2, the `BullX.Principals.LoginProvider` host is already in place, and OAuth2 lets Discord browser users complete first-time login without needing to message the bot first. |
| Use Discord webhook ingress for interactions | Rejected. Webhook ingress adds a Phoenix controller, public endpoint, signature validation, and per-source URL mount. Gateway WSS via Nostrum delivers `INTERACTION_CREATE` events on the same connection as messages, with no extra public surface. |
| Implement native attachment upload (`sendMessage` with files) in v1 | Rejected. Outbound content kinds are limited to `:text` in the first version; non-text degrades to `fallback_text`. Native attachment upload will arrive with a follow-up design once media URI resolution is shared across adapters. |
| Publish reactions, recalls, channel posts, member updates, voice events | Rejected for v1. Inbound surface is pinned to `MESSAGE_CREATE` and a subset of `INTERACTION_CREATE`. A later version may extend the list when consumers exist. |
| Maintain adapter-local ETS cache | Rejected. `BullX.Cache` already provides TTL state with predictable supervision and metrics. |
| Put resolved Principal ids into Gateway Signals | Rejected. Gateway actor data stays channel-local; Principal-aware routing needs a later design. |
| Strip `@bot_user` mentions from inbound text at the adapter edge | Adopted. Discord users see the original message in Discord; the normalized text drops the literal `<@id>` token so consumers receive clean prompts. Mention metadata stays in `refs`. |
| Silently retry on Gateway invalid-token | Rejected. A persistent auth failure indicates a rotated or revoked token; the bot subtree crashes and the supervisor surfaces the condition. |

### Behaviors deliberately carried over from main-branch RFC 0015 / `lib/bullx_discord/`

- Nostrum-based per-source bot supervision with a stable per-channel bot
  name; all REST calls under `Nostrum.Bot.with_bot/2`.
- Gateway intents include `MESSAGE_CONTENT`; connectivity check documents
  the requirement.
- `:READY`-time bot user id and application id resolution; application
  command sync runs on `:READY`.
- Selective application command reconciliation by BullX-owned name; never
  bulk overwrite.
- Attention-policy ignore-reason taxonomy: `bot_author`, `ignored_channel`,
  `ignored_thread`, `outside_allowlist`, `unmentioned_guild_message`,
  `thread_ownership_unresolved`.
- DM/mention/`application_command`/`owned_thread`/`free_response` attention
  reasons.
- Thread-as-scope semantics: BullX-owned and existing Discord threads map
  to `scope_id = thread_channel_id, thread_id = nil`.
- Auto-thread creation on guild text-channel mention or `/ask` invocation,
  with `auto_archive_duration_minutes` from config and a name derived from
  the first ~80 characters of the prompt text.
- Thread ownership resolution via Discord channel metadata (`owner_id ==
  bot_user_id`) with cache acceleration; no BullX persistence.
- Safe `allowed_mentions` defaults (`parse: ["users"], replied_user:
  true`).
- Ephemeral interaction responses (`flags = 64`) for `/ping`, `/preauth`,
  `/web_auth`, `/ask` acknowledgement, and activation-required prompts on
  interactions.
- Multi-message streaming with throttled edits and final reconciliation
  via edits + `DELETE` for overshoots.
- Reply-target-missing fallback to plain channel send with
  `"reply_target_missing_sent_to_scope"` warning.
- OAuth2 `identify email` scopes; userinfo from `GET /users/@me`; verified
  email gate.

### Deliberate evolutions from main-branch behavior

- Namespace migration: `BullXDiscord.*` → `Discord.*` under
  `plugins/discord/lib/`; `BullXAccounts.*` → `BullX.Principals.*`;
  `BullXGateway.*` → `BullX.Gateway.*`; `BullXDiscord.Cache` →
  `BullX.Cache` with adapter-prefixed keys.
- Discord OAuth2 callback lives behind the generic
  `BullX.Principals.LoginProvider` host contract, not a dedicated
  `BullXWeb.DiscordAuthController`. The Web boundary's generic Web login
  routes dispatch through the login-provider registry.
- The Principal `login_subject.provider` is the source slug, not the
  literal string `"discord"`. Multiple Discord applications coexist.
- Plugin namespace is `Discord.*` rather than `BullXDiscord.*`. The plugin
  id is `"discord"`.
- Bot credentials live in plugin-owned encrypted `BullX.Config` storage
  under `bullx.plugins.discord.credentials`, not in Gateway adapter
  config. Source config references a credential profile by `credential_id`.
- Discord snowflake ids (`message_id`, `channel_id`, `guild_id`,
  `interaction_id`, `user_id`) are stringified inside Gateway carrier
  payloads to keep the carrier JSON-neutral. The adapter parses them back
  to integers before calling Nostrum.
- Direct-command replies for text-message transport go through
  `BullX.Gateway.deliver/1` instead of calling Nostrum directly. Ephemeral
  interaction responses remain Nostrum-direct because Discord interaction
  tokens are short-lived; only the `/ping`, `/preauth`, `/web_auth`, and
  `/ask` acknowledgement paths use this exception.
- `attention.require_mention: false` and `free_response_channel_ids` are
  supported, matching Telegram's attention policy. Operators may opt
  channels into free-response without an Installation-wide change.
- `event.data` is flat (cross-adapter consistency with Feishu and
  Telegram). Provider-specific fields (`guild_id`, `discord_channel_id`,
  `message_id`, `attention_reason`, etc.) remain present, just without the
  `event.data.discord.` prefix.
- Supervisor topology is wrapped in `Discord.Supervisor` (one-for-all) per
  source so the new `source_child_spec/1` single-child contract returns
  one spec instead of two siblings.
- Capabilities is the map shape required by the current
  `BullX.Gateway.Adapter` behaviour, not the flat list
  `[:send, :edit, :stream, :threads]` from RFC 0015.
- The Nostrum dependency is pinned to a `Kraigie/nostrum` Git commit on the
  0.11-dev line because per-bot supervision via `Nostrum.Bot` is required
  but is not yet present on the Hex stable line (current stable is `0.10.4`,
  which has no `Nostrum.Bot`). The pin moves to a Hex release once `0.11.x`
  ships.
- `MESSAGE_UPDATE` events are normalized as `message_edited`, beyond the
  RFC 0015 inbound surface (which fell through to `_event → ignored`).
  This aligns with the Telegram adapter's `edited_message` handling and
  uses the documented `MESSAGE_UPDATE` filter rules (`edited_timestamp`
  guard, self-author drop, empty-content drop, attention re-evaluation).

## Implementation handoff

### Goal

Implement the Discord plugin as one trusted plugin that exposes both
Gateway transport and Principal OAuth2 login, while preserving the
current Plugin, Gateway, and Principal boundaries. Mirror `plugins/feishu`
and `plugins/bullx_telegram` shape and contracts wherever possible.

### Context pointers

- `AGENTS.md`
- [Plugins.md](Plugins.md)
- [Principal.md](Principal.md)
- [SignalsGateway.md](SignalsGateway.md)
- [Cache.md](Cache.md)
- [FeishuAdapter.md](FeishuAdapter.md)
- [TelegramAdapter.md](TelegramAdapter.md)
- [lib/bullx/gateway/adapter.ex](../../lib/bullx/gateway/adapter.ex)
- [lib/bullx/gateway/source_config.ex](../../lib/bullx/gateway/source_config.ex)
- [lib/bullx/gateway/sources.ex](../../lib/bullx/gateway/sources.ex)
- [lib/bullx/principals.ex](../../lib/bullx/principals.ex)
- [lib/bullx/principals/authn.ex](../../lib/bullx/principals/authn.ex)
- [lib/bullx/principals/login_provider.ex](../../lib/bullx/principals/login_provider.ex)
- [lib/bullx/plugins/plugin.ex](../../lib/bullx/plugins/plugin.ex)
- [plugins/feishu/](../../plugins/feishu/) (reference implementation, OIDC pattern)
- [plugins/bullx_telegram/](../../plugins/bullx_telegram/) (reference implementation, messaging-adapter pattern)
- `Kraigie/nostrum` hex package

### Constraints

- Put plugin code under `plugins/discord`.
- Use plugin id `"discord"`, Gateway adapter extension id `"discord"`, and
  login-provider extension id `"discord"`.
- Use `BullX.Principals`, not `BullXAccounts`.
- Use `BullX.Gateway`, not `BullXGateway`.
- Use `bullx.gateway.sources`, not `bullx.gateway.adapters`.
- Use the Discord source slug as the Principal OAuth2 `login_subject.provider`;
  `"discord"` is the adapter and login-provider implementation id.
- Use `BullX.Cache`, not adapter-owned ETS tables.
- Use `Nostrum` as a stateless Bot/Gateway client; do not rely on
  Nostrum's application-global bot configuration; do not pin Nostrum to a
  Git commit unless a feature requires it.
- Store plugin secrets through `BullX.Config`; do not persist bot tokens,
  OAuth tokens, or client secrets in source config.
- Do not change `BullX.Runtime.Supervisor` or add Jido dependencies.
- Do not add Principal ids to Gateway Signals.
- Do not add a Discord webhook controller or webhook secret generation.
- Do not bulk-overwrite Discord application commands.
- Do not add native attachment upload in the first version.
- Do not persist BullX-owned thread membership.

### Tasks

1. Add the Discord plugin skeleton.
   Owns: `plugins/discord/mix.exs`, `Discord.Plugin`, plugin tests.
   Depends on: none.
   Acceptance: BullX discovers plugin id `"discord"` and both extension
   declarations when the plugin is compiled.
   Verify: plugin discovery and registry tests.

2. Add Discord plugin configuration.
   Owns: `Discord.Config`, config casters, secret-key tests.
   Depends on: Task 1.
   Acceptance: `bullx.plugins.discord.credentials` is secret, validates
   the credential-profile map, validates `client_secret` presence when any
   source enables OAuth2 login, and supports source config lookup without
   logging credentials.
   Verify: config and secret writer tests.

3. Implement `Discord.GatewayAdapter` config, capabilities, and
   connectivity.
   Owns: `Discord.GatewayAdapter`, `Discord.Source`, `Discord.Error`.
   Depends on: Task 2.
   Acceptance: adapter callbacks satisfy `BullX.Gateway.Adapter`,
   capabilities are precise, and connectivity check returns only safe
   metadata after `GET /users/@me` and `GET /oauth2/applications/@me`
   with optional application-id match.
   Verify: adapter unit tests with `Req.Test` and a fake Nostrum API
   module.

4. Implement inbound runtime, attention, and event mapping.
   Owns: `Discord.Supervisor`, `Discord.Channel`, `Discord.Consumer`,
   `Discord.EventMapper`, `Discord.ContentMapper`,
   `Discord.AttentionPolicy`, `Discord.ApplicationCommands`,
   `Discord.ThreadOwnership`, cache key helpers.
   Depends on: Task 3.
   Acceptance: per-source bot starts under the supervisor, `:READY`
   resolves bot identity and runs application command sync, attention
   policy returns the documented reasons, `MESSAGE_CREATE` and
   `INTERACTION_CREATE` events map into valid Gateway inputs,
   `MESSAGE_UPDATE` events map into `message_edited` inputs with
   `edited_timestamp` and self-author guards, thread-ownership cache +
   REST fallback resolves correctly, anonymous, webhook, and bot messages
   are dropped.
   Verify: event-mapping tests including `message_edited`, attention-policy
   tests, thread-ownership tests, `MESSAGE_UPDATE` non-user-edit filter
   tests, and a `BullX.Gateway.publish/2` integration test with a fake
   Router and fake Nostrum API.

5. Implement Principal account gate and direct commands.
   Owns: `Discord.DirectCommand`, locale keys.
   Depends on: Task 4 and the Gateway outbound API slice.
   Acceptance: normal user-origin events call Principal matching before
   publish; `/ping` bypasses Principal; `/preauth` consumes activation
   codes only in DMs; `/web_auth` issues login auth codes only for bound
   active Humans in DMs; duplicate message id / interaction id returns
   cached results; ephemeral responses are used for interaction-transport
   replies.
   Verify: focused direct-command tests with Principal fixtures, ephemeral
   reply assertions.

6. Implement `/ask` and auto-threading.
   Owns: `Discord.AskCommand`, auto-thread branch in `Discord.Channel`,
   thread caching.
   Depends on: Tasks 4 and 5.
   Acceptance: `/ask` is registered as a native application command, sends
   an ephemeral acknowledgement, creates a BullX-owned thread when invoked
   in a guild text channel with `auto_thread.enabled = true`, rewrites
   `scope_id` to the thread channel, and publishes a `slash_command`
   Signal; thread creation failures produce a localized error and do not
   publish.
   Verify: focused tests for `/ask` happy path, DM path, `no_thread`
   channel, and thread-create failure path.

7. Implement Discord OAuth2 login provider.
   Owns: `Discord.OAuth2Provider`, OAuth2 state/profile tests.
   Depends on: Tasks 2, 3, and a Principal login-provider host extension
   point.
   Acceptance: authorization URL generation and callback normalization
   produce a valid Principal login subject with provider set to the source
   slug; userinfo email is included only when verified; tokens are
   discarded after userinfo retrieval; fail closed without `id`.
   Verify: fake `Req` callback tests.

8. Implement outbound send and edit.
   Owns: `Discord.Delivery`, outbound error mapping, safe allowed-mentions.
   Depends on: Task 3 and the Gateway outbound API slice.
   Acceptance: send/edit return Gateway-compatible sent, degraded, or
   error results; reply-target fallback returns
   `"reply_target_missing_sent_to_scope"`; over-limit edit returns a
   payload error; safe `allowed_mentions` is applied to every send; "message
   not modified" is treated as success.
   Verify: outbound tests with fake Nostrum API responses.

9. Implement streaming with multi-message accumulation.
   Owns: `Discord.Streamer`.
   Depends on: Task 8.
   Acceptance: stream finalizes with the expected message list,
   `external_message_ids` order matches creation order, extra messages
   from earlier overshoots are deleted on finalize, UTF-16 splitting
   matches the `stream_chunk_soft_limit`, throttling honors
   `stream_update_interval_ms`, missing stream content returns the
   documented payload error.
   Verify: streamer tests with deterministic chunk inputs.

10. Add telemetry, logs, and locale coverage.
    Owns: Discord modules and locale files.
    Depends on: Tasks 4 through 9.
    Acceptance: safe telemetry/log metadata exists for startup, READY,
    application command sync, inbound, attention, direct-command, `/ask`,
    thread, publish, delivery, stream, and OAuth2 callback paths; locale
    tests fail on missing keys.
    Verify: telemetry/log capture tests and locale key tests.

### Done when

- `plugins/discord` compiles as a BullX plugin.
- The plugin registers `:"bullx.gateway.adapter"` id `"discord"`.
- The plugin registers the Discord
  `:"bullx.principals.login_provider"` implementation, and enabled
  Discord source slugs route to it as concrete login provider ids.
- Discord source config and plugin credentials validate through
  `BullX.Config`.
- `Discord.GatewayAdapter.connectivity_check/1` verifies the bot token,
  application identity, and client secret presence without starting a
  Nostrum bot or leaking secrets.
- Enabled Discord sources start one bot subtree under
  `BullX.Gateway.SourceSupervisor`, with shared restart semantics across
  channel and bot.
- The attention policy filters guild noise according to this design.
- Discord inbound events normalize into valid Gateway inputs and publish
  through `BullX.Gateway.publish/2`. `MESSAGE_UPDATE` user edits publish
  as `message_edited` Signals with `event.data.target_external_id =
  <message_id>` and a distinct `occurrence_key` per edit; non-user
  `MESSAGE_UPDATE` events (embed refresh, pin/unpin) are filtered.
- Built-in direct commands behave as specified and do not publish
  Runtime slash-command Signals; interaction-transport replies are
  ephemeral.
- `/ask` is registered as a native application command, acknowledges
  ephemerally, auto-creates a BullX-owned thread in guild text channels
  when enabled, and publishes a `slash_command` Signal scoped to the
  thread.
- Native application command sync runs on `:READY`, is selective by
  BullX-owned name, and never bulk-overwrites.
- Discord OAuth2 callback logs in or creates only Human Principals
  according to `BullX.Principals` matching rules; tokens are discarded;
  unverified emails are dropped.
- Discord outbound send, edit, and stream paths produce Gateway-compatible
  outcomes or adapter error maps; safe `allowed_mentions` is applied
  everywhere.
- UTF-16 message splitting passes targeted tests on multi-byte and
  surrogate-pair text.
- A persistent Discord Gateway auth failure produces a visible bot
  subtree crash and is not silently retried.
- Self-sent, other-bot, and webhook messages are filtered before publish.
- Bot tokens, OAuth secrets, OAuth tokens, OAuth codes, raw event
  payloads, plaintext activation/login codes, and raw Discord API bodies
  do not enter telemetry, logs, error details, receipts, or dead-letter
  summaries. Normalized Gateway content may enter Gateway carrier and
  replay surfaces according to the Gateway contract.
- No Jido dependency, old `BullXGateway`, old `BullXAccounts`, RFC 0015
  webhook plumbing, `BullXWeb.DiscordAuthController`, or legacy Discord
  compatibility shim is introduced.
- `bun precommit` passes.

Implementation should stop and ask if a change would require persistent
Discord OAuth tokens, BullX-owned thread membership persistence, native
attachment upload, callback-component (button/select/modal) handling,
shard coordination for multi-source-per-token, Principal ids in Signals,
Gateway route topology as a Discord-specific contract, a new credential
store, or a supervision boundary outside the plugin and Gateway source
supervisors.

## Acceptance criteria

- Discord is implemented only as the `plugins/discord` plugin.
- The plugin exposes both required hooks: `:"bullx.gateway.adapter"` and
  `:"bullx.principals.login_provider"`.
- The adapter uses `Kraigie/nostrum`; no other Discord dependency is
  added.
- Discord source config uses `bullx.gateway.sources`.
- Discord secrets (bot tokens, OAuth client secrets) are declared by
  plugin config and encrypted by `BullX.Config`.
- Gateway actor ids use `discord:<user_id>` and remain channel-local.
- Discord snowflake ids appear as strings in Gateway carrier payloads.
- Normal user-origin events are gated by `BullX.Principals` before
  publish.
- The attention policy filters guild events according to this design;
  `event.data.attention_reason` records the decision;
  `require_mention: false` and `free_response_channel_ids` are supported.
- `MESSAGE_UPDATE` user edits publish as `message_edited` Signals with the
  filter rules (`edited_timestamp` guard, self-author drop,
  empty-content drop, attention re-evaluation) applied; non-user edits
  are not published.
- `/preauth` and `/web_auth` are rejected in guild channels and threads
  without consuming or issuing secrets; interaction-transport replies are
  ephemeral.
- `/ping` works before activation and does not require Principal matching.
- `/ask` is registered as a native application command and auto-creates
  a BullX-owned thread in guild text channels when enabled; the thread
  channel becomes the input `scope_id`.
- BullX-owned thread membership is reconstructible from Discord channel
  metadata without BullX-owned persistence.
- Native application command sync is selective; bulk overwrite is never
  used.
- Discord OAuth2 produces a `login_subject` identity input keyed by the
  source slug and never writes Principal external identities directly;
  unverified Discord emails are dropped from login subjects.
- Discord access tokens and refresh tokens are discarded after OAuth2
  userinfo retrieval.
- Send, edit, and stream delivery use Gateway outbound contracts and safe
  error maps; UTF-16 splitting is used wherever Discord message limits
  apply; safe `allowed_mentions` defaults apply everywhere.
- Streaming finalizes with the expected message set, deleting overshoots
  and honoring `stream_update_interval_ms`.
- A Discord Gateway auth failure crashes the bot subtree with a visible
  reason; the supervisor does not silently restart it forever.
- Self-sent, other-bot, and webhook messages are filtered before publish.
- Bot tokens, OAuth secrets, OAuth codes, OAuth tokens, raw event
  payloads, plaintext activation/login codes, and raw Discord API bodies
  do not enter telemetry, logs, error details, receipts, or dead-letter
  summaries. Normalized Gateway content may enter Gateway carrier and
  replay surfaces according to the Gateway contract.
- No Jido dependency, old `BullXGateway`, old `BullXAccounts`, RFC 0015
  webhook plumbing, or legacy Discord compatibility shim is introduced.
- `bun precommit` passes.
