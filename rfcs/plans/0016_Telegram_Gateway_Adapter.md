# RFC 0016: Telegram Gateway Adapter

**Status**: Implementation plan
**Author**: OpenAI Codex
**Created**: 2026-05-05
**Depends on**: RFC 0001, RFC 0002, RFC 0003, RFC 0007, RFC 0008, RFC 0009, RFC 0015

## 1. Scope

Implement Telegram as a first-class Gateway channel adapter for BullX.

The adapter supports:

- Telegram inbound updates through long polling.
- Telegram inbound updates through webhook delivery to BullXWeb.
- Polling as the default transport, matching Hermes.
- Webhook mode through BullX's existing `BullXWeb.Endpoint`, not through an adapter-owned HTTP server.
- BullX-generated Telegram webhook `secret_token` values, stored as adapter config but not edited as operator-supplied credentials.
- Telegram `/ping`, `/preauth`, `/web_auth`, and `/ask` commands.
- Telegram command menu registration through `setMyCommands`.
- Account gate handling before `BullXGateway.publish_inbound/1`.
- Direct-message account linking through `/preauth <activation-code>`.
- Web auth code issuance through `/web_auth` for already-bound Telegram actors.
- Text, command, caption, location, and basic media inbound mapping.
- Telegram group/supergroup attention gating through mentions, replies to the bot, and bot-qualified commands.
- Telegram forum topics through Gateway `thread_id`.
- Outbound send, edit, and streaming text delivery through the Gateway delivery contract.
- Text fallback for outbound media/card content through `fallback_text`.
- Localized human-facing Telegram replies through `BullX.I18n`.

The adapter uses `visciang/telegram` for Bot API HTTP requests. BullX does not use that package's `Telegram.Poller` or `Telegram.Webhook` supervisors because those wrappers are application-global and do not match BullX's per-channel adapter supervision boundary.

## 2. Non-Goals

- Do not change the Gateway signal contract from RFC 0002.
- Do not change the Gateway delivery or DLQ contract from RFC 0003.
- Do not introduce a separate OTP application.
- Do not add a generic Telegram Login Widget or Telegram OAuth-style web login flow.
- Do not persist Telegram user tokens. Telegram Bot API does not issue user OAuth tokens for this adapter path.
- Do not make Telegram files or media storage a durable BullX subsystem.
- Do not implement outbound native media upload. Outbound media/card content is sent as `fallback_text`.
- Do not implement inline keyboard callback actions, approval buttons, model pickers, or card/action components.
- Do not support free-response group listening by default. Group and supergroup messages require an explicit bot trigger unless the configured attention policy says otherwise.
- Do not store the Telegram webhook URL as adapter configuration. The URL is derived from `BullXWeb.Endpoint.url/0` and the adapter channel ID.
- Do not let operators manually edit the Telegram webhook `secret_token`. BullX generates and rotates it.
- Do not put the bot token in the webhook URL path.
- Do not use `Telegram.Poller` or `Telegram.Webhook` from the dependency as supervised children.

## 3. Cleanup Plan

### 3.1 What can be deleted

Nothing in the existing Gateway, Feishu, Discord, Accounts, I18n, Web, or Runtime implementation should be deleted for this adapter.

The implementation must avoid compatibility shims such as `BullXGateway.Adapters.Telegram` unless an existing caller already requires that module name. The settled subsystem rule places channel adapter implementations in top-level namespaces, so Telegram code belongs under `lib/bullx_telegram/` as `BullXTelegram.*`.

### 3.2 Existing utilities and patterns to reuse

- `BullXGateway.Adapter` behaviour.
- `BullXGateway.AdapterSupervisor` and `BullXGateway.AdapterRegistry`.
- `BullXGateway.publish_inbound/1`.
- `BullXGateway.Inputs.Message` and `BullXGateway.Inputs.SlashCommand`.
- `BullXGateway.Delivery`, `BullXGateway.deliver/1`, ScopeWorker serialization, DLQ, and telemetry.
- `BullXGateway.Delivery.Content` fallback-text validation.
- `BullXAccounts.match_or_create_from_channel/1`, `consume_activation_code/2`, and `issue_user_channel_auth_code/3`.
- `BullX.I18n.t/3` and locale TOML files.
- Feishu and Discord adapter account-gate behavior.
- Discord adapter attention-policy isolation and direct-command result dedupe.
- Feishu adapter setup/control-plane persistence through `bullx.gateway.adapters`.
- `BullX.Config.GeneratedSecret` from RFC 0001 for webhook `secret_token` generation and validation.
- Hermes Telegram behavior for polling as default, optional webhook mode, group attention checks, command menu sync, message splitting, and thread/topic delivery.
- `Telegram.Api.request/3` from `visciang/telegram` for Bot API calls.

### 3.3 Code paths changing

- Add a new top-level channel adapter namespace: `BullXTelegram.*`.
- Add one dependency on `visciang/telegram`.
- Configure Tesla for the Telegram package's HTTP client using BullX's existing HTTP client stack.
- Add a BullXWeb Telegram webhook controller and route.
- Extend Gateway adapter setup/configuration code so `bullx.gateway.adapters` can store Telegram JSON-safe entries.
- Extend the setup UI with Telegram adapter fields and `type: :generated_secret` handling.
- Add Telegram translation keys to `priv/locales/en-US.toml` and `priv/locales/zh-Hans-CN.toml`.
- Add Telegram adapter configuration examples without changing Gateway core configuration shape.

### 3.4 Invariants

- The Gateway core remains transport-agnostic.
- Telegram actor identities remain channel-local until `BullXAccounts` resolves or links them.
- Adapter process state is ephemeral and reconstructible. PostgreSQL remains the system of record for accounts and Gateway control-plane data.
- Inbound updates are published only after adapter attention policy, duplicate filtering, and account handling.
- Unbound Telegram actors do not reach Runtime. They receive a localized account-binding prompt from the adapter.
- Adapter-local commands do not enter the Runtime signal stream.
- Human-facing Telegram text is localized through `BullX.I18n`; adapter modules must not hard-code operator/user messages.
- Outbound delivery preserves per-scope serialization through RFC 0003 ScopeWorkers.
- Adapter success paths return only `{:ok, %BullXGateway.Delivery.Outcome{status: :sent | :degraded, error: nil}}`. Adapter failures return `{:error, error_map}`. The adapter must never return `{:ok, %Outcome{status: :failed}}`.
- Adapter error maps are JSON-neutral string-keyed maps. `error["kind"]` is a string and optional retry hints live under `error["details"]`.
- Telegram webhook URL is derived from BullX endpoint configuration. If the operator needs a different public origin, they must fix `BullXWeb.Endpoint` URL configuration, not Telegram adapter config.
- Telegram webhook `secret_token` is generated by BullX before persistence and redacted after persistence.
- Telegram webhook requests are accepted only when `X-Telegram-Bot-Api-Secret-Token` matches the stored generated token.
- Polling mode clears any existing Telegram webhook before starting `getUpdates`.
- Only one polling process may run for a bot token. Telegram polling conflict is treated as an operator-visible transport error.
- Stream delivery is required. If the adapter cannot stream a delivery, it returns a payload or transport error instead of silently downgrading to final-only send.

### 3.5 Verification command

Run:

```bash
mix deps.get
mix test test/bullx_telegram test/bullx_web/controllers/telegram_webhook_controller_test.exs
mix test test/bullx_gateway/adapter_config_test.exs test/bullx_accounts/authn_test.exs
mix precommit
```

## 4. Subsystem Placement

Telegram is a Gateway channel adapter, not a new BullX subsystem. It is implemented in a top-level namespace because channel adapters are first-class integrations parallel to the Gateway core implementation.

Files live under:

```text
lib/bullx_telegram/
test/bullx_telegram/
```

The public adapter module is:

```elixir
BullXTelegram.Adapter
```

It implements `BullXGateway.Adapter` and is configured as:

```elixir
{{:telegram, "default"}, BullXTelegram.Adapter, config}
```

Only webhook ingress touches `BullXWeb`, because webhook HTTP delivery must use the Phoenix endpoint.

## 5. Dependency

Add `visciang/telegram` from GitHub and pin the dependency to the reviewed release tag:

```elixir
{:telegram, github: "visciang/telegram", tag: "2.1.1"}
```

The pin targets release `2.1.1`, published on 2026-02-14.

Do not use Hex package name `telegram` without the GitHub source. The package currently requested by this RFC is `visciang/telegram`; the Hex package name is ambiguous and historically points at an unrelated old package.

The dependency choice is deliberate:

- It exposes a generic `Telegram.Api.request/3` for Bot API methods.
- It provides Bot API file upload parameter encoding without forcing this RFC to implement outbound native media delivery.
- It avoids hand-written Bot API JSON/multipart plumbing.
- BullX keeps transport ownership in `BullXTelegram.Poller` and BullXWeb instead of using the package's application-global supervisors.

The package uses Tesla. BullX must configure a production HTTP adapter for Tesla. Prefer the existing Finch stack already present through BullX's HTTP dependencies; the final implementation must add a named Finch child only if the selected Tesla adapter requires one at runtime.

## 6. Module Plan

Create:

```text
lib/bullx_telegram.ex
lib/bullx_telegram/adapter.ex
lib/bullx_telegram/channel.ex
lib/bullx_telegram/config.ex
lib/bullx_telegram/poller.ex
lib/bullx_telegram/cache.ex
lib/bullx_telegram/update_mapper.ex
lib/bullx_telegram/content_mapper.ex
lib/bullx_telegram/attention_policy.ex
lib/bullx_telegram/direct_command.ex
lib/bullx_telegram/commands.ex
lib/bullx_telegram/delivery.ex
lib/bullx_telegram/streamer.ex
lib/bullx_telegram/error.ex
lib/bullx_web/controllers/telegram_webhook_controller.ex
```

`BullXTelegram.Channel` owns the normalized channel config and adapter-local cache for one configured Telegram channel.

`BullXTelegram.Poller` owns the `getUpdates` loop for polling mode. It stores the current update offset in process state only; on restart, Telegram's offset semantics and Gateway dedupe determine replay behavior.

`BullXTelegram.UpdateMapper` converts Telegram updates into Gateway input structs or adapter-local direct commands. It owns profile extraction, bot self-message filtering, command parsing, and common metadata extraction.

`BullXTelegram.ContentMapper` converts Telegram message payloads into Gateway content blocks and renders outbound Gateway content into Telegram text.

`BullXTelegram.AttentionPolicy` decides whether a Telegram update should enter BullX. This module is isolated so attention changes do not alter Gateway signal shape.

`BullXTelegram.DirectCommand` owns `/ping`, `/preauth`, and `/web_auth`. These commands are handled before Gateway inbound publish.

`BullXTelegram.Commands` owns Telegram `setMyCommands` payloads and registration.

`BullXTelegram.Streamer` owns streaming message state: Telegram message IDs, accumulated text, chunk boundaries, edit throttling, and finalization.

`BullXWeb.TelegramWebhookController` verifies Telegram webhook secrets, parses update bodies, dispatches updates to `BullXTelegram.Channel`, and returns Telegram-facing HTTP responses.

There is no broad `BullXTelegram.API` wrapper. Adapter modules call `config.api_module.request/3`, defaulting to `Telegram.Api`. Tests inject a small API module through config only where an external boundary must be controlled.

## 7. Supervision and Runtime

`BullXTelegram.Adapter.child_specs/2` returns one `BullXTelegram.Channel` child for every configured Telegram channel.

When `transport.mode == "polling"`, the channel subtree also starts one `BullXTelegram.Poller` child.

When `transport.mode == "webhook"`, the channel subtree does not start a poller. It registers the Telegram webhook on startup when `transport.set_webhook == true`.

Shape:

```text
BullXGateway.AdapterSupervisor.Channel
|-- BullXTelegram.Channel
`-- BullXTelegram.Poller     (polling mode only)
```

No failure boundary changes outside the adapter channel supervisor.

Polling process behavior:

- On startup, call `deleteWebhook(drop_pending_updates: false)`.
- Verify bot identity through `getMe`.
- Register command menu when command sync is enabled.
- Start bounded long polling through `getUpdates`.
- Maintain `offset` as `last_update_id + 1`.
- Dispatch every update to `BullXTelegram.Channel.handle_update/2`.
- Retry transient network failures with exponential backoff and jitter.
- Detect Telegram polling conflict errors, retry a bounded number of times, then crash the poller with an operator-readable error.

Webhook channel behavior:

- Verify bot identity through `getMe`.
- Register command menu when command sync is enabled.
- Compute webhook URL from `BullXWeb.Endpoint.url/0` and `channel_id`.
- Validate that the derived URL is HTTPS and has a host.
- Call `setWebhook` with the derived URL, generated `secret_token`, and allowed update types when `transport.set_webhook == true`.
- Do not start an HTTP server; BullXWeb already owns HTTP.

## 8. Configuration

Telegram adapter configuration is passed through the RFC 0002 Gateway adapter spec.

Example:

```elixir
config :bullx, :gateway,
  adapters: [
    {{:telegram, "default"}, BullXTelegram.Adapter,
     %{
       bot_token: {:system, "BULLX_TELEGRAM_BOT_TOKEN"},
       bot_username: {:system, "BULLX_TELEGRAM_BOT_USERNAME"},
       web_login_disabled: false,
       dedupe_ttl_ms: :timer.minutes(5),
       poll_timeout_s: 30,
       poll_limit: 100,
       poll_retry_max: 10,
       flood_wait_max_ms: 5_000,
       stream_update_interval_ms: 1_000,
       stream_chunk_soft_limit: 3_900,
       transport: %{
         mode: "polling",
         set_webhook: true
       },
       attention: %{
         allowed_chat_ids: [],
         ignored_chat_ids: [],
         ignored_thread_ids: [],
         require_mention: true,
         free_response_chat_ids: []
       },
       commands: %{
         sync_policy: "replace"
       }
     }}
  ]
```

Required keys:

- `:bot_token`

Recommended keys:

- `:bot_username`, so mention stripping works before `getMe` has completed.

Optional keys:

- `:web_login_disabled`: disables `/web_auth` when `true`, default `false`.
- `:dedupe_ttl_ms`: inbound dedupe TTL, default `5 minutes`.
- `:poll_timeout_s`: Telegram long-poll timeout, default `30`.
- `:poll_limit`: maximum updates per `getUpdates`, default `100`.
- `:poll_retry_max`: bounded retry count before poller crash, default `10`.
- `:flood_wait_max_ms`: maximum Telegram flood-control wait the adapter may honor inline before retrying, default `5000`.
- `:stream_update_interval_ms`: streaming message edit throttle interval, default `1000`.
- `:stream_chunk_soft_limit`: soft UTF-16 code-unit limit before opening another Telegram message, default `3900`.
- `:transport.mode`: `"polling"` or `"webhook"`, default `"polling"`.
- `:transport.set_webhook`: whether startup should call `setWebhook` in webhook mode, default `true`.
- `:transport.secret_token`: generated secret used only in webhook mode. This value is created by the setup/control-plane write path and is not an operator-editable field.
- `:attention.allowed_chat_ids`: optional allowlist. If empty, all non-ignored chats are eligible.
- `:attention.ignored_chat_ids`: chats that never enter BullX.
- `:attention.ignored_thread_ids`: Telegram forum topic IDs that never enter BullX.
- `:attention.require_mention`: group/supergroup messages require an explicit bot trigger unless the chat is in `free_response_chat_ids`, default `true`.
- `:attention.free_response_chat_ids`: chats where group/supergroup messages may enter without mention, default `[]`.
- `:commands.sync_policy`: `"replace"` or `"off"`, default `"replace"`.

`attention.require_mention: false` is accepted only when explicitly configured. The default remains mention-, reply-, command-, and DM-driven.

Configuration resolution must use the existing BullX config style. Operator-supplied secrets such as `bot_token` may use system env indirection. BullX-generated values such as `transport.secret_token` are created or rotated by the control-plane boundary before persistence. Secrets must not be logged.

### 8.1 Webhook URL Derivation

Telegram webhook URL is not adapter configuration.

For channel ID `default`, BullX derives:

```text
<BullXWeb.Endpoint.url()>/gateway/telegram/default/webhook
```

If this URL is wrong, the operator must correct `BullXWeb.Endpoint` URL configuration. The Telegram adapter must not carry a separate webhook URL override.

The webhook route must not contain the bot token. The route identifies the configured BullX adapter channel; authentication is the Telegram secret header.

### 8.2 Generated Webhook Secret

`transport.secret_token` is BullX-generated data.

Rules:

- Setup creates it with `BullX.Config.GeneratedSecret.generate/1`.
- Operators may copy it and may rotate it, but may not type arbitrary replacements.
- Rotation regenerates the value through BullX and displays the new value for copy before the entry is saved again.
- `BullXTelegram.Config.normalize/2` validates it through `BullX.Config.GeneratedSecret.cast/1`.
- If webhook mode is selected and no existing secret can be reused, the setup save path generates one before persistence.
- After persistence, public setup payloads redact it and report only secret status.
- Runtime config inspection must redact it.
- Webhook requests compare it against `X-Telegram-Bot-Api-Secret-Token`.

This value is different from `bot_token`: `bot_token` is a Telegram credential supplied by the operator; `secret_token` is a BullX-generated verifier supplied to Telegram.

### 8.3 Setup Persisted Shape

When `/setup` saves Telegram from the React wizard, the browser submits the RFC 0002 JSON-neutral adapter-array shape:

```json
[
  {
    "id": "telegram:default",
    "enabled": true,
    "adapter": "telegram",
    "channel_id": "default",
    "web_login_disabled": false,
    "credentials": {
      "bot_token": "write-only"
    },
    "transport": {
      "mode": "polling",
      "set_webhook": true,
      "secret_token": "generated-write-only"
    },
    "attention": {
      "allowed_chat_ids": [],
      "ignored_chat_ids": [],
      "ignored_thread_ids": [],
      "require_mention": true,
      "free_response_chat_ids": []
    },
    "advanced": {
      "dedupe_ttl_ms": 300000,
      "poll_timeout_s": 30,
      "poll_limit": 100,
      "poll_retry_max": 10,
      "stream_update_interval_ms": 1000,
      "stream_chunk_soft_limit": 3900,
      "commands_sync_policy": "replace"
    }
  }
]
```

`BullXGateway.AdapterConfig` must generalize the existing Feishu/Discord-specific code paths:

- `default_entry/1` supports `"feishu"`, `"discord"`, and `"telegram"`.
- `catalog/1` returns all supported adapters.
- secret redaction includes `bot_token` and `transport.secret_token`.
- field metadata for `["transport", "secret_token"]` declares `type: :generated_secret`.
- generated-secret merge, redaction, and `secret_status` behavior are driven by catalog field metadata rather than Telegram-specific branches.
- runtime spec building dispatches by adapter.
- connectivity checks dispatch to the selected adapter module.

Catalog metadata for the generated secret:

```elixir
%{
  "path" => ["transport", "secret_token"],
  "type" => :generated_secret,
  "secret" => true
}
```

Setup UI behavior:

- It must not hard-code Telegram webhook secret behavior.
- It reads `type: :generated_secret` from the adapter catalog.
- It renders generated secrets as BullX-created values with copy and rotate actions.
- It treats `secret: true` fields as write-only after save.
- It must not represent the derived webhook URL as configuration.

## 9. Connectivity Check

`BullXTelegram.Adapter.connectivity_check/2` implements the required Gateway adapter connectivity callback.

Minimum behavior:

1. Normalize the submitted config with `BullXTelegram.Config.normalize/2`.
2. Verify bot credentials by calling `getMe`.
3. Validate that `bot_username`, when configured, matches the returned bot username.
4. Validate transport mode.
5. For webhook mode, validate the derived BullX endpoint URL and generated secret.
6. Return only safe metadata.

Connectivity checks must not start polling and must not call `setWebhook`.

Success shape:

```elixir
{:ok,
 %{
   "status" => "ok",
   "adapter" => "telegram",
   "channel_id" => "default",
   "bot_id" => "123456",
   "bot_username" => "bullx_bot",
   "capabilities" => ["send", "edit", "stream", "threads"],
   "transport" => %{
     "mode" => "polling",
     "long_lived_client_started" => false
   }
 }}
```

Failure shape:

```elixir
{:error,
 %{
   "kind" => "auth" | "config" | "network" | "rate_limited" | "unknown",
   "message" => "safe operator-facing summary",
   "details" => %{}
 }}
```

Connectivity must never log or return `bot_token`, webhook `secret_token`, or raw update bodies.

## 10. Command Menu

BullX supports Telegram command menu registration for:

- `/ping`
- `/preauth`
- `/web_auth`
- `/ask`

Telegram `setMyCommands` replaces the bot command list. There is no Discord-style safe reconciliation. BullX therefore supports exactly two policies:

- `"replace"`: set the command list to BullX's desired commands.
- `"off"`: do not modify Telegram command menu state.

The default is `"replace"` because a configured Telegram bot token is assumed to be owned by the BullX deployment.

Failure to register commands logs a warning and leaves the adapter running. Inbound command handling and outbound delivery still work.

## 11. Attention Policy

Telegram attention policy is user-facing behavior, not a technical Telegram chat taxonomy.

An inbound Telegram update enters BullX when one of these conditions is true:

- It is a private chat message from a human actor.
- It is a Telegram command directed to the bot.
- It is a group/supergroup message that mentions the bot.
- It is a group/supergroup message that replies to a bot-authored message.
- It is in a configured free-response chat.

An inbound Telegram update does not enter BullX when:

- it was authored by the configured bot;
- it was authored by another bot;
- it is in an ignored chat;
- it is in an ignored forum topic;
- it is outside an allowlist when an allowlist is configured;
- it is an unmentioned ordinary group/supergroup message and the chat is not in free-response mode;
- it is a channel post without a user actor.

The event mapper must annotate accepted events with an attention reason under `event.data["telegram"]["attention_reason"]` using one of:

- `"dm"`
- `"command"`
- `"mention"`
- `"reply_to_bot"`
- `"free_response"`

### 11.1 Account Gate

Attention policy decides whether the Telegram update is addressed to BullX. It does not decide whether the actor may enter Runtime.

After mapping and before `BullXGateway.publish_inbound/1`, `BullXTelegram.Channel` must run the same account gate shape used by Feishu and Discord:

```elixir
config.accounts_module.match_or_create_from_channel(mapped.account_input)
```

Outcomes:

- `{:ok, _user, _binding}`: publish the mapped Gateway input.
- `{:error, :activation_required}`: do not publish; reply locally through the activation-required path.
- `{:error, :user_banned}`: do not publish; reply locally with the localized denied message.
- other errors: do not publish; return a normalized adapter error.

The activation-required prompt must not generate, reveal, or include an activation code or web-auth code. The activation code is created outside the Telegram adapter, typically by bootstrap/setup or an authorized operator, and the user supplies that existing code to `/preauth`.

The prompt text follows Feishu and Discord:

- Telegram private chat: use the normal localized activation-required guidance with `/preauth <code>`.
- Telegram group/supergroup: use the localized "message the bot privately" guidance and do not mention activation-code syntax.

`/preauth`, `/web_auth`, and `/ping` bypass this account gate because they are adapter-local direct commands. `/preauth` is the path that binds an unbound Telegram actor by calling `BullXAccounts.consume_activation_code/2`.

## 12. Telegram Scope Contract

`scope_id` is the user-visible chat where BullX is expected to respond.

Rules:

- Private chat: `scope_id = chat.id`, `thread_id = nil`.
- Group/supergroup without forum topic: `scope_id = chat.id`, `thread_id = nil`.
- Group/supergroup forum topic: `scope_id = chat.id`, `thread_id = message_thread_id`.

Telegram forum topics are modeled as Gateway `thread_id` because the chat remains the visible message surface and the Bot API sends topic replies with `message_thread_id`.

Telegram's General topic may appear as a special thread ID. The adapter must normalize it consistently and avoid sending `message_thread_id` when Telegram expects the root chat.

## 13. Inbound Mapping

Accepted Telegram text messages map to `BullXGateway.Inputs.Message`.

Accepted `/ask` commands map to `BullXGateway.Inputs.SlashCommand`.

Mapped inputs are published only after the Account Gate in Section 11.1 succeeds. An unbound actor never reaches Runtime as an ownerless actor.

Common fields:

- `source`: `bullx://gateway/telegram/<channel_id>`.
- `channel`: `{:telegram, config.channel_id}`.
- `scope_id`: Telegram chat ID as a string.
- `thread_id`: Telegram `message_thread_id` as a string when present.
- `actor.id`: `"telegram:" <> user_id`.
- `actor.display`: Telegram display name.
- `reply_channel.adapter`: `"telegram"`.
- `reply_channel.channel_id`: BullX adapter channel ID.
- `reply_channel.scope_id`: same as input `scope_id`.
- `reply_channel.thread_id`: same as input `thread_id`.
- `reply_to_external_id`: triggering Telegram message ID when available.
- `content`: Gateway content blocks.
- `refs`: Telegram update, message, chat, thread, and user references.
- `event.data["telegram"]`: Telegram-specific JSON-neutral metadata.

Text handling:

- Plain text uses message `text`.
- Commands strip `/command`, optional `@bot_username`, and leading whitespace before publishing `/ask` content.
- Captions use message `caption`.
- Empty content after trigger stripping is skipped with telemetry and a localized direct reply when user-visible.

Location handling:

- Location and venue messages are converted to text content that includes latitude, longitude, and a maps URL.

Media handling:

- Photo, audio, voice, video, document, and sticker updates are accepted.
- The adapter maps them to Gateway media or text blocks with safe fallback text.
- Media block URLs use `telegram://file/<file_id>` or another adapter-local URI form; they are not durable public URLs.
- The adapter may call `getFile` for safe metadata, but it must not introduce durable media storage.
- Unsupported media maps to a localized unsupported-message text block.

## 14. Direct Commands

`/ping`, `/preauth`, and `/web_auth` are adapter-local.

They intentionally keep account-linking side effects outside the Runtime signal stream, matching Feishu and Discord.

Telegram command parsing must support:

- `/command`
- `/command args`
- `/command@bot_username`
- `/command@bot_username args`

Commands addressed to a different bot username are ignored.

`/preauth`:

- accepts a required activation code argument;
- is valid only in Telegram private chats;
- returns the localized "message the bot privately" result in group/supergroup chats without consuming the activation code;
- uses the Telegram actor external ID;
- calls `BullXAccounts.consume_activation_code/2`;
- returns a localized result.

`/web_auth`:

- is valid only in Telegram private chats;
- returns the localized "message the bot privately" result in group/supergroup chats without issuing a web-auth code;
- checks whether `web_login_disabled != true` for the adapter channel;
- calls `BullXAccounts.issue_user_channel_auth_code/3`;
- returns a localized result including the code and `/sessions/new` URL.

`/ping`:

- returns a localized connectivity response.

`/ask`:

- publishes a canonical Gateway `SlashCommand` input.
- Requires non-empty prompt text after command stripping.
- Replies locally with a localized prompt-required message when prompt text is absent.

## 15. Duplicate Filtering

Published Telegram inbound events rely on Gateway's existing durable-backed dedupe.

Rules:

- Telegram message inputs use a derived canonical ID of `update_id:message_id`.
- Telegram `/ask` inputs use a derived canonical ID of `update_id:message_id:ask`.
- `BullXGateway.publish_inbound/1` builds the inbound signal and calls `BullXGateway.Deduper.seen?/2` before policy and bus publish.
- `BullXGateway.Deduper` stores truth in Gateway control-plane storage and uses ETS only as a hot cache.
- `dedupe_ttl_ms` remains a Gateway adapter config value read by `BullXGateway.AdapterRegistry.dedupe_ttl_ms/1`.
- `BullXTelegram.Cache` must not duplicate published-inbound dedupe.

Adapter-local direct commands do not enter Gateway, so they use best-effort direct-command result dedupe in `BullXTelegram.Cache`, keyed by Telegram update ID and bounded by `dedupe_ttl_ms`. This cache is intentionally restartable. Duplicate direct-command execution after restart must remain safe:

- `/ping` is idempotent.
- `/web_auth` may issue a newer web-auth code for the same already-bound actor.
- `/preauth` relies on `BullXAccounts.consume_activation_code/2` single-use and already-bound semantics.

## 16. Outbound Delivery

`BullXTelegram.Adapter.capabilities/0` returns:

```elixir
[:send, :edit, :stream, :threads]
```

### 16.1 Send

`:send` maps to Telegram `sendMessage` in `delivery.scope_id`.

Rules:

- Text content uses `body["text"]`.
- Non-text content uses `body["fallback_text"]`.
- Messages are split at Telegram's message length limit.
- Splitting must count Telegram's UTF-16 code units, not Elixir graphemes.
- `delivery.thread_id` maps to Telegram `message_thread_id` when present.
- `reply_to_external_id` maps to Telegram reply parameters when possible.
- If a reply reference is invalid or unavailable, the adapter sends without the reference and returns a degraded outcome with a warning.
- Link preview behavior is controlled by adapter config only if a concrete setting is added; otherwise defaults to Telegram behavior.

### 16.2 Edit

`:edit` maps to Telegram `editMessageText`.

Rules:

- Edits support text and fallback text only.
- Missing `target_external_id` returns a payload error.
- Edits that exceed Telegram limits are split only when the target is part of a known stream message set. Otherwise they return a payload error.
- A known stream message set is passed as `delivery.extensions["telegram"]["stream_message_ids"]`, ordered by Telegram message position. The adapter edits the retained IDs, creates missing trailing messages when the edited text grows, and deletes stale trailing messages when the edited text shrinks.
- Telegram "message is not modified" is treated as success.

### 16.3 Stream

`:stream` maps to one or more Telegram messages that are edited as chunks arrive.

Rules:

- The first stream chunk creates a message.
- Later chunks edit the active message no more often than `stream_update_interval_ms`.
- When accumulated text exceeds `stream_chunk_soft_limit`, the adapter creates additional messages in the same scope/thread.
- Finalization reconciles all stream messages to the final chunk set.
- If stream content is absent on DLQ replay, return `{:error, %{"kind" => "payload", ...}}`.
- Flood-control waits are honored when bounded. Long waits return a retryable transport error instead of blocking the ScopeWorker indefinitely.

## 17. Webhook Controller

Add route:

```text
POST /gateway/telegram/:channel_id/webhook
```

Controller behavior:

1. Validate `channel_id` as a safe route segment.
2. Look up `{:telegram, channel_id}` in `BullXGateway.AdapterRegistry`.
3. Normalize the adapter config.
4. Require `transport.mode == "webhook"`.
5. Verify `X-Telegram-Bot-Api-Secret-Token` with constant-time comparison.
6. Decode JSON body.
7. Dispatch the update to `BullXTelegram.Channel.handle_update/2`.
8. Return `200` for ignored, duplicate, direct-command, and successfully published updates.
9. Return `401` for missing or invalid secret.
10. Return `404` for unknown channel.
11. Return `500` for publish or transport errors that should be retried by Telegram.

The controller must not log the secret token or raw update body.

## 18. Setup Integration

`/setup` continues to persist the complete adapter array in `bullx.gateway.adapters`.

Telegram setup requirements:

- The connector catalog includes Telegram.
- The operator supplies `bot_token`.
- The operator chooses polling or webhook transport.
- Webhook mode shows the derived webhook URL as read-only information, not configuration.
- Webhook mode uses a BullX-generated `secret_token`.
- The generated secret is displayed for copy before save.
- Rotating the generated secret creates a new BullX-generated value, displays it for copy, and saves it through the same adapter-array write path.
- After save, public payloads show only secret status.
- Connectivity check verifies `getMe` but does not call `setWebhook`.
- Save writes the full adapter array and reconciles Gateway adapter channels.

Adding Telegram must not broaden setup beyond adapter configuration. The only shared setup behavior added by this RFC is support for fields declared with `type: :generated_secret` in RFC 0001.

## 19. Manual Run Support

Manual local runs must be observable from normal logs.

At `info` level:

- channel start requested: `channel`, `channel_id`, `transport`
- channel registered in `BullXGateway.AdapterRegistry`
- Telegram bot identity resolved
- polling started / webhook registered
- command menu sync result

At `warning` level:

- bot credentials missing or rejected
- webhook URL invalid
- webhook secret missing in webhook mode
- Telegram polling conflict
- polling reconnect retry
- account gate returns `:activation_required` or `:user_banned`

For every Telegram update that reaches mapping, log one safe inbound line with:

- `channel`
- `channel_id`
- `update_id`
- `message_id` when present
- `chat_id` when present
- `thread_id` when present
- `actor_id` when present

For every terminal inbound decision, log one safe result line:

- ignored self-sent bot message
- ignored attention policy
- direct command handled
- account activation required
- account denied
- published
- duplicate
- publish failed

Secrets, tokens, and raw message bodies must not be logged.

`/ping` is the built-in manual connectivity command. It must work before account activation, so an operator can verify Telegram inbound and outbound wiring before using `/preauth`.

## 20. Tests

Create:

```text
test/bullx_telegram/adapter_test.exs
test/bullx_telegram/config_test.exs
test/bullx_telegram/update_mapper_test.exs
test/bullx_telegram/content_mapper_test.exs
test/bullx_telegram/attention_policy_test.exs
test/bullx_telegram/direct_command_test.exs
test/bullx_telegram/delivery_test.exs
test/bullx_telegram/streamer_test.exs
test/bullx_telegram/poller_test.exs
test/bullx_telegram/commands_test.exs
test/bullx_telegram/locale_test.exs
test/bullx_web/controllers/telegram_webhook_controller_test.exs
```

Coverage must prove:

- config normalization resolves secrets and redacts inspect output;
- webhook mode requires a valid generated secret;
- polling mode does not require webhook secret;
- connectivity check calls `getMe` without starting polling or setting webhook;
- polling startup clears webhook before calling `getUpdates`;
- polling detects conflict errors;
- webhook controller rejects bad or absent secret headers;
- webhook controller dispatches authenticated updates to the channel;
- attention policy accepts DMs, commands, mentions, replies to bot, and configured free-response chats;
- attention policy rejects ignored chats and unaddressed groups;
- `/preauth` consumes activation codes only in private chats;
- `/web_auth` issues web auth codes only in private chats;
- `/ask` publishes `SlashCommand` input with prompt content;
- message mapping preserves `scope_id` and `thread_id`;
- text splitting uses UTF-16 code-unit limits;
- send/edit/stream return only valid Gateway delivery outcomes;
- `type: :generated_secret` catalog metadata is returned by AdapterConfig;
- setup redacts generated secrets after persistence;
- locale keys exist for all Telegram user-facing strings.

## 21. Implementation Order

1. Add the `visciang/telegram` dependency and Tesla adapter configuration.
2. Add `BullX.Config.GeneratedSecret` from RFC 0001.
3. Add `BullXTelegram.Config`, `Error`, and API test doubles.
4. Add `UpdateMapper`, `ContentMapper`, `AttentionPolicy`, and direct command handling.
5. Add outbound `Delivery` and `Streamer`.
6. Add `Channel` and `Poller`.
7. Add BullXWeb webhook route/controller.
8. Extend `BullXGateway.AdapterConfig` and setup UI for Telegram and `type: :generated_secret`.
9. Add locales and documentation links.
10. Run targeted tests, then `mix precommit`.

Deviations from this order are allowed only when they preserve the contracts above and are recorded in the implementation notes.
