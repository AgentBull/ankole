# Telegram Adapter

The Telegram Adapter connects one Telegram Bot to one Agent binding. Telegram
is a consumer IM. The category changes catalog and Console presentation only;
the adapter uses the same SignalsGateway contracts as every other Signal
adapter.

Read [SignalsGateway](../SignalsGateway.md), [Principal](../Principal.md), and
[Local Password Identity Provider](../LocalPasswordIdentityProvider.md) for the
common message and identity rules.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `telegram-adapter` |
| Signal adapter ID | `telegram` |
| Adapter category | `consumer_im` |
| Signal configuration | `signals_gateway.telegram.bindings.<id>` |
| Bot API client | Project `Req` client |

The only setting is the required encrypted `botToken`. One token can belong to
only one enabled Telegram binding. The adapter does not use `telegram_ex`. Its
narrow client must return Telegram message IDs for durable reply checkpoints,
and its poll owner must not confirm an update before SignalsGateway accepts it.

The adapter supports all three group modes: `addressed_only`, `observe_all`,
and `may_intervene`.

Inbound capabilities are `entry_receive`, `reaction_add`, `reaction_remove`,
and `action_event`. Telegram does not provide an ordinary Bot API update for a
deleted message, so the adapter does not declare `entry_removed`. It also does
not convert `edited_message` into a new entry.

Outbound capabilities are `post_entry`, `reply_entry`, `edit_entry`,
`delete_entry`, `add_reaction`, `remove_reaction`, `divider`, and `card`. The
adapter does not declare `outbound_reconciliation`.

## Connect through Long Polling

Each enabled binding has one supervised long-poll owner. Before it polls, the
owner calls `getMe` and `getWebhookInfo`. A configured webhook blocks polling.
The owner reports `webhook_configured` and checks again later, but it does not
delete configuration that another operator or system owns.

The owner calls `getUpdates` with a positive timeout and processes updates in
`update_id` order. It advances the in-memory offset only after durable ingress
succeeds or the adapter explicitly ignores the update. A control-plane crash
can therefore deliver an update again. SignalsGateway deduplicates that update
with its durable source keys, so Telegram needs no second offset table.

The connection reconciler reads the current enabled bindings. A token change
replaces the old owner, and a disabled or deleted binding stops its owner. A
control-plane restart rebuilds the owners from binding state.

## Receive Messages

The adapter accepts private chats, groups, supergroups, and independent forum
topics. The channel ID includes the Bot ID and chat ID. A forum topic also
includes `message_thread_id`, so topics remain separate Agent sessions.

A direct message is explicit input. In a group, these forms are explicit:

- a structured mention of the current Bot;
- a `/command@bot` command;
- a reply to a message from the current Bot.

SignalsGateway applies the binding's group mode to other group messages. The
adapter ignores channel posts, Business messages, Guest or anonymous senders,
messages from bots, and messages sent through another bot.

Telegram text and captions use Bot API UTF-16 entity offsets. The adapter
converts them without splitting supplementary Unicode characters. Text,
captions, location, contact, poll, photo, document, audio, voice, video, video
note, animation, and sticker facts enter one common message projection.

## Admit Telegram Identities

The author provider is always `telegram`, and the stable external identity is
the decimal Telegram `User.id`. Username, name, and language are display hints.
They are not identity keys or verified contact information.

The binding owns `unmatched_sender_policy`. Telegram does not force
`manual_review` and does not disable `create_standalone`. One standard consumer
IM setup uses this sequence:

1. An administrator signs in through LocalPassword and creates a human
   Principal.
2. The Telegram binding selects `manual_review`.
3. An unmatched user receives the fixed mapping notice. SignalsGateway creates
   a mapping request and does not store the original message.
4. The administrator maps the Telegram external identity to the existing
   Principal.
5. The user sends the message again, and SignalsGateway admits it to the Agent.

This sequence describes a common setup. It is not a dependency between
LocalPassword and Telegram. The mapping target can be any existing human
Principal and does not need a LocalPassword credential.

## Materialize Attachments

SignalsGateway first commits the admitted message with a pending attachment
projection. The adapter then calls `getFile`, downloads the bytes, writes them
to the Agent's `user-files` lane, and updates the same entry. An unmatched
sender cannot make Ankole download a file.

The official cloud Bot API cannot download files larger than 20 MB. For such a
file, the adapter keeps the provider file metadata and a clear
`provider_download_limit` restriction. It does not create a local path or
claim that the Agent can read the file.

## Send Replies and Actions

The adapter uses Telegram message IDs as source entry IDs. It can post, reply,
edit, delete, add or remove a reaction, send a divider, and render a card. It
sends file attachments through Bot API multipart requests. Forum-topic output
keeps the original `message_thread_id`.

A mutable Agent reply owns one or more Telegram messages. After each provider
mutation, the adapter stores the current message IDs and presentation in the
source ActorEvent checkpoint. A restart can therefore continue by editing the
same messages. A terminal reply updates that surface instead of posting a
second final answer.

An InlineKeyboard button carries a short token of less than 64 bytes. The
token identifies an action in the durable checkpoint; it does not contain the
full action. On a callback, the adapter resolves the Telegram user to a
Principal, restores the action, checks the binding and message, and submits the
standard SignalsGateway action event.

## Failures and Secrets

Telegram does not give `sendMessage` a general idempotency key, and this
adapter does not reconcile an uncertain send. A transport or server failure
can mean that Telegram accepted a request before the connection failed. The
adapter returns `unknown` for that case and for a partially sent multi-message
reply. SignalsGateway does not make an unsafe automatic retry.

Rate-limit responses are retryable and preserve Telegram `retry_after`.
Authentication and permission failures require operator action. A confirmed
invalid target is permanent.

AppConfigure encrypts the Bot token. The token does not enter connection
status, logs, persisted errors, or stored raw provider payloads. Public status
contains only safe Bot identity, offset, connection state, and bounded error
classification.

## Tests

Repository tests cover declaration validation, token ownership, long-poll
offset confirmation, webhook conflicts, token rotation, message and reaction
projection, identity policies, the 20 MB limit, card actions, outbound request
construction, and uncertain sends. Real Telegram acceptance needs an operator
Bot token that the repository does not contain.

The implementation sources are:

- `plugins/telegram_adapter/lib/ankole/plugins/telegram_adapter.ex`
- `plugins/telegram_adapter/lib/ankole/plugins/telegram_adapter/`
