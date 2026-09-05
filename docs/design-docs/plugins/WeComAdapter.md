# WeCom Adapter

The WeCom Adapter receives messages from one WeCom AI bot and sends Agent
replies. It also signs operators in through a WeCom self-built app and imports
WeCom users and departments. WeCom splits these functions across two product
surfaces, so the chat face and the identity face use different credentials.

Read [SignalsGateway](../SignalsGateway.md), [Principal](../Principal.md), and
[Plugins](../Plugins.md) for the common message, identity, and Plugin rules.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `wecom-adapter` |
| API version | `1` |
| Signal adapter ID | `wecom` |
| Signal configuration | `signals_gateway.wecom.bindings.<agent_uid>` |
| Identity adapter ID | `wecom` |
| Identity configuration | `principals.identity_providers.wecom.<id>` |
| Provider library | `libs/wecom_openapi` |

The signal adapter supports only `addressed_only`. WeCom does not deliver
unaddressed group messages to the bot.

Inbound capabilities are `entry_receive` and `action_event`. Outbound
capabilities are `post_entry` and `card`. WeCom has no recall API, so there is
no `delete_entry`.

The identity adapter supports OIDC authorization, code exchange, credential
check, and full directory sync. WeCom has no realtime directory events on this
path, so directory changes converge through periodic full sync.

## Settings

The chat configuration contains these fields:

| Field | Purpose |
| --- | --- |
| `botId` | Required AI bot ID |
| `secret` | Required encrypted long-connection secret |
| `group_message_mode` | Must be `addressed_only` |
| `platformSubjectNamespace` | Selects the Principal subject namespace |
| `userName` | Sets the outbound display name |

A corp super administrator must create the bot. A bot from another creator
sends encrypted user IDs that can never join the directory or login
identities.

The identity configuration contains `corpId`, `agentId`, and `appSecret` for
the self-built app, and the optional `contactsSecret` from the WeCom contacts
sync tool. `oidc.enabled` controls login and `sync.contacts` controls
directory import. Directory sync refuses to save without `contactsSecret`:
since 2022-06 the ordinary app secret does not return member names.

One Agent can have at most one enabled WeCom binding. One `botId` cannot
belong to two Agents. The binding save transaction validates both rules.

The identity REST calls need a fixed egress IP in the WeCom trusted-IP lists.
The self-built app and the contacts sync tool each have their own list. The
credential check reports a missing entry (error 60020) with the console
location to fix.

## Connect to WeCom

`ConnectionReconciler` selects one long connection for each bot.
`ConnectionSupervisor` runs each connection. The identity face is pure REST
and holds no connection.

The client opens the WebSocket, authenticates in-band with the bot
credentials, and sends a heartbeat every 30 seconds. All outbound frames wait
for their acknowledgement, correlated by `req_id`. Replies to one `req_id` go
out one at a time, because their acknowledgements are only attributable by
that `req_id`. The WeCom gateway requires the exact WebSocket Upgrade header
names `Upgrade`, `Connection`, `Sec-WebSocket-Version`, and
`Sec-WebSocket-Key`. It returns HTTP 404 when a client sends these names in
lowercase, so the client preserves their canonical case in the HTTP/1 request.

An acknowledgement timeout closes the connection and fails its queued sends.
A later acknowledgement cannot confirm the next frame with the same `req_id`.
The existing reconnect and outbox recovery rules then apply.

WeCom permits one live connection for each bot. When a second consumer
connects, the platform disconnects the first one and announces it with a
`disconnected_event`. The client then stops instead of reconnecting, because a
reconnect would disconnect the new holder in a loop. The connection owner logs
the conflict for the operator, parks, and retries after a long idle window.

The push protocol has no client acknowledgement. The adapter persists each
message immediately, and the `msgid` uniqueness key absorbs any platform
redelivery.

## Receive Messages

The message callback becomes `entry_receive`, and a `template_card_event`
becomes `action_event`. Groups deliver only messages that address the bot, so
every group message is explicit.

The stable channel ID is `wecom:<encoded chat target>`. The chat target is the
group `chatid` or, for a direct message, the counterpart `userid`. WeCom has
no thread or anchored reply, so provider thread ID and reply target are empty.

`from.userid` identifies the sender. The adapter ignores messages without it
and messages from the `sys` sender.

Each inbound frame carries a `req_id` that stays valid as a reply anchor for
24 hours. The adapter records the newest `req_id` in the channel mirror
metadata.

A voice message arrives as its platform transcript only; the transcript is the
message text. A quoted message carries content but no ID of the quoted entry,
so quoted text renders as a leading quote block and quoted media joins the
attachments.

Attachment URLs live five minutes and their bytes are AES-encrypted with a
per-item key. The adapter downloads and decrypts each attachment before
ingress and saves it through WorkerFiles. It never stores the temporary URL or
the key.

WeCom does not provide inbound edit, recall, or reaction events. Images,
voice, files, and video arrive in direct messages only.

## Send Replies

The adapter sends only operations already stored in the outbox. It can send
Markdown text, send one attachment, or send a template card.

Each send resolves a channel. A fresh respond anchor rides `aibot_respond_msg`
and, in a group, the platform quotes the trigger message. Without an anchor,
the proactive `aibot_send_msg` path needs the user to have messaged the bot in
that conversation before. Media has no verified proactive carrier, so an
attachment without a respond anchor fails with a clear error.

Text uses the WeCom Markdown subset. Tables pass through; images degrade to
links. An oversized image or video and a non-AMR voice file all ship as plain
files; an oversized file fails loudly.

Template cards are plain JSON. Card buttons round-trip only a `key` string, so
the portable interaction protocol packs into the key and the source actor
event rides `task_id`. After a click, the card can change only inside a
5-second event window; the adapter settles the interaction and writes a
receipt card in that window.

New button keys use an `ank2:` prefix and a JSON array of interaction fields.
This preserves separators inside IDs and values. If a key exceeds 1,024 UTF-8
bytes, the whole card uses its Markdown fallback. The decoder still accepts
`ank1|` keys from previously sent cards.

Neither send path has an idempotency parameter. The adapter cannot reconcile an
uncertain send. SignalsGateway can resend an uncertain visible final reply only
inside its remaining attempt budget, and the resent reply says that it can be a
duplicate.

The adapter classifies connection, timeout, rate-limit, and server failures as
retryable. Authentication and trusted-IP failures require operator action.
Other deterministic provider rejections, including anti-spam rejection 40201,
are permanent and stop after the first call.

## Show a Live Streaming Reply

`AIStream` shows the reply preview with the platform's native stream message.
One reply is a chain of stream messages bound to the trigger's `req_id`. Each
page refreshes with the full content snapshot under a deterministic stream ID,
so every provider write is replay-safe.

Two limits drive paging: a source-byte budget below the 20480-byte message
cap, and the platform rule that one stream must finish within 10 minutes. An
open page near that deadline freezes at its last written text, seals, and the
chain continues on a new stream message.

The ActorEvent checkpoint is the durable page ledger. It stores each page's
stream ID, source slice, open time, and sealed state, plus the pinned reply
`req_id` and the last presentation that recovery can render. Sealed pages do
not change.

A turn without a respond anchor cannot stream. Working updates then return a
non-retryable error and only the final durable delivery falls back to plain
Markdown sends. The checkpoint records each delivered chunk, so an outbox
retry resumes after the last recorded chunk.

## Import People and Sign In

Login uses the WWLogin page and exchanges the redirect code for the enterprise
`userid` with the self-built app credential. Non-members and linked-corp users
fail closed. The profile hydrates from the contacts-sync secret when it is
configured.

Full sync reads the department tree and the members of each department, and
de-duplicates members that belong to several departments. There are no
realtime events; the host runs periodic full syncs.

## Restart and Recovery

AppConfigure stores encrypted settings. SignalsGateway records messages, Agent
work, and replies. Principals and AuthZ store people, groups, memberships, and
grants.

A control-plane restart rebuilds the long connections. An open stream page
continues under its recorded stream ID when its window still permits;
otherwise it seals and the chain continues. Agent Computer does not receive
WeCom credentials.

## Tests

The repository tests the provider client and its WebSocket protocol,
normalization, outbox channel resolution, template cards, streaming
checkpoints, login, and directory sync. The end-to-end transport suite drives
a fake WeCom gateway through connect, auth, reply serialization, kick, and
reconnect. A real WeCom acceptance test needs operator credentials, a
super-administrator-created bot, and a trusted-IP setup.

The implementation sources are:

- `plugins/wecom_adapter/lib/ankole/plugins/wecom_adapter.ex`
- `plugins/wecom_adapter/lib/ankole/plugins/wecom_adapter/`
- `libs/wecom_openapi/`
