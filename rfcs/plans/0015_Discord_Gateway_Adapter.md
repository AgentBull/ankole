# RFC 0015: Discord Gateway Adapter and Web Login

**Status**: Implementation plan
**Author**: OpenAI Codex
**Created**: 2026-05-05
**Depends on**: RFC 0002, RFC 0003, RFC 0007, RFC 0008, RFC 0009, RFC 0014

## 1. Scope

Implement Discord as a first-class Gateway channel adapter for BullX.

The adapter handles:

- Discord Gateway inbound message events through Nostrum.
- Discord native application commands registered automatically by BullX.
- Message Content Intent for guild message content.
- Discord OAuth2 web login through BullXWeb and `BullXAccounts.login_from_provider/1`.
- Discord-specific `/ping`, `/preauth`, and `/web_auth` account commands.
- Discord `/ask` as a native application command that starts or addresses a BullX conversation.
- Automatic BullX-owned Discord thread creation for guild text-channel mentions and `/ask`.
- Outbound send, edit, and streaming delivery through the Gateway delivery contract.
- Text fallback for outbound media/card content through `fallback_text`.
- Localized human-facing Discord replies through `BullX.I18n`.

The adapter uses Nostrum `0.11.0-dev` pinned to a Git commit because that line exposes `Nostrum.Bot` as a supervised child and supports multiple bots. Hex currently publishes Nostrum `0.10.4`; this plan intentionally avoids that release because its global runtime shape does not match BullX's per-adapter supervision model.

## 2. Non-Goals

- Do not change the Gateway signal contract from RFC 0002.
- Do not change the Gateway delivery or DLQ contract from RFC 0003.
- Do not add a generic OAuth/OIDC framework to `BullXAccounts`.
- Do not persist Discord OAuth access tokens or refresh tokens.
- Do not introduce a separate OTP application.
- Do not hand-roll a Discord Gateway client.
- Do not implement outbound media upload. Media/card outbound content is sent as `fallback_text`.
- Do not implement Discord reactions, message deletion, or message edit inbound mapping in this plan.
- Do not enable unmentioned guild-channel listening by default. The adapter remains mention- or command-driven outside BullX-owned threads.
- Do not add Discord-specific PostgreSQL tables for adapter-local thread ownership state.

## 3. Cleanup Plan

### 3.1 What can be deleted

Nothing in the existing Gateway, Feishu, Accounts, Web, or Runtime implementation should be deleted for this adapter.

The implementation must avoid compatibility shims such as `BullXGateway.Adapters.Discord` unless an existing caller already requires that module name. The settled subsystem rule places channel adapter implementations in top-level namespaces, so Discord code belongs under `lib/bullx_discord/` as `BullXDiscord.*`.

### 3.2 Existing utilities and patterns to reuse

- `BullXGateway.Adapter` behaviour.
- `BullXGateway.AdapterSupervisor` and `BullXGateway.AdapterRegistry`.
- `BullXGateway.publish_inbound/1`.
- `BullXGateway.Deduper` for durable-backed inbound dedupe after the adapter publishes canonical inputs.
- `BullXGateway.Inputs.Message` and `BullXGateway.Inputs.SlashCommand`.
- `BullXGateway.Delivery`, `BullXGateway.deliver/1`, ScopeWorker serialization, DLQ, and telemetry.
- `BullXGateway.Delivery.Content` fallback-text validation.
- `BullXAccounts.match_or_create_from_channel/1`, `consume_activation_code/2`, `issue_user_channel_auth_code/3`, and `login_from_provider/1`.
- `BullX.I18n.t/3` and locale TOML files.
- BullXWeb session helpers and Feishu web-login route patterns from RFC 0009.
- Feishu adapter account-gate behavior: adapter-local account checks happen before `BullXGateway.publish_inbound/1`, and unbound actors receive a localized activation prompt.
- Hermes Discord adapter behavior for attention policy, safe slash-command sync, ephemeral slash acknowledgements, auto-threading, and safe allowed mentions.
- `Req` for Discord OAuth2 HTTP token and userinfo calls.
- Nostrum's REST API, event consumer, Gateway intents, and per-bot supervision APIs.

### 3.3 Code paths changing

- Add a new top-level channel adapter namespace: `BullXDiscord.*`.
- Add one dependency on Nostrum pinned to a Git commit.
- Add BullXWeb routes and a thin Discord login controller for OAuth2 browser login.
- Replace Feishu-only session provider URL helpers with provider-qualified helpers.
- Extend `BullXWeb.Sessions.login_providers/0` to include Feishu and Discord providers on equal terms.
- Extend Gateway setup/configuration code so `bullx.gateway.adapters` can store Feishu and Discord JSON-safe entries.
- Extend the setup UI in `webui/src/apps/setup/App.tsx` with Discord adapter fields.
- Add Discord translation keys to `priv/locales/en-US.toml` and `priv/locales/zh-Hans-CN.toml`.
- Add Discord adapter configuration examples without changing Gateway core configuration shape.

### 3.4 Invariants

- The Gateway core remains transport-agnostic.
- Discord actor identities remain channel-local until `BullXAccounts` resolves or links them.
- Adapter process state is ephemeral and reconstructible. BullX-owned thread membership is reconstructed from Discord thread metadata and may be cached only as discardable adapter-local state.
- Inbound events are published only after adapter attention policy, duplicate filtering, and account handling.
- Unbound Discord actors do not reach Runtime. They receive a localized account-binding prompt from the adapter.
- Adapter-local commands do not enter the Runtime signal stream.
- Message Content Intent is required and must be included in Nostrum Gateway intents.
- OAuth tokens are used only inside the callback exchange and are not persisted.
- Discord profile email is stored only when Discord returns `verified == true` and a non-empty `email`.
- Human-facing Discord text is localized through `BullX.I18n`; adapter modules must not hard-code operator/user messages.
- Outbound delivery preserves per-scope serialization through RFC 0003 ScopeWorkers.
- Adapter success paths return only `{:ok, %BullXGateway.Delivery.Outcome{status: :sent | :degraded, error: nil}}`. Adapter failures return `{:error, error_map}`. The adapter must never return `{:ok, %Outcome{status: :failed}}`.
- Adapter error maps are JSON-neutral string-keyed maps. `error["kind"]` is a string and optional retry hints live under `error["details"]`.
- Discord message sends use safe allowed-mentions defaults: no `@everyone`, no role mentions, user mentions allowed, replied-user mentions allowed.
- Stream delivery is required. If the adapter cannot stream a delivery, it returns a payload or transport error instead of silently downgrading to final-only send.

### 3.5 Verification command

Run:

```bash
mix deps.get
mix test test/bullx_discord test/bullx_web/controllers/discord_auth_controller_test.exs test/bullx_web/sessions_test.exs
mix test test/bullx_gateway/adapter_config_test.exs test/bullx_accounts/authn_test.exs
mix precommit
```

## 4. Subsystem Placement

Discord is a Gateway channel adapter, not a new BullX subsystem. It is implemented in a top-level namespace because channel adapters are first-class integrations parallel to the Gateway core implementation.

Files live under:

```text
lib/bullx_discord/
test/bullx_discord/
```

The public adapter module is:

```elixir
BullXDiscord.Adapter
```

It implements `BullXGateway.Adapter` and is configured as:

```elixir
{{:discord, "default"}, BullXDiscord.Adapter, config}
```

Only browser login callbacks touch `BullXWeb`, because web login must use Phoenix cookie sessions.

## 5. Dependency

Add Nostrum from Git and pin the dependency to the reviewed commit:

```elixir
{:nostrum,
 github: "Kraigie/nostrum",
 ref: "03b06ba1c5094b83991097b1ce76b5fe2740324c"}
```

The pin targets Nostrum `0.11.0-dev` as of 2026-05-05. Do not track `master` without a commit pin.

This dependency choice is deliberate:

- `0.11.0-dev` exposes `Nostrum.Bot` as a child spec.
- `0.11.0-dev` supports multiple supervised bots.
- BullX can keep Discord runtime under each configured adapter channel rather than relying on global Nostrum application config.
- The cost is depending on an unreleased Git snapshot. The explicit commit pin is the control for that cost.

## 6. Module Plan

Create:

```text
lib/bullx_discord.ex
lib/bullx_discord/adapter.ex
lib/bullx_discord/channel.ex
lib/bullx_discord/config.ex
lib/bullx_discord/consumer.ex
lib/bullx_discord/cache.ex
lib/bullx_discord/event_mapper.ex
lib/bullx_discord/attention_policy.ex
lib/bullx_discord/application_commands.ex
lib/bullx_discord/direct_command.ex
lib/bullx_discord/delivery.ex
lib/bullx_discord/streamer.ex
lib/bullx_discord/thread_ownership.ex
lib/bullx_discord/sso.ex
lib/bullx_discord/error.ex
```

`BullXDiscord.Channel` owns the supervised Discord runtime for one configured BullX adapter channel. Its children include a `Nostrum.Bot` child configured with a stable bot name, token, consumer, and Gateway intents.

`BullXDiscord.Consumer` is the Nostrum consumer. It receives Discord events, delegates normalization to `BullXDiscord.EventMapper`, handles adapter-local direct commands, runs the account gate, and publishes only account-accepted canonical inputs to Gateway.

`BullXDiscord.Cache` owns adapter-local TTL cache needs. It stores direct-command interaction results and thread-ownership lookups. The cache is a restartable accelerator, not durable truth.

`BullXDiscord.EventMapper` converts Discord messages and interactions into Gateway input structs. It owns profile extraction, mention stripping, and the early self-message filter.

`BullXDiscord.AttentionPolicy` decides whether a Discord event should enter BullX. This module is intentionally isolated so that a separately approved free-response mode can be added without changing signal shape, scope rules, or Runtime routing.

`BullXDiscord.ApplicationCommands` owns desired command definitions and safe reconciliation against Discord. It must not bulk overwrite commands by default.

`BullXDiscord.DirectCommand` owns `/ping`, `/preauth`, and `/web_auth`. These commands are handled before Gateway inbound publish, matching Feishu's adapter-local command boundary.

`BullXDiscord.ThreadOwnership` decides whether a Discord thread is BullX-owned by reading Discord channel metadata. It must not write ownership facts to PostgreSQL.

`BullXDiscord.Streamer` owns streaming message state: Discord message IDs, accumulated text, chunk boundaries, edit throttling, and finalization.

`BullXDiscord.SSO` owns Discord OAuth2 URL construction, token exchange, userinfo fetching, and provider-input normalization.

There is no generic `BullXDiscord.API` wrapper. Adapter modules call Nostrum and `Req` directly, with `BullXDiscord.Error` handling error normalization. Tests use pure mappers and small injectable function/module options only where an external boundary must be controlled.

## 7. Supervision and Runtime

`BullXDiscord.Adapter.child_specs/2` returns one `BullXDiscord.Channel` child for the configured `{adapter, channel_id}`.

`BullXDiscord.Channel` starts `Nostrum.Bot` under the adapter channel supervisor with:

- a stable per-channel bot name;
- the configured bot token;
- `BullXDiscord.Consumer` as the consumer;
- Gateway intents including guild messages, direct messages, guilds, and message content;
- cache settings kept to the minimum needed for message and channel routing.

All Nostrum REST calls that depend on bot context must execute under the configured bot context, using Nostrum's per-bot API. A Discord adapter must not rely on process-global Nostrum bot selection.

The supervision boundary is one Discord bot runtime per configured BullX Discord adapter channel. A bot crash restarts only that adapter channel supervisor, not Gateway core or other adapters.

## 8. Configuration

Discord adapter configuration is passed through the RFC 0002 Gateway adapter spec.

Example:

```elixir
config :bullx, :gateway,
  adapters: [
    {{:discord, "default"}, BullXDiscord.Adapter,
     %{
       application_id: {:system, "BULLX_DISCORD_APPLICATION_ID"},
       bot_token: {:system, "BULLX_DISCORD_BOT_TOKEN"},
       client_secret: {:system, "BULLX_DISCORD_CLIENT_SECRET"},
       dedupe_ttl_ms: :timer.minutes(5),
       thread_ownership_cache_ttl_ms: :timer.hours(24),
       stream_update_interval_ms: 1_000,
       stream_chunk_soft_limit: 1_850,
       web_login_disabled: false,
       auto_thread: %{
         enabled: true,
         auto_archive_duration_minutes: 1440,
         no_thread_channel_ids: []
       },
       attention: %{
         allowed_channel_ids: [],
         ignored_channel_ids: [],
         require_mention: true
       },
       sso: %{
         scopes: ["identify", "email"]
       },
       application_commands: %{
         sync_policy: "safe"
       }
     }}
  ]
```

Required keys:

- `:application_id`
- `:bot_token`

Required when `web_login_disabled != true`:

- `:client_secret`

Optional keys:

- `:dedupe_ttl_ms`: inbound dedupe TTL, default `5 minutes`.
- `:thread_ownership_cache_ttl_ms`: in-memory thread ownership cache TTL, default `24 hours`.
- `:stream_update_interval_ms`: Discord message edit throttle interval, default `1000 ms`.
- `:stream_chunk_soft_limit`: soft text length limit before opening another Discord message, default `1850`.
- `:auto_thread.enabled`: create BullX-owned threads on guild text-channel mentions and `/ask`, default `true`.
- `:auto_thread.auto_archive_duration_minutes`: Discord thread auto-archive duration, default `1440`.
- `:auto_thread.no_thread_channel_ids`: Discord channel IDs where replies stay in the channel.
- `:attention.allowed_channel_ids`: optional allowlist. If empty, all non-ignored channels are eligible.
- `:attention.ignored_channel_ids`: channels that never enter BullX, even when mentioned.
- `:attention.require_mention`: guild channels require `@bot` or a native command unless the message is in a BullX-owned thread. Default `true`.
- `:web_login_disabled`: disables Discord web login when `true`, default `false`.
- `:sso.scopes`: OAuth2 scopes, default `["identify", "email"]`.
- `:application_commands.sync_policy`: `"safe"` or `"off"`, default `"safe"`.

`attention.require_mention: false` is not accepted by this plan. The configuration shape reserves a clear location for free-response mode, but this plan implements only mention-, command-, DM-, and BullX-owned-thread-driven attention.

Configuration resolution must use the existing BullX config style, including system env indirection. Secrets must not be logged.

## 9. Setup Persisted Shape

When `/setup` saves Discord from the React wizard, the browser submits the RFC 0002 JSON-neutral adapter-array shape:

```json
[
  {
    "id": "discord:default",
    "enabled": true,
    "adapter": "discord",
    "channel_id": "default",
    "credentials": {
      "application_id": "123456789012345678",
      "bot_token": "write-only",
      "client_secret": "write-only"
    },
    "web_login_disabled": false,
    "attention": {
      "allowed_channel_ids": [],
      "ignored_channel_ids": [],
      "require_mention": true
    },
    "auto_thread": {
      "enabled": true,
      "auto_archive_duration_minutes": 1440,
      "no_thread_channel_ids": []
    },
    "advanced": {
      "dedupe_ttl_ms": 300000,
      "thread_ownership_cache_ttl_ms": 86400000,
      "stream_update_interval_ms": 1000,
      "stream_chunk_soft_limit": 1850,
      "application_commands_sync_policy": "safe"
    }
  }
]
```

`BullXGateway.AdapterConfig` must generalize the existing Feishu-specific code path:

- `default_entry/1` supports `"feishu"` and `"discord"`.
- `catalog/1` returns both adapters.
- secret redaction includes `bot_token` and `client_secret`.
- runtime spec building dispatches by adapter.
- connectivity checks dispatch to the selected adapter module.

## 10. Native Application Commands

BullX automatically registers Discord native application commands for:

- `/ping`
- `/preauth` with one required string option for the activation code
- `/web_auth`
- `/ask prompt:<string>`

Registration uses safe reconciliation:

- Fetch existing global commands for the application.
- Compare only the command names and command payload fields owned by BullX.
- Create missing commands.
- Edit changed commands.
- Delete commands previously owned by BullX but removed from desired definitions.
- Do not bulk overwrite all application commands.

The sync runs after the Discord bot reaches ready state. Failure to sync commands logs a warning and leaves the bot running; inbound message handling and outbound delivery still work.

Command handling:

- `/ping` is adapter-local and returns a localized connectivity response.
- `/preauth` is adapter-local and calls `BullXAccounts.consume_activation_code/2`.
- `/web_auth` is adapter-local and calls `BullXAccounts.issue_user_channel_auth_code/3`.
- `/ask` publishes a canonical Gateway `SlashCommand` input and may create a BullX-owned thread before publish.

Interaction response policy follows Hermes:

- Unauthorized command attempts receive an ephemeral rejection.
- Adapter-local command responses are ephemeral because they may contain account-linking status or web-auth codes.
- `/ask` sends an ephemeral acknowledgement or thread link, then the BullX answer is delivered through Gateway to the selected scope.
- Component/button authorization failures are ephemeral.

## 11. Attention Policy

Discord attention policy is user-facing behavior, not a technical Discord channel taxonomy.

An inbound Discord event enters BullX when one of these conditions is true:

- It is a DM message from an allowed human actor.
- It is a native application command.
- It is a guild text-channel message that mentions the bot.
- It is a message inside a BullX-owned thread.

An inbound Discord event does not enter BullX when:

- it was authored by the configured bot;
- it was authored by another bot;
- it is in an ignored channel;
- it is outside an allowlist when an allowlist is configured;
- it is an unmentioned ordinary guild-channel message;
- it is an unmentioned message inside a Discord thread not owned by BullX.

The event mapper must annotate accepted events with an attention reason under `event.data["discord"]["attention_reason"]` using one of:

- `"dm"`
- `"mention"`
- `"application_command"`
- `"owned_thread"`

The signal shape deliberately leaves room for a separately approved `"free_response"` reason without changing scope identity, delivery identity, or Runtime session keys.

### 11.1 Account Gate

Attention policy decides whether the Discord event is addressed to BullX. It does not decide whether the actor may enter Runtime.

After mapping and before `BullXGateway.publish_inbound/1`, `BullXDiscord.Consumer` must run the same account gate shape used by Feishu:

```elixir
config.accounts_module.match_or_create_from_channel(mapped.account_input)
```

Outcomes:

- `{:ok, _user, _binding}`: publish the mapped Gateway input.
- `{:error, :activation_required}`: do not publish; reply locally through the Feishu-aligned activation-required path described below.
- `{:error, :user_banned}`: do not publish; reply locally with the localized denied message.
- other errors: do not publish; return a normalized adapter error.

The activation-required prompt must not generate, reveal, or include an activation code or web-auth code. The activation code is created outside the Discord adapter, typically by bootstrap/setup or an authorized operator, and the user supplies that existing code to `/preauth`.

The prompt text follows Feishu's private-chat split:

- Discord DM: use the normal localized activation-required guidance with `/preauth <code>`.
- Discord guild channel or guild thread: use the localized "message the bot privately" guidance and do not mention activation-code syntax.

For native `/ask`, the activation prompt is an ephemeral interaction response. For a mention-based guild message, the prompt is a localized reply to the triggering Discord message. DMs receive a normal DM reply.

`/preauth`, `/web_auth`, and `/ping` bypass this account gate because they are adapter-local direct commands. `/preauth` is the path that binds an unbound Discord actor by calling `BullXAccounts.consume_activation_code/2`.

## 12. Discord Thread Scope Contract

`scope_id` is the user-visible conversation surface where BullX is expected to respond.

Rules:

- DM: `scope_id = dm_channel_id`, `thread_id = nil`.
- Guild text channel without auto-threading: `scope_id = channel_id`, `thread_id = nil`.
- BullX-created thread: `scope_id = thread_channel_id`, `thread_id = nil`.
- Existing Discord thread or forum post: `scope_id = thread_channel_id`, `thread_id = nil`.

Parent guild/channel/thread metadata belongs in `event.data["discord"]` and `refs`, not in `scope_id`.

This contract means BullX Runtime sessions naturally follow the conversation users see in Discord. A BullX-owned Discord thread is the scope. It is not represented as a parent `scope_id` plus nested `thread_id` because that would make the visible conversation share ordering and session identity with the parent channel.

## 13. Auto-Threading

Auto-threading is enabled by default for guild text-channel mentions and `/ask`.

Behavior:

- DMs never create threads.
- Messages already inside Discord threads do not create nested threads.
- Channels listed in `auto_thread.no_thread_channel_ids` reply directly in the channel.
- When a guild text-channel mention is accepted and auto-threading is enabled, the adapter creates a Discord thread from the triggering message.
- When `/ask` is invoked in a guild text channel and auto-threading is enabled, the adapter creates a Discord thread for the request.
- The triggering input is published with `scope_id` set to the created thread channel ID.
- Follow-up messages inside that BullX-owned thread do not need to mention the bot.
- Ordinary parent-channel messages and non-BullX-owned threads still require mention or a native command.

If thread creation fails, the adapter returns an ephemeral localized error for native `/ask` or a localized reply to the triggering message for mention-based entry. It must not silently fall back to a parent-channel conversation, because that changes the visible user story from a scoped conversation to a channel-wide conversation.

### 13.1 Thread Ownership Without BullX Persistence

Hermes persists participated Discord thread IDs in local JSON so follow-up behavior survives process restart. BullX should not copy that storage shape into PostgreSQL, because BullX-owned thread membership is adapter-local Discord behavior, not a cross-adapter BullX domain object.

BullX uses Discord itself as the source of truth:

- When BullX creates a thread, the adapter immediately caches that thread ID as BullX-owned in `BullXDiscord.Cache`.
- On restart, the cache is empty.
- When a message arrives in a Discord thread that is not in cache, `BullXDiscord.ThreadOwnership` resolves the thread through the event payload, Nostrum cache, or a bounded Discord REST fetch.
- A thread is BullX-owned when Discord reports the thread creator/owner as the configured bot user.
- If ownership cannot be resolved, attention policy fails closed and the message must mention the bot or use a native command.

The thread-ownership portion of `BullXDiscord.Cache` is in-memory only. It may be ETS-backed inside the adapter channel process tree, keyed by `{channel_id, thread_channel_id}`, with a bounded TTL. It must not be treated as the system of record.

This is a deliberate weaker guarantee than writing a BullX-owned marker to PostgreSQL. It avoids adapter-specific schema and keeps the behavior reconstructible from the external system that owns the thread. The risk is that another feature using the same Discord bot could create a non-BullX conversational thread and be treated as BullX-owned. That is acceptable under this plan because the Discord adapter is the only component creating threads with that bot. If that changes, the new feature must introduce an explicit Discord-side marker or a separately approved generic Gateway scope-state table.

## 14. OAuth2 Web Login

Discord OAuth2 web login is equal to Feishu OIDC web login in BullXWeb.

Web login is enabled unless the adapter config sets `web_login_disabled: true`. There is no separate `sso.enabled` flag.

Routes become provider-qualified:

```text
GET /sessions/:provider/:channel_id
GET /sessions/:provider/:channel_id/callback
```

Feishu and Discord login providers are both discovered by `BullXWeb.Sessions.login_providers/0`.

Discord flow:

1. `BullXWeb.DiscordAuthController.new/2` validates provider/channel, creates state, builds callback URL, and redirects to Discord OAuth2 authorization.
2. Discord redirects back with `code` and `state`.
3. `BullXDiscord.SSO.login_from_callback/2` exchanges the code with `Req`.
4. `BullXDiscord.SSO` fetches `GET /users/@me`.
5. `BullXDiscord.SSO` builds provider input and calls `BullXAccounts.login_from_provider/1`.
6. The Phoenix session is renewed and `:user_id` is set.

OAuth2 scopes:

```text
identify email
```

Provider input:

```elixir
%{
  provider: :discord,
  provider_user_id: discord_user_id,
  adapter: :discord,
  channel_id: config.channel_id,
  external_id: "discord:" <> discord_user_id,
  profile: profile,
  metadata: metadata
}
```

Profile handling:

- `display_name` prefers `global_name`, then `username`.
- `email` is included only when `verified == true` and `email` is a non-empty string.
- `avatar_url` is built only when Discord returns an avatar hash.
- `locale` is metadata, not a BullX locale selector.

`/web_auth` remains because Feishu keeps the same command. It issues a BullX web-auth code for an already bound Discord actor and points the user at `/sessions/new`, matching the existing account-linking model.

## 15. Inbound Mapping

Accepted Discord messages map to `BullXGateway.Inputs.Message`.

Accepted `/ask` invocations map to `BullXGateway.Inputs.SlashCommand`.

Mapped inputs are published only after the Account Gate in Section 11.1 succeeds. An unbound actor never reaches Runtime as an ownerless actor.

Common fields:

- `source`: `discord:<channel_id>`.
- `channel`: `{:discord, config.channel_id}`.
- `scope_id`: the Discord visible conversation surface from Section 12.
- `thread_id`: always `nil` for Discord threads because a Discord thread is modeled as the scope.
- `actor.id`: `"discord:" <> user_id`.
- `actor.display_name`: Discord display name.
- `reply_channel.adapter`: `"discord"`.
- `reply_channel.channel_id`: BullX adapter channel ID.
- `reply_channel.scope_id`: same as input `scope_id`.
- `reply_channel.thread_id`: `nil`.
- `reply_to_external_id`: triggering Discord message ID when available.
- `content`: text block from message content or `/ask` prompt.
- `refs`: Discord message, channel, guild, parent channel, and thread references.
- `event.data["discord"]`: Discord-specific JSON-neutral metadata.

The mapper strips the bot mention from content before publishing. Empty content after mention stripping is skipped with telemetry.

## 16. Direct Commands

`/ping`, `/preauth`, and `/web_auth` are adapter-local.

They intentionally keep account-linking side effects outside the Runtime signal stream, matching Feishu.

`/preauth`:

- accepts a required activation code argument;
- is valid only in Discord DMs;
- returns the localized "message the bot privately" result in guild channels or guild threads without consuming the activation code;
- uses the Discord actor external ID;
- calls `BullXAccounts.consume_activation_code/2`;
- returns a localized ephemeral result.

`/web_auth`:

- is valid only in Discord DMs;
- returns the localized "message the bot privately" result in guild channels or guild threads without issuing a web-auth code;
- checks whether `web_login_disabled != true` for the adapter channel;
- calls `BullXAccounts.issue_user_channel_auth_code/3`;
- returns a localized ephemeral result including the code and `/sessions/new` URL.

`/ping`:

- returns a localized ephemeral connectivity response.

## 17. Duplicate Filtering

Published Discord inbound events rely on Gateway's existing durable-backed dedupe.

Rules:

- Discord message inputs use the Discord message ID as the canonical input ID.
- Discord `/ask` inputs use the Discord interaction ID as the canonical input ID.
- `BullXGateway.publish_inbound/1` builds the inbound signal and calls `BullXGateway.Deduper.seen?/2` before policy and bus publish.
- `BullXGateway.Deduper` stores truth in Gateway control-plane storage and uses ETS only as a hot cache.
- `dedupe_ttl_ms` remains a Gateway adapter config value read by `BullXGateway.AdapterRegistry.dedupe_ttl_ms/1`.
- `BullXDiscord.Cache` must not duplicate published-inbound dedupe.

Adapter-local direct commands do not enter Gateway, so they use best-effort interaction-result dedupe in `BullXDiscord.Cache`, keyed by Discord interaction ID and bounded by `dedupe_ttl_ms`. This cache is intentionally restartable. Duplicate direct-command execution after restart must remain safe:

- `/ping` is idempotent.
- `/web_auth` may issue a newer web-auth code for the same already-bound actor.
- `/preauth` relies on `BullXAccounts.consume_activation_code/2` single-use and already-bound semantics.

## 18. Outbound Delivery

`BullXDiscord.Adapter.capabilities/0` returns:

```elixir
[:send, :edit, :stream, :threads]
```

### 18.1 Send

`:send` maps to Discord message creation in `delivery.scope_id`.

Rules:

- Text content uses `body["text"]`.
- Non-text content uses `body["fallback_text"]`.
- Messages are split at Discord's message length limit.
- Safe allowed-mentions defaults are applied to every send.
- `reply_to_external_id` is used as a Discord message reference when possible.
- If a reply reference is invalid or unavailable, the adapter sends without the reference and returns a degraded outcome with a warning.

### 18.2 Edit

`:edit` maps to Discord message edit using `delivery.target_external_id`.

Rules:

- Edits support text and fallback text only.
- Missing `target_external_id` returns a payload error.
- Edits that exceed Discord limits are split only when the target is part of a known stream message set. Otherwise they return a payload error.

### 18.3 Stream

`:stream` is required.

Behavior:

- Wait for the first visible text delta before creating the first Discord message.
- Edit the active Discord message no more often than `stream_update_interval_ms`, default `1000 ms`.
- Keep accumulated text in adapter process state only while the stream is active.
- When the active message approaches `stream_chunk_soft_limit`, finalize it and create the next Discord message.
- On final replacement, replace accumulated stream text with the final answer and re-chunk as needed.
- Return all Discord message IDs in `Outcome.external_message_ids`.
- Set `Outcome.primary_external_id` to the first Discord message ID.

If stream content is absent during DLQ replay, return `{:error, %{"kind" => "payload", ...}}`.

## 19. Connectivity Check

`BullXDiscord.Adapter.connectivity_check/2` validates:

- required config fields;
- bot token can call Discord as the bot;
- configured application ID matches the bot application when Discord exposes that relationship;
- OAuth2 client secret is present when `web_login_disabled != true`;
- command sync policy is valid;
- Message Content Intent is documented as required in the result metadata.

Connectivity check must not start the long-lived Gateway connection. It performs bounded REST checks and returns JSON-neutral metadata.

## 20. Security and Privacy

- Bot token and OAuth client secret are write-only setup fields.
- No token is logged.
- No OAuth token is persisted.
- Discord email is ignored unless verified by Discord.
- Ephemeral responses are used for account-linking commands and authorization failures.
- `@everyone` and role mentions are disabled by default for outbound messages.
- Inbound unmentioned guild messages are ignored by default.
- Thread-ownership cache stores thread IDs and ownership decisions only in memory, not message content.
- Logs include safe IDs and event kinds, not message bodies by default.

## 21. Web and Setup Modules

Create:

```text
lib/bullx_web/controllers/discord_auth_controller.ex
test/bullx_web/controllers/discord_auth_controller_test.exs
```

Modify:

```text
lib/bullx_web/router.ex
lib/bullx_web/sessions.ex
lib/bullx_web/controllers/feishu_auth_controller.ex
lib/bullx_web/controllers/setup_gateway_controller.ex
webui/src/apps/setup/App.tsx
priv/locales/en-US.toml
priv/locales/zh-Hans-CN.toml
priv/locales/client/en-US.toml
priv/locales/client/zh-Hans-CN.toml
```

Route helpers:

- replace `callback_url(channel_id)` with `callback_url(provider, channel_id)`;
- replace provider hrefs like `/sessions/#{channel_id}` with `/sessions/#{provider}/#{channel_id}`;
- keep `/sessions/new` as the provider picker and web-auth-code entry point.

## 22. Tests

Add focused tests for:

- Discord config normalization and JSON-safe setup persistence.
- Discord connectivity-check config validation.
- Attention policy for DM, mention, application command, owned thread, ignored channel, and unmentioned guild text.
- Account gate behavior for bound actors, activation-required actors, banned actors, native `/ask`, mention-based messages, and direct-command bypass.
- Scope mapping for DM, guild channel, BullX-created thread, existing thread, and forum post.
- Thread ownership resolution from Discord metadata, cache hit, cache miss, and fail-closed behavior.
- Gateway-backed published-inbound dedupe and adapter-local direct-command dedupe.
- Native command definitions and safe command reconciliation planning.
- Direct command behavior for `/ping`, `/preauth`, `/web_auth`, and non-DM rejection for account-linking commands.
- OAuth2 callback success, invalid state, missing code, unbound actor, banned user, and unverified email handling.
- Delivery content mapping for text and fallback text.
- Stream chunking, throttled edits, final replacement, and missing stream replay.
- Safe allowed-mentions options.

Use pure unit tests for mappers and policy. Use small fake modules/functions for Nostrum and Discord HTTP boundaries rather than opening real Discord connections in test.

## 23. References

- Nostrum `Nostrum.Bot` documentation: https://kraigie.github.io/nostrum/Nostrum.Bot.html
- Nostrum Hex package: https://hex.pm/packages/nostrum
- Nostrum pinned commit: https://github.com/Kraigie/nostrum/commit/03b06ba1c5094b83991097b1ce76b5fe2740324c
- Discord User Resource, Get Current User: https://docs.discord.com/developers/resources/user#get-current-user
- Hermes Discord adapter reference: `/Users/ding/Projects/hermes-agent/gateway/platforms/discord.py`
