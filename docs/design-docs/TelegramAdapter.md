# Telegram adapter

The Telegram integration is a trusted BullX plugin under `plugins/telegram`. It
contributes one extension declaration: a `:"bullx.gateway.adapter"` source for
Signals Gateway inbound and outbound transport. The plugin uses the
`visciang/telegram` Bot API client and does not port the old `BullXGateway`,
`BullXAccounts`, or Jido-era architecture. Telegram does not register a
Principal login provider; browser login for Telegram actors uses the existing
`/preauth` and `/web_auth` direct commands instead of an OIDC-style hook.

## Scope

This design covers the Telegram plugin adapter:

- plugin placement, metadata, extension declaration, and plugin-owned runtime
  configuration;
- Gateway source configuration, connectivity checks, long-poll source
  supervision, inbound normalization, attention filtering, account gating, and
  outbound send, edit, and stream delivery;
- built-in BullX direct commands implemented over Telegram messages for local
  connectivity and Principal activation: `/ping`, `/preauth <code>`, and
  `/web_auth`;
- Telegram-specific content mapping, actor normalization, UTF-16 message
  splitting, multi-message streaming, error mapping, telemetry, logging,
  security, tests, and implementation handoff.

This design depends on [Plugins.md](Plugins.md), [Principal.md](Principal.md),
and [SignalsGateway.md](SignalsGateway.md) for the host contracts. It
specializes those contracts for Telegram instead of redefining them. It also
mirrors [FeishuAdapter.md](FeishuAdapter.md) wherever the two plugins share
architecture, so the two plugins can be reviewed side by side.

## Goals

- Keep Telegram out of BullX core modules by shipping it as one plugin under
  `plugins/telegram`.
- Expose Telegram transport through the Gateway adapter extension point with
  inbound and outbound support.
- Reuse `visciang/telegram` for Bot API calls and update decoding, with BullX
  owning supervision and transport lifecycle.
- Keep Gateway actor data channel-local until `BullX.Principals` resolves,
  creates, or activates a Human Principal.
- Preserve Gateway transport boundaries: Telegram may produce normalized Signals
  and execute authorized Deliveries, but it does not create Admission, Work,
  Intents, Effects, Outcomes, or Brain facts.
- Keep bot tokens, raw provider payloads, private adapter config, and
  Principal activation/login codes out of telemetry, logs, error details,
  receipts, and dead-letter summaries. Normalized Gateway content may enter
  Signals, Deliveries, Mailbox jobs, and replayable dead letters according to
  the Gateway contract; those storage surfaces are operator-sensitive.
- Filter group-chat noise at the adapter edge through an explicit attention
  policy so unrelated group messages never reach the Signals carrier.

## Non-goals

- Do not add Telegram modules under `lib/bullx/` or `lib/bullx_web/` except for
  generic host surfaces needed by plugin hooks.
- Do not recreate old `BullXGateway`, `BullXAccounts`, RFC 0002/0003, RFC 0016,
  or Jido abstractions.
- Do not add runtime plugin installation, hot plugin enablement, hook priority,
  or plugin-specific persistence tables.
- Do not register a Telegram Principal login provider. There is no OIDC
  equivalent in the Bot API; browser login for Telegram actors uses
  `/preauth` and `/web_auth` exclusively.
- Do not add a Telegram Login Widget controller, embed page, `auth_date`/hash
  verification flow, or domain allowlist.
- Do not implement webhook ingress in the first version. Inbound transport is
  long-poll only. A future version may add webhook support behind a
  `transport.mode` switch.
- Do not implement native media upload (`sendPhoto`, `sendDocument`,
  `sendAudio`, `sendVideo`) in the first version. Non-text outbound content
  degrades to `fallback_text`.
- Do not implement inline-keyboard callback handling, custom reply keyboards,
  poll/quiz handling, business connection, or payments.
- Do not publish channel posts, edited channel posts, chat member updates,
  shipping/pre-checkout, or callback-query events as Signals by default.
- Do not maintain a Telegram-owned ETS cache or call Cachetastic directly when
  `BullX.Cache` already owns adapter cache state.
- Do not collect operator-edited webhook URLs, webhook secrets, or transport
  tokens. Bot tokens are the only operator-supplied credential.

## Cleanup plan

- **Dead code to delete:** none. The current branch has no live Telegram
  adapter. Do not copy deleted legacy namespaces or compatibility shims into
  the new branch.
- **Duplicate logic to merge:** do not introduce Telegram-specific HTTP, retry,
  cache, or identity infrastructure when `BullX.Cache`, `BullX.Gateway`,
  `BullX.Principals`, `BullX.Retry`, and the Bot API client already own those
  concerns.
- **Existing utilities and patterns to reuse:** use `BullX.Plugins.Plugin`,
  `BullX.Gateway.Adapter`, `BullX.Gateway.SourceConfig`,
  `BullX.Gateway.publish/2`, `BullX.Gateway.normalize_inbound/4`,
  `BullX.Principals`, `BullX.Config`, `BullX.Cache`, `BullX.I18n`,
  `BullX.Ext`, and `BullX.Retry`.
- **Code paths and contracts changing:** add `plugins/telegram`, Telegram
  plugin configuration declarations, Telegram Gateway adapter modules,
  Telegram locale keys, and focused tests.
- **Invariants that must remain true:** plugin state is reconstructible;
  PostgreSQL remains durable truth; Gateway actors remain channel-local;
  Principal matching owns Human identity decisions; plaintext activation and
  login codes are never stored; bot tokens and raw provider payloads never
  enter Gateway payloads; outbound Delivery is assumed already authorized
  before the Gateway invokes Telegram.
- **Verification command:** run focused Telegram, Gateway adapter, and
  Principal direct-command tests, then run `bun precommit`.

## Existing context

[Plugins.md](Plugins.md) defines plugins as compile-time trusted Mix projects
discovered from `plugins/*`. The plugin host registers declarations from all
discovered plugins and starts children only for enabled plugins.

[SignalsGateway.md](SignalsGateway.md) defines Gateway adapters as plugin
extensions under `:"bullx.gateway.adapter"`. Gateway configured sources live in
`bullx.gateway.sources`. A configured source is identified by
`{adapter, channel_id}` after case folding. For Telegram, `channel_id` is the
source slug and must be globally unique inside the BullX Installation.

[Principal.md](Principal.md) defines Human login and channel identity through
`BullX.Principals`. Telegram channel actors use
`principal_external_identities(kind = channel_actor)`. Telegram does not
contribute `login_subject` identities in the first version, because the
adapter does not implement an OIDC-equivalent login provider.

The old main-branch Telegram RFC 0016 and `lib/bullx_telegram/` modules remain
useful only for Telegram mechanics: long-poll lifecycle, update mapping,
attention policy, direct-command flow, UTF-16 message splitting, forum-topic
mapping, streaming state machine, error mapping, and safe logging. Their old
namespace (`BullXTelegram`), `BullXAccounts` calls, `BullXGateway` calls,
top-level OTP application, `BullxTelegram.Poller`/`Telegram.Webhook` package
supervisors, `transport.mode = "webhook"` branch, and `/ask` adapter-local
command are not implementation sources for this branch.

## Plugin shape

The plugin app id is `:bullx_telegram`, the plugin id is `"bullx_telegram"`,
and the directory is `plugins/bullx_telegram`. The plugin entry module is
`BullxTelegram.Plugin`. Operators enable the plugin with
`bullx.enabled_plugins = ["bullx_telegram"]`.

The Gateway adapter **extension id** is `"telegram"` (the value referenced in
`bullx.gateway.sources` as `"adapter": "telegram"`). Plugin id and extension
id differ here because the host derives plugin id from the app atom, and the
app atom must be `:bullx_telegram` to avoid the namespace collision described
below.

The plugin namespace is `BullxTelegram.*`, not `Telegram.*`, because the
`visciang/telegram` hex package already occupies `Telegram.Api`,
`Telegram.Bot`, `Telegram.Poller`, and `Telegram.Webhook` at the root level.
The old main-branch tree (`lib/bullx_telegram/`) used the same `BullXTelegram`
namespace for the same reason.

```elixir
defmodule BullxTelegram.Plugin do
  use BullX.Plugins.Plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.gateway.adapter",
        id: "telegram",
        module: BullxTelegram.GatewayAdapter
      }
    ]
  end

  @impl BullX.Plugins.Plugin
  def config_modules, do: [BullxTelegram.Config]
end
```

The plugin should not start a plugin-wide supervisor child in the first
implementation. Gateway source listeners start through
`BullxTelegram.GatewayAdapter.source_child_spec/1` under
`BullX.Gateway.SourceSupervisor`. This keeps the transport failure boundary in
Gateway source supervision instead of making the plugin host a transport
supervisor.

Suggested module ownership:

| Module | Responsibility |
| --- | --- |
| `BullxTelegram.Plugin` | Plugin metadata, config modules, and extension declarations. |
| `BullxTelegram.Config` | Plugin-owned `BullX.Config` declarations and config casters. |
| `BullxTelegram.GatewayAdapter` | `BullX.Gateway.Adapter` implementation. |
| `BullxTelegram.Source` | Runtime Telegram source config normalization and redaction. |
| `BullxTelegram.Channel` | Per-source runtime supervisor; owns cache state and dispatcher wiring. |
| `BullxTelegram.Poller` | Long-poll worker holding `getUpdates` offset and retry state. |
| `BullxTelegram.UpdateMapper` | Telegram update payload normalization to Gateway inputs. |
| `BullxTelegram.ContentMapper` | Telegram message content to Gateway content blocks; UTF-16 splitting; outbound text rendering. |
| `BullxTelegram.AttentionPolicy` | Group-chat attention filter (DM, command, mention, reply-to-bot, allowlists). |
| `BullxTelegram.DirectCommand` | Built-in `/ping`, `/preauth`, and `/web_auth` direct-command handler. |
| `BullxTelegram.Commands` | `setMyCommands` sync helper. |
| `BullxTelegram.Delivery` | `:send` and `:edit` execution; reply-target fallback. |
| `BullxTelegram.Streamer` | Multi-message accumulating streamer with throttled edits and final reconciliation. |
| `BullxTelegram.Error` | SDK and Bot API error normalization. |

Adapter modules call `Telegram.Api.request/2` (from `visciang/telegram`)
directly and route failures through `BullxTelegram.Error`. The plugin must not start
`BullxTelegram.Poller`/`Telegram.Webhook` supervisors provided by the package; the
package is treated as a stateless Bot API client.

## Runtime configuration

Operators enable the plugin through `bullx.enabled_plugins`:

```json
["bullx_telegram"]
```

The plugin id is `bullx_telegram` (matching the app atom); the Gateway
adapter id remains `telegram` for the source `adapter` field.

Bot credentials live in plugin configuration so the plugin can declare the
secret shape before any Gateway source is enabled. The first implementation
uses one encrypted credential-profile map:

| Accessor | DB key | Secret | Default |
| --- | --- | --- | --- |
| `credentials!/0` | `bullx.plugins.telegram.credentials` | yes | `{}` |

`credentials` is a JSON object keyed by credential id. Each value contains the
bot token and optional metadata operators want to share across sources:

```json
{
  "default": {
    "bot_token": "123456:ABCDEF",
    "bot_username": "bullx_bot"
  }
}
```

The whole credentials map is encrypted by `BullX.Config`. It must not appear in
Gateway source config, Signals, Oban args, telemetry, logs, receipts, or dead
letters.

`bot_username` is optional; if absent or stale, the adapter resolves it from
`getMe` at startup. The persisted `bot_username` is only used to validate
`@bot_username` mentions and `/command@bot_username` parsing; it must match
`getMe.username` (case-insensitive) at connectivity check time.

Each Telegram source has its own effective bot credential through
`config.credential_id`. Operators may choose one credential profile per source
or deliberately reuse a credential profile across sources. The source slug
remains the identity namespace even when two sources share a credential
profile.

> **Polling caveat:** Telegram enforces a global lock on `getUpdates` per bot
> token. Two sources sharing the same `credential_id` therefore cannot both run
> long-polling at the same time. The adapter detects this at startup by
> tracking active credentials per node and refuses to start a second poller
> with a `config` error. Operators who need multiple BullX sources for the
> same bot must wait for webhook support in a later version.

Gateway source entries live in `bullx.gateway.sources`. A Telegram source uses
the standard source shape:

```json
{
  "adapter": "telegram",
  "channel_id": "main",
  "enabled": true,
  "config": {
    "credential_id": "default",
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
    "details": {"adapter": "telegram", "transport": "polling"}
  }
}
```

`channel_id` is a BullX configured source slug. It is globally unique inside
the Installation and stable across config edits. It is not a Telegram chat id,
user id, or bot username. Telegram chat ids become `scope_id` in Gateway
inputs and Deliveries.

`BullxTelegram.GatewayAdapter.connectivity_check/1` validates one normalized
`BullX.Gateway.SourceConfig` without starting a poller, registering a listener,
publishing a Signal, or writing source config. It loads the referenced
credential profile, constructs a `Telegram.Api` client (from the
`visciang/telegram` package), calls `getMe`, and returns only redacted
operator metadata. If `config.bot_username` is set, it
must match the resolved username (case-insensitive); otherwise the resolved
username is returned in `details` for operator confirmation.

Success shape:

```elixir
{:ok,
 %{
   status: :ok,
   adapter: "telegram",
   channel_id: "main",
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

Connectivity responses must never include `bot_token`, raw `getMe` bodies, or
internal retry state.

## Gateway adapter contract

`BullxTelegram.GatewayAdapter` implements `BullX.Gateway.Adapter`.

| Callback | Telegram behavior |
| --- | --- |
| `config_schema/0` | Describes source config fields, defaults, and redaction rules. |
| `normalize_config/1` | Casts persisted source JSON into adapter runtime config. |
| `public_config/1` | Returns an operator-facing redacted source projection. |
| `capabilities/0` | Declares long-poll inbound, send, edit, stream, threads, and supported content kinds. |
| `connectivity_check/1` | Validates credential and bot identity without starting a poller. |
| `source_child_spec/1` | Starts one source listener for an enabled source, or returns `:ignore` for disabled sources. |
| `normalize_inbound/3` | Converts exactly one Telegram `Update` into one normalized Gateway input. |
| `deliver/2` | Executes `:send` and `:edit` Deliveries. |
| `stream/3` | Executes `:stream` Deliveries with multi-message accumulation and edits. |

Capabilities should be:

```elixir
%{
  inbound_modes: [:polling],
  outbound_ops: [:send, :edit, :stream],
  content_kinds: [:text, :image, :audio, :video, :file, :card],
  stream_strategy: :edit_accumulate,
  features: [:threads]
}
```

`content_kinds` includes the full Gateway set so non-text Deliveries are not
rejected at the Gateway core boundary; the adapter renders them as text with
`body.fallback_text` (matching the old `lib/bullx_telegram/content_mapper.ex`
`render_outbound/1` behavior). Native media upload is out of scope for the
first version, so degraded outcomes carry a `<kind>_degraded_to_fallback_text`
warning. `features: [:threads]` declares Telegram forum-topic support so
Gateway core may target `thread_id`.

The Gateway core rejects unsupported operations and malformed carrier shapes
before invoking Telegram. Telegram still validates provider-specific payloads,
target ids, message size limits, and Bot API responses.

## Inbound source runtime

For each enabled Telegram source, `source_child_spec/1` starts a source-local
runtime boundary. The new `BullX.Gateway.Adapter.source_child_spec/1` contract
returns a single child spec, so the per-source `BullxTelegram.Channel` and
`BullxTelegram.Poller` siblings from `lib/bullx_telegram/adapter.ex`
(`child_specs/2 -> [Channel, Poller]`) are wrapped in a per-source supervisor:

```text
BullX.Gateway.SourceSupervisor
└── BullxTelegram.Supervisor (one per source)
    ├── BullxTelegram.Channel
    └── BullxTelegram.Poller
```

`BullxTelegram.Supervisor` is a `:one_for_all` supervisor. If either child crashes,
both restart so cache state stays consistent with the polling offset.

`BullxTelegram.Channel` owns the normalized source config, source-local dispatch,
bot identity resolution, command-menu sync, source-local startup logs, and
source-local dedupe/cache key prefixes. `BullxTelegram.Poller` owns the
`getUpdates` offset, polling retry counter, and the long-poll loop. The poller
calls `BullxTelegram.Channel.handle_update/2` (registered under
`{:via, Registry, ...}` by source) for each accepted update; the channel runs
mapping, attention filtering, direct-command interception, Principal gating,
and Gateway publish.

`BullxTelegram.Channel` uses `BullX.Cache` for TTL state:

- message context for reply/recall/reaction correlation when later versions
  need it (first version keeps the cache minimal);
- direct-command result dedupe keyed by `update_id`.

Cache entries are reconstructible. If a source restarts and loses dedupe
state, the next idempotent direct command may resend the same reply once;
`/preauth` activation codes are single-use, so a duplicate retry returns
"already linked" or "invalid code" rather than re-binding. Long-poll offset
state is held in `BullxTelegram.Poller` and restarts at `last_update_id + 1` after
each accepted batch; on poller restart, the offset resets to the highest
acknowledged update and Telegram replays only updates the bot has not yet
confirmed.

At startup `BullxTelegram.Channel`:

1. Resolves `bot_id` and `bot_username` from `getMe`.
2. Calls `deleteWebhook(drop_pending_updates: false)` to release any previously
   registered webhook before long-polling. This is required even when the
   adapter never sets a webhook, because Telegram returns 409 Conflict on
   `getUpdates` if a webhook is still registered.
3. Optionally syncs the command menu via `setMyCommands` based on
   `config.commands.sync_policy`.
4. Hands control to `BullxTelegram.Poller`.

`BullxTelegram.Poller` calls `getUpdates` with `timeout = poll_timeout_s`,
`limit = poll_limit`, and `allowed_updates = ["message", "edited_message"]`.
The allow-list pins the inbound surface to the events this design normalizes.
On transient failure (network, 5xx, rate limit) it backs off with `BullX.Retry`
up to `poll_retry_max` times before crashing the source so the supervisor and
operator alerts can observe the failure.

Polling conflict (HTTP 409 / Telegram description containing `terminated by
other getUpdates`) is terminal, not transient: the poller crashes with a
distinct `:telegram_polling_conflict` reason. The supervisor must not silently
restart it. A persistent conflict means another instance is holding the bot
token; the right response is to alert the operator.

Webhook ingress is not supported in the first version. There is no Phoenix
controller, no `setWebhook` call, no secret-token generation, and no
`X-Telegram-Bot-Api-Secret-Token` validation. Any later webhook support will
add `transport.mode = "webhook"` to source config and a Web boundary mount
that identifies `{adapter = "telegram", channel_id}` before invoking
`normalize_inbound/3`.

## Inbound normalization

Telegram normalized inputs must satisfy `BullX.Gateway.InboundInput`. A
Telegram message input has this shape:

```elixir
%{
  "adapter" => "telegram",
  "channel_id" => "main",
  "occurrence_key" => "telegram:main:update:18293",
  "time" => "2026-05-13T00:00:00Z",
  "content" => [
    %{"kind" => "text", "body" => %{"text" => "hello"}}
  ],
  "event" => %{
    "type" => "message",
    "name" => "telegram.message",
    "version" => 1,
    "data" => %{
      "update_id" => "18293",
      "message_id" => "421",
      "chat_id" => "-100123456",
      "chat_type" => "supergroup",
      "thread_id" => "12",
      "attention_reason" => "mention",
      "update_type" => "message",
      "date" => 1_715_558_400
    }
  },
  "actor" => %{
    "id" => "telegram:987654321",
    "display" => "Alice",
    "bot" => false,
    "profile" => %{
      "username" => "alice",
      "first_name" => "Alice",
      "language_code" => "en",
      "user_id" => "987654321"
    },
    "metadata" => %{"chat_type" => "supergroup"}
  },
  "scope_id" => "-100123456",
  "thread_id" => "12",
  "refs" => [
    %{"kind" => "telegram.update", "id" => "18293"},
    %{"kind" => "telegram.message", "id" => "421"},
    %{"kind" => "telegram.chat", "id" => "-100123456"},
    %{"kind" => "telegram.thread", "id" => "12"},
    %{"kind" => "telegram.user", "id" => "987654321"}
  ],
  "reply_channel" => %{
    "adapter" => "telegram",
    "channel_id" => "main",
    "scope_id" => "-100123456",
    "thread_id" => "12",
    "reply_to_external_id" => "421"
  },
  "provenance" => %{
    "update_id" => "18293",
    "update_type" => "message"
  }
}
```

`occurrence_key` always uses Telegram's `update_id` because every update has
one. Message-only fields (`message_id`, `chat_id`) live in `event.data` and
`refs`; they are not part of the occurrence key.

Telegram numeric ids are JSON-encoded as strings inside Gateway inputs to keep
the carrier JSON-neutral and avoid 64-bit integer issues. The adapter converts
back to integers when calling the Bot API.

### Actor identity

Telegram actor ids are channel-local external ids. User-origin events use
`external_id = "telegram:#{user_id}"`. `user_id` is required for Principal
binding. Telegram always supplies `user.id` for non-anonymous messages; if a
message has no `from` field (anonymous admin posts, channel posts), the
adapter ignores it.

Trusted profile fields may include `display_name`, `username`, `first_name`,
`last_name`, `language_code`, and `user_id`. The adapter computes
`display_name` from `first_name + " " + last_name` (trimmed), falling back to
`username` and then `"telegram:#{user_id}"`. Telegram does not expose email or
phone to bots, so the Principal channel input has no `email` or `phone`
fields. User-editable display names are presentation data, not identity proof.

Self-sent bot messages are filtered before content parsing, Principal matching,
direct-command handling, or publishing. Telegram messages whose
`from.is_bot == true` and whose `from.id` matches the resolved bot id are
ignored. Messages from other bots are also ignored unless they are explicit
replies to the BullX bot and an attention reason permits them.

### Event mapping

Telegram maps allowed updates onto the seven Gateway event types:

| Telegram update | Gateway `event.type` | Notes |
| --- | --- | --- |
| `message` (text) | `message` or `slash_command` | Slash-command parsing happens after text normalization; built-in direct commands implemented by this adapter are intercepted before publish. |
| `message` (media or location) | `message` | Content blocks describe the media; primary text uses caption or generated fallback. |
| `edited_message` | `message_edited` | `event.data.target_external_id` is the Telegram message id; `refs` includes the original message. |

Reaction, recall, channel-post, callback-query, member, and business
connection updates are not in the `allowed_updates` list and are not part of
the first version. A later version may extend the list.

Provider-specific names stay in `event.name`, for example `telegram.message`
or `telegram.edited_message`. Gateway core must not maintain a Telegram event-
name allowlist.

### Scope, threads, and chat types

| Telegram chat type | Scope and thread mapping |
| --- | --- |
| `private` | `scope_id = chat_id` (equals `user_id`), `thread_id = nil`. |
| `group`, `supergroup` | `scope_id = chat_id`, `thread_id = message_thread_id` when present in a forum-enabled supergroup. |
| `supergroup` forum "General" topic | `thread_id = nil`. Telegram does not assign `message_thread_id` to General; the adapter must not synthesize one. |
| `channel` | Inbound channel posts are ignored. Outbound `:send` may target a channel chat id if Governance has authorized it. |

`thread_id` is stringified to keep the carrier JSON-neutral. Outbound code
parses it back to an integer for `message_thread_id`.

### Attention policy

Group-chat messages are filtered before publish. The policy returns one of
`"dm"`, `"command"`, `"mention"`, `"reply_to_bot"`, `"free_response"`, or an
ignore reason. Filter order:

1. `from.is_bot == true` and `from.id == bot_id` → ignore as `bot_author`.
2. `chat.id` in `attention.ignored_chat_ids` → ignore as `ignored_chat`.
3. `message_thread_id` in `attention.ignored_thread_ids` → ignore as
   `ignored_thread`.
4. `attention.allowed_chat_ids` non-empty and `chat.id` not in it → ignore as
   `outside_allowlist`.
5. `chat.type == "private"` → `"dm"`.
6. Text begins with `/` and parses as a known command (`/ping`, `/preauth`,
   `/web_auth`, or any other `/...`) targeted at this bot
   (`/cmd` or `/cmd@bullx_bot`) → `"command"`. Commands explicitly addressed to
   a different bot via `/cmd@other_bot` are ignored as `unsupported_command`.
7. Text mentions `@bullx_bot` (case-insensitive) → `"mention"`.
8. Message replies to a bot-authored message owned by this bot → `"reply_to_bot"`.
9. `chat.id` in `attention.free_response_chat_ids`, or
   `attention.require_mention == false` → `"free_response"`.
10. Otherwise → ignore as `unmentioned_group_message`.

The attention reason lives in `event.data.attention_reason`. It is operator-
visible diagnostic data, not an authorization signal.

### Content mapping

Inbound content mapping follows the old
`lib/bullx_telegram/content_mapper.ex` `inbound_blocks/1` precedence and
shapes:

1. **Text** (`message.text` non-empty) → one `:text` block:

   ```elixir
   %{"kind" => "text", "body" => %{"text" => "hello"}}
   ```

   Mentions of the BullX bot are preserved in the text and recorded in `refs`;
   they are not stripped at the adapter edge.

2. **Media with `file_id`** (photo, sticker, audio, voice, video, document) →
   an optional caption text block followed by a native media block:

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

   | Telegram field | Block `kind` | `file_id` |
   | --- | --- | --- |
   | `message.photo` (largest size) | `:image` | last entry's `file_id` |
   | `message.sticker` | `:image` | `sticker.file_id` |
   | `message.audio` | `:audio` | `audio.file_id` |
   | `message.voice` | `:audio` | `voice.file_id` |
   | `message.video` | `:video` | `video.file_id` |
   | `message.document` | `:file` | `document.file_id` |

   `fallback_text` is the localized `gateway.telegram.media.<kind>` value.
   Telegram message ids and file ids also stay in `refs` so Runtime consumers
   can resolve the media URI externally.

3. **Location or venue** → one `:text` block with the venue title, address,
   `Location: <lat>, <lon>` line, and a Google Maps URL:

   ```text
   [venue title]
   [venue address]
   Location: <lat>, <lon>
   https://maps.google.com/?q=<lat>,<lon>
   ```

4. **Caption-only media** (caption present, but `media_file_id` resolves to
   `nil`; only possible for unsupported media kinds) → one `:text` block with
   the caption.

5. **Otherwise** (sticker variants without `file_id`, dice, contact, poll,
   unsupported message kinds) → one `:text` block with a deterministic
   fallback through `gateway.telegram.errors.unsupported_message`.

The adapter must not publish empty content for a user-origin event.

`telegram://file/<file_id>` URIs are channel-local opaque references. The
adapter does not download bytes at normalization time; downloads happen
on-demand through `Telegram.Api.File.get/2` or similar, only when a consumer
asks for them. File-id TTL (Telegram rotates `file_id` over time) is not
guaranteed by the adapter.

## Principal account gate

Before publishing normal user-origin duplex events, Telegram calls
`BullX.Principals.match_or_create_human_from_channel/1` with the normalized
channel actor:

```elixir
%{
  "adapter" => "telegram",
  "channel_id" => "main",
  "external_id" => "telegram:987654321",
  "profile" => %{
    "display_name" => "Alice",
    "username" => "alice",
    "first_name" => "Alice",
    "language_code" => "en",
    "user_id" => "987654321"
  },
  "metadata" => %{
    "source" => "telegram_im",
    "chat_id" => "-100123456",
    "chat_type" => "supergroup",
    "thread_id" => "12"
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
login auth codes, or links that reveal account state. The reply should ask the
user to message the bot privately. In `private` chats, the adapter may include
localized `/preauth <code>` and `/web_auth` guidance.

## Direct commands

Direct commands are built-in BullX channel commands implemented by messaging
adapters. In this design, the Telegram adapter handles `/ping`, `/preauth`,
and `/web_auth` before publishing slash-command Signals. The command contract
is not Telegram-specific; another messaging adapter can implement the same
names with its own transport, actor normalization, and delivery mechanics.

For Telegram, direct commands run after `BullxTelegram.Poller` accepts an update,
`BullxTelegram.Channel` resolves the chat and actor, attention policy classifies
the message as `"command"`, and direct-command dedupe lookup misses. Only
`/ping`, `/preauth`, and `/web_auth` are intercepted by the Telegram adapter.
Other normalized text messages that start with `/` and pass attention policy
publish as Gateway `slash_command` inputs after Principal account gating.
There is no Telegram-local `/ask` command in this design.

Command parsing accepts `/cmd`, `/cmd args`, `/cmd@bot_username`, and
`/cmd@bot_username args`. The bot-username suffix is required in group chats
when more than one bot may respond; the adapter rejects `/cmd@other_bot`
addressed to a different bot.

### `/ping`

`/ping` is a manual connectivity command. It works in private chats and
groups (when correctly addressed), does not require Principal activation, and
does not call `BullX.Principals.match_or_create_human_from_channel/1`.

The adapter builds a Gateway external Delivery with `op = :send`, the current
`{adapter, channel_id}`, the Telegram chat id as `scope_id`, the current
`message_thread_id` as `thread_id`, and the current message id as
`reply_to_external_id`. It calls `BullX.Gateway.deliver/1`; the direct-command
path depends on the Gateway outbound API instead of calling Bot API methods
directly. The localized reply body is `PONG!` in bundled locales.

The adapter acknowledges the Telegram update only after Gateway accepts the
Delivery or after a duplicate direct-command result is found.

### `/preauth <code>`

`/preauth <code>` consumes a BullX activation code and creates a new Human
Principal with the current Telegram actor as the first channel binding.

Flow:

1. Reject group chats with a localized DM-only instruction and do not consume
   the code.
2. Normalize the Telegram actor and trusted profile.
3. Call `BullX.Principals.consume_activation_code(code, channel_input)`.
4. Submit one localized Telegram reply as a Gateway external Delivery through
   `BullX.Gateway.deliver/1`.
5. Do not publish the command as a Gateway Signal.

Result mapping:

| Principal result | Telegram reply key |
| --- | --- |
| `{:ok, _principal, _identity}` | `gateway.telegram.auth.activation_success` |
| `{:error, :invalid_or_expired_code}` | `gateway.telegram.auth.activation_code_invalid` |
| `{:error, :already_bound}` | `gateway.telegram.auth.already_linked` |
| `{:error, :principal_disabled}` | `gateway.telegram.auth.denied` |
| any other `{:error, _}` | `gateway.telegram.auth.activation_failed` |

The direct-command result cache stores the reply result by Telegram
`update_id` for the configured short TTL so transport retries do not send
duplicate activation replies. A duplicate `update_id` returns the cached
result without re-running `consume_activation_code/2`.

### `/web_auth`

`/web_auth` issues a built-in channel-auth login code for an already bound
active Human Principal. It uses the Principal login-auth-code table.

Flow:

1. Reject group chats with a localized DM-only instruction and do not issue a
   code.
2. If `config.web_login_disabled == true`, reply with a localized
   `web_auth_disabled` message and do not issue a code.
3. Normalize the Telegram actor and trusted profile.
4. Call `BullX.Principals.issue_login_auth_code("telegram", channel_id, "telegram:#{user_id}")`.
5. Render a localized reply containing the short-lived code and the generic
   Web login URL.
6. Submit the reply as a Gateway external Delivery through
   `BullX.Gateway.deliver/1`.
7. Do not publish the command as a Gateway Signal.

Result mapping:

| Principal result | Telegram reply key |
| --- | --- |
| `{:ok, code}` | `gateway.telegram.auth.web_auth_created` |
| `{:error, :not_bound}` | `gateway.telegram.auth.web_auth_not_bound` |
| `{:error, :principal_disabled}` | `gateway.telegram.auth.denied` |
| `{:error, :not_human}` | `gateway.telegram.auth.web_auth_not_bound` |
| any other `{:error, _}` | `gateway.telegram.auth.web_auth_failed` |

The login auth code never enters telemetry, logs, error details, receipts, or
dead letters. Only its issuance outcome is recorded.

## Outbound delivery

Telegram outbound delivery executes already-authorized Gateway external
Deliveries. The plugin does not decide whether an Agent may speak in a chat,
edit a message, or stream. Governance and upstream Runtime decide that before
submitting a Delivery to Gateway.

`BullxTelegram.GatewayAdapter.deliver/2` handles `:send` and `:edit`.
`BullxTelegram.GatewayAdapter.stream/3` handles `:stream`.

Telegram numeric ids appear in Delivery fields as strings (matching the
carrier shape). The adapter parses them back to integers before calling the
Bot API.

### Message size limits

Telegram measures message text in UTF-16 code units. The hard limit is 4096
units per message; the soft limit for streaming is `stream_chunk_soft_limit`
(default 3900) to leave room for in-flight edits.

`BullxTelegram.ContentMapper.utf16_units/1` counts code units by treating codepoints
above `0xFFFF` as two units. Splitting walks the codepoint list, never the
grapheme list, because counting graphemes would double-count surrogate pairs
and break long Asian-script or emoji-heavy messages.

### Send

Targeting rules:

- `delivery.scope_id` is the Telegram chat id (integer string).
- `delivery.thread_id`, when present, is passed as `message_thread_id`.
- `delivery.reply_to_external_id`, when present, is passed via reply
  parameters.

Content rules:

- `text` sends `sendMessage` with the rendered text. Text exceeding 4096
  UTF-16 units splits into multiple `sendMessage` calls. The adapter returns
  all created message ids in `external_message_ids`; `primary_external_id` is
  the first message id.
- `image`, `audio`, `video`, `file`, and `card` degrade to one `sendMessage`
  call with `body.fallback_text`. The outcome includes a warning of the form
  `"<kind>_degraded_to_fallback_text"` so Runtime can observe the degrade.

If Telegram reports that a reply target was recalled or missing
(`description` containing `replied message not found`,
`message to reply not found`, or `MESSAGE_ID_INVALID`), the adapter retries
once as a normal chat send to `delivery.scope_id` without reply parameters. A
successful fallback returns a degraded outcome with a warning
`"reply_target_missing_sent_to_scope"`. If `scope_id` is missing, the adapter
returns a payload error.

Link previews are left in their default state unless a future design adds an
explicit content flag.

### Edit

`delivery.target_external_id` is required for edit. Telegram supports editing
text via `editMessageText` in the first version. Editing media captions, file
content, or reply markup is not in scope. The adapter passes through chat id
and message id parsed from string ids.

Edited text exceeding 4096 UTF-16 units returns a payload error rather than
silently truncating, unless the edit is part of an active streaming context
where the streamer is responsible for splitting (see Stream below).

Telegram's `message is not modified` response is treated as success with a
warning `"message_unchanged"`, not an error.

Missing or uneditable target messages map to payload, unsupported, or
not-found errors, not network errors.

### Stream

Telegram streaming uses multi-message accumulation with throttled edits and
final reconciliation. The state machine matches RFC 0016 / `bullx_telegram/
streamer.ex` in mechanics, with current naming.

State:

```elixir
%{
  delivery: %BullX.Gateway.Delivery{...},
  source: %BullxTelegram.Source{...},
  current_text: "",
  message_ids: [],     # ordered list of created Telegram message ids
  last_update_at: nil, # monotonic ms timestamp of last edit/send
  warnings: []
}
```

Chunk shapes accepted from the Gateway stream:

- `binary()` appends text.
- `%{text: binary()}` or `%{"text" => binary()}` appends text.
- `%{replace_text: binary()}` or `%{"replace_text" => binary()}` replaces the
  accumulated text and forces a flush.

For each accepted chunk:

1. Update `current_text` accordingly.
2. Split `current_text` into chunks at `stream_chunk_soft_limit` UTF-16 units
   per chunk.
3. If `length(chunks) > length(message_ids)`, edit the last existing message
   to its corresponding chunk and then `sendMessage` the missing tail chunks
   without reply parameters (reply parameters are only used for the first
   message in the stream).
4. Otherwise, if `now - last_update_at >= stream_update_interval_ms` or the
   chunk forced a flush, edit the last existing message with its
   corresponding chunk.

On stream end:

1. `current_text` empty → return a payload error
   (`"stream content is absent"`).
2. Re-split and reconcile: edit every existing message to its current chunk,
   create any missing tail chunks, and `deleteMessage` any extra messages
   beyond the final chunk count.
3. Return a `sent` outcome with `external_message_ids` set to the final
   message list and `primary_external_id` set to the first message id.

If `stream/3` receives absent or non-enumerable stream content (including a
dead-letter replay that cannot reconstruct the live stream), it returns:

```elixir
{:error, %{"kind" => "payload", "message" => "stream content is not replayable"}}
```

On stream exception or cancellation, the adapter attempts one final edit of
the last existing message with localized failure text
(`gateway.telegram.delivery.stream_failed` or `stream_cancelled`), then
returns the original normalized error to Gateway.

Telegram flood-control responses (`retry_after` < `flood_wait_max_ms`) are
honored inline by the streamer with `BullX.Retry`. Longer flood waits return a
retryable transport error so Gateway core can apply its outbound retry budget.

The streamer does not strip reply parameters from the first message; reply
parameters apply only to message 0. Subsequent split messages use bare
`sendMessage(chat_id, message_thread_id)` calls.

## Error mapping

`BullxTelegram.Error` maps SDK and Bot API failures into Gateway adapter error maps.
All returned errors are JSON-neutral and string-keyed:

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
| HTTP 429 or Telegram description `Too Many Requests` | `rate_limit` |
| HTTP 401, `Unauthorized`, rejected bot token | `auth` |
| HTTP 403, `Forbidden: bot was kicked`, missing permission, blocked by user | `permission` |
| Timeout, DNS, TLS, transient 5xx | `network` or `provider_unavailable` |
| 409 with `terminated by other getUpdates` | `polling_conflict` (poller crash) |
| Invalid source config or missing credential profile | `config` |
| Invalid content, missing target, reply not found, message text empty, stream replay without content | `payload` |
| Unsupported edit kind, channel inbound, or content with no fallback | `unsupported` |
| Stream cancellation observed by the adapter | `stream_cancelled` |
| Unknown Bot API error | `unknown` |

`details` may include Telegram `error_code`, `description`, `retry_after`, and
redacted endpoint context. It must not include the bot token, raw update or
message bodies, plaintext activation/login codes, or private callback data.

Adapters do not emit Gateway-owned error kinds such as `"contract"` or
`"adapter_restarted"` unless Gateway core defines that mapping for adapter
contract violations.

## Telemetry and logs

Telegram emits telemetry under:

```text
[:bullx, :telegram, :source, :start]
[:bullx, :telegram, :poller, :tick]
[:bullx, :telegram, :poller, :retry]
[:bullx, :telegram, :poller, :conflict]
[:bullx, :telegram, :update, :received]
[:bullx, :telegram, :update, :ignored]
[:bullx, :telegram, :update, :mapped]
[:bullx, :telegram, :update, :publish, :start]
[:bullx, :telegram, :update, :publish, :stop]
[:bullx, :telegram, :update, :publish, :exception]
[:bullx, :telegram, :direct_command, :handled]
[:bullx, :telegram, :delivery, :start]
[:bullx, :telegram, :delivery, :stop]
[:bullx, :telegram, :delivery, :exception]
[:bullx, :telegram, :stream, :flush]
[:bullx, :telegram, :commands, :sync]
```

Safe metadata includes `adapter`, `channel_id`, `bot_id`, `chat_id`,
`chat_type`, `thread_id`, `update_id`, `event_type`, `delivery_id`,
`attention_reason`, and sanitized Bot API `error_code` or `description`.

Logs are part of the manual-run contract. Startup, bot identity resolution,
polling lifecycle, command-menu sync, inbound mapping, attention decisions,
direct-command handling, publish result, outbound delivery, and stream flush
paths should emit safe structured log lines. Logs must not include the bot
token, raw update bodies, raw message text beyond what already lives in
normalized content, plaintext activation/login codes, or private callback
data.

## I18n

All human-facing Telegram text uses `BullX.I18n` and the application-global
locale. The adapter does not choose locale from Telegram `language_code`,
`Accept-Language`, or browser settings.

Add at least these keys in supported locales:

```toml
[gateway.telegram.auth]
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

[gateway.telegram.ping]
pong = "PONG!"

[gateway.telegram.delivery]
fallback_text = "..."
stream_generating = "..."
stream_failed = "..."
stream_cancelled = "..."
reply_target_missing_sent_to_scope = "..."

[gateway.telegram.media]
image = "..."
audio = "..."
video = "..."
file = "..."

[gateway.telegram.errors]
unsupported_message = "..."
profile_unavailable = "..."
```

Tests must fail if a key used by the adapter is missing in any bundled locale.

## Security and privacy

Telegram transport authenticity stays adapter-owned. Long-poll responses come
over TLS from `api.telegram.org` and authenticate via the bot token in the URL
path. There is no webhook secret to compare in the first version.

The adapter must:

- drop self-sent bot messages before publish;
- ignore messages without `from` (anonymous admins, channel posts);
- reject `/preauth` and `/web_auth` in group chats without consuming or
  issuing secrets;
- discard activation codes and login auth codes from logs, telemetry, error
  details, and dead letters;
- keep bot tokens, raw update bodies, and plaintext auth codes out of logs and
  persisted Gateway records;
- keep bot tokens in `BullX.Config` secret storage;
- keep Gateway actor ids channel-local and avoid writing Principal ids into
  Signals;
- refuse to start a second long-poller against the same bot token on the same
  node.

Telegram outbound delivery may be customer-facing. The adapter assumes the
Delivery already passed Governance or another upstream authorization boundary.
The adapter must not add a shortcut that lets direct Bot API calls bypass
Gateway outbound validation for business effects.

## Failure behavior

Bot API authentication failures, malformed updates, missing required fields,
missing credential profiles, and unsupported content fail closed. They produce
redacted telemetry and safe logs.

For inbound updates, the adapter advances the `getUpdates` offset only when
one of these conditions is true:

- the update was intentionally ignored (self-sent, ignored chat, outside
  allowlist, unmentioned group message, unsupported update kind);
- an adapter-local direct command completed or a duplicate direct-command
  result was found;
- `BullX.Gateway.publish/2` returned accepted;
- the update is structurally malformed and retry would not help (a payload
  error).

For outbound Delivery, Telegram errors follow the Gateway retry and terminal
outcome contract. Retryable errors include rate limiting (`retry_after`
honored inline up to `flood_wait_max_ms`, then surfaced as retryable),
network failures, timeouts, and temporary provider unavailability. Auth,
permission, payload, unsupported, and malformed-target errors are terminal
unless Telegram supplies a specific retry hint.

Process-local state is reconstructible. If `BullxTelegram.Channel` or
`BullxTelegram.Poller` restarts, the poller reopens `getUpdates` at the highest
acknowledged offset and rebuilds cache entries opportunistically. Gateway and
Principal durable facts remain in PostgreSQL.

A persistent `getUpdates` conflict is not reconstructible: another instance
holds the bot token. The poller crashes with `:telegram_polling_conflict` and
relies on supervisor escalation and operator alerts rather than silent
recovery.

## Alternatives considered

| Alternative | Decision |
| --- | --- |
| Port the old main-branch RFC 0016 directly | Rejected. It is tied to old Gateway, Accounts, top-level OTP application, and `transport.mode = "webhook"` plus operator-edited webhook secret state that no longer fits the Plugin/Gateway/Principal boundaries. |
| Add Telegram directly under BullX core | Rejected. The plugin system is the selected integration boundary. |
| Use a top-level `BullXTelegram` app outside `plugins/*` | Rejected. The source boundary should be the plugin Mix project. |
| Build a new `packages/telegram_bot_api` to mirror `packages/feishu_openapi` | Rejected for the first version. Telegram's Bot API is small enough that `visciang/telegram` is a sufficient client; a BullX-owned package can be added later if needed. |
| Use the `visciang/telegram` package's `Poller` and `Webhook` application supervisors | Rejected. Transport lifecycle belongs to `BullX.Gateway.SourceSupervisor`. The package is used as a stateless Bot API client only. |
| Support webhook ingress in the first version | Rejected. Webhook adds a Phoenix controller, generated secret, URL plumbing, and per-source mount routing that doubles the inbound surface area. The first version is polling only; webhook may be added later behind `transport.mode`. |
| Register a Telegram Principal login provider via the Login Widget | Rejected. The Login Widget is not OIDC, requires an embedded web page and hash-signature verification, and its userinfo is weaker than what `/preauth` and `/web_auth` already deliver. Browser login for Telegram actors uses the existing channel-auth-code path. |
| Keep `/ask` as a Telegram-local direct command | Rejected. Adapter command sets stay aligned with Feishu: `/ping`, `/preauth`, `/web_auth`. Other `/...` text becomes a Gateway `slash_command` Signal after the attention policy and Principal gate accept it. |
| Implement native media upload (`sendPhoto`, `sendDocument`, etc.) in v1 | Rejected. Outbound content kinds are limited to `:text` in the first version; non-text degrades to `fallback_text`. Native uploads will arrive with a follow-up design once media URI resolution is shared across adapters. |
| Publish reactions, recalls, channel posts, callback queries, member updates | Rejected for v1. `allowed_updates` is pinned to `message` and `edited_message`. A later version may extend the list when consumers exist. |
| Maintain adapter-local ETS dedupe table | Rejected. `BullX.Cache` already provides TTL state with predictable supervision and metrics. |
| Put resolved Principal ids into Gateway Signals | Rejected. Gateway actor data stays channel-local; Principal-aware routing needs a later design. |
| Silently retry on `getUpdates` conflict | Rejected. A persistent conflict indicates another instance is running with the same bot token; the poller should crash and surface the conflict to operators. |
| Strip `@bot_username` mentions from inbound text at the adapter edge | Rejected for v1. Mention text is preserved so Runtime consumers can render the original message faithfully; mention metadata lives in `refs`. |

### Behaviors deliberately carried over from main-branch RFC 0016 / `lib/bullx_telegram/`

- Long-poll lifecycle: `deleteWebhook(drop_pending_updates: false)` → `getMe`
  → `setMyCommands` → loop on `getUpdates`. Bounded retry on transient
  failures, crash on `getUpdates` conflict.
- `allowed_updates = ["message", "edited_message"]` pinning.
- Attention policy reasons (`"dm" | "command" | "mention" | "reply_to_bot" |
  "free_response"`) and ignore-reason taxonomy, including
  `ignored_thread_ids` precedence over `allowed_chat_ids`.
- `bot_username`-qualified command parsing (`/cmd@bullx_bot args`) and
  rejection of `/cmd@other_bot`.
- Forum-topic mapping including "General" topic normalization to
  `thread_id = nil`.
- Inbound content blocks with native media kinds and
  `telegram://file/<file_id>` URIs; outbound `render_outbound/1`
  degrade-to-fallback-text for non-text content.
- UTF-16 code-unit splitting (`codepoint_units/1` treating codepoints above
  `0xFFFF` as two units), with hard limit `4096` and soft limit
  `stream_chunk_soft_limit` (default `3900`).
- Multi-message streaming state machine, throttled by
  `stream_update_interval_ms`, finalizing with edits + `deleteMessage` to
  reconcile overshoots.
- Reply-target failure fallback (`replied message not found`,
  `message to reply not found`, `MESSAGE_ID_INVALID`) to plain
  `sendMessage(chat_id)` with `"reply_target_missing_sent_to_scope"` warning.
- `setMyCommands` sync policy (`"replace" | "off"`, default `"replace"`).
- Flood-control: honor `retry_after` inline up to `flood_wait_max_ms`,
  surface longer waits as retryable transport errors.
- Test-injection seams (`api_module`, `gateway_module`, `start_transport?`)
  preserved under their current names.

### Deliberate evolutions from main-branch behavior

- Webhook ingress is removed in v1 (operator-chosen, per the scoping
  decision). RFC 0016's `transport.mode = "webhook"`, `BullX.Config.
  GeneratedSecret` for `transport.secret_token`, and the
  `/gateway/telegram/:channel_id/webhook` controller are not implemented.
- `/ask` is dropped (operator-chosen, for parity with the Feishu command
  set).
- Numeric Telegram ids (`update_id`, `message_id`, `chat_id`, `thread_id`,
  `user_id`) are stringified inside Gateway carrier payloads to keep the
  carrier JSON-neutral. The adapter parses them back to integers before
  calling the Bot API. Old `BullXTelegram` kept them as integers in carrier
  context.
- Direct-command replies (`/ping`, `/preauth`, `/web_auth`) go through
  `BullX.Gateway.deliver/1` instead of calling Bot API directly. This
  matches the Feishu pattern and lets Gateway outbound own retries, dead
  letters, and rate-limit handling for adapter-local replies.
- Namespace migration: `BullXTelegram.*` → `BullxTelegram.*` under
  `plugins/telegram/lib/`; `BullXAccounts.*` → `BullX.Principals.*`;
  `BullXGateway.*` → `BullX.Gateway.*`; `BullXTelegram.Cache` → `BullX.Cache`
  with adapter-prefixed keys.
- `event.data` is flat (cross-adapter consistency with Feishu) rather than
  nested under `"telegram"` as the old `UpdateMapper.gateway_event/5` did.
  Provider-specific fields (`update_id`, `message_id`, `attention_reason`,
  etc.) remain present, just without the `event.data.telegram.` prefix.
- Supervisor topology is wrapped in `BullxTelegram.Supervisor` (one-for-all) per
  source so the new `source_child_spec/1` single-child contract can return
  one spec instead of two siblings.
- Capabilities is the map shape required by the current
  `BullX.Gateway.Adapter` behaviour (`%{inbound_modes, outbound_ops,
  content_kinds, stream_strategy, features}`), not the flat list
  `[:send, :edit, :stream, :threads]` from RFC 0016.

## Implementation handoff

### Goal

Implement the Telegram plugin as one trusted plugin that exposes Gateway
transport for Telegram, while preserving the current Plugin, Gateway, and
Principal boundaries. Mirror `plugins/feishu` shape and contracts wherever
possible.

### Context pointers

- `AGENTS.md`
- [Plugins.md](Plugins.md)
- [Principal.md](Principal.md)
- [SignalsGateway.md](SignalsGateway.md)
- [Cache.md](Cache.md)
- [FeishuAdapter.md](FeishuAdapter.md)
- [lib/bullx/gateway/adapter.ex](../../lib/bullx/gateway/adapter.ex)
- [lib/bullx/gateway/source_config.ex](../../lib/bullx/gateway/source_config.ex)
- [lib/bullx/gateway/sources.ex](../../lib/bullx/gateway/sources.ex)
- [lib/bullx/principals.ex](../../lib/bullx/principals.ex)
- [lib/bullx/principals/authn.ex](../../lib/bullx/principals/authn.ex)
- [lib/bullx/plugins/plugin.ex](../../lib/bullx/plugins/plugin.ex)
- [plugins/feishu/](../../plugins/feishu/) (reference implementation)
- `visciang/telegram` hex package

### Constraints

- Put plugin code under `plugins/bullx_telegram`.
- Use plugin id `"bullx_telegram"` (host derives it from the app atom) and
  Gateway adapter extension id `"telegram"`.
- Use `BullX.Principals`, not `BullXAccounts`.
- Use `BullX.Gateway`, not `BullXGateway`.
- Use `bullx.gateway.sources`, not `bullx.gateway.adapters`.
- Use `BullX.Cache`, not adapter-owned ETS tables or direct Cachetastic calls.
- Use `visciang/telegram` as a stateless client; do not start
  `BullxTelegram.Poller` or `Telegram.Webhook` supervisors from the package.
- Store plugin secrets through `BullX.Config`; do not persist bot tokens in
  source config.
- Do not change `BullX.Runtime.Supervisor` or add Jido dependencies.
- Do not add Principal ids to Gateway Signals.
- Do not register a Telegram Principal login provider.
- Do not add a webhook controller, `setWebhook` call, or webhook secret
  generation in the first version.
- Do not add native media upload in the first version.

### Tasks

1. Add the Telegram plugin skeleton.
   Owns: `plugins/telegram/mix.exs`, `BullxTelegram.Plugin`, plugin tests.
   Depends on: none.
   Acceptance: BullX discovers plugin id `"telegram"` and the adapter
   extension declaration when the plugin is compiled.
   Verify: plugin discovery and registry tests.

2. Add Telegram plugin configuration.
   Owns: `BullxTelegram.Config`, config casters, secret-key tests.
   Depends on: Task 1.
   Acceptance: `bullx.plugins.telegram.credentials` is secret, validates the
   credential-profile map, and supports source config lookup without logging
   credentials.
   Verify: config and secret writer tests.

3. Implement `BullxTelegram.GatewayAdapter` config, capabilities, and connectivity.
   Owns: `BullxTelegram.GatewayAdapter`, `BullxTelegram.Source`, `BullxTelegram.Error`.
   Depends on: Task 2.
   Acceptance: adapter callbacks satisfy `BullX.Gateway.Adapter`,
   capabilities are precise, and connectivity check returns only safe
   metadata after a `getMe` call with optional bot-username match.
   Verify: adapter unit tests with `Req.Test` or a fake API module.

4. Implement inbound runtime and update mapping.
   Owns: `BullxTelegram.Channel`, `BullxTelegram.Poller`, `BullxTelegram.UpdateMapper`,
   `BullxTelegram.ContentMapper`, `BullxTelegram.AttentionPolicy`, `BullxTelegram.Commands`,
   cache key helpers.
   Depends on: Task 3.
   Acceptance: long-poll lifecycle starts, syncs the command menu, and maps
   `message` and `edited_message` updates into valid Gateway inputs;
   attention policy returns the documented reasons; bot self-author and
   anonymous messages are dropped; polling conflict crashes with the
   documented reason.
   Verify: update-mapping tests and a `BullX.Gateway.publish/2` integration
   test with a fake Router and fake API module.

5. Implement Principal account gate and direct commands.
   Owns: `BullxTelegram.DirectCommand`, locale keys.
   Depends on: Task 4 and the Gateway outbound API slice.
   Acceptance: normal user-origin events call Principal matching before
   publish; `/ping` bypasses Principal; `/preauth` consumes activation codes
   only in private chats; `/web_auth` issues login auth codes only for bound
   active Humans in private chats; duplicate `update_id` returns cached
   results.
   Verify: focused direct-command tests with Principal fixtures.

6. Implement outbound send and edit.
   Owns: `BullxTelegram.Delivery`, outbound error mapping.
   Depends on: Task 3 and the Gateway outbound API slice.
   Acceptance: send/edit return Gateway-compatible sent, degraded, or error
   results; reply-target fallback returns
   `"reply_target_missing_sent_to_scope"`; over-limit edit returns a payload
   error; `message is not modified` is treated as success.
   Verify: outbound tests with fake API responses.

7. Implement streaming with multi-message accumulation.
   Owns: `BullxTelegram.Streamer`.
   Depends on: Task 6.
   Acceptance: stream finalizes with the expected message list,
   `external_message_ids` order matches creation order, extra messages from
   earlier overshoots are deleted on finalize, UTF-16 splitting matches the
   `stream_chunk_soft_limit`, throttling honors `stream_update_interval_ms`,
   missing stream content returns the documented payload error.
   Verify: streamer tests with deterministic chunk inputs.

8. Add telemetry, logs, and locale coverage.
   Owns: Telegram modules and locale files.
   Depends on: Tasks 4 through 7.
   Acceptance: safe telemetry/log metadata exists for startup, poller,
   inbound, attention, direct-command, publish, delivery, and stream paths;
   locale tests fail on missing keys.
   Verify: telemetry/log capture tests and locale key tests.

### Done when

- `plugins/telegram` compiles as a BullX plugin.
- The plugin registers `:"bullx.gateway.adapter"` id `"telegram"`.
- Telegram source config and plugin credentials validate through
  `BullX.Config`.
- `BullxTelegram.GatewayAdapter.connectivity_check/1` verifies the bot token
  through `getMe` without starting a poller or leaking secrets.
- Enabled Telegram sources start one long-poll loop under
  `BullX.Gateway.SourceSupervisor`.
- The attention policy filters group-chat noise according to this design.
- Telegram inbound updates normalize into valid Gateway inputs and publish
  through `BullX.Gateway.publish/2`.
- Built-in direct commands implemented by the Telegram adapter behave as
  specified and do not publish Runtime slash-command Signals.
- Telegram outbound send, edit, and stream paths produce Gateway-compatible
  outcomes or adapter error maps.
- UTF-16 message splitting passes targeted tests on multi-byte and
  surrogate-pair text.
- A persistent `getUpdates` conflict produces a visible poller crash and is
  not silently retried.
- Focused tests and `bun precommit` pass.

Implementation should stop and ask if a change would require persistent
Telegram tokens beyond the bot token, webhook ingress, native media upload,
inline-keyboard callback handling, a Telegram Principal login provider,
Principal ids in Signals, Gateway route topology as a Telegram-specific
contract, a new credential store, or a supervision boundary outside the
plugin and Gateway source supervisors.

## Acceptance criteria

- Telegram is implemented only as the `plugins/telegram` plugin.
- The plugin exposes the `:"bullx.gateway.adapter"` extension only and does
  not register a Principal login provider.
- The adapter uses `visciang/telegram`; no other Telegram dependency is
  added.
- Telegram source config uses `bullx.gateway.sources`.
- Bot tokens are declared by plugin config and encrypted by `BullX.Config`.
- Gateway actor ids use `telegram:<user_id>` and remain channel-local.
- Numeric Telegram ids appear as strings in Gateway carrier payloads.
- Normal user-origin events are gated by `BullX.Principals` before publish.
- The attention policy filters group-chat updates according to this design;
  `event.data.attention_reason` records the decision.
- `/preauth` and `/web_auth` are rejected in group chats without consuming or
  issuing secrets.
- `/ping` works before activation and does not require Principal matching.
- `/ask` is not implemented as a direct command; `/...` messages that are not
  `/ping`, `/preauth`, or `/web_auth` flow through Principal gating and
  publish as `slash_command` Signals when attention policy accepts them.
- Send, edit, and stream delivery use Gateway outbound contracts and safe
  error maps; UTF-16 splitting is used wherever Telegram message limits
  apply.
- Streaming finalizes with the expected message set, deleting overshoots and
  honoring `stream_update_interval_ms`.
- A persistent `getUpdates` conflict crashes the poller with a documented
  reason; the supervisor does not silently restart it forever.
- Self-sent and anonymous-admin messages are filtered before publish.
- Bot tokens, raw update payloads, plaintext activation/login codes, and raw
  Bot API bodies do not enter telemetry, logs, error details, receipts, or
  dead-letter summaries. Normalized Gateway content may enter Gateway carrier
  and replay surfaces according to the Gateway contract.
- No Jido dependency, old `BullXGateway`, old `BullXAccounts`, RFC 0016
  webhook plumbing, or legacy Telegram compatibility shim is introduced.
- `bun precommit` passes.
