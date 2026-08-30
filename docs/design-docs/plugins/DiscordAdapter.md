# Discord Adapter

The Discord Adapter connects one Discord bot to one Agent binding. Discord is a
consumer IM. The category changes catalog and Console presentation only; the
adapter uses the same SignalsGateway contracts as every other Signal adapter.

Read [SignalsGateway](../SignalsGateway.md), [Principal](../Principal.md), and
[Local Password Identity Provider](../LocalPasswordIdentityProvider.md) for the
common message and identity rules.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `discord-adapter` |
| Signal adapter ID | `discord` |
| Adapter category | `consumer_im` |
| Signal configuration | `signals_gateway.discord.bindings.<id>` |
| REST client | Project `Req` client against API v10 |
| Gateway client | Project `Mint.WebSocket` client |

The only setting is the required encrypted `botToken`. One token can belong to
only one enabled Discord binding. The adapter does not use a Discord library.
Its narrow client must return Discord message IDs for durable reply
checkpoints, and its gateway owner must not advance the session sequence before
SignalsGateway accepts the event.

The adapter supports all three group modes: `addressed_only`, `observe_all`,
and `may_intervene`. The last two also need the privileged message-content
intent described below.

Inbound capabilities are `entry_receive`, `reaction_add`, `reaction_remove`,
and `action_event`. The adapter does not declare `entry_removed`, and it does
not convert `MESSAGE_UPDATE` into a new entry.

Outbound capabilities are `post_entry`, `reply_entry`, `edit_entry`,
`delete_entry`, `add_reaction`, `remove_reaction`, `divider`, and `card`. The
adapter does not declare `outbound_reconciliation`.

## Connect through the Gateway

Each enabled binding has one supervised gateway owner that runs one shard. A
bot large enough to need more shards needs a different placement contract than
one binding to one connection.

Before it connects, the owner reads three REST facts: `GET /users/@me` for the
bot identity, `GET /applications/@me` for the application flags, and `GET
/gateway/bot` for the socket URL. It then opens the websocket, answers `HELLO`
with `IDENTIFY`, and starts the heartbeat timer with the jitter Discord asks
for. A heartbeat that Discord does not answer means the connection is a zombie,
so the owner replaces it.

Discord has no per-event acknowledgement. The client stores the sequence number
of the last event it handled, and a `RESUME` replays everything after it. The
owner therefore advances the sequence only after ingress durably accepted the
event or the adapter explicitly ignored it. Each queued event keeps the gateway
session that received it, so an old task cannot move a new session's sequence.
The owner retains received events across a dropped connection and
SignalsGateway deduplicates a replay with its durable source keys, so Discord
needs no second table.

Event handling runs in one supervised task at a time. The owner keeps reading
frames and answering heartbeats while that task runs, because a slow ingress or
a large attachment download would otherwise miss a heartbeat. The local queue
holds at most 1,000 events. At that limit, the owner sheds the queued events
that a resume will replay, keeps the in-flight event and events from an older
session, and reconnects so Discord replays from the last confirmed sequence
instead of growing memory without a bound.

Close codes divide into three groups. `4004`, and `4010` through `4014`, need
an operator to change the token or the Developer Portal, so the owner stops
reconnecting, reports the reason, and retries the preflight after five minutes,
which keeps it far below the daily `IDENTIFY` budget. `4007` and `4009`
invalidate the session but keep the token, so the owner identifies again. Every
other close resumes. Ordinary reconnect backoff doubles from one second to a
maximum of one minute and resets on `READY` or on the next durably handled
event, not on the resume handshake alone.

The connection reconciler reads the current enabled bindings. A token change
replaces the old owner, and a disabled or deleted binding stops its owner. A
control-plane restart rebuilds the owners from binding state.

## Request Intents Honestly

The adapter asks for `GUILD_MESSAGES`, `GUILD_MESSAGE_REACTIONS`,
`DIRECT_MESSAGES`, and `DIRECT_MESSAGE_REACTIONS`. It keeps no channel cache,
so it does not ask for `GUILDS`.

`MESSAGE_CONTENT` is privileged. Discord closes the connection with `4014` when
a client asks for a privileged intent that the application does not have, so
the adapter adds that bit only after the preflight sees the
`GATEWAY_MESSAGE_CONTENT` flag on the application. Without the intent, Discord
delivers guild messages that do not mention the bot with empty content, and the
adapter skips them instead of mirroring blank entries. A binding in that state
still works, but only for direct messages and addressed guild messages.

To use `observe_all` or `may_intervene` in a guild, enable **MESSAGE CONTENT
INTENT** for the application in the Discord Developer Portal.

Discord sends component interactions to an HTTP endpoint instead of the gateway
when the application has an **Interactions Endpoint URL**. Messages still
arrive, so the adapter does not block on this, but buttons in an Agent reply
never reach Ankole.

## Receive Messages

The adapter accepts direct messages and guild channels. A thread has its own
channel ID, so threads become separate Agent sessions without extra state. The
channel ID includes the bot user ID and the Discord channel ID. A message
without `guild_id` is a direct message; every other message is a group message.

A direct message is explicit input. In a guild, these forms are explicit:

- a mention of the current bot;
- a reply to a message from the current bot.

SignalsGateway applies the binding's group mode to other guild messages. The
adapter accepts only Discord `DEFAULT` and `REPLY` message types, and it ignores
its own messages, other bots, webhook posts, and system notices. A message must
have visible text after bot mention removal or a real attachment. Sticker-only,
embed-only, and mention-only messages do not create blank turns.

Discord renders a bot mention as `<@id>` markup inside the content. The adapter
removes that markup so the Agent reads the line the human wrote.

## Admit Discord Identities

The author provider is always `discord`, and the stable external identity is
the Discord user snowflake. Username and global name are display hints. They
are not identity keys or verified contact information.

The binding owns `unmatched_sender_policy`. Discord does not force
`manual_review` and does not disable `create_standalone`. One standard consumer
IM setup uses this sequence:

1. An administrator signs in through LocalPassword and creates a human
   Principal.
2. The Discord binding selects `manual_review`.
3. An unmatched user receives the fixed mapping notice. SignalsGateway creates
   a mapping request and does not store the original message.
4. The administrator maps the Discord external identity to the existing
   Principal.
5. The user sends the message again, and SignalsGateway admits it to the Agent.

This sequence describes a common setup. It is not a dependency between
LocalPassword and Discord. The mapping target can be any existing human
Principal and does not need a LocalPassword credential.

## Materialize Attachments

SignalsGateway first commits the admitted message with a pending attachment
projection. The adapter then downloads the CDN bytes, writes them to the
Agent's `user-files` lane, and updates the same entry. An unmatched sender
cannot make Ankole download a file.

Discord serves attachments without a documented size ceiling, so Ankole applies
its own budget of 25 MB. For a larger file, the adapter keeps the provider file
metadata and a clear `provider_download_limit` restriction. It does not create
a local path or claim that the Agent can read the file.

## Send Replies and Actions

The adapter uses Discord message IDs as source entry IDs. It can post, reply,
edit, delete, add or remove a reaction, send a divider, and render a card. It
sends file attachments as one multipart request whose `payload_json` part
carries the message and whose `files[n]` parts carry the bytes, so text and
attachments arrive as one message. A reply sets `fail_if_not_exists` to false,
so a reply to an already deleted message posts as an ordinary message instead
of failing. Message create and edit requests disable all Discord mention
parsing, so Agent text cannot notify a user, role, or everyone by accident.

A mutable Agent reply owns one or more Discord messages, split at the 2000
character limit. After each provider mutation, the adapter stores the current
message IDs and presentation in the source ActorEvent checkpoint. A restart can
therefore continue by editing the same messages. A terminal reply updates that
surface instead of posting a second final answer. A checkpointed message that
Discord no longer has is not an error: the human deleted it, and the reply
continues by posting the chunk again.

A button carries a `custom_id` of at most 100 bytes. The token identifies an
action in the durable checkpoint; it does not contain the full action. Discord
shows the human an error banner if the interaction callback does not arrive
within three seconds. The owner starts the deferred acknowledgement as soon as
the gateway frame arrives, even when an earlier message is still processing.
Durable action handling stays in gateway order: it resolves the token, maps the
Discord user to a Principal, checks the binding and message, and submits the
standard SignalsGateway action event. A stale token therefore produces no
visible change, which is the correct outcome for an action the reply already
replaced.

Buttons fill action rows of at most five buttons, and one message carries at
most five rows. Actions past that budget are dropped instead of sent in a
request Discord would reject whole.

## Failures and Secrets

Discord does not give message creation an idempotency key, and this adapter
does not reconcile an uncertain send. A transport or server failure can mean
that Discord accepted a request before the connection failed. The adapter
returns `unknown` for that case and for a partially sent multi-message reply.
SignalsGateway does not make an unsafe automatic retry. A delete or an edit of
a message that is already gone is the outcome the outbox asked for, so `404`
on those two operations is a success.

Edits, deletes, and reaction changes are safe to repeat, so a transport or
server failure on those operations remains retryable. A successful message
create that has no message ID is unknown because Ankole cannot checkpoint it
without risking a duplicate.

Rate-limit responses are retryable. Discord reports `retry_after` in fractional
seconds, and the adapter rounds it up so that a sub-second limit still waits.
Authentication and permission failures require operator action. A confirmed
invalid request is permanent.

AppConfigure encrypts the bot token. The token does not enter connection
status, logs, persisted errors, or stored raw provider payloads. The gateway
`IDENTIFY` and `RESUME` payloads carry the token itself, which is why the
adapter reads it directly for the handshake and nowhere else. Public status
contains only safe bot identity, session state, the intent fact, queue depth,
and bounded error classification.

## Tests

Repository tests cover declaration validation, token ownership, the intent and
close-code taxonomy, payload classification, preflight blocking, rate-limit
delay, token rotation, ordered resume, prompt interaction acknowledgement,
message and reaction projection, identity policies, the 25 MB limit, attachment
materialization into the user-files lane, replay deduplication, card actions,
outbound request construction, mention suppression, and uncertain sends. Real
Discord acceptance needs an operator bot token that the repository does not
contain.

The implementation sources are:

- `plugins/discord_adapter/lib/ankole/plugins/discord_adapter.ex`
- `plugins/discord_adapter/lib/ankole/plugins/discord_adapter/`
