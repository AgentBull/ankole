# Discord Adapter

The Discord Adapter connects one Discord bot application to one Agent binding.
Although Discord belongs to the `consumer_im` catalog category—which affects
only Console and catalog grouping—it implements the exact same Signals and
Conversations contracts as every other messaging adapter.

See [Signals](../Signals.md), [Conversations](../Conversations.md),
[Sessions](../Sessions.md), [Principal](../Principal.md), and
[Authentication](../Authentication.md) for the shared messaging and identity
contracts.

## Provider and Public Identity

On inbound events, the adapter reports an opaque `provider_conversation_id` and
`provider_message_id`, which `Conversations` resolves to a shared public
Conversation UUID and Message UUID. Every Agent observing that Discord channel
or thread within the same tenant reads those shared public records while running
in its own `conversation:<public UUID>` Session—a Binding defines an observation
and delivery route rather than owning the Discord channel.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `discord-adapter` |
| Signal adapter ID | `discord` |
| Adapter category | `consumer_im` |
| Signal configuration | `signals.discord.bindings.<id>` |
| REST client | Project `Req` client against API v10 |
| Gateway client | `IMTransport.WebSocket` through the Discord socket |

Configuration consists of a single required encrypted field, `botToken`, which
can belong to at most one enabled Discord binding. The REST client returns
Discord message IDs for durable reply checkpoints, and the Gateway owner
advances its session sequence watermark only after `Conversations` durably
accepts (or explicitly ignores) each event.

All three group-message policies are supported: `addressed_only`, `observe_all`,
and `may_intervene` (the latter two require Discord's privileged Message Content
Intent, described below). Inbound capabilities are `entry_receive`,
`reaction_add`, `reaction_remove`, and `action_event`; the adapter neither
declares `entry_removed` nor turns `MESSAGE_UPDATE` frames into new entries.
Outbound capabilities are `post_entry`, `reply_entry`, `edit_entry`,
`delete_entry`, `add_reaction`, `remove_reaction`, `divider`, and `card`,
without `outbound_reconciliation`.

## Connect through the Gateway

Each enabled binding supervises a single Gateway owner running one shard (bots
large enough to require multi-shard partitioning fall outside this single-socket
binding contract).

Before opening the WebSocket, the owner runs three REST preflight checks—`GET /users/@me`
for bot identity, `GET /applications/@me` for application flags, and
`GET /gateway/bot` for the Gateway URL—then connects, answers `HELLO` with
`IDENTIFY`, and schedules heartbeats with Discord's requested jitter. If Discord
stops acknowledging heartbeats, the owner treats the socket as a zombie and
replaces it.

Because Discord's Gateway has no per-event ACK—relying instead on `RESUME` to
replay everything after the client's last stored sequence number—the owner
updates its sequence number only after ingress commits or explicitly drops an
event. Queued events carry the Gateway session ID that delivered them so an
older session's worker task can never advance a newer session's sequence, while
`Signals` deduplicates any replayed events on durable source keys across socket
reconnects.

Event processing runs sequentially in a single supervised task while the Gateway
owner continues reading frames and answering heartbeats, preventing slow ingress
writes or large attachment downloads from starving heartbeats. To bound memory,
the local queue caps at 1,000 events: if the queue fills, the owner drops queued
events that `RESUME` can replay, preserves the in-flight task plus any events
from an earlier unresumable session, and reconnects so Discord replays from the
last confirmed sequence number.

Gateway close codes trigger three distinct recovery paths:

- **Operator-action codes (`4004`, `4010`–`4014`):** require fixing the bot
  token or Developer Portal settings, so the owner halts reconnect loops,
  surfaces the error reason, and re-runs preflight only every five minutes to
  stay well within Discord's daily `IDENTIFY` budget.
- **Session-invalidating codes (`4007`, `4009`):** keep the token valid while
  discarding the Gateway session, so the owner reconnects with a fresh
  `IDENTIFY`.
- **All other closes:** reconnect with `RESUME`, doubling backoff from 1 second
  up to 1 minute and resetting backoff only after `READY` or the next durably
  processed event—not on the `RESUME` handshake alone.

The connection reconciler tracks enabled bindings: rotating `botToken` replaces
the running owner, disabling or deleting a binding stops it, and control-plane
restarts rebuild active owners from persisted binding rows.

## Request Intents Honestly

The Gateway handshake requests `GUILD_MESSAGES`, `GUILD_MESSAGE_REACTIONS`,
`DIRECT_MESSAGES`, and `DIRECT_MESSAGE_REACTIONS`, omitting `GUILDS` because the
adapter maintains no local channel cache.

Because Discord closes the socket with `4014` whenever a bot requests an
unapproved privileged intent, the adapter sets the `MESSAGE_CONTENT` bit only
when `GET /applications/@me` confirms `GATEWAY_MESSAGE_CONTENT`. Without that
flag, Discord strips message text from unmentioned guild messages; the adapter
skips those empty payloads rather than mirroring blank entries, leaving direct
messages and @-mentioned guild messages working normally. To use `observe_all`
or `may_intervene` in guild channels, enable **MESSAGE CONTENT INTENT** in the
Discord Developer Portal.

If an operator configures an **Interactions Endpoint URL** in the Developer
Portal, Discord routes button clicks over HTTP instead of the Gateway WebSocket:
chat messages continue arriving over the Gateway, so the connection stays up,
but interactive buttons on Agent replies will not reach Ankole.

## Receive Messages

The adapter handles both direct messages (events without `guild_id`) and guild
channels or threads. Because each Discord thread gets its own
`provider_conversation_id`—combining the bot user ID and the Discord
channel/thread ID—threads map to separate public Conversations, with each
participating Agent running in its own Session.

Direct messages always count as explicit input; in guilds, @-mentioning the
current bot or replying to one of its messages counts as explicit input, while
other guild messages follow the binding's group-message policy. Only Discord
`DEFAULT` and `REPLY` message types are accepted—the adapter ignores its own
posts, other bots, webhooks, and system notices, strips `<@id>` bot-mention
markup so the Agent reads clean user prose, and drops sticker-only, embed-only,
or mention-only messages that have neither remaining text nor a file attachment.

## Admit Discord Identities

Inbound authors use provider namespace `discord` keyed by the immutable Discord
user snowflake; `username` and `global_name` serve purely as display hints
rather than identity keys or verified contact fields.

Each binding's `unmatched_sender_policy` (`manual_review` or
`create_standalone`) governs unknown senders:

- `manual_review`: sends the localized mapping notice to an unmatched addressed
  sender while `Conversations.IdentityAdmission` records a mapping request
  (without persisting the original message) so an administrator can bind that
  Discord snowflake to an existing Human Principal.
- `create_standalone`: provisions a new Human Principal and binds the Discord
  snowflake automatically.

## Materialize Attachments

For admitted messages with attachments, `Conversations` first commits the entry
with pending attachment metadata—ensuring unmapped senders never trigger CDN
downloads—and the adapter then fetches the file from Discord's CDN, writes it to
the file service ([Files](../Files.md)), and finalizes the entry. Because
Discord enforces no single global CDN download cap, Ankole enforces a 25 MB per-file
budget: larger attachments retain their provider metadata alongside a
`provider_download_limit` marker without creating a local file path or claiming
local readability.

## Send Replies and Actions

Using Discord message snowflakes as `provider_message_id`, the adapter supports
posting, replying (`fail_if_not_exists: false`, so replying to a deleted target
gracefully posts a standalone message), editing, deleting, adding and removing
reactions, posting dividers, and rendering interactive cards. Outbound files
upload in a single `multipart/form-data` request combining `payload_json` and
`files[n]` parts so text and attachments appear in one Discord message, and all
create and edit calls disable Discord mention parsing (`allowed_mentions`) so
Agent prose can never accidentally ping users, roles, or `@everyone`.

Mutable streaming replies own one or more Discord messages split at Discord's
2,000-character limit. After every create or edit, the adapter checkpoints the
active message IDs and rendered presentation on the source Signal so a restarted
node resumes editing the same messages in place, and terminal delivery updates
that existing surface instead of posting a duplicate answer. If a user deletes
one of the checkpointed preview messages (`404`), the adapter recovers cleanly
by posting a fresh message for that chunk.

Interactive card buttons pack into at most five action rows of up to five
buttons each (dropping excess actions rather than sending a payload that Discord
would reject outright). Each button's `custom_id` (capped at 100 bytes) carries
a compact lookup token rather than the full action payload. Because Discord
displays an interaction failure banner if a click is not acknowledged within
3 seconds, the Gateway owner dispatches a deferred interaction ACK as soon as
the frame arrives—even while an earlier message is still running—and then
processes the click in Gateway sequence order: resolving the checkpoint token,
mapping the clicking Discord snowflake to a Principal, verifying the binding and
message, and emitting `signal.action.invoked` (stale tokens from superseded
replies quietly no-op).

## Failures and Secrets

Because Discord message creation lacks caller-supplied idempotency keys and the
adapter does not reconcile uncertain sends, a transport drop or `5xx` error
during `POST`—or partway through a multi-chunk reply, or on a `2xx` response
missing a message ID—returns `unknown` so `Conversations` avoids unsafe
automatic retries. By contrast, edits, deletes, and reaction mutations are
idempotent and retryable on network or `5xx` failures, and `404` on edit or
delete counts as success because the target message is already gone. HTTP `429`
rate limits are retryable as well, rounding Discord's fractional-second
`retry_after` upward so sub-second waits still pause; auth/permission errors
require operator intervention, and `4xx` validation errors fail permanently.

`AppConfigure` stores `botToken` encrypted at rest. The adapter reads the raw
token only when building Gateway `IDENTIFY` and `RESUME` frames and HTTP
authorization headers—never logging or persisting it in connection status, error
records, or raw payloads—exposing only bot identity, session state, granted
intents, queue depth, and bounded error codes in public status views.

## Tests

Automated tests cover plugin declaration validation, single-binding token
ownership, Gateway intent and close-code handling, payload normalization,
preflight backoff, `retry_after` rounding, token rotation, ordered `RESUME`
replay, immediate interaction ACKs, message and reaction projection, sender
identity policies, the 25 MB attachment ceiling, file-service writes, replay
deduplication, button tokens, multipart/mention-safe outbound requests, and
`unknown` send classification. Live Discord end-to-end tests require an operator
bot token outside the repository.

Implementation paths:

- `plugins/discord_adapter/lib/ankole/plugins/discord_adapter.ex`
- `plugins/discord_adapter/lib/ankole/plugins/discord_adapter/`
