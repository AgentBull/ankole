# WeCom Adapter

The WeCom Adapter connects one WeCom AI bot for Agent messaging and replies,
while using a separate WeCom self-built application for OIDC sign-in and user
and department imports. Because WeCom divides AI bots and enterprise
applications across two distinct product surfaces, chat bindings and identity
providers configure separate credentials—all stored on the control plane.

See [Signals](../Signals.md), [Conversations](../Conversations.md),
[Sessions](../Sessions.md), [Principal](../Principal.md), and
[Plugins](../Plugins.md) for the shared messaging, identity, and Plugin
contracts.

## Provider and Public Identity

On inbound events, the adapter reports an opaque `provider_conversation_id` and
`provider_message_id`, which `Conversations` resolves to a shared public
Conversation UUID and Message UUID. Every Agent observing that WeCom
conversation within the same tenant reads those shared public records while
running in its own `conversation:<public UUID>` Session—a Binding defines an
observation and delivery route rather than owning the WeCom chat.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `wecom-adapter` |
| API version | `1` |
| Signal adapter ID | `wecom` |
| Signal configuration | `signals.wecom.bindings.<agent_uid>` |
| Identity adapter ID | `wecom` |
| Identity configuration | `principals.identity_providers.wecom.<id>` |
| Provider library | `plugins/wecom_adapter/lib/wecom_openapi` |

Because WeCom delivers only @-mentioned group messages to AI bots, the Signal
adapter supports only `addressed_only` mode. Inbound capabilities are
`entry_receive` and `action_event`; outbound capabilities are `post_entry` and
`card` (WeCom exposes no message-recall API, so `delete_entry` is omitted).

On the identity side, the adapter supports OIDC authorization, OIDC code
exchange, credential verification, and full directory sync; because WeCom emits
no real-time directory events on this path, directory changes converge through
scheduled full syncs.

## Settings

Chat bindings configure these fields:

| Field | Purpose |
| --- | --- |
| `botId` | Required AI bot ID |
| `secret` | Required encrypted long-connection secret |
| `group_message_mode` | Must be `addressed_only` |
| `identityProvider` | References the identity provider that owns the Principal subject namespace; a single provider is adopted by default, several require a choice, `:standalone` keeps the adapter default |
| `userName` | Sets the outbound display name |

A WeCom corp super administrator must create the AI bot; bots created by
non-super-admin accounts emit encrypted user IDs that can never link to
directory or sign-in Principals. Each Agent can enable at most one WeCom
binding, and a `botId` cannot belong to two Agents—the binding save transaction
enforces both rules.

Identity-provider configurations store `corpId`, `agentId`, and `appSecret` from
the self-built app plus optional `contactsSecret` from the WeCom contacts-sync
tool (`oidc.enabled` governs login, and `sync.contacts` governs directory
import—saving fails if `sync.contacts` is enabled without `contactsSecret`,
because WeCom's standard `appSecret` omits member names). In addition, WeCom
REST endpoints require static egress IPs allowlisted separately on both the
self-built app and the contacts-sync tool; credential verification surfaces
missing allowlist entries (WeCom error `60020`) along with the exact WeCom
admin path to update.

## Connect to WeCom

`ConnectionReconciler` derives one persistent WebSocket per enabled AI bot,
supervised by `Ankole.Plugins.ConnectionLifecycle` (the identity side uses
stateless REST calls without holding a socket).

During the HTTP/1.1 WebSocket upgrade, the client preserves canonical header
casing (`Upgrade`, `Connection`, `Sec-WebSocket-Version`, and
`Sec-WebSocket-Key`) because WeCom's gateway returns HTTP `404` when those
header names arrive lowercased. Once connected, the client authenticates in-band
with the bot credentials and sends heartbeats every 30 seconds:

- Outbound frames wait for an ACK correlated by `req_id`, serializing replies
  sharing a `req_id` one at a time because ACKs identify only `req_id`. If an
  ACK times out, the client closes the socket and fails queued sends so a late
  ACK can never misconfirm a subsequent frame under the same `req_id`, after
  which standard reconnect and Delivery recovery apply.
- Inbound push frames carry no client-side ACK; instead, the adapter persists
  each observation immediately and relies on `msgid` uniqueness keys to
  deduplicate platform redeliveries.
- Because WeCom allows only one active WebSocket per bot, a second client
  connecting with the same credentials kicks the existing socket with a
  `disconnected_event`. Rather than reconnecting immediately and fighting the
  other consumer in a kick loop, the displaced owner logs the conflict for the
  operator, parks, and retries only after a long idle backoff.

## Receive Messages

Message frames map to `entry_receive` and `template_card_event` frames map to
`action_event` (WeCom delivers no inbound edits, recalls, or reactions, and
delivers images, voice, files, and video in 1-on-1 direct messages only).
Group messages arrive only when addressing the bot, so every received group
message counts as explicit input.

`provider_conversation_id` is formatted as `wecom:<encoded chat target>`—using
the group `chatid` or the DM counterpart `userid`—with empty thread and reply
targets because WeCom exposes no sub-threads or anchored reply IDs. Sender
attribution reads `from.userid`, dropping frames that lack it or originate from
`sys`. Each inbound frame also supplies a `req_id` valid as a reply anchor for
24 hours, and the adapter stores the newest `req_id` in channel mirror metadata.

Voice messages arrive pre-transcribed as text, quoted messages render quoted
prose as a leading Markdown blockquote and merge quoted media into attachments
(since WeCom omits the quoted message's ID), and inbound attachment URLs—which
expire after 5 minutes and serve AES-encrypted bytes with a per-item key—are
downloaded, decrypted, and written to the file service ([Files](../Files.md))
during ingress without ever storing temporary URLs or AES keys.

## Send Replies

Outbound execution processes only durable Delivery intents: sending WeCom
Markdown text, uploading a single attachment, or sending a JSON template card.
Before sending, the Rust kernel converts prose to WeCom's Markdown dialect
(keeping tables intact, turning inline images into links, and using CommonMark
byte spans to preserve fenced, indented, and inline code verbatim, while live
`AIStream` previews use their own paging rules). Oversized images/videos and
non-AMR audio upload as generic files, whereas files exceeding the overall file
cap fail explicitly.

Channel routing depends on whether a fresh 24-hour `req_id` respond anchor is
available:

- With a valid respond anchor, replies travel over `aibot_respond_msg`
  (automatically quoting the trigger message in groups).
- Without a respond anchor, text and cards fall back to proactive
  `aibot_send_msg` (which requires the user to have already messaged the bot in
  that chat), whereas attachments fail with a clear error because WeCom provides
  no proactive media transport on this path.

Interactive template-card buttons round-trip only a `key` string (with actor
event tracking carried in `task_id`), encoded with an `ank2:` prefix followed by
a JSON array of interaction fields so embedded delimiters stay intact (if any
button key exceeds 1,024 UTF-8 bytes, the entire card falls back to Markdown).
After a user clicks a button, WeCom allows updating that card only within a
5-second callback window, during which the adapter settles the interaction and
writes a receipt card.

Because neither `aibot_respond_msg` nor `aibot_send_msg` accepts an idempotency
key, uncertain sends settle as `unknown` (operators can manually requeue a
visible durable reply once with a possible-duplicate notice). Connection drops,
timeouts, rate limits, and `5xx` errors are retryable; auth and trusted-IP
errors require operator action; and deterministic rejections—including anti-spam
error `40201`—fail permanently on the first attempt.

## Show a Live Streaming Reply

When a turn has a valid `req_id` respond anchor, `AIStream` renders live reply
previews as a chain of native WeCom stream messages bound to that `req_id`
(turns lacking a respond anchor return a non-retryable preview error and fall
back to plain Markdown chunks on final Delivery, checkpointing each delivered
chunk for safe retry resumption). Each page sends full content snapshots under a
deterministic stream ID so writes are replay-safe.

Two platform bounds trigger page rollover: staying beneath WeCom's 20,480-byte
stream message cap, and WeCom's hard 10-minute lifetime per stream message
(approaching 10 minutes freezes and seals the active page and continues on a new
stream message). The source Signal's checkpoint acts as the durable page
ledger—storing each page's stream ID, source slice, open timestamp, and sealed
flag alongside the pinned `req_id`, last recoverable presentation, and
`cleanup_at` thought-cleanup lease (`PreviewAdapter.put_thought_lease/4`, cleared
on final updates or updates without visible reasoning). Sealed pages never
mutate, throttled updates retain the last confirmed snapshot in the ledger, and
newly opened tail pages bypass throttling.

## Import People and Sign In

OIDC sign-in redirects through WWLogin and exchanges the authorization code via
the self-built app credentials for the enterprise `userid`—failing closed for
external or linked-corp accounts—and enriches profile fields using
`contactsSecret` when configured. Full directory sync traverses the department
tree, deduplicating members across multiple departments, and converges via
periodic full sync runs.

## Restart and Recovery

PostgreSQL persists encrypted settings in `AppConfigure`, public Messages and
Delivery intents in `Conversations`, accepted stimuli in `Signals`, execution
state in `Sessions`, and people, groups, memberships, and grants in `Principals`
and `AuthZ`—never exposing WeCom credentials to Agent Computer. After a
control-plane restart, `ConnectionLifecycle` reconnects bot WebSockets, and any
open `AIStream` page still inside its 10-minute window resumes under its stored
stream ID (or seals and rolls over to a new page if the window elapsed).

## Tests

Automated tests cover `wecom_openapi`, WebSocket header/frame handling, inbound
normalization, channel/anchor resolution, template cards, `AIStream`
checkpoints, WWLogin sign-in, and directory sync, alongside an end-to-end
transport suite exercising connect, auth, serialized `req_id` replies, duplicate
connection kicks, and reconnects against a fake WeCom gateway. Live WeCom
acceptance testing requires operator credentials, a super-admin-created AI bot,
and allowlisted egress IPs.

Implementation paths:

- `plugins/wecom_adapter/lib/ankole/plugins/wecom_adapter.ex`
- `plugins/wecom_adapter/lib/ankole/plugins/wecom_adapter/`
- `plugins/wecom_adapter/lib/wecom_openapi/`
