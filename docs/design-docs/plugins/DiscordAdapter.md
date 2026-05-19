# Discord Adapter Plugin

The Discord integration is a trusted BullX plugin under `plugins/discord`. It
registers one Discord EventBus Channel Adapter and a Principal-owned Discord
OAuth2 browser login provider. Its Channel Adapter verifies Discord bot and
interaction input, normalizes accepted occurrences into decoded CloudEvents
JSON, calls `BullX.EventBus.accept/2`, and exposes optional Discord outbound
delivery and stream transport. It does not evaluate Event Routing Rules, create
TargetSessions, invoke Targets, authorize side effects, or persist business
facts. Its OAuth2 login provider hands verified Discord identities to
`BullX.Principals`; it is not part of EventBus transport.

Discord uses `Kraigie/nostrum` as the bot, Discord gateway WebSocket, and REST
client. BullX owns the source configuration, plugin lifecycle, Event
normalization, Principal handoff, outbound rendering, and stream transport
contract.

## Scope

This design covers the Discord adapter plugin:

- plugin placement, extension declarations, plugin-owned source configuration,
  and plugin-owned credential configuration;
- Discord bot source supervision through Nostrum, connectivity checks,
  application command reconciliation, inbound normalization, attention
  filtering, command normalization, `/ask`, auto-threading, and provider
  acknowledgement behavior;
- Discord channel actor evidence and Principal activation/login handoff;
- Discord OAuth2 browser login through a Principal login-provider extension;
- Discord outbound send, edit, safe allowed mentions, reply fallback, UTF-16
  message splitting, and multi-message stream transport;
- Discord-specific content mapping, actor normalization, error mapping,
  telemetry, logging, security, privacy, tests, and implementation handoff.

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
  Discord stream transport may consume;
- `docs/design-docs/Principal.md` for channel actor matching, activation codes,
  login subjects, and channel-auth login codes.

## Goals

- Keep Discord out of BullX core modules by shipping it as one plugin under
  `plugins/discord`.
- Register the Discord Channel Adapter through
  `:"bullx.event_bus.channel_adapter"`.
- Register Discord OAuth2 as a Principal login-provider implementation through
  `:"bullx.principals.login_provider"`.
- Reuse Nostrum for Discord bot gateway WebSocket, REST calls, heartbeats,
  session resume, and per-bot supervision while keeping BullX source lifecycle
  explicit.
- Use stable CloudEvents `(source, id)` values for Discord event redelivery and
  retry idempotency.
- Keep Discord actor evidence channel-local unless `BullX.Principals` resolves
  it into a trusted `actor.principal`.
- Filter guild-channel noise at the adapter edge through an explicit attention
  policy so unrelated guild messages do not enter EventBus.
- Provide a Discord-shaped guild entry point through native `/ask` and optional
  BullX-owned thread creation, where a Discord thread is its own Event scope.
- Keep bot tokens, OAuth client secrets, OAuth codes, OAuth access/refresh
  tokens, bearer-like handles, and private interaction secrets out of Events,
  telemetry, logs, safe errors, `routing_facts`, `reply_channel`, Oban job args,
  and stream metadata. Activation/login codes must not enter generic routing or
  diagnostic surfaces; any command that needs them must use a command-design-owned
  protected argument shape.

## Non-goals

- Do not add Discord modules under `lib/bullx/` or `lib/bullx_web/` except for
  generic host surfaces required by plugin or Principal extension contracts.
- Do not add provider-specific EventBus tables, route tables, durable raw event
  logs, thread-membership tables, or adapter-owned business records.
- Do not route on raw Discord events, CloudEvents extension attributes,
  `subject`, nested provider carrier names, message text, interaction private
  values, or attachment bytes.
- Do not implement Discord webhook ingress for interactions in the first
  implementation. Inbound events arrive through the Discord bot gateway
  WebSocket via Nostrum.
- Do not implement native attachment upload, embed construction, components,
  buttons, select menus, modals, autocomplete, voice, presence, guild member,
  reaction, message delete, payment, or channel-post surfaces in the first
  implementation.
- Do not bulk-overwrite Discord application commands. Command sync reconciles
  only BullX-owned command names.
- Do not auto-create Discord threads from DMs or from messages already inside
  Discord threads.
- Do not persist Discord OAuth access tokens, refresh tokens, raw callback
  bodies, downloaded attachments, or BullX-owned thread membership as BullX
  facts.
- Do not put resolved Principal ids into `routing_facts` or any matcher surface.
- Do not add a provider-specific runtime framework, credential store, or Event
  routing path.

## Plugin shape

The plugin app id is `:discord`, the plugin id is `"discord"`, and the
directory is `plugins/discord`. The Channel Adapter extension id is `"discord"`.

The plugin namespace is `Discord.*`. That namespace is available in this repo
because the selected Discord dependency uses `Nostrum.*`.

```elixir
defmodule Discord.Plugin do
  use BullX.Plugins.Plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.event_bus.channel_adapter",
        id: "discord",
        module: Discord.ChannelAdapter,
        opts: %{provider: "discord"}
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

  @impl BullX.Plugins.Plugin
  def children(_enabled_plugin_config), do: [Discord.SourceSupervisor]
end
```

`:"bullx.event_bus.channel_adapter"` is the EventBus-owned transport extension
point. The Channel Adapter extension id `"discord"` must match
`data.channel.adapter` in normalized Events.

`:"bullx.principals.login_provider"` is a Principal-owned extension point for
browser login providers. The extension id `"discord"` names the provider
implementation type. The concrete Principal login provider id for one Discord
application source is the enabled Discord source id, not the string
`"discord"` and not the Discord application id.

Suggested module ownership:

| Module | Responsibility |
| --- | --- |
| `Discord.Plugin` | Plugin metadata, config modules, extension declarations, and plugin children. |
| `Discord.Config` | Plugin-owned `BullX.Config` declarations and source/credential casters. |
| `Discord.Source` | Runtime source normalization, credential lookup, bot/application validation, redacted public projection, and connectivity checks. |
| `Discord.SourceSupervisor` | Enabled-source supervision under the plugin failure boundary. |
| `Discord.SourceRuntime` | Per-source one-for-all supervisor wrapping `Discord.Channel` and the Nostrum bot subtree. |
| `Discord.Channel` | Per-source runtime boundary: source context, READY handling, event dispatch, command sync, and cache key prefixes. |
| `Discord.Consumer` | Nostrum consumer that forwards gateway WebSocket events to the matching source channel. |
| `Discord.ChannelAdapter` | `BullX.EventBus.ChannelAdapter` implementation and public adapter boundary. |
| `Discord.EventMapper` | Discord message, edit, and interaction payload normalization into CloudEvents. |
| `Discord.ContentMapper` | Discord inbound content blocks, outbound rendering, mention stripping, and UTF-16 splitting. |
| `Discord.AttentionPolicy` | Guild-channel and thread attention filter. |
| `Discord.ApplicationCommands` | Safe selective reconciliation of BullX-owned native application commands. |
| `Discord.CommandNormalizer` | Safe slash-text and native application command parsing plus command routing facts. |
| `Discord.AskCommand` | Native `/ask` handling, immediate acknowledgement, and Event production. |
| `Discord.ThreadOwnership` | BullX-owned Discord thread resolution through cache and Discord channel metadata. |
| `Discord.ProviderResponse` | Immediate ephemeral interaction responses for documented command paths. |
| `Discord.Outbound` | Send, edit, safe allowed mentions, and reply-target fallback. |
| `Discord.Streamer` | Multi-message stream consumption with throttled edits and final reconciliation. |
| `Discord.OAuth2Provider` | Principal login-provider callback implementation. |
| `Discord.Error` | Nostrum, Discord HTTP, and OAuth2 error normalization. |

Adapter modules call Nostrum bot and REST APIs under the per-source bot context.
OAuth2 token exchange and userinfo fetching use `Req` directly. Failures route
through `Discord.Error`.

The implementation should use a released Nostrum package when it supports the
needed per-source bot supervision. If no released package supports that runtime
shape, implementation must stop and ask before pinning a Git commit, forking
Nostrum, or weakening source isolation.

## Runtime configuration

Operators enable the plugin through the normal plugin list:

```json
["discord"]
```

Discord configuration lives under the plugin namespace:

```text
bullx.plugins.discord.credentials
bullx.plugins.discord.eventbus_sources
bullx.plugins.discord.oauth2_state_ttl_seconds
```

Initial declarations:

| Accessor | DB key | Secret | Default |
| --- | --- | --- | --- |
| `credentials!/0` | `bullx.plugins.discord.credentials` | yes | `{}` |
| `eventbus_sources!/0` | `bullx.plugins.discord.eventbus_sources` | no | `[]` |
| `oauth2_state_ttl_seconds!/0` | `bullx.plugins.discord.oauth2_state_ttl_seconds` | no | `600` |

`credentials` is a JSON object keyed by credential id. Each value contains one
Discord application credential profile:

```json
{
  "default": {
    "application_id": "123456789012345678",
    "bot_token": "MTIzNDU2.ABC.xyz",
    "client_secret": "secret_xxx"
  }
}
```

The credentials map is encrypted by `BullX.Config`. It must not appear in
Events, source public projections, `routing_facts`, `reply_channel`, Oban job
args, stream metadata, telemetry, logs, safe errors, or operator receipts.

`client_secret` may be omitted on a credential profile only when no source under
that profile enables OAuth2 login. Source normalization validates this
combination.

`eventbus_sources` is a JSON array of Discord source entries:

```json
[
  {
    "id": "main",
    "enabled": true,
    "credential_id": "default",
    "connected_realm_ref": "discord:application:123456789012345678",
    "bot_user_id": null,
    "oauth2": {
      "enabled": true,
      "redirect_uri": "https://bullx.example.com/sessions/oauth2/main/callback",
      "scopes": ["identify", "email"]
    },
    "message_context_ttl_seconds": 2592000,
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
  }
]
```

The source `id` is the stable adapter-local source id. It becomes
`data.channel.id` in Events, `channel_id` in Principal channel-actor
references, and the concrete Principal login provider id when `oauth2.enabled`
is true. It is not a Discord application id, bot user id, guild id, channel id,
thread id, credential id, or display label.

Discord channel ids and thread channel ids become `data.scope.id`. Discord
threads are channels, so `data.scope.thread_id` is always `null`.

Discord rejects concurrent gateway WebSocket connections from the same bot token
unless the implementation performs explicit shard coordination. Two enabled
sources using the same credential id cannot both run their own bot gateway
connection in the first implementation. The source runtime must detect an active
credential collision on the same node and fail the second source with a `config`
error instead of starting a conflicting bot connection.

## Connectivity check

`Discord.Source.connectivity_check/1` validates one normalized source without
starting a bot, registering listeners, syncing application commands, publishing
an Event, changing source config, or writing Principal data. It loads the
referenced credential profile, verifies the bot token through Discord's current
bot user endpoint, verifies the application id through Discord's application
endpoint, validates `client_secret` presence when `oauth2.enabled` is true, and
returns only redacted operator metadata.

Connectivity also records that Message Content Intent is required for guild
message text. Operators must enable it in the Discord developer portal for
guild message content to reach the adapter.

Success shape:

```elixir
{:ok,
 %{
   status: :ok,
   adapter: "discord",
   source_id: "main",
   capabilities: [:inbound, :send, :edit, :stream, :threads, :application_commands, :oauth2],
   details: %{
     "transport" => "discord_gateway_ws",
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

Connectivity responses must never include bot tokens, OAuth client secrets,
OAuth tokens, raw Discord response bodies, interaction tokens, retry state, or
event payloads.

## Channel Adapter contract

`Discord.ChannelAdapter` implements `BullX.EventBus.ChannelAdapter`.

| Callback | Discord behavior |
| --- | --- |
| `normalize_inbound/2` | Converts one Discord message, edit, or interaction occurrence into one decoded CloudEvent, returns `:ignore`, or returns a safe error. |
| `capabilities/0` | Declares Discord gateway WebSocket inbound, interaction inbound, send, edit, stream, thread support, application command sync, and OAuth2 support. |
| `deliver/4` | Executes upstream-approved send or edit transport when supported. |
| `consume_stream/4` | Consumes an EventBus output stream and mirrors chunks to Discord messages. |

Capabilities should include:

```elixir
%{
  inbound_modes: [:discord_gateway_ws, :interaction],
  outbound_ops: [:send, :edit, :stream],
  content_kinds: [:text, :image, :audio, :video, :file, :card],
  features: [:threads, :application_commands, :ephemeral_provider_responses, :oauth2_login],
  stream_strategy: :edit_accumulate
}
```

`content_kinds` is a coarse transport capability list. Inbound decoded
CloudEvents still use `NormalizedCloudEvent` content part types such as
`image_url`, `video_url`, and `file`. The first implementation degrades
non-text outbound content to fallback text instead of using Discord native
attachments or embeds.

EventBus core validates the decoded CloudEvent passed to `accept/2`. Discord
still validates source config, payload shape, attention policy, target ids,
message size limits, application command options, interaction response timing,
and Discord API responses.

## Source runtime

For each enabled source, `Discord.SourceSupervisor` starts a source-local
runtime boundary:

```text
Discord.SourceSupervisor
  -> Discord.SourceRuntime
     -> Discord.Channel
     -> Nostrum.Bot
        -> shard supervisor
        -> consumer dispatcher
```

`Discord.SourceRuntime` is a `:one_for_all` supervisor. If `Discord.Channel` or
the Nostrum bot subtree crashes, both restart so source-local cache state stays
consistent with the bot connection state.

`Discord.Channel` owns normalized source config, source-local dispatch, bot
identity resolution, application command sync, startup logs, and source-local
cache key prefixes. Nostrum owns the Discord gateway WebSocket connection,
heartbeat, session sequence, and resume mechanics.

The Nostrum consumer forwards every relevant event to `Discord.Channel`.
`Discord.Channel` performs self-message filtering, event mapping, attention
filtering, command normalization, `/ask` handling, auto-threading,
Principal gating, and EventBus acceptance.

Source-local runtime state is reconstructible and may use the existing cache
layer when available:

- message context used for reply/edit correlation where needed;
- BullX-owned thread ownership keyed by `{source_id, thread_channel_id}`.

If thread-ownership cache is missing, the adapter resolves ownership from
Discord channel metadata and re-caches the result. Provider redelivery of a
command occurrence relies on stable CloudEvents `(source, id)`, EventBus dedupe,
and downstream Target idempotency rather than adapter-local command execution
state.

At startup `Discord.Channel`:

1. Waits for the Nostrum READY event before accepting inbound occurrences.
2. Resolves bot user id, bot username, and application id.
3. Validates the resolved application id against the credential profile and the
   configured `bot_user_id` when one is present.
4. Runs `Discord.ApplicationCommands.sync/1` when
   `application_commands.sync_policy = "safe"`.
5. Starts normal event dispatch.

Required Discord gateway intents include guilds, guild messages, direct
messages, and message content. The privileged Message Content Intent must be
enabled on the Discord developer portal for guild message content.

Webhook ingress for Discord interactions is not used in the first
implementation. Native application command invocations arrive as interaction
events through the bot gateway WebSocket.

## Inbound normalization

Discord normalizes one accepted occurrence into one decoded string-keyed
CloudEvents JSON object. `BullX.EventBus.accept/2` is called once per accepted
occurrence.

CloudEvents attributes:

- `specversion` is `"1.0"`.
- `id` is stable inside the source:
  - message create uses the Discord message id;
  - user message edit uses `edit:<message_id>:<edited_timestamp>`;
  - application command interaction uses the Discord interaction id.
- `source` is a stable URI-like string such as
  `discord://main/application/123456789012345678`.
- `type` is a normalized BullX Event type such as
  `bullx.im.message.addressed`, `bullx.im.message.ambient`,
  `bullx.message.edited`, or `bullx.command.invoked`.
- `time` is Discord message timestamp, edited timestamp, or interaction
  timestamp when trusted; otherwise it is adapter receive time.
- `datacontenttype` is `"application/json"`.
- `data` is the BullX normalized payload from
  `eventbus/NormalizedCloudEvent.md`.

All Discord snowflake ids enter Events as strings to avoid JSON number
precision and 64-bit integer ambiguity. The adapter parses them back to
integers only when calling Discord through Nostrum.

Example message Event:

```json
{
  "specversion": "1.0",
  "id": "9876543210",
  "source": "discord://main/application/123456789012345678",
  "type": "bullx.im.message.addressed",
  "subject": "Discord message 9876543210",
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
      "adapter": "discord",
      "id": "main",
      "kind": "group"
    },
    "scope": {
      "id": "777888999000111222",
      "thread_id": null
    },
    "actor": {
      "external_account_id": "discord:234567890123456789",
      "display_name": "Alice",
      "principal": {
        "id": "optional-principal-id",
        "type": "human"
      }
    },
    "refs": [
      {
        "kind": "discord.message",
        "id": "9876543210"
      },
      {
        "kind": "discord.channel",
        "id": "777888999000111222"
      },
      {
        "kind": "discord.guild",
        "id": "111222333444555666"
      },
      {
        "kind": "discord.user",
        "id": "234567890123456789"
      }
    ],
    "reply_channel": {
      "adapter": "discord",
      "channel_id": "main",
      "scope_id": "777888999000111222",
      "thread_id": null,
      "reply_to_external_id": "9876543210"
    },
    "routing_facts": {
      "provider_event_type": "message_create",
      "guild_id": "111222333444555666",
      "discord_channel_id": "777888999000111222",
      "content_kind": "text",
      "attention_reason": "mention",
      "connected_realm_ref": "discord:application:123456789012345678"
    },
    "raw_ref": {
      "kind": "discord.message",
      "id": "9876543210"
    }
  }
}
```

`subject` is display/debug text only. Discord must not depend on it for
routing. Provider-specific matching data belongs in `data.routing_facts` or
another normalized field exposed by `RoutingContext`.

`raw_ref` is not a matcher surface. It may contain stable Discord ids, a provider
raw reference, or a provider raw snapshot when the adapter needs it. Credentials,
bearer-like values, and private interaction secrets still must not enter Events,
telemetry, logs, safe errors, Oban args, or stream metadata.

## Actor identity

Discord actor ids are channel-local external ids:

```text
data.actor.external_account_id = "discord:" <> user_id
```

`user_id` is required for Principal channel actor matching. Discord supplies a
user id for normal user-origin messages and application command interactions.
Webhook authors, system messages, anonymous events, and messages without a user
id are ignored.

Trusted profile fields may include `display_name`, `global_name`, `username`,
`avatar_url`, `locale`, and `user_id`. The adapter computes `display_name` from
the first non-empty value among `global_name`, `username`, and
`"discord:" <> user_id`. Discord bot gateway events do not expose user email or
phone; those fields can arrive only through OAuth2 login.

Self-sent bot messages are ignored before content parsing, command
classification, Principal matching, `/ask` handling, or EventBus handoff.
Messages from other bots and webhook messages are ignored in the first
implementation.

## Scope, threads, and channel types

`data.scope.id` is the user-visible Discord conversation surface where BullX is
expected to respond. Discord threads are their own channels, so a thread is the
scope and not a sub-key of a parent channel.

| Discord surface | Scope mapping |
| --- | --- |
| DM | `scope.id = dm_channel_id`, `scope.thread_id = null`. |
| Guild text channel without auto-threading | `scope.id = channel_id`, `scope.thread_id = null`. |
| Guild voice text or guild news channel | `scope.id = channel_id`, `scope.thread_id = null`; news channel posts are ignored on inbound. |
| BullX-created thread | `scope.id = thread_channel_id`, `scope.thread_id = null`. |
| Existing public/private thread or forum post | `scope.id = thread_channel_id`, `scope.thread_id = null`. |

Parent guild, channel, and thread metadata belongs in `data.routing_facts` and
`refs`, not in `scope.id`. TargetSession reuse follows the visible Discord
conversation. A BullX-owned thread is its own conversation; parent-channel
ordering does not enter TargetSession identity.

## Attention policy

Inbound Discord events are filtered before EventBus handoff. This is transport
admission, not business routing. If an occurrence is accepted by attention
policy, Event Routing Rules still decide which Target receives it.

The policy returns an attention reason:

- `dm`
- `mention`
- `application_command`
- `owned_thread`
- `free_response`

or an ignore reason:

- `bot_author`
- `ignored_channel`
- `ignored_thread`
- `outside_allowlist`
- `unmentioned_guild_message`
- `thread_ownership_unresolved`
- `unsupported_interaction`
- `unsupported_event`
- `non_user_edit`
- `edit_content_empty`
- `anonymous_actor`

Filter order for message create:

1. `author.bot == true` and `author.id == bot_user_id` -> ignore as
   `bot_author`.
2. Any other bot author, webhook author, or system author -> ignore as
   `bot_author`.
3. `channel_id` in `attention.ignored_channel_ids` -> ignore as
   `ignored_channel`.
4. A thread channel id in `attention.ignored_thread_ids` -> ignore as
   `ignored_thread`.
5. `attention.allowed_channel_ids` non-empty and `channel_id` not in it, unless
   the current channel is a BullX-owned thread -> ignore as `outside_allowlist`.
6. DM -> `dm`.
7. Message mentions the bot user id -> `mention`.
8. Message is inside a Discord thread and `Discord.ThreadOwnership.owned?/3`
   returns true -> `owned_thread`.
9. `channel_id` in `attention.free_response_channel_ids`, or
   `attention.require_mention == false` -> `free_response`.
10. Otherwise ignore as `unmentioned_guild_message` or
    `thread_ownership_unresolved`.

Filter order for native application command interactions:

1. ignored channel or ignored thread -> ignore.
2. allowlist non-empty and channel not in it -> ignore as `outside_allowlist`.
3. Otherwise -> `application_command`.

`attention.require_mention = false` opens a broad free-response mode in
non-ignored, non-allowlisted-out channels. Operators should prefer
`free_response_channel_ids` and `allowed_channel_ids` before using it
Installation-wide.

The attention reason is stored in `data.routing_facts.attention_reason`. It is
operator-visible diagnostic and matching data, not authorization.

## Event mapping

Discord maps allowed provider occurrences to normalized BullX Event types:

| Discord occurrence | Normalized `type` | Notes |
| --- | --- | --- |
| `MESSAGE_CREATE` text | `bullx.im.message.addressed`, `bullx.im.message.ambient`, or `bullx.command.invoked` | Accepted EventBus slash-style text commands become command Events. Adapter-local `/preauth` and `/web_auth` are handled before EventBus. Addressed text becomes an addressed IM Event; observed unmentioned guild text becomes an ambient IM Event only when the source listens to all messages. |
| `MESSAGE_CREATE` attachment/embed/sticker | `bullx.im.message.addressed` or `bullx.im.message.ambient` | Content blocks describe the media; primary text uses message content or generated fallback. Attention policy decides addressed versus ambient. |
| `MESSAGE_UPDATE` user edit | `bullx.message.edited` | Requires non-null `edited_timestamp`; self-edits, empty content, and non-user updates are ignored. |
| `INTERACTION_CREATE` application command | `bullx.command.invoked` or adapter-local command result | Provider-native EventBus command input publishes a command Event after transport acknowledgement. Adapter-local `/preauth` and `/web_auth` are handled before EventBus. |
| Other interaction types | ignored | Components, modals, autocomplete, and ping interactions are out of scope. |

`MESSAGE_UPDATE` filter rules sit before attention policy and Event mapping:

1. `edited_timestamp` absent or `null` -> ignore as `non_user_edit`.
2. Self-authored bot edit -> ignore as `bot_author`.
3. Content empty after bot-mention stripping -> ignore as `edit_content_empty`.
4. Re-run attention policy on the post-edit content and context.

When all checks pass, the adapter publishes `bullx.message.edited` with the
edited message id in `refs`, `raw_ref`, and `routing_facts.target_external_id`.
The CloudEvents `id` includes `edited_timestamp` so successive user edits are
distinct occurrences.

Message delete, reactions, member events, voice events, presence events, and
components are not normalized in the first implementation and are dropped after
safe telemetry.

Provider-specific names stay in `routing_facts.provider_event_type`, such as
`message_create`, `message_update`, or `interaction_create`. EventBus core must
not maintain a Discord event-name allowlist.

## Content mapping

Inbound content mapping preserves user-visible text after removing direct bot
mention tokens. Mention metadata stays in `refs`.

Plain text with non-empty content after mention stripping produces one text
block:

```elixir
%{"type" => "text", "text" => "hello"}
```

Attachments produce an optional caption text block followed by one media block
per attachment:

```elixir
%{
  "type" => "image_url",
  "url" => "discord://attachment/<channel_id>/<attachment_id>",
  "fallback_text" => "[image]"
}
```

Mapping rules:

| Discord content type or hint | Block `type` |
| --- | --- |
| `image/*` content type | `image_url` |
| `audio/*` content type | `file` with `media_type` |
| `video/*` content type | `video_url` with `media_type` |
| Any other attachment content type | `file`, with `media_type` when Discord provides one |
| Sticker with image metadata | `image_url` |

Embeds produce one text block when they have a title or description. The adapter
does not normalize embed fields into structured content in the first
implementation. Empty embeds are skipped. Stickers without usable media
metadata produce one localized text fallback.

`/ask` interaction produces one text block from the required `prompt` option.

The adapter must not publish empty `data.content` for a user-origin Event. If a
provider occurrence has no meaningful user-facing body and is still accepted,
the adapter synthesizes a deterministic localized fallback text block.

All non-text attachment blocks include `fallback_text` so AIAgent can render a
safe text transcript without downloading bytes or expanding raw provider
payloads. Native interaction options that become EventBus input render as text
blocks; provider-private interaction tokens remain outside the Event.

`discord://attachment/<channel_id>/<attachment_id>` URIs are channel-local
opaque references. The adapter does not download bytes during normalization. A
Target or Capability that needs attachment bytes must resolve the reference
through an explicitly authorized provider capability or follow-up adapter helper.

## Principal account gate

Before accepting normal user-origin message Events, Discord calls
`BullX.Principals.match_or_create_human_from_channel/1` with the normalized
channel actor:

```elixir
%{
  adapter: :discord,
  channel_id: "main",
  external_id: "discord:234567890123456789",
  profile: %{
    "display_name" => "Alice",
    "global_name" => "Alice",
    "username" => "alice",
    "avatar_url" => "https://cdn.discordapp.com/avatars/...",
    "user_id" => "234567890123456789"
  },
  metadata: %{
    "connected_realm_ref" => "discord:application:123456789012345678",
    "guild_id" => "111222333444555666",
    "discord_channel_id" => "777888999000111222"
  }
}
```

Result handling:

| Principal result | Discord behavior |
| --- | --- |
| `{:ok, principal, _identity}` | Normalize the Event, set `data.actor.principal` to the Principal id and type, and call `BullX.EventBus.accept/2`. |
| `{:error, :activation_required}` | Send localized activation guidance when appropriate and do not call EventBus. |
| `{:error, :principal_disabled}` | Send a localized denied reply when appropriate and do not call EventBus. |
| `{:error, reason}` | Treat as provider processing failure, emit safe telemetry, and do not call EventBus. |

Command-shaped input is not automatically a normal conversation message. When
Discord classifies an accepted slash-text command or native application command
as `bullx.command.invoked`, the adapter may publish the command Event with actor
evidence and `data.actor.principal = null` if no active Principal binding
exists yet. System commands such as `/command` and `/status`, and AIAgent-owned
commands such as `/ask`, use that path. Channel activation and login commands
such as `/preauth` and `/web_auth` are adapter-local entry points and may be
handled before EventBus. For EventBus commands, the adapter still does not
choose the command handler, decide command authorization, or write command
business facts.

Principal resolution is identity evidence, not authorization. Downstream
Principal, AuthZ, Governance, Capability, Target, and business layers still
decide permission, budget, approval, and side effects.

In guild channels and threads, activation-required replies must not include
activation codes, login auth codes, OAuth2 links, or account-state details. The
reply should ask the user to message the bot privately. For native interactions,
the prompt is an ephemeral provider response. For mention-based guild messages,
the prompt may be a localized public reply with no private state. DMs may
include localized `/preauth <code>` and `/web_auth` guidance.

## Command normalization and interaction acknowledgement

Discord has two command surfaces:

- slash-style text messages accepted by attention policy;
- provider-native application command interactions.

Both surfaces normalize to `bullx.command.invoked` when they represent an
EventBus command. Examples include `/command`, `/status`, localized aliases such
as Chinese `/命令` and `/状态` when that locale is active, and `/ask`. These
commands are BullX product concepts, not Discord-specific concepts, and the
adapter does not execute their business behavior before EventBus handoff.

`/preauth <code>` and `/web_auth` are channel activation/login commands. The
Discord adapter handles them locally through Principal/Auth services and safe
Discord replies, because they may need to run before a Principal binding exists
and may use provider-private interaction response context. They are not
published to EventBus as `bullx.command.invoked`.

Command normalization runs after source context resolution, bot/self filtering,
attention policy, and safe command-token or interaction-option parsing. Discord
stores only matcher-oriented facts in `data.routing_facts`:

- `command_name`, the canonical English command name without the leading slash;
- `command_namespace`, when the command grammar or application command defines
  one;
- `command_surface = "slash_text"` for text commands or
  `command_surface = "provider_native"` for application command interactions;
- `command_args_kind`, such as `none`, `text`, or `options`;
- `provider_command_id` for native application commands;
- `attention_reason`.

Command arguments may appear in normalized content only when the relevant command
design allows it. Interaction tokens, callback URLs, private option values, bot
tokens, and provider credentials must not enter EventBus `routing_facts`,
`reply_channel`, Events, telemetry, or logs. Activation/login codes stay inside
the adapter-local auth path or an explicitly protected input shape.

Native Discord interactions have a short provider response window. The adapter
may send a neutral acknowledgement or defer response so Discord does not retry or
mark the interaction failed. That acknowledgement is transport timing only: it
does not choose the Target, execute the command, decide visible reply content, or
bypass the Channel Adapter outbound boundary. Any follow-up visible reply uses a
safe `reply_channel` reference or adapter-private handle; the interaction token
itself is never serialized into EventBus-owned data.

The Event Routing Rule decides the Target for EventBus commands. System command
routes for `/command` and `/status` target `target_type = "command"` through
code-owned built-ins merged into the runtime route table. AIAgent conversation
commands, including Discord-shaped `/ask`, must target AIAgent-owned command
handling or remain ordinary AIAgent text commands when this adapter does not
normalize them. The Discord adapter must not mutate Conversation, Message, or
generation lease state directly.

Provider redelivery of the same EventBus command message or interaction reuses
the same CloudEvents `(source, id)` based on the Discord message id or
interaction id. Duplicate visible replies are prevented by EventBus dedupe and
Target idempotency, not by an adapter-local command execution cache.
Adapter-local `/preauth` and `/web_auth` flows use their own Principal/Auth
idempotency and safe reply rules.

## `/ask` and auto-threading

`/ask <prompt:string>` is the Discord-shaped native application command for
opening or continuing a BullX conversation in a guild. It publishes a
`bullx.command.invoked` Event that routing should send to AIAgent-owned command
handling, not to the generic system Command Target.

Flow for `/ask` in a guild text channel:

1. `Discord.AskCommand` receives an application command interaction.
2. Attention policy classifies it as `application_command`.
3. The actor is normalized and passed through the Principal account gate.
4. If activation is required, the adapter sends an ephemeral
   activation-required response and does not publish an Event.
5. The adapter sends an ephemeral acknowledgement so Discord's interaction
   response window is satisfied immediately.
6. If `auto_thread.enabled == true` and the channel is eligible, the adapter
   creates a BullX-owned Discord thread with
   `auto_archive_duration_minutes` from source config. The thread name is
   derived from the trimmed first roughly 80 characters of the prompt.
7. The adapter marks the created thread as BullX-owned in
   `Discord.ThreadOwnership` and rewrites `data.scope.id` to the thread channel
   id.
8. The adapter publishes a `bullx.command.invoked` Event with
   `routing_facts.command_name = "ask"` and
   `routing_facts.command_surface = "provider_native"`.

Flow for `/ask` in a DM or inside an existing thread is the same without thread
creation. `data.scope.id` is the DM channel id or existing thread channel id.

Thread creation failure sends a localized ephemeral or direct reply error and
does not publish an Event. `/ask` reply output later arrives through normal
Target outbound behavior and the Discord outbound adapter.

The interaction id is the CloudEvents `id` and appears in `refs`. A created
thread id is recorded in `refs` so downstream business code can inspect the
provider relationship when needed.

### Thread ownership

`Discord.ThreadOwnership.owned?(thread_channel_id, source, cache)` decides
whether an inbound message inside a Discord thread should bypass mention
requirements.

Resolution order:

1. Cache hit on `{source_id, thread_channel_id}` -> return cached boolean.
2. Cache miss -> fetch the Discord channel. A thread is BullX-owned when the
   channel type is a Discord thread type and `owner_id` equals the resolved
   `bot_user_id`.
3. Resolution error returns `:thread_ownership_unresolved` so attention policy
   fails closed.

`Discord.ThreadOwnership.mark_owned/3` is called immediately after the adapter
creates a thread, so the next message inside the thread does not require a REST
lookup.

Thread ownership is not persisted to PostgreSQL. If another feature later uses
the same Discord bot to create threads, that feature must introduce a Discord
side marker or a separate approved runtime state design before sharing the bot
identity.

## Native application command sync

The adapter registers three BullX-owned global application commands:

| Name | Description | Options |
| --- | --- | --- |
| `preauth` | Link this Discord account to BullX | `code: string` required |
| `web_auth` | Create a BullX web login code | none |
| `ask` | Ask BullX in a Discord thread | `prompt: string` required |

`Discord.ApplicationCommands.sync/1` runs on READY when
`application_commands.sync_policy = "safe"`:

1. List existing global application commands for the configured application id.
2. Create each BullX-owned command if missing.
3. Edit each BullX-owned command only when relevant fields differ.
4. Delete only commands whose name is in the BullX-owned set and no longer
   desired.
5. Never bulk-overwrite the application's global command list.

Sync policy values:

- `safe`: selective reconciliation on READY; failures log a warning and do not
  stop inbound or outbound paths.
- `off`: skip sync entirely. Operators must register commands manually or accept
  that native command UX is unavailable. Text-message `/command`, `/status`,
  `/preauth`, and `/web_auth` still work through text parsing.

## Discord OAuth2 login provider

`Discord.OAuth2Provider` implements the Principal login-provider hook for Human
browser login. Discord OAuth2 is OAuth 2.0, not OIDC: there is no `id_token`.
Userinfo is fetched from Discord's current user endpoint with the access token
as a bearer credential.

Suggested host behavior, if missing when this design is implemented:

```elixir
defmodule BullX.Principals.LoginProvider do
  @callback authorization_url(source :: map(), opts :: map()) ::
              {:ok, %{url: String.t(), state: map()}} | {:error, map()}

  @callback callback(source :: map(), params :: map(), state :: map()) ::
              {:ok, login_subject :: map()} | {:error, map()}
end
```

The Web login controller receives a provider id from the login route. For
Discord, that provider id is the enabled source id. The controller loads the
source, verifies `adapter = "discord"` and `oauth2.enabled = true`, resolves the
Discord login-provider implementation, asks it for an authorization URL, signs
provider state with Phoenix token infrastructure, and redirects the browser.

Authorization URL:

```text
https://discord.com/oauth2/authorize?
  client_id=<application_id>&
  redirect_uri=<redirect_uri>&
  response_type=code&
  scope=identify%20email&
  state=<signed_state>
```

Callback flow:

1. Verify signed state, source id, adapter, nonce, age, and local `return_to`.
2. Exchange `code` at Discord's OAuth2 token endpoint with client id, client
   secret, grant type `authorization_code`, redirect URI, and code.
3. Fetch userinfo at Discord's current user endpoint with the returned access
   token.
4. Normalize a Principal login subject.
5. Discard the Discord access token and refresh token.
6. Pass the login subject to `BullX.Principals` for matching and session
   establishment.

Login subject shape:

```elixir
%{
  provider: "main",
  external_id: "discord:234567890123456789",
  profile: %{
    "display_name" => "Alice",
    "global_name" => "Alice",
    "username" => "alice",
    "email" => "alice@example.com",
    "avatar_url" => "https://...",
    "user_id" => "234567890123456789"
  },
  metadata: %{
    "adapter" => "discord",
    "channel_id" => "main",
    "application_id" => "123456789012345678",
    "verified_email" => true,
    "locale" => "en-US"
  }
}
```

`provider = "main"` is the Discord source id. Multiple Discord applications may
be configured as different sources, each with its own source id, credential
profile, application id, bot token, client secret, and OAuth2 setting. The
Principal `login_subject` provider namespace is therefore the source id, not
`"discord"` and not the Discord application id.

Email is included only when Discord returns `verified = true` and a non-empty
email value. Unverified emails are dropped. If userinfo lacks `id`, login fails
closed without creating or binding a Principal.

`Discord.OAuth2Provider` must not write `principal_external_identities`
directly. On `{:error, :not_bound}`, the Web surface should direct the user to
activate from Discord with `/preauth <code>`. On
`{:error, :principal_disabled}` or `{:error, :not_human}`, it fails closed.

## Outbound delivery

Discord outbound delivery executes upstream-approved transport requests. The
adapter does not decide whether an AIAgent, Workflow, Human, Capability, or
business layer may speak in a Discord channel, edit a message, or stream.
Principal, AuthZ, Budget, policy, approval, and durable business-record checks
happen before the adapter is called.

`Discord.ChannelAdapter.deliver/4` supports send and edit in the first
implementation.

Discord snowflake ids in `reply_channel` and outbound targets are strings. The
adapter parses them back to integers for Nostrum calls.

### Allowed mentions

Every outbound Discord message uses safe allowed mentions:

```elixir
%{"parse" => ["users"], "replied_user" => true}
```

This disables `@everyone` and role mentions by default. User mentions and the
replied-user notification are allowed because they are part of normal Discord
conversation behavior.

### Message size limits

Discord measures message content in UTF-16 code units. The hard limit is 2000
units per message. `stream_chunk_soft_limit` defaults to 1850 units so stream
edits have room for in-flight text.

`Discord.ContentMapper.utf16_units/1` counts code units by treating codepoints
above `0xFFFF` as two units. Splitting walks codepoints, not graphemes, so
surrogate pairs are counted correctly for emoji-heavy text.

### Send

Targeting rules:

- `reply_channel.scope_id` is the Discord channel id or thread channel id.
- `reply_channel.thread_id` is always `null` for Discord.
- `reply_channel.reply_to_external_id`, when present, is passed as a message
  reference with `fail_if_not_exists = false`.

Content rules:

- `text` sends a Discord message with rendered text.
- Text exceeding 2000 UTF-16 units splits into multiple message creates.
- `image_url`, `video_url`, `file`, and `card` degrade to one localized fallback
  text message in the first implementation.

The adapter returns all created Discord message ids in `external_message_ids`.
`primary_external_id` is the first message id. Degraded non-text sends include a
warning such as `"_degraded_to_fallback_text"`.

If Discord reports that a reply target was missing, the adapter retries once as
a normal channel send without message reference. A successful fallback returns a
degraded result with warning `"reply_target_missing_sent_to_scope"`. If
`scope_id` is missing, the adapter returns a payload error.

### Edit

Edit requires the target Discord message id. Discord supports editing text in
the first implementation. Editing embeds, components, attachments, or reply
markup is out of scope.

Edited text exceeding 2000 UTF-16 units returns a payload error unless the edit
is part of active stream reconciliation where the streamer owns splitting.
Discord's "message is not modified" or equivalent no-op response is treated as
success with warning `"message_unchanged"`. Missing or uneditable target
messages map to payload, unsupported, not-found, or permission errors, not
network errors.

## Stream transport

Discord streaming uses multi-message accumulation with throttled edits and final
reconciliation through `Discord.ChannelAdapter.consume_stream/4`. The adapter
consumes the EventBus stream buffer APIs; it does not create stream chunks,
inspect Target internals, infer business completion, or write Conversation
transcripts.

State:

```elixir
%{
  source: %Discord.Source{},
  reply_channel: %{},
  current_text: "",
  message_ids: [],
  last_update_at: nil,
  warnings: []
}
```

Flow:

1. Call `resume_stream/2` with the upstream `stream_id` and last delivered
   offset.
2. Append or replace `current_text` according to stream chunks.
3. Split `current_text` into chunks at `stream_chunk_soft_limit` UTF-16 units.
4. If the chunk count exceeds existing `message_ids`, edit the last existing
   message to its current chunk, then send missing tail chunks without message
   reference.
5. Otherwise, edit the last existing message when the throttle interval expires
   or the current chunk forced a flush.
6. When `follow?` is true, call `follow_stream/3` and apply the same update
   logic for live chunks.
7. On terminal stream status, reconcile every existing Discord message, create
   missing tail messages, and delete extra messages from earlier overshoots.

Only the first stream message uses reply parameters. Later split messages use
plain sends with the same channel id.

If the stream contains no text by terminal reconciliation, the adapter returns a
payload error such as `"stream content is absent"`. If Redis stream state is
missing or expired, the adapter returns safe unavailable or no-content result.

Discord rate-limit responses with retry hints below the configured inline bound
are honored inline. Longer waits return a retryable transport error so upstream
retry policy can decide when to resume.

On stream exception or cancellation observed by the adapter, Discord attempts
one final edit of the last existing message with localized failure text and then
returns the original normalized safe error to the caller.

## Error mapping

`Discord.Error` maps Nostrum, Discord HTTP, and OAuth2 failures into
JSON-neutral, string-keyed safe errors:

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
| HTTP 404 on edit or reply target | `payload` or `not_found` according to caller contract |
| Timeout, DNS, TLS, gateway WebSocket disconnect, transient 5xx | `network` or `provider_unavailable` |
| Invalid source config, missing credential profile, application id mismatch | `config` |
| Invalid content, missing target, malformed interaction option, unavailable stream content | `payload` |
| Unsupported edit kind, unsupported event surface, content with no fallback | `unsupported` |
| Stream cancellation observed by adapter | `stream_cancelled` |
| Missing or disabled Principal where required | `principal` |
| Unknown Discord or Nostrum error | `unknown` |

`details` may include `http_status`, `discord_code`, `retry_after`, and
redacted endpoint context. It must not include bot tokens, client secrets,
OAuth codes, OAuth tokens, raw message or interaction bodies, private
interaction values, plaintext activation/login codes, full Events, attachment
bytes, or stream chunks.

The adapter must not invent EventBus core errors such as
`%BullX.EventBus.InvalidEvent{}` or `%BullX.EventBus.AppendFailed{}`. It may
return those values only when `BullX.EventBus.accept/2` returned them.

## Telemetry and logs

Discord uses the Channel Adapter telemetry prefix from `ChannelAdapter.md` and
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
- `[:bullx, :event_bus, :adapter, :discord, :ready]`
- `[:bullx, :event_bus, :adapter, :discord, :application_commands, :sync]`
- `[:bullx, :event_bus, :adapter, :discord, :attention, :decided]`
- `[:bullx, :event_bus, :adapter, :discord, :command, :normalized]`
- `[:bullx, :event_bus, :adapter, :discord, :ask, :acknowledged]`
- `[:bullx, :event_bus, :adapter, :discord, :thread, :created]`
- `[:bullx, :event_bus, :adapter, :discord, :thread, :ownership_resolved]`
- `[:bullx, :event_bus, :adapter, :discord, :oauth2, :callback]`

Allowed metadata includes adapter id, plugin id, source id, application id, bot
user id, guild id, Discord channel id, thread channel id, message id,
interaction id, hashed Event source, hashed Event id, normalized Event type,
attention reason, ignore reason, command name, EventBus acceptance status, Event
Routing Rule id, TargetSession id, stream id, offset, diagnostic code, retry
delay, Discord error code, and provider HTTP status code.

Logs are part of the manual-run contract. Startup, READY, application command
sync, inbound mapping, attention decisions, command normalization, `/ask`
acknowledgement, thread creation, EventBus acceptance, outbound delivery, stream
flush, and OAuth2 callback paths should emit safe structured log lines. Logs
must not include bot tokens, client secrets, OAuth codes, OAuth tokens, raw
message or interaction bodies, raw message text beyond normalized content,
private interaction values, plaintext activation/login codes, full
`reply_channel`, full Events, attachment bytes, or stream chunks.

## I18n

All human-facing Discord text uses `BullX.I18n` and the application-global
locale. The adapter does not choose locale from Discord user locale, guild
preferred locale, `Accept-Language`, or browser settings.

Add at least these keys in supported locales:

```toml
[eventbus.discord.auth]
activation_required = "..."
login_not_bound = "..."
denied = "..."

[eventbus.discord.ask]
accepted = "..."

[eventbus.discord.delivery]
fallback_text = "..."
stream_generating = "..."
stream_failed = "..."
stream_cancelled = "..."
reply_target_missing_sent_to_scope = "..."
message_unchanged = "..."

[eventbus.discord.media]
image = "..."
audio = "..."
video = "..."
file = "..."
sticker = "..."

[eventbus.discord.errors]
unsupported_message = "..."
profile_unavailable = "..."
thread_create_failed = "..."
```

Tests must fail if a key used by the adapter is missing in any bundled locale.

## Security and privacy

Discord bot transport authenticity is adapter-owned through Nostrum's gateway
WebSocket session identification. OAuth2 token exchange and userinfo fetching
run over TLS to Discord with the client secret in the token request body, never
in a query string.

The adapter must:

- drop self-sent bot messages and other bots' messages before EventBus handoff;
- ignore webhook messages and system messages;
- preserve guild, channel, thread, actor, and safe command facts so
  adapter-local `/preauth <code>` and `/web_auth` handlers can reject disallowed
  surfaces without consuming or issuing secrets;
- restrict immediate native interaction responses to neutral acknowledgements,
  source-level malformed/unsupported responses, and activation-required prompts
  for AIAgent-facing entry points such as `/ask`;
- validate OAuth2 state, nonce, source id, age, and local `return_to`;
- discard Discord user access and refresh tokens after userinfo retrieval;
- never include unverified Discord emails in login subjects;
- keep bot tokens, OAuth client secrets, OAuth codes, OAuth tokens, raw provider
  payloads, private interaction values, and raw callback bodies out of Events,
  `routing_facts`, `reply_channel`, Oban args, stream metadata, telemetry, logs,
  and safe errors;
- keep provider credential values in `BullX.Config` secret storage;
- keep provider ids as external evidence and let `BullX.Principals` own durable
  identity decisions;
- refuse to start a second Discord gateway connection against the same bot token
  on the same node;
- apply safe `allowed_mentions` defaults to every outbound message and
  interaction reply.

Discord outbound delivery may be customer-facing. The adapter assumes the
transport request already passed the necessary upstream authorization and
business-record boundaries. The adapter must not add a shortcut that lets direct
Discord API calls bypass the adapter delivery contract for business effects.
Immediate ephemeral provider responses are restricted to documented command and
acknowledgement paths; they are not a general outbound path.

## Failure behavior

Provider authentication failures, malformed events, missing required Discord
fields, missing credential profiles, unsupported content, unsupported
interactions, and unsupported events fail closed. They produce redacted
telemetry and safe logs.

For inbound occurrences, the adapter considers the Discord event handled only
when one of these conditions is true:

- the occurrence was intentionally ignored, such as self-sent bot, other bot,
  webhook author, ignored channel, outside allowlist, unmentioned guild message,
  unsupported event surface, or unresolved thread ownership;
- native interaction acknowledgement and EventBus handoff completed for accepted
  command interactions;
- `BullX.EventBus.accept/2` returned accepted, duplicate, or accepted_ignored;
- the occurrence is structurally malformed and retry would not produce a valid
  Event.

Transient EventBus append failures should surface as provider processing
failures. Discord gateway WebSocket redelivery semantics are provider-owned, and
EventBus dedupe through `(source, id)` protects against repeated handoff.

Retryable provider errors include rate limiting, network failures, timeouts,
gateway reconnects, and temporary provider unavailability. Auth, permission,
payload, unsupported, and malformed-target errors are terminal unless Discord
supplies a specific retry hint.

Process-local state is reconstructible. If `Discord.Channel` or the Nostrum bot
subtree restarts, `Discord.SourceRuntime` restarts both together, the Discord
gateway WebSocket reconnects through Nostrum's normal resume path, cache entries
rebuild opportunistically, and thread ownership re-resolves from Discord channel
metadata on demand. EventBus and Principal durable facts remain in PostgreSQL.

A persistent Discord gateway authentication failure, such as invalid token,
must produce a visible bot subtree crash and operator diagnostic instead of an
infinite silent retry loop.

## Implementation handoff

### Goal

Implement the Discord adapter plugin as one trusted plugin that exposes Discord
EventBus Channel Adapter transport and Discord Principal OAuth2 browser login
while preserving the current Plugin, EventBus, Channel Adapter, StreamingOutput,
and Principal boundaries.

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
- `docs/design-docs/plugins/FeishuAdapter.md`
- `docs/design-docs/plugins/TelegramAdapter.md`
- `Kraigie/nostrum`

### Constraints

- Put plugin code under `plugins/discord`.
- Use plugin id `"discord"` and Channel Adapter id `"discord"`.
- Use plugin config keys under `bullx.plugins.discord.*`.
- Register `:"bullx.event_bus.channel_adapter"` and
  `:"bullx.principals.login_provider"`.
- Use the Discord source id as `data.channel.id`, Principal `channel_id`, and
  concrete Discord OAuth2 `login_subject.provider`.
- Use `BullX.EventBus.ChannelAdapter`, not a provider-specific routing
  contract.
- Use `BullX.EventBus.accept/2`, not a second publish path.
- Use `BullX.Principals`, not provider-owned account tables.
- Store bot tokens and OAuth client secrets through `BullX.Config`; do not
  persist OAuth user tokens.
- Use Nostrum as the Discord bot and REST client; do not add a separate Discord
  dependency unless Nostrum cannot support the required source runtime after a
  design decision.
- Do not add webhook ingress, native attachment upload, component callbacks,
  modals, autocomplete, Login Widget flow, or provider-specific persistence
  tables in the first implementation.
- Do not change EventBus matcher, TargetSession side-channel behavior,
  TargetSession Oban job behavior, Target dispatch, or business persistence to
  fit Discord.
- Do not add Principal ids to Events unless they came from `BullX.Principals`.
- Do not put resolved Principal ids into `routing_facts`.

### Tasks

1. Add the Discord plugin skeleton.
   - Owns: `plugins/discord/mix.exs`, `Discord.Plugin`, plugin tests.
   - Depends on: plugin host implementation.
   - Acceptance: BullX discovers plugin id `"discord"`, Channel Adapter
     extension id `"discord"`, and login-provider extension id `"discord"` when
     the plugin is compiled.
   - Verify: plugin discovery and registry tests.

2. Add Discord plugin configuration.
   - Owns: `Discord.Config`, source/credential casters, redaction helpers, and
     secret-key tests.
   - Depends on: Task 1.
   - Acceptance: `bullx.plugins.discord.credentials` is secret,
     `eventbus_sources` validates enabled sources, OAuth2 requires a client
     secret, source ids are stable, and public projections never reveal
     credentials.
   - Verify: config and secret writer tests.

3. Implement Discord source connectivity and adapter capabilities.
   - Owns: `Discord.Source`, `Discord.ChannelAdapter`, `Discord.Error`.
   - Depends on: Task 2.
   - Acceptance: capabilities are precise, connectivity checks bot token and
     application identity without starting a bot, Message Content Intent
     requirement is surfaced, and responses contain only safe metadata.
   - Verify: source and adapter unit tests with fake Nostrum and fake Req
     modules.

4. Implement source runtime, READY handling, and application command sync.
   - Owns: `Discord.SourceSupervisor`, `Discord.SourceRuntime`,
     `Discord.Channel`, `Discord.Consumer`, `Discord.ApplicationCommands`.
   - Depends on: Task 3.
   - Acceptance: one source starts one isolated bot subtree, READY resolves bot
     identity, command sync is selective by BullX-owned names, duplicate bot
     token runtime conflicts fail visibly, and sync failures do not stop
     inbound/outbound paths.
   - Verify: source-runtime and command-sync tests with fake Nostrum APIs.

5. Implement inbound mapping, content mapping, attention policy, and thread
   ownership.
   - Owns: `Discord.EventMapper`, `Discord.ContentMapper`,
     `Discord.AttentionPolicy`, `Discord.ThreadOwnership`.
   - Depends on: Task 4.
   - Acceptance: message create, message edit, and `/ask` interactions normalize
     to valid decoded CloudEvents; snowflakes are strings; bot mentions are
     stripped from text; thread-as-scope semantics hold; attention reasons and
     ignore reasons are tested; thread ownership cache plus REST fallback
     behaves as specified.
   - Verify: mapping, attention, edit-filter, and thread-ownership tests.

6. Implement Principal account gate and command normalization.
   - Owns: `Discord.CommandNormalizer`, `Discord.ProviderResponse`, locale keys,
     Principal fixtures.
   - Depends on: Task 5.
   - Acceptance: normal user-origin Events call Principal matching before
     EventBus acceptance; command-shaped input normalizes to
     `bullx.command.invoked` with actor evidence, optional `actor.principal`,
     command routing facts, and safe native interaction acknowledgement when
     needed; `/preauth` and `/web_auth` run as adapter-local channel
     activation/login commands.
   - Verify: focused command-normalization and Principal integration tests.

7. Implement `/ask` and auto-threading.
   - Owns: `Discord.AskCommand`, auto-thread branch in `Discord.Channel`,
     thread ownership marking.
   - Depends on: Tasks 5 and 6.
   - Acceptance: `/ask` sends an ephemeral acknowledgement, creates a BullX-owned
     thread when eligible and enabled, rewrites scope to the thread channel id,
     and publishes `bullx.command.invoked`; thread creation failures return a
     localized error and do not publish.
   - Verify: `/ask` happy path, DM path, no-thread channel, and thread-create
     failure tests.

8. Implement Discord OAuth2 login provider.
   - Owns: `Discord.OAuth2Provider`, OAuth2 state/profile tests.
   - Depends on: Tasks 2 and 3, plus the Principal login-provider host contract.
   - Acceptance: authorization URL generation and callback normalization produce
     a valid Principal login subject with provider set to the source id; verified
     email only; tokens are discarded; missing user id fails closed.
   - Verify: fake `Req` callback tests.

9. Implement outbound send and edit.
   - Owns: `Discord.Outbound`, outbound content rendering, safe allowed mentions,
     reply fallback, UTF-16 splitting, and error mapping.
   - Depends on: Task 3.
   - Acceptance: send/edit return adapter-compatible sent, degraded, or safe
     error results; reply-target fallback returns
     `"reply_target_missing_sent_to_scope"`; over-limit edit returns a payload
     error; safe `allowed_mentions` is applied; no-op edit is treated as
     success.
   - Verify: outbound tests with fake Nostrum responses.

10. Implement stream consumption with multi-message accumulation.
    - Owns: `Discord.Streamer`.
    - Depends on: Task 9 and EventBus streaming APIs from `StreamingOutput.md`.
    - Acceptance: stream consumes buffered chunks first, follows live pointer
      notifications, UTF-16 splitting respects `stream_chunk_soft_limit`,
      throttling honors `stream_update_interval_ms`, final reconciliation edits
      current messages, creates missing tail messages, deletes overshoots, and
      never inspects Target internals or writes transcripts.
    - Verify: streamer tests with fake stream buffer and fake Nostrum
      responses.

11. Add telemetry, logs, locale coverage, and privacy tests.
    - Owns: Discord modules and locale files.
    - Depends on: Tasks 4 through 10.
    - Acceptance: safe telemetry/log metadata exists for startup, READY,
      command sync, attention, inbound mapping, command normalization, `/ask`, thread
      creation, EventBus acceptance, delivery, streaming, and OAuth2 callback;
      locale tests fail on missing keys; secrets, tokens, raw events, raw
      message bodies, private interaction values, and auth codes never appear in
      logs or safe errors.

### Stop and ask

Implementation should stop and ask if a change would require:

- routing on data that cannot be normalized into `routing_facts` or another
  explicit `RoutingContext` field;
- provider raw payload retention that needs a new retention, redaction, or access
  control rule;
- provider acknowledgement waiting for Target execution or business
  persistence;
- webhook ingress, native attachment upload, component callback handling, modal
  handling, voice/presence/member surfaces, Discord Login Widget, or shard
  coordination for multiple sources per bot token;
- persistent Discord OAuth access or refresh tokens, or a new credential store;
- authorization, approval, or business-record decisions inside the adapter;
- EventBus route topology, TargetSession behavior, or Target internals as a
  Discord-specific contract;
- source supervision outside plugin children;
- provider-specific persistence tables.

### Done when

- `plugins/discord` compiles as a BullX plugin.
- The plugin registers `:"bullx.event_bus.channel_adapter"` id `"discord"`.
- The plugin registers `:"bullx.principals.login_provider"` implementation id
  `"discord"`, and enabled Discord source ids route to it as concrete login
  provider ids.
- Discord source config and plugin credentials validate through `BullX.Config`.
- Connectivity checks verify bot token, application identity, and OAuth2 client
  secret presence without starting a bot or leaking secrets.
- Enabled Discord sources start isolated Nostrum bot runtimes under plugin
  supervision.
- The attention policy filters guild noise according to this design.
- Discord inbound occurrences normalize into valid decoded CloudEvents and call
  `BullX.EventBus.accept/2`.
- `MESSAGE_UPDATE` user edits publish as `bullx.message.edited`; non-user edits
  are filtered.
- Accepted Discord `/command`, `/status`, and `/ask` slash-text or native
  application commands publish `bullx.command.invoked` Events with command
  routing facts and no adapter-owned EventBus command business side effects;
  native interaction acknowledgements remain transport timing only.
- Discord `/preauth` and `/web_auth` run as adapter-local channel
  activation/login commands and do not publish EventBus command Events.
- `/ask` is registered as a native application command, acknowledges
  ephemerally, auto-creates a BullX-owned thread in eligible guild text channels
  when enabled, and publishes `bullx.command.invoked` scoped to the thread.
- Native application command sync is selective by BullX-owned names and never
  bulk-overwrites.
- Discord OAuth2 callback logs in or creates only Human Principals according to
  `BullX.Principals` matching rules; tokens are discarded; unverified emails are
  dropped.
- Discord outbound send, edit, and stream paths produce adapter-compatible
  outcomes or safe errors; safe `allowed_mentions` is applied everywhere.
- UTF-16 message splitting passes targeted tests on Asian-script and
  emoji-heavy text.
- A persistent Discord gateway authentication failure produces a visible bot
  runtime crash and is not silently retried forever.
- Self-sent, other-bot, webhook, anonymous, and unsupported events are filtered
  before EventBus handoff.
- Bot tokens, OAuth client secrets, OAuth codes, OAuth tokens, raw provider
  payloads, private interaction values, attachment bytes, and stream chunks do
  not enter telemetry, logs, safe errors, Events, `routing_facts`,
  `reply_channel`, Oban args, or stream metadata. Plaintext activation/login
  codes do not enter generic routing or diagnostic surfaces and only appear
  through a protected command argument shape when a command design requires them.
- No provider-owned routing layer, provider-owned identity system, webhook
  ingress, component callback flow, Discord Login Widget flow, or parallel
  provider runtime is introduced.

Verification commands:

```bash
mix format --check-formatted
# focused tests for plugin discovery, config, source connectivity, source
# runtime, command sync, inbound normalization, attention policy, direct
# commands, /ask, OAuth2 login, delivery, stream transport, telemetry, logging,
# and locale coverage
MIX_ENV=test mix compile --warnings-as-errors
bun precommit
```
