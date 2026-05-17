# Telegram Channel Adapter

The Telegram integration is a trusted BullX plugin under
`plugins/bullx_telegram`. It registers one Telegram Channel Adapter for
EventBus. The adapter verifies Telegram Bot API input, normalizes accepted
updates into decoded CloudEvents JSON, calls `BullX.EventBus.accept/2`, and
exposes optional Telegram outbound delivery and stream transport. It does not
evaluate Event Routing Rules, create TargetSessions, invoke Targets, authorize
side effects, or persist business facts.

Telegram does not register a Principal browser login provider. Browser login for
Telegram actors uses the built-in `/preauth <code>` activation flow and
`/web_auth` channel-auth login code flow.

## Scope

This design covers the Telegram plugin adapter:

- plugin placement, extension declaration, plugin-owned source configuration,
  and plugin-owned credential configuration;
- long-poll source supervision, connectivity checks, inbound normalization,
  attention filtering, direct channel commands, and provider acknowledgement by
  polling offset;
- Telegram channel actor evidence and Principal activation/login handoff;
- outbound send, edit, reply fallback, UTF-16 message splitting, and
  multi-message stream transport;
- Telegram-specific content mapping, actor normalization, error mapping,
  telemetry, logging, security, privacy, tests, and implementation handoff.

This design depends on:

- `docs/design-docs/Plugins.md` for trusted plugin discovery, enabled plugin
  configuration, extension declarations, config modules, and plugin children;
- `docs/design-docs/eventbus/ChannelAdapter.md` for the common adapter contract;
- `docs/design-docs/eventbus/Core.md` for `BullX.EventBus.accept/2`,
  CloudEvents validation, and normalized payload shape;
- `docs/design-docs/eventbus/Matcher.md` for `RoutingContext`,
  `routing_facts`, Event Routing Rule priority, Blackhole, and scope/window
  policy;
- `docs/design-docs/eventbus/StreamingOutput.md` for output stream buffers that
  Telegram stream transport may consume;
- `docs/design-docs/Principal.md` for channel actor matching, activation codes,
  and channel-auth login codes.

## Goals

- Keep Telegram out of BullX core modules by shipping it as one plugin under
  `plugins/bullx_telegram`.
- Register Telegram as a Channel Adapter through
  `:"bullx.event_bus.channel_adapter"`.
- Use `visciang/telegram` as a stateless Bot API client while BullX owns source
  supervision and transport lifecycle.
- Use stable CloudEvents `(source, id)` values for Telegram update redelivery
  idempotency.
- Keep Telegram actor evidence channel-local unless `BullX.Principals` resolves
  it into a trusted `actor.principal_ref`.
- Filter group-chat noise at the adapter edge through an explicit attention
  policy so unrelated group messages do not enter EventBus.
- Keep bot tokens, raw updates, message text outside normalized content, and
  activation/login codes out of telemetry, logs, safe errors, Events,
  `routing_facts`, `reply_channel`, Oban job args, and stream metadata.

## Non-goals

- Do not add Telegram modules under `lib/bullx/` or `lib/bullx_web/` except for
  generic host surfaces required by plugin or Principal extension contracts.
- Do not add provider-specific EventBus tables, route tables, durable raw update
  logs, or adapter-owned business records.
- Do not route on raw Telegram updates, CloudEvents extension attributes,
  `subject`, nested provider carrier names, message text, or media bytes.
- Do not register a Telegram Principal login provider. Telegram Bot API browser
  login uses `/preauth <code>` and `/web_auth`.
- Do not add Telegram Login Widget routes, embedded login pages,
  `auth_date`/hash verification, or domain allowlists.
- Do not implement webhook ingress in the first implementation. Inbound
  transport is long-poll only.
- Do not implement native media upload in the first implementation. Non-text
  outbound content degrades to localized fallback text.
- Do not implement inline-keyboard callback handling, custom reply keyboards,
  poll/quiz handling, business connection, payments, channel post ingress, or
  member updates.
- Do not maintain Telegram-owned durable offset state or provider-specific
  persistence tables.

## Plugin shape

The plugin app id is `:bullx_telegram`, the plugin id is `"bullx_telegram"`,
and the directory is `plugins/bullx_telegram`. The adapter extension id is
`"telegram"`. These names intentionally differ: the plugin id follows the Mix
app and config namespace, while the adapter id is the external channel type that
appears in Events, Principal channel actors, and Event Routing Rule matching.

The plugin namespace is `BullxTelegram.*`, not `Telegram.*`, because the
Telegram Bot API dependency owns the `Telegram.*` namespace.

```elixir
defmodule BullxTelegram.Plugin do
  use BullX.Plugins.Plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.event_bus.channel_adapter",
        id: "telegram",
        module: BullxTelegram.ChannelAdapter,
        opts: %{provider: "telegram"}
      }
    ]
  end

  @impl BullX.Plugins.Plugin
  def config_modules, do: [BullxTelegram.Config]

  @impl BullX.Plugins.Plugin
  def children(_enabled_plugin_config), do: [BullxTelegram.SourceSupervisor]
end
```

Suggested module ownership:

| Module | Responsibility |
| --- | --- |
| `BullxTelegram.Plugin` | Plugin metadata, config modules, extension declarations, and plugin children. |
| `BullxTelegram.Config` | Plugin-owned `BullX.Config` declarations and source/credential casters. |
| `BullxTelegram.Source` | Runtime source normalization, credential lookup, bot identity validation, redacted public projection, and connectivity checks. |
| `BullxTelegram.SourceSupervisor` | Enabled-source supervision under the plugin failure boundary. |
| `BullxTelegram.Channel` | Per-source runtime boundary, source-local dispatch, cache key prefixes, command sync, and bot identity context. |
| `BullxTelegram.Poller` | Long-poll worker holding `getUpdates` offset and retry state. |
| `BullxTelegram.ChannelAdapter` | `BullX.EventBus.ChannelAdapter` implementation and public adapter boundary. |
| `BullxTelegram.UpdateMapper` | Telegram update normalization into CloudEvents. |
| `BullxTelegram.ContentMapper` | Telegram message content blocks, outbound rendering, and UTF-16 text splitting. |
| `BullxTelegram.AttentionPolicy` | Group-chat attention filter. |
| `BullxTelegram.DirectCommand` | Built-in `/ping`, `/preauth <code>`, and `/web_auth` command handling. |
| `BullxTelegram.Commands` | Optional `setMyCommands` sync helper. |
| `BullxTelegram.Outbound` | Send, edit, and reply-target fallback. |
| `BullxTelegram.Streamer` | Multi-message stream consumption with throttled edits and final reconciliation. |
| `BullxTelegram.Error` | Bot API and client error normalization. |

Adapter modules call the Telegram Bot API client directly and route failures
through `BullxTelegram.Error`. The plugin must not start package-owned poller or
webhook supervisors. The dependency is a Bot API client, not the BullX
transport lifecycle owner.

## Runtime configuration

Operators enable the plugin through the normal plugin list:

```json
["bullx_telegram"]
```

Telegram configuration lives under the plugin namespace:

```text
bullx.plugins.bullx_telegram.credentials
bullx.plugins.bullx_telegram.eventbus_sources
```

Initial declarations:

| Accessor | DB key | Secret | Default |
| --- | --- | --- | --- |
| `credentials!/0` | `bullx.plugins.bullx_telegram.credentials` | yes | `{}` |
| `eventbus_sources!/0` | `bullx.plugins.bullx_telegram.eventbus_sources` | no | `[]` |

`credentials` is a JSON object keyed by credential id. Each value contains the
bot token and optional bot username metadata:

```json
{
  "default": {
    "bot_token": "123456:ABCDEF",
    "bot_username": "bullx_bot"
  }
}
```

The credentials map is encrypted by `BullX.Config`. It must not appear in
Events, source public projections, `routing_facts`, `reply_channel`, Oban job
args, stream metadata, telemetry, logs, safe errors, or operator receipts.

`bot_username` is optional. If absent, the adapter resolves it from `getMe` at
startup and connectivity check time. If present, it must match the resolved
`getMe.username` case-insensitively. The username is used for mention and
`/command@bot_username` parsing; it is not identity truth.

`eventbus_sources` is a JSON array of Telegram source entries:

```json
[
  {
    "id": "main",
    "enabled": true,
    "credential_id": "default",
    "connected_realm_ref": "telegram:bot:123456",
    "bot_username": "bullx_bot",
    "web_login_disabled": false,
    "poll_timeout_s": 30,
    "poll_limit": 100,
    "poll_retry_max": 10,
    "flood_wait_max_ms": 5000,
    "stream_update_interval_ms": 1000,
    "stream_chunk_soft_limit": 3900,
    "direct_command_dedupe_ttl_seconds": 300,
    "message_context_ttl_seconds": 2592000,
    "attention": {
      "allowed_chat_ids": [],
      "ignored_chat_ids": [],
      "ignored_thread_ids": [],
      "require_mention": true,
      "free_response_chat_ids": []
    },
    "commands": {
      "sync_policy": "replace"
    }
  }
]
```

The source `id` is the stable adapter-local source id. It becomes
`data.channel.id` in Events and `channel_id` in Principal channel-actor
references. It is not a Telegram chat id, user id, bot id, bot username, or
credential id.

Telegram chat ids become `data.scope.id`. Telegram forum topic ids become
`data.scope.thread_id`.

Telegram enforces one active `getUpdates` long poll per bot token. Two enabled
sources using the same credential id cannot long-poll at the same time. The
source runtime must detect an active credential collision on the same node and
fail the second source with a `config` error instead of starting a conflicting
poller.

## Connectivity check

`BullxTelegram.Source.connectivity_check/1` validates one normalized source
without starting a poller, syncing commands, publishing an Event, changing
source config, or writing Principal data. It loads the referenced credential
profile, constructs a Telegram Bot API client, calls `getMe`, and returns only
redacted operator metadata.

If `bot_username` is set in source or credential config, it must match the
resolved username case-insensitively. If absent, the resolved username is
returned for operator confirmation.

Success shape:

```elixir
{:ok,
 %{
   status: :ok,
   adapter: "telegram",
   source_id: "main",
   capabilities: [:inbound, :send, :edit, :stream, :threads],
   details: %{
     "transport" => "polling",
     "bot_id" => "123456",
     "bot_username" => "bullx_bot",
     "credential" => "verified"
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

Connectivity responses must never include bot tokens, raw `getMe` response
bodies, polling offsets, retry state, or update payloads.

## Adapter contract

`BullxTelegram.ChannelAdapter` implements `BullX.EventBus.ChannelAdapter`.

| Callback | Telegram behavior |
| --- | --- |
| `normalize_inbound/2` | Converts one Telegram update into one decoded CloudEvent, returns `:ignore`, or returns a safe error. |
| `capabilities/0` | Declares long-poll inbound, send, edit, stream, thread support, and supported content kinds. |
| `deliver/4` | Executes upstream-approved send or edit transport when supported. |
| `consume_stream/4` | Consumes an EventBus output stream and mirrors chunks to Telegram messages. |

Capabilities should include:

```elixir
%{
  inbound_modes: [:polling],
  outbound_ops: [:send, :edit, :stream],
  content_kinds: [:text, :image, :audio, :video, :file, :card],
  features: [:reply, :threads, :attention_policy],
  stream_strategy: :edit_accumulate
}
```

`content_kinds` includes non-text content so upstream callers can pass standard
BullX content blocks. The first implementation degrades non-text outbound
content to fallback text instead of using Telegram native upload methods.

EventBus core validates the decoded CloudEvent passed to `accept/2`. Telegram
still validates source config, update shape, attention policy, target ids,
message size limits, and Bot API responses.

## Source runtime

For each enabled source, `BullxTelegram.SourceSupervisor` starts a source-local
runtime boundary:

```text
BullxTelegram.SourceSupervisor
  -> BullxTelegram.SourceRuntime
     -> BullxTelegram.Channel
     -> BullxTelegram.Poller
```

`BullxTelegram.SourceRuntime` may be a `:one_for_all` supervisor so channel
context and polling offset restart together. If the poller crashes because of a
persistent `getUpdates` conflict, the runtime should surface a distinct
`:telegram_polling_conflict` reason for operator diagnosis instead of silently
running forever in a restart loop.

At startup the source runtime:

1. Resolves `bot_id` and `bot_username` through `getMe`.
2. Calls `deleteWebhook(drop_pending_updates: false)` so Telegram allows
   `getUpdates`.
3. Optionally syncs bot commands through `setMyCommands` when
   `commands.sync_policy = "replace"`.
4. Starts long polling with `getUpdates`.

The poller calls `getUpdates` with:

- `timeout = poll_timeout_s`;
- `limit = poll_limit`;
- `allowed_updates = ["message", "edited_message"]`.

On transient failure, the poller backs off up to `poll_retry_max` attempts
before crashing the source runtime. Transient failures include network errors,
timeouts, temporary 5xx responses, and rate limits. A 409 response or Telegram
description containing `terminated by other getUpdates` is a polling conflict.
It is terminal for that source attempt and must be visible to operators.

Webhook ingress is not part of the first implementation. There is no Phoenix
controller, no `setWebhook`, no generated webhook secret, and no
`X-Telegram-Bot-Api-Secret-Token` validation.

## Inbound normalization

Telegram normalizes one update into one decoded string-keyed CloudEvents JSON
object. `BullX.EventBus.accept/2` is called once per accepted update.

CloudEvents attributes:

- `specversion` is `"1.0"`.
- `id` is the Telegram `update_id` string. Every Telegram update has one.
- `source` is a stable URI-like string such as `telegram://main/bot/123456`.
  It must include enough source context to make `(source, id)` unique inside the
  Installation.
- `type` is a normalized BullX Event type such as `bullx.message.created`,
  `bullx.message.edited`, or `bullx.command.invoked`.
- `time` is Telegram message time when trusted; otherwise it is adapter receive
  time.
- `datacontenttype` is `"application/json"`.
- `data` is the BullX normalized payload from `Core.md`.

All Telegram numeric ids enter Events as strings to avoid JSON number precision
and 64-bit integer ambiguity. The adapter parses them back to integers only when
calling the Bot API.

Example message Event:

```json
{
  "specversion": "1.0",
  "id": "18293",
  "source": "telegram://main/bot/123456",
  "type": "bullx.message.created",
  "subject": "Telegram message 421",
  "time": "2026-05-17T10:00:00Z",
  "datacontenttype": "application/json",
  "data": {
    "content": [
      {
        "kind": "text",
        "body": {
          "text": "hello"
        }
      }
    ],
    "channel": {
      "adapter": "telegram",
      "id": "main"
    },
    "scope": {
      "id": "-100123456",
      "thread_id": "12"
    },
    "actor": {
      "id": "telegram:987654321",
      "display": "Alice",
      "bot": false,
      "principal_ref": "optional-principal-id"
    },
    "refs": [
      {
        "kind": "telegram.update",
        "id": "18293"
      },
      {
        "kind": "telegram.message",
        "id": "421"
      },
      {
        "kind": "telegram.chat",
        "id": "-100123456"
      },
      {
        "kind": "telegram.thread",
        "id": "12"
      },
      {
        "kind": "telegram.user",
        "id": "987654321"
      }
    ],
    "reply_channel": {
      "adapter": "telegram",
      "channel_id": "main",
      "scope_id": "-100123456",
      "thread_id": "12",
      "reply_to_external_id": "421"
    },
    "routing_facts": {
      "provider_update_type": "message",
      "chat_type": "supergroup",
      "content_kind": "text",
      "attention_reason": "mention",
      "connected_realm_ref": "telegram:bot:123456"
    },
    "raw_ref": {
      "kind": "telegram.update",
      "id": "18293"
    }
  }
}
```

`subject` is display/debug text only. Telegram must not depend on it for
routing. Provider-specific matching data belongs in `data.routing_facts` or
another normalized field exposed by `RoutingContext`.

`raw_ref` is a safe reference, not the raw update. It must not include raw
message text, bot tokens, activation/login codes, private callback data, or
media bytes.

## Actor identity

Telegram actor ids are channel-local external ids:

```text
data.actor.id = "telegram:" <> user_id
```

`user_id` is required for Principal channel actor matching. Telegram normally
supplies `message.from.id` for user-origin messages. If a message has no
`from` field, such as anonymous administrator posts or channel posts, the
adapter ignores it.

Trusted profile fields may include `display_name`, `username`, `first_name`,
`last_name`, `language_code`, and `user_id`. The adapter computes
`display_name` from first and last name, falling back to username and then
`"telegram:" <> user_id`. Telegram bots do not receive user email or phone
numbers, so Telegram channel actor inputs normally carry neither field.

Self-sent bot messages are ignored before content parsing, Principal matching,
direct-command handling, or EventBus handoff. Messages from other bots are also
ignored unless they explicitly reply to the BullX bot and the attention policy
accepts them.

## Scope, threads, and chat types

| Telegram chat type | Scope and thread mapping |
| --- | --- |
| `private` | `data.scope.id = chat_id`, which equals the user id; `thread_id = null`. |
| `group` or `supergroup` | `data.scope.id = chat_id`; `thread_id = message_thread_id` when present. |
| Forum "General" topic | `thread_id = null`; Telegram does not assign `message_thread_id` to General. |
| `channel` | Inbound channel posts are ignored in the first implementation. Outbound may target a channel only after upstream authorization. |

`thread_id` is stringified inside Events and parsed back to integer
`message_thread_id` only for Bot API calls.

## Attention policy

Group-chat messages are filtered before EventBus handoff. This is transport
admission, not business routing. If a message is accepted by attention policy,
Event Routing Rules still decide which Target receives it.

The policy returns an attention reason:

- `dm`
- `command`
- `mention`
- `reply_to_bot`
- `free_response`

or an ignore reason:

- `bot_author`
- `ignored_chat`
- `ignored_thread`
- `outside_allowlist`
- `unsupported_command`
- `unmentioned_group_message`
- `unsupported_update`
- `anonymous_actor`

Filter order:

1. `from.is_bot == true` and `from.id == bot_id` -> ignore as `bot_author`.
2. `chat.id` in `attention.ignored_chat_ids` -> ignore as `ignored_chat`.
3. `message_thread_id` in `attention.ignored_thread_ids` -> ignore as
   `ignored_thread`.
4. `attention.allowed_chat_ids` non-empty and `chat.id` not in it -> ignore as
   `outside_allowlist`.
5. `chat.type == "private"` -> `dm`.
6. Text begins with a command addressed to this bot -> `command`.
7. Text mentions `@bot_username` case-insensitively -> `mention`.
8. Message replies to a bot-authored message owned by this bot ->
   `reply_to_bot`.
9. `chat.id` is in `attention.free_response_chat_ids`, or
   `attention.require_mention == false` -> `free_response`.
10. Otherwise ignore as `unmentioned_group_message`.

Command parsing accepts `/cmd`, `/cmd args`, `/cmd@bot_username`, and
`/cmd@bot_username args`. Commands addressed to another bot are ignored as
`unsupported_command`.

The attention reason is stored in `data.routing_facts.attention_reason`. It is
operator-visible diagnostic and matching data, not authorization.

## Event mapping

Telegram maps allowed updates to normalized BullX Event types:

| Telegram update | Normalized `type` | Notes |
| --- | --- | --- |
| `message` text | `bullx.message.created` or `bullx.command.invoked` | Built-in direct commands are intercepted before EventBus. Other slash-style commands become command Events after attention and Principal gating. |
| `message` media or location | `bullx.message.created` | Content blocks describe the media; primary text uses caption or generated fallback. |
| `edited_message` | `bullx.message.edited` | `refs` includes the Telegram message id. |

Reaction, recall, channel-post, callback-query, member, payment, poll, quiz, and
business connection updates are not in `allowed_updates` for the first
implementation.

Provider-specific names stay in `routing_facts.provider_update_type`, such as
`message` or `edited_message`. EventBus core must not maintain a Telegram
update-name allowlist.

## Content mapping

Telegram content mapping preserves user-visible text and records stable provider
references. Mentions of the BullX bot are preserved in the primary text and
recorded in `refs`; the adapter does not strip them.

Text messages produce one text block:

```elixir
%{"kind" => "text", "body" => %{"text" => "hello"}}
```

Media with `file_id` produces an optional caption text block followed by one
native media block:

```elixir
[
  %{"kind" => "text", "body" => %{"text" => "caption"}},
  %{
    "kind" => "image",
    "body" => %{
      "url" => "telegram://file/<file_id>",
      "fallback_text" => "[image]"
    }
  }
]
```

Mapping rules:

| Telegram field | Block `kind` | File id |
| --- | --- | --- |
| `message.photo` | `image` | largest photo entry `file_id` |
| `message.sticker` | `image` | sticker `file_id` |
| `message.audio` | `audio` | audio `file_id` |
| `message.voice` | `audio` | voice `file_id` |
| `message.video` | `video` | video `file_id` |
| `message.document` | `file` | document `file_id` |

Location or venue messages produce one deterministic text block with venue
title, address when present, latitude/longitude, and a Google Maps URL. Contact,
dice, poll, unsupported sticker variants, and unsupported message kinds produce
one deterministic fallback text block through
`eventbus.telegram.errors.unsupported_message`.

The adapter must not publish empty `data.content` for a user-origin Event.

`telegram://file/<file_id>` URIs are channel-local opaque references. The
adapter does not download bytes during normalization. A Target or Capability
that needs file bytes must resolve the reference through an explicitly
authorized provider capability or follow-up adapter helper.

## Principal account gate

Before accepting normal user-origin duplex Events, Telegram calls
`BullX.Principals.match_or_create_human_from_channel/1` with the normalized
channel actor:

```elixir
%{
  adapter: :telegram,
  channel_id: "main",
  external_id: "telegram:987654321",
  profile: %{
    "display_name" => "Alice",
    "username" => "alice",
    "first_name" => "Alice",
    "language_code" => "en",
    "user_id" => "987654321"
  },
  metadata: %{
    "connected_realm_ref" => "telegram:bot:123456",
    "chat_id" => "-100123456",
    "chat_type" => "supergroup",
    "thread_id" => "12"
  }
}
```

Result handling:

| Principal result | Telegram behavior |
| --- | --- |
| `{:ok, principal, _identity}` | Normalize the Event, set `data.actor.principal_ref` to the stringified `principal.id`, and call `BullX.EventBus.accept/2`. |
| `{:error, :activation_required}` | Send localized activation guidance when appropriate and do not call EventBus. |
| `{:error, :principal_disabled}` | Send a localized denied reply when appropriate and do not call EventBus. |
| `{:error, reason}` | Treat as provider processing failure, emit safe telemetry, and do not call EventBus. |

Principal resolution is identity evidence, not authorization. Downstream
Principal, AuthZ, Governance, Capability, Target, and business layers still
decide permission, budget, approval, and side effects.

In group chats, activation-required replies must not include activation codes,
login auth codes, or links that reveal account state. The reply should ask the
user to message the bot privately. In private chats, the adapter may include
localized `/preauth <code>` and `/web_auth` guidance.

## Direct channel commands

Direct channel commands are built-in BullX channel commands implemented by
messaging adapters. Telegram handles `/ping`, `/preauth <code>`, and
`/web_auth` before EventBus handoff. These command names are not
Telegram-specific product concepts.

Direct commands run after the poller receives an update, source context is
resolved, attention policy classifies the message as `command`, and
direct-command dedupe misses. Adapter-local dedupe stores the response result by
Telegram `update_id` for `direct_command_dedupe_ttl_seconds`.

Only these built-in commands are intercepted. There is no Telegram-local `/ask`
command. Other accepted slash-style messages become `bullx.command.invoked`
Events after Principal account gating.

### `/ping`

`/ping` is a manual connectivity command. It works in private chats and groups
when addressed to the bot, does not require Principal activation, and does not
call `BullX.Principals.match_or_create_human_from_channel/1`.

The adapter sends a localized reply through its own outbound transport boundary
or through the common adapter `deliver/4` helper. The localized reply body is
`PONG!` in bundled locales. The adapter advances the polling offset only after
the reply was accepted for transport or an equivalent duplicate result was
found.

### `/preauth <code>`

`/preauth <code>` consumes a BullX activation code and creates a new Human
Principal with the current Telegram actor as the first channel binding.

Flow:

1. Reject group chats with localized DM-only guidance and do not consume the
   code.
2. Normalize the Telegram actor and trusted profile.
3. Call `BullX.Principals.consume_activation_code(code, channel_actor)`.
4. Send one localized Telegram reply through adapter outbound transport.
5. Do not publish the command as an Event.

Result mapping:

| Principal result | Telegram reply key |
| --- | --- |
| `{:ok, _principal, _identity}` | `eventbus.telegram.auth.activation_success` |
| `{:error, :invalid_or_expired_code}` | `eventbus.telegram.auth.activation_code_invalid` |
| `{:error, :already_bound}` | `eventbus.telegram.auth.already_linked` |
| `{:error, :principal_disabled}` | `eventbus.telegram.auth.denied` |
| any other `{:error, _}` | `eventbus.telegram.auth.activation_failed` |

A duplicate `update_id` returns the cached result without re-running
`consume_activation_code/2`.

### `/web_auth`

`/web_auth` issues a built-in channel-auth login code for an already bound
active Human Principal.

Flow:

1. Reject group chats with localized DM-only guidance and do not issue a code.
2. If `web_login_disabled == true`, reply with localized disabled guidance and
   do not issue a code.
3. Normalize the Telegram actor and trusted profile.
4. Call `BullX.Principals.issue_login_auth_code(:telegram, source_id, "telegram:" <> user_id)`.
5. Render a localized reply containing the short-lived code and the generic Web
   login URL.
6. Send the reply through adapter outbound transport.
7. Do not publish the command as an Event.

Result mapping:

| Principal result | Telegram reply key |
| --- | --- |
| `{:ok, code}` | `eventbus.telegram.auth.web_auth_created` |
| `{:error, :not_bound}` | `eventbus.telegram.auth.web_auth_not_bound` |
| `{:error, :principal_disabled}` | `eventbus.telegram.auth.denied` |
| `{:error, :not_human}` | `eventbus.telegram.auth.web_auth_not_bound` |
| any other `{:error, _}` | `eventbus.telegram.auth.web_auth_failed` |

The login auth code never enters telemetry, logs, safe errors, Events, or stream
metadata.

## Outbound delivery

Telegram outbound delivery executes upstream-approved transport requests. The
adapter does not decide whether an AIAgent, Workflow, Human, Capability, or
business layer may speak in a chat, edit a message, or stream. Principal, AuthZ,
Budget, policy, approval, and durable business-record checks happen before the
adapter is called.

`BullxTelegram.ChannelAdapter.deliver/4` supports send and edit in the first
implementation.

Telegram numeric ids in `reply_channel` and outbound targets are strings. The
adapter parses them back to integers for Bot API calls.

### Message size limits

Telegram measures message text in UTF-16 code units. The hard limit is 4096
units per message. `stream_chunk_soft_limit` defaults to 3900 units so stream
edits have room for in-flight text.

`BullxTelegram.ContentMapper.utf16_units/1` counts code units by treating
codepoints above `0xFFFF` as two units. Splitting walks codepoints, not
graphemes, so surrogate pairs are counted correctly for emoji-heavy text.

### Send

Targeting rules:

- `reply_channel.scope_id` is the Telegram chat id.
- `reply_channel.thread_id`, when present, is passed as `message_thread_id`.
- `reply_channel.reply_to_external_id`, when present, is passed through reply
  parameters.

Content rules:

- `text` sends `sendMessage` with rendered text.
- Text exceeding 4096 UTF-16 units splits into multiple `sendMessage` calls.
- `image`, `audio`, `video`, `file`, and `card` degrade to one localized
  fallback text message in the first implementation.

The adapter returns all created Telegram message ids in `external_message_ids`.
`primary_external_id` is the first message id. Degraded non-text sends include a
warning such as `"_degraded_to_fallback_text"`.

If Telegram reports that a reply target was recalled or missing, including
descriptions such as `replied message not found`, `message to reply not found`,
or `MESSAGE_ID_INVALID`, the adapter retries once as a normal chat send to
`reply_channel.scope_id` without reply parameters. A successful fallback returns
a degraded result with warning `"reply_target_missing_sent_to_scope"`.

### Edit

Edit requires the target Telegram message id. Telegram supports editing text
through `editMessageText` in the first implementation. Editing media captions,
file content, or reply markup is out of scope.

Edited text exceeding 4096 UTF-16 units returns a payload error rather than
silently truncating. Telegram's `message is not modified` response is treated as
success with warning `"message_unchanged"`. Missing or uneditable target
messages map to payload, unsupported, or not-found errors, not network errors.

## Stream transport

Telegram streaming uses multi-message accumulation with throttled edits and
final reconciliation through `BullxTelegram.ChannelAdapter.consume_stream/4`.
The adapter consumes the EventBus stream buffer APIs; it does not create stream
chunks, inspect Target internals, infer business completion, or write
Conversation transcripts.

State:

```elixir
%{
  source: %BullxTelegram.Source{},
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
   message to its current chunk, then send missing tail chunks without reply
   parameters.
5. Otherwise, edit the last existing message when the throttle interval expires
   or the current chunk forced a flush.
6. When `follow?` is true, call `follow_stream/3` and apply the same update
   logic for live chunks.
7. On terminal stream status, reconcile every existing Telegram message, create
   missing tail messages, and delete extra messages from earlier overshoots.

Only the first stream message uses reply parameters. Later split messages use
plain `sendMessage` with the same chat id and optional thread id.

If the stream contains no text by terminal reconciliation, the adapter returns a
payload error such as `"stream content is absent"`. If Redis stream state is
missing or expired, the adapter returns safe unavailable or no-content result.

Telegram flood-control responses with `retry_after` below `flood_wait_max_ms`
are honored inline. Longer waits return a retryable transport error so upstream
retry policy can decide when to resume.

On stream exception or cancellation observed by the adapter, Telegram attempts
one final edit of the last existing message with localized failure text and then
returns the original normalized safe error to the caller.

## Error mapping

`BullxTelegram.Error` maps Bot API and client failures into JSON-neutral,
string-keyed safe errors:

```elixir
%{
  "kind" => "rate_limit",
  "message" => "Telegram API flood control",
  "details" => %{
    "retry_after_ms" => 3000,
    "description" => "Too Many Requests: retry after 3"
  }
}
```

Mapping rules:

| Condition | Error kind |
| --- | --- |
| HTTP 429 or Telegram `Too Many Requests` | `rate_limit` |
| HTTP 401, `Unauthorized`, rejected bot token | `auth` |
| HTTP 403, bot kicked, missing permission, blocked by user | `permission` |
| Timeout, DNS, TLS, transient 5xx | `network` or `provider_unavailable` |
| 409 with `terminated by other getUpdates` | `polling_conflict` |
| Invalid source config or missing credential profile | `config` |
| Invalid content, missing target, reply not found, empty message text, unavailable stream content | `payload` |
| Unsupported edit kind, unsupported inbound update, or content with no fallback | `unsupported` |
| Missing or disabled Principal where required | `principal` |
| Unknown Bot API error | `unknown` |

`details` may include Telegram `error_code`, `description`, `retry_after`, and
redacted endpoint context. It must not include bot tokens, raw updates, raw
message bodies, plaintext activation/login codes, full Events, media bytes, or
stream chunks.

The adapter must not invent EventBus core errors such as
`%BullX.EventBus.InvalidEvent{}` or `%BullX.EventBus.AppendFailed{}`. It may
return those values only when `BullX.EventBus.accept/2` returned them.

## Telemetry and logs

Telegram uses the Channel Adapter telemetry prefix from `ChannelAdapter.md` and
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
- `[:bullx, :event_bus, :adapter, :telegram, :poller, :tick]`
- `[:bullx, :event_bus, :adapter, :telegram, :poller, :retry]`
- `[:bullx, :event_bus, :adapter, :telegram, :poller, :conflict]`
- `[:bullx, :event_bus, :adapter, :telegram, :attention, :decided]`
- `[:bullx, :event_bus, :adapter, :telegram, :direct_command, :handled]`
- `[:bullx, :event_bus, :adapter, :telegram, :commands, :sync]`

Allowed metadata includes adapter id, plugin id, source id, bot id, hashed
Event source, hashed Event id, update id, normalized Event type, chat id, chat
type, thread id, actor external id hash, attention reason, ignore reason,
EventBus acceptance status, Event Routing Rule id, TargetSession id, stream id,
offset, diagnostic code, retry delay, Telegram error code, and provider HTTP
status code.

Logs are part of the manual-run contract. Startup, bot identity resolution,
polling lifecycle, command-menu sync, inbound mapping, attention decisions,
direct-command handling, EventBus acceptance, outbound delivery, and stream
flush paths should emit safe structured log lines. Logs must not include bot
tokens, raw updates, raw message bodies beyond normalized content, plaintext
activation/login codes, full `reply_channel`, full Events, media bytes, or
stream chunks.

## I18n

All human-facing Telegram text uses `BullX.I18n` and the application-global
locale. The adapter does not choose locale from Telegram `language_code`,
`Accept-Language`, or browser settings.

Add at least these keys in supported locales:

```toml
[eventbus.telegram.auth]
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

[eventbus.telegram.ping]
pong = "PONG!"

[eventbus.telegram.delivery]
fallback_text = "..."
stream_generating = "..."
stream_failed = "..."
stream_cancelled = "..."
reply_target_missing_sent_to_scope = "..."
message_unchanged = "..."

[eventbus.telegram.media]
image = "..."
audio = "..."
video = "..."
file = "..."

[eventbus.telegram.errors]
unsupported_message = "..."
profile_unavailable = "..."
```

Tests must fail if a key used by the adapter is missing in any bundled locale.

## Security and privacy

Telegram long-poll transport relies on TLS to Telegram and the bot token. There
is no webhook secret in the first implementation.

The adapter must:

- drop self-sent bot messages before EventBus handoff;
- ignore messages without `from`;
- reject `/preauth <code>` and `/web_auth` in group chats without consuming or
  issuing secrets;
- discard activation codes and login auth codes from telemetry, logs, safe
  errors, Events, and stream metadata;
- keep bot tokens in `BullX.Config` secret storage;
- keep bot tokens, raw updates, raw Bot API bodies, and media bytes out of
  Events, `routing_facts`, `reply_channel`, Oban args, stream metadata,
  telemetry, logs, and safe errors;
- keep provider ids as external evidence and let `BullX.Principals` own durable
  identity decisions;
- refuse to start a second long poller against the same bot token on the same
  node.

Telegram outbound delivery may be customer-facing. The adapter assumes the
transport request already passed the necessary upstream authorization and
business-record boundaries. The adapter must not add a shortcut that lets direct
Bot API calls bypass the adapter delivery contract for business effects.

## Failure behavior

Bot API authentication failures, malformed updates, missing required fields,
missing credential profiles, unsupported content, and unsupported updates fail
closed. They produce redacted telemetry and safe logs.

For inbound updates, the adapter advances the `getUpdates` offset only when one
of these conditions is true:

- the update was intentionally ignored, such as self-sent, anonymous actor,
  ignored chat, outside allowlist, unmentioned group message, unsupported
  command, or unsupported update kind;
- an adapter-local direct command completed or a duplicate direct-command result
  was found;
- `BullX.EventBus.accept/2` returned accepted, duplicate, or accepted_ignored;
- the update is structurally malformed and retry would not produce a valid
  Event.

Transient EventBus append failures should not advance the offset when retrying
the same update may succeed. `:no_match` is terminal from EventBus perspective;
the adapter may advance the offset after emitting safe diagnostics.

Retryable provider errors include rate limiting, network failures, timeouts, and
temporary provider unavailability. Auth, permission, payload, unsupported, and
malformed-target errors are terminal unless Telegram supplies a specific retry
hint.

Process-local state is reconstructible. If the source runtime restarts, the
poller resumes from the highest acknowledged offset that is still available to
the process and relies on Telegram redelivery plus EventBus `(source, id)`
dedupe. A persistent `getUpdates` conflict is not reconstructible by retry; it
means another process holds the bot token and must be surfaced to operators.

## Implementation handoff

### Goal

Implement the Telegram plugin as one trusted plugin that exposes Telegram
EventBus transport while preserving the current Plugin, EventBus, Channel
Adapter, StreamingOutput, and Principal boundaries.

### Context pointers

- `AGENTS.md`
- `docs/Architecture.md`
- `docs/design-docs/Plugins.md`
- `docs/design-docs/Principal.md`
- `docs/design-docs/eventbus/ChannelAdapter.md`
- `docs/design-docs/eventbus/Core.md`
- `docs/design-docs/eventbus/Matcher.md`
- `docs/design-docs/eventbus/StreamingOutput.md`
- `docs/design-docs/eventbus/adapters/Feishu.md`
- `visciang/telegram` Bot API client

### Constraints

- Put plugin code under `plugins/bullx_telegram`.
- Use plugin id `"bullx_telegram"` and Channel Adapter id `"telegram"`.
- Use plugin config keys under `bullx.plugins.bullx_telegram.*`.
- Register only `:"bullx.event_bus.channel_adapter"`; do not register a
  Telegram Principal login provider.
- Use `BullX.EventBus.ChannelAdapter`, not a provider-specific routing
  contract.
- Use `BullX.EventBus.accept/2`, not a second publish path.
- Use `BullX.Principals`, not provider-owned account tables.
- Store bot tokens through `BullX.Config`; do not persist tokens in source
  config or Events.
- Use the Telegram Bot API client as a stateless client; do not use
  package-owned poller or webhook supervisors as BullX runtime owners.
- Do not add webhook ingress, `setWebhook`, webhook secret generation, native
  media upload, inline keyboard callbacks, Telegram Login Widget, or `/ask` in
  the first implementation.
- Do not change EventBus matcher, TargetSession side-channel behavior,
  TargetSession Oban job behavior, Target dispatch, or business persistence to
  fit Telegram.
- Do not add Principal ids to Events unless they came from `BullX.Principals`.

### Tasks

1. Add the Telegram plugin skeleton.
   - Owns: `plugins/bullx_telegram/mix.exs`, `BullxTelegram.Plugin`, plugin
     tests.
   - Depends on: plugin host implementation.
   - Acceptance: BullX discovers plugin id `"bullx_telegram"` and Channel
     Adapter extension id `"telegram"` when the plugin is compiled.
   - Verify: plugin discovery and registry tests.

2. Add Telegram plugin configuration.
   - Owns: `BullxTelegram.Config`, source/credential casters, redaction helpers,
     and secret-key tests.
   - Depends on: Task 1.
   - Acceptance: `bullx.plugins.bullx_telegram.credentials` is secret,
     `eventbus_sources` validates enabled sources, source ids are stable, and
     public projections never reveal bot tokens.
   - Verify: config and secret writer tests.

3. Implement Telegram source connectivity and adapter capabilities.
   - Owns: `BullxTelegram.Source`, `BullxTelegram.ChannelAdapter`,
     `BullxTelegram.Error`.
   - Depends on: Task 2.
   - Acceptance: capabilities are precise, connectivity checks call `getMe`
     without starting a poller, bot username matching is enforced, and responses
     contain only safe metadata.
   - Verify: source and adapter unit tests with a fake API module.

4. Implement source runtime and long polling.
   - Owns: `BullxTelegram.SourceSupervisor`, `BullxTelegram.SourceRuntime`,
     `BullxTelegram.Channel`, `BullxTelegram.Poller`, `BullxTelegram.Commands`.
   - Depends on: Task 3.
   - Acceptance: source startup resolves bot identity, clears webhook with
     `drop_pending_updates: false`, optionally syncs commands, polls only
     `message` and `edited_message`, retries transient failures, and surfaces
     polling conflicts distinctly.
   - Verify: poller and source-runtime tests with a fake API module.

5. Implement inbound mapping and attention policy.
   - Owns: `BullxTelegram.UpdateMapper`, `BullxTelegram.ContentMapper`,
     `BullxTelegram.AttentionPolicy`.
   - Depends on: Task 4.
   - Acceptance: accepted updates normalize to valid decoded CloudEvents; all
     numeric ids are strings; private, group, supergroup, and forum-topic scope
     mapping match this design; attention reasons and ignore reasons are tested.
   - Verify: update-mapping tests and `BullX.EventBus.accept/2` integration
     tests with a fake EventBus or route table.

6. Implement Principal account gate and direct commands.
   - Owns: `BullxTelegram.DirectCommand`, locale keys, Principal fixtures.
   - Depends on: Task 5.
   - Acceptance: normal user-origin Events call Principal matching before
     EventBus acceptance; `/ping` bypasses Principal; `/preauth <code>` consumes
     activation codes only in private chats; `/web_auth` issues login auth codes
     only for bound active Humans in private chats; duplicate `update_id`
     returns cached results.
   - Verify: focused direct-command and Principal integration tests.

7. Implement outbound send and edit.
   - Owns: `BullxTelegram.Outbound`, outbound content rendering, reply fallback,
     UTF-16 splitting, and error mapping.
   - Depends on: Task 3.
   - Acceptance: send/edit return adapter-compatible sent, degraded, or safe
     error results; reply-target fallback returns
     `"reply_target_missing_sent_to_scope"`; over-limit edit returns a payload
     error; `message is not modified` is treated as success.
   - Verify: outbound tests with fake API responses.

8. Implement stream consumption with multi-message accumulation.
   - Owns: `BullxTelegram.Streamer`.
   - Depends on: Task 7 and EventBus streaming APIs from `StreamingOutput.md`.
   - Acceptance: stream consumes buffered chunks first, follows live pointer
     notifications, UTF-16 splitting respects `stream_chunk_soft_limit`,
     throttling honors `stream_update_interval_ms`, final reconciliation edits
     current messages, creates missing tail messages, deletes overshoots, and
     never inspects Target internals or writes transcripts.
   - Verify: streamer tests with fake stream buffer and fake Bot API responses.

9. Add telemetry, logs, locale coverage, and privacy tests.
   - Owns: Telegram modules and locale files.
   - Depends on: Tasks 4 through 8.
   - Acceptance: safe telemetry/log metadata exists for startup, poller,
     attention, inbound mapping, direct commands, EventBus acceptance, delivery,
     and streaming; locale tests fail on missing keys; bot tokens, auth codes,
     raw updates, and raw message bodies never appear in logs or safe errors.

### Stop and ask

Implementation should stop and ask if a change would require:

- routing on data that cannot be normalized into `routing_facts` or another
  explicit `RoutingContext` field;
- raw Telegram update persistence rather than safe `raw_ref`;
- provider acknowledgement waiting for Target execution or business
  persistence;
- webhook ingress, native media upload, inline-keyboard callback handling,
  payment handling, Telegram Login Widget, or a Telegram Principal login
  provider;
- persistent Telegram tokens beyond the bot token, or a new credential store;
- authorization, approval, or business-record decisions inside the adapter;
- EventBus route topology, TargetSession behavior, or Target internals as a
  Telegram-specific contract;
- source supervision outside plugin children;
- plugin-specific persistence tables.

### Done when

- `plugins/bullx_telegram` compiles as a BullX plugin.
- The plugin registers `:"bullx.event_bus.channel_adapter"` id `"telegram"` and
  does not register a Principal login provider.
- Telegram source config and plugin credentials validate through
  `BullX.Config`.
- Connectivity checks verify the bot token through `getMe` without starting a
  poller or leaking secrets.
- Enabled Telegram sources start long-poll loops under plugin supervision.
- The attention policy filters group-chat noise according to this design.
- Telegram inbound updates normalize into valid decoded CloudEvents and call
  `BullX.EventBus.accept/2`.
- Built-in direct channel commands behave as specified and do not publish
  command Events.
- Telegram outbound send, edit, and stream paths produce adapter-compatible
  outcomes or safe errors.
- UTF-16 message splitting passes targeted tests on Asian-script and
  emoji-heavy text.
- A persistent `getUpdates` conflict produces a visible poller crash and is not
  silently retried forever.
- Self-sent and anonymous-actor messages are filtered before EventBus handoff.
- Bot tokens, raw updates, raw Bot API bodies, plaintext activation/login codes,
  media bytes, and stream chunks do not enter telemetry, logs, safe errors,
  Events, `routing_facts`, `reply_channel`, Oban args, or stream metadata.
- No provider-owned routing layer, provider-owned identity system, webhook
  ingress, Login Widget flow, `/ask` command, or compatibility shim is
  introduced.

Verification commands:

```bash
mix format --check-formatted
# focused tests for plugin discovery, config, source connectivity, polling,
# update normalization, attention policy, direct commands, delivery, stream
# transport, telemetry, logging, and locale coverage
MIX_ENV=test mix compile --warnings-as-errors
bun precommit
```
