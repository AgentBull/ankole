# LINE Adapter

The LINE Adapter connects one LINE Official Account to one Agent binding
through the Messaging API. LINE is a consumer IM. The category changes catalog
and Console presentation only; the adapter uses the same Conversations
contracts as every other Signal adapter.

Read [Signals](../Signals.md), [Conversations](../Conversations.md),
[Sessions](../Sessions.md), [Principal](../Principal.md), and
[Local Password Identity Provider](../LocalPasswordIdentityProvider.md) for the
common message and identity rules.

## Provider and Public Identity

The adapter reports an opaque `provider_conversation_id` and a
`provider_message_id`. Conversations resolves these to a shared public
Conversation UUID and Message UUID. All Agent observers of the same provider
conversation in one tenant read those same public facts. Each participating
Agent has its own `conversation:<public UUID>` Session; a Binding is its
observation and delivery route, not the owner of the platform room.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `line-adapter` |
| Signal adapter ID | `line` |
| Adapter category | `consumer_im` |
| Signal configuration | `signals.line.bindings.<id>` |
| Webhook handler ID | `line` |
| Messaging API client | Project `Req` client against `api.line.me` and `api-data.line.me` |

The settings are the channel ID, the encrypted channel secret, and the
encrypted long-lived channel access token from the LINE Developers Console. One
channel can belong to only one enabled LINE binding, because two Agents behind
one Official Account would both answer every message.

The adapter supports all three group modes: `addressed_only`, `observe_all`,
and `may_intervene`. LINE delivers every group message to the bot, so no extra
permission is necessary.

Inbound capabilities are `entry_receive`, `entry_removed`, and `action_event`.
LINE has no reaction webhook, so the adapter does not declare reactions. It
ignores the edit event.

Outbound capabilities are `post_entry`, `reply_entry`, `divider`, `card`, and
`outbound_reconciliation`. The Messaging API cannot edit, unsend, or react to a
message, so the adapter does not declare `edit_entry`, `delete_entry`,
`add_reaction`, or `remove_reaction`. It declares no reply-preview module: a
LINE message cannot change after it is sent, so a live preview would only add
messages and use the monthly message quota.

## Receive Webhooks

The Messaging API has no polling or socket transport. LINE posts events to
this route:

```text
https://<host>/webhooks/v1/line/<channelId>/events
```

The handler finds the enabled binding for the channel ID and checks the
`x-line-signature` header: the Base64 HMAC-SHA256 of the exact request bytes,
keyed with the channel secret. Conversations keeps those bytes for every
provider webhook. A request with a wrong signature gets status 401 and an
unknown channel ID gets status 404, before the handler reads any event.

The handler completes durable Conversations.Observe for every event in the
request before it returns status 200. The Verify button in the LINE Developers
Console sends an empty event list; the handler answers 200. When redelivery is
enabled for the channel, LINE sends a batch again after a non-2xx answer. The
`webhookEventId` of each event is its `source_event_id`, so the gateway stores
a redelivered event once.

Operator setup in LINE:

1. Create a Messaging API channel, and copy its channel ID, channel secret, and
   a long-lived channel access token into the binding.
2. Set the webhook URL above, enable **Use webhook**, and press **Verify**.
3. In LINE Official Account Manager, set the response method to the bot and
   disable auto-response and greeting messages, so the account does not answer
   next to the Agent.
4. For group chats, enable **Allow bot to join group chats**.

## Receive Messages

The adapter accepts one-to-one chats, group chats, and multi-person chats
(rooms). The `provider_conversation_id` includes the bot user ID from the webhook
`destination` and the chat ID. LINE has no threads, so the adapter records no
provider thread: the chat is the channel, and a quote is the only reply
relation. A message in a group or room without a sender user ID cannot be
attributed and is ignored. An event in `standby` mode is ignored.

A one-to-one message is explicit input. In a group or room, these forms are
explicit:

- a mention of the bot (`mention.mentionees[].isSelf`), which the adapter
  removes from the visible text;
- a quote of a message the Agent sent, which the adapter recognizes through the
  Delivery intent that recorded the sent message IDs; a long reply is several LINE
  messages, and a quote of any of them counts.

Known limit: a `/retry` that quotes a later message of a split reply does not
find its target, because Conversations resolves a durable reply by its first
message ID only. The user can quote the first message or name the Signal
with `/retry signal::<id>`.

A database error while checking the quoted author fails ingress. It must not
turn a quote of the Agent into ordinary group input. Provider redelivery uses
the durable source keys to prevent duplicate accepted input.

Conversations applies the binding's group mode to other group messages. LINE
indexes and character limits count UTF-16 code units; the shared
`Ankole.Plugins.UTF16Text` helper applies them.

Text, image, video, audio, file, sticker, and location messages enter the
common message projection. A sticker or location becomes a short text line.
The quote token of each text message stays in the entry metadata so a later
group reply can quote it.

## Admit LINE Identities

The author provider is always `line`, and the stable external identity is the
LINE `userId`. A webhook event carries no display name, so the adapter
declares the `Profile` author hydrator: for an unmatched sender the gateway
reads the user profile, or the group or room member profile, and fills the
display name that the console mapping request or a standalone account shows.
The profile holds no email or phone number, so it never feeds the contact
match.

A LINE user ID belongs to the LINE Developers provider that owns the channel.
The same person has a different user ID under channels of different
providers, so such bindings need separate mappings.

The binding owns `unmatched_sender_policy` (`manual_review` or
`create_standalone`). With `manual_review`, an unmatched addressed sender
receives the fixed mapping notice while `Conversations.IdentityAdmission`
creates a mapping request with the LINE display name without storing the
original message; an administrator can then bind the LINE external identity to
any existing human Principal. With `create_standalone`,
`Conversations.IdentityAdmission` creates a human Principal and binds the LINE
user ID.

## Materialize Attachments

Conversations first commits the admitted message with a pending attachment
observation inside the webhook request. A supervised task then downloads the
bytes from `api-data.line.me`, stores them in the file service
([Files](../Files.md)), and updates the same entry. The webhook answer does not wait for the download.
If the task cannot start, the webhook fails and LINE delivers the event again;
the pending observation is already durable, so that redelivery fetches the
file. An unmatched sender cannot make Ankole download a file. A redelivered event
keeps a result this Agent already holds and fetches everything else again,
including a download whose earlier task never finished, because the adapter
cannot prove that such a task is alive. Conversations never replaces an
attachment this Agent can read with a later observation from this Agent that
has no path, so a second download that overlaps the first cannot lose the
file. A copy that another Agent downloaded does not count: when a route moves
to another Agent, that Agent fetches its own copy.

A video or audio message from the LINE app is transcoded first; the task waits
a bounded time for that. Ankole applies its own budget of 25 MB. For a larger
file, the adapter keeps the provider file metadata and a clear
`provider_download_limit` restriction. Content that another service hosts
keeps its URL and is not downloaded. The adapter never creates a local path
for such a file or claims that the Agent can read it.

## Send Replies and Actions

Every outbound operation is a push message, because a reply token expires one
minute after the webhook and an Agent turn is usually longer. Push messages
count against the monthly message plan of the Official Account, and reply
messages do not. Every Agent reply, mapping notice, and failure notice uses
that plan; an operator must choose a plan that covers the expected traffic.

The adapter uses LINE message IDs as provider message IDs. It splits text at 5,000
UTF-16 code units and sends up to five messages in one request. A reply in a
group or room quotes the human message through its stored quote token; a
one-to-one reply does not quote, because it already follows the human message.
A divider is a text separator.

A pending clarification renders its choices as a buttons template with up to
four postback actions after the text. The postback data carries a short token
of at most 300 bytes that names the Signal, the action index, and the
action fingerprint; it does not contain the action. The adapter records the
sent message ID as the Signal's reply surface. On a postback, it resolves
the LINE user to a Principal, restores the action from the durable checkpoint,
reads the reply surface from the Delivery intent that sent the buttons, and submits
the standard signal.action.invoked stimulus. A stale token produces no visible
change.

Outbound attachments are outside the contract. A bot can send only image,
video, and audio messages, each by a public HTTPS URL, and Ankole serves no
public file. An attachment row stops with a permanent
`outbound_attachments_not_supported` error; the text intent is delivered
separately.

## Failures and Secrets

Each push request carries an `X-Line-Retry-Key` that the adapter derives from
the intent key and the request index. LINE keeps a key for 24 hours after the
first request and answers a repeated request with status 409 and the original
message IDs, which the adapter records as success. A transport failure or a
server error is therefore retryable, and the adapter declares
`outbound_reconciliation`: a recovered in-flight `pending` intent repeats the same requests
instead of marking the reply unknown.

The key protects a repeat only inside that window. The adapter measures the
window from the Delivery intent's creation with a one hour margin. An in-flight `pending` intent
recovered after the window reports `unknown`, and so does every retry after
the window that follows an earlier attempt: the row records only its last
error, and a long reply is several requests, so a definitive last answer does
not prove that no earlier request landed. Delivery stops as `unknown`. An
operator can requeue a visible durable reply for one more call with a
possible-duplicate notice.

Authentication and permission failures require operator action. A rejected
request is permanent. LINE answers both a per-second limit and an exhausted
monthly plan with status 429; the plan message names the monthly limit, and
that case also requires operator action, because only a plan change or the
next month can clear it.

AppConfigure encrypts the channel secret and the channel access token. They do
not enter logs, persisted errors, or stored raw provider payloads.

## Tests

Repository tests cover declaration validation, channel ownership, signature
validation, the Verify probe, redelivery deduplication, message and mention
projection, quote recognition, attachment limits and storage in the file
service, unsend removal, identity policies with profile hydration,
postback buttons and token resolution, outbound request construction, retry
keys, accepted retries, and failure classification. Real LINE acceptance needs
an operator channel that the repository does not contain.

The implementation sources are:

- `plugins/line_adapter/lib/ankole/plugins/line_adapter.ex`
- `plugins/line_adapter/lib/ankole/plugins/line_adapter/`
