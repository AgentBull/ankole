# Telegram Adapter

The Telegram Adapter connects one Telegram Bot to one Agent binding. Although
Telegram belongs to the `consumer_im` catalog category—which affects only
Console and catalog grouping—it implements the exact same `Signals` and
`Conversations` contracts as every other messaging adapter.

See [Signals](../Signals.md), [Conversations](../Conversations.md),
[Sessions](../Sessions.md), [Principal](../Principal.md), and
[Authentication](../Authentication.md) for the shared messaging and identity
contracts.

## Provider and Public Identity

On inbound updates, the adapter reports an opaque `provider_conversation_id` and
`provider_message_id`, which `Conversations` resolves to a shared public
Conversation UUID and Message UUID. Every Agent observing that Telegram chat or
forum topic within the same tenant reads those shared public records while
running in its own `conversation:<public UUID>` Session—a Binding defines an
observation and delivery route rather than owning the Telegram chat.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `telegram-adapter` |
| Signal adapter ID | `telegram` |
| Adapter category | `consumer_im` |
| Signal configuration | `signals.telegram.bindings.<id>` |
| Bot API client | Project `Req` client |

Configuration consists of a single required encrypted field, `botToken`, which
can belong to at most one enabled Telegram binding. The Bot API client returns
Telegram message IDs for durable reply checkpoints, and the long-poll worker
confirms each `update_id` only after `Conversations` durably accepts (or
explicitly ignores) the update.

All three group-message modes (`addressed_only`, `observe_all`, and
`may_intervene`) are supported. Inbound capabilities are `entry_receive`,
`reaction_add`, `reaction_remove`, and `action_event`; because standard Telegram
Bot API updates omit message-deletion events, the adapter does not declare
`entry_removed`, nor does it turn `edited_message` updates into new entries.
Outbound capabilities are `post_entry`, `reply_entry`, `edit_entry`,
`delete_entry`, `add_reaction`, `remove_reaction`, `divider`, and `card`,
without `outbound_reconciliation`.

## Connect through Long Polling

Each enabled binding supervises a dedicated long-poll owner process. Before
polling, the owner runs `getMe` and `getWebhookInfo`: if an active webhook is
registered on the bot, long polling cannot proceed, so the owner reports
`webhook_configured` and re-checks periodically without deleting a webhook
configuration owned by another operator or service.

During normal operation, the owner calls `getUpdates` with a positive timeout,
processes updates sequentially in `update_id` order, and advances its in-memory
offset only after durable ingress commits or the update is explicitly ignored.
If the control plane crashes before advancing the offset, Telegram redelivers
the update and `Signals` deduplicates it on durable source keys. Rotating
`botToken` replaces the running owner, disabling or deleting a binding stops it,
and control-plane restarts rebuild active owners from persisted binding rows.

## Receive Messages

The adapter accepts 1-on-1 private chats, groups, supergroups, and forum topics.
`provider_conversation_id` combines the Bot ID and chat ID, appending
`message_thread_id` inside forum supergroups so each forum topic runs in its own
Agent Session. Because Telegram reaction updates omit `message_thread_id`, the
adapter looks up the target message's stored conversation before recording a
reaction—falling back to the base chat if no reference exists, and failing
ingress on any database error (leaving the update unconfirmed for retry rather
than misrouting a forum-topic reaction into the base chat).

Private 1-on-1 messages always count as explicit input; in groups and
supergroups, structured @-mentions of the current Bot, `/command@bot` commands,
and replies to messages sent by the current Bot count as explicit input, while
other group messages follow the binding's group-message policy. Channel posts,
Telegram Business messages, anonymous/guest senders, bot authors, and inline
`via_bot` messages are ignored.

Entity offsets in Telegram text and media captions use UTF-16 code units, which
the adapter converts cleanly without splitting supplementary Unicode code
points. Plain text, captions, locations, shared contacts, polls, photos,
documents, audio, voice notes, video, video notes, animations, and stickers all
project into the shared `Conversations` entry format.

## Admit Telegram Identities

Inbound senders use provider namespace `telegram` keyed by the decimal Telegram
`User.id`; `username`, display names, and `language_code` act purely as UI
hints rather than identity keys or verified contact fields.

Under each binding's `unmatched_sender_policy`:

- `manual_review`: sends the localized mapping notice to an unmatched addressed
  sender while `Conversations.IdentityAdmission` records a mapping request
  (without storing the original message) so an administrator can bind that
  Telegram `User.id` to an existing Human Principal.
- `create_standalone`: provisions a new Human Principal and binds the Telegram
  `User.id` automatically.

## Materialize Attachments

For admitted messages with media, `Conversations` commits a pending attachment
projection first—ensuring unmapped senders never trigger downloads—after which
the adapter calls `getFile`, downloads the bytes into the file service
([Files](../Files.md)), and updates the entry. Because Telegram's hosted cloud
Bot API caps bot file downloads at 20 MB, larger attachments retain their
provider metadata plus a `provider_download_limit` marker without creating a
local file path or claiming local readability.

## Send Replies and Actions

Using Telegram integer message IDs as `provider_message_id`, the adapter
supports posting, replying, editing, deleting, adding/removing reactions,
sending dividers, and rendering cards—uploading outbound files via multipart Bot
API requests and preserving `message_thread_id` inside forum topics.

Mutable streaming replies own one or more Telegram messages whose message IDs
and rendered presentation are checkpointed on the source Signal after every
provider write, allowing restarts and final delivery to edit those same messages
in place rather than posting a duplicate answer. Interactive `InlineKeyboard`
buttons carry a compact callback token under Telegram's 64-byte limit that
points to the durable checkpoint rather than embedding the action; when clicked,
the adapter maps the Telegram user to a Principal, restores the checkpointed
action, validates the binding and message, and emits `signal.action.invoked`.

## Failures and Secrets

Because Telegram's `sendMessage` offers no caller idempotency key and the
adapter does not reconcile uncertain sends, a transport drop or `5xx` failure
during message creation—or partway through a multi-message reply—returns
`unknown` so `Conversations` avoids unsafe automatic retries. HTTP `429`
responses are retryable and honor Telegram's `retry_after` delay, auth and
permission errors require operator action, and confirmed invalid targets fail
permanently.

`AppConfigure` encrypts `botToken` at rest and keeps it out of connection
status, logs, persisted error records, and raw provider payloads; public status
views expose only safe Bot identity, current `offset`, connection state, and
bounded error codes.

## Tests

Automated tests verify plugin declarations, single-binding token ownership,
long-poll offset confirmation, active-webhook detection, token rotation, message
and reaction projection, sender identity policies, the 20 MB download ceiling,
inline button callbacks, outbound request construction, and `unknown` send
classification. Live Telegram acceptance testing requires an operator Bot token
outside the repository.

Implementation paths:

- `plugins/telegram_adapter/lib/ankole/plugins/telegram_adapter.ex`
- `plugins/telegram_adapter/lib/ankole/plugins/telegram_adapter/`
