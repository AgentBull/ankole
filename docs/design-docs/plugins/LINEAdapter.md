# LINE Adapter

The LINE Adapter connects one LINE Official Account to one Agent binding via the
LINE Messaging API. Although LINE belongs to the `consumer_im` catalog
category—which affects only Console and catalog grouping—the adapter implements
the same `Signals` and `Conversations` contracts as every other messaging
adapter.

See [Signals](../Signals.md), [Conversations](../Conversations.md),
[Sessions](../Sessions.md), [Principal](../Principal.md), and
[Authentication](../Authentication.md) for the shared messaging and identity
contracts.

## Provider and Public Identity

On inbound webhooks, the adapter reports an opaque `provider_conversation_id`
and `provider_message_id`, which `Conversations` resolves to a shared public
Conversation UUID and Message UUID. Every Agent observing that LINE chat within
the same tenant reads those shared public records while running in its own
`conversation:<public UUID>` Session—a Binding defines an observation and
delivery route rather than owning the LINE chat.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `line-adapter` |
| Signal adapter ID | `line` |
| Adapter category | `consumer_im` |
| Signal configuration | `signals.line.bindings.<id>` |
| Webhook handler ID | `line` |
| Messaging API client | Project `Req` client against `api.line.me` and `api-data.line.me` |

Each binding stores the LINE Developers channel ID alongside the encrypted
channel secret and encrypted long-lived channel access token. A channel ID can
belong to at most one enabled LINE binding so two Agents never double-answer the
same Official Account.

Because LINE delivers all group messages to joined bots without extra scopes,
all three group modes (`addressed_only`, `observe_all`, and `may_intervene`)
work out of the box. Inbound capabilities are `entry_receive`, `entry_removed`,
and `action_event` (LINE sends no emoji reaction webhooks, and the adapter
ignores edit events). Outbound capabilities are `post_entry`, `reply_entry`,
`divider`, `card`, and `outbound_reconciliation`; because the Messaging API
supports neither editing, unsending, nor reacting to sent messages, the adapter
omits `edit_entry`, `delete_entry`, `add_reaction`, `remove_reaction`, and
streaming reply previews (which would otherwise post extra messages and burn the
Official Account's monthly push quota).

## Receive Webhooks

LINE's Messaging API pushes events exclusively over HTTP POST to:

```text
https://<host>/webhooks/v1/line/<channelId>/events
```

Before inspecting any event payload, the handler looks up the enabled binding
for `<channelId>` (returning `404` if unknown) and verifies `x-line-signature`
as the Base64 HMAC-SHA256 of the raw request bytes keyed by the channel secret
(returning `401` on mismatch). The handler then runs durable
`Conversations.Observe` for every event in the batch before returning `200`
(answering `200` immediately to the empty event array sent by the LINE
Developers Console **Verify** button). When webhook redelivery is enabled in
LINE, any non-`2xx` response triggers a batch retry, and Ankole deduplicates
redelivered events via each event's `webhookEventId` (`source_event_id`).

Operator setup in LINE:

1. Create a Messaging API channel and copy its channel ID, channel secret, and
   long-lived channel access token into the Ankole binding.
2. Configure the webhook URL above, enable **Use webhook**, and click **Verify**.
3. In LINE Official Account Manager, set the response mode to Bot and disable
   auto-responses and greeting messages so LINE does not reply alongside the
   Agent.
4. To use the Agent in groups, enable **Allow bot to join group chats**.

## Receive Messages

The adapter accepts 1-on-1 chats, group chats, and multi-person rooms, combining
the webhook's `destination` bot user ID and the chat ID into
`provider_conversation_id`. Because LINE has no sub-threads, `provider_thread_id`
stays empty and message quoting is the sole reply relation. Events arriving in
`standby` mode—or group/room messages lacking a sender `userId`—are ignored.

1-on-1 messages always count as explicit input; in groups and rooms, a message
counts as explicit input when it either:

- @-mentions the bot (`mention.mentionees[].isSelf`, stripped from the prompt
  text using UTF-16 code-unit offsets via `Ankole.Plugins.UTF16Text`), or
- quotes any message that the Agent sent earlier (matched against the message
  IDs recorded on outbound Delivery intents, including any chunk of a split
  multi-message reply—though `/retry` quoting a non-initial chunk will not match
  because `Conversations` indexes durable replies by their first message ID
  only; users can quote the first chunk or run `/retry signal::<id>`).

If a database error occurs while checking whether a quoted message belongs to
the Agent, ingress fails closed so LINE redelivers the webhook rather than
downgrading an Agent reply into unaddressed group chatter. Other group messages
follow the binding's group-message policy. Text, image, video, audio, file,
sticker, and location messages project into `Conversations` (converting stickers
and locations into concise text lines and retaining each text message's quote
token in metadata for outbound group replies).

## Admit LINE Identities

Senders map under provider namespace `line` keyed by their `userId`. Because
LINE scopes `userId` values per LINE Developers provider, the same human has
different `userId`s across channels owned by different LINE providers and needs
separate identity bindings for each.

Because LINE webhooks omit display names, the adapter registers the `Profile`
author hydrator: when an inbound `userId` is unmapped, the gateway fetches the
user's 1-on-1, group-member, or room-member profile to populate the display name
shown on Console mapping requests or standalone Principals (LINE profiles carry
neither email addresses nor phone numbers, so hydration never triggers contact
matching). Under `unmatched_sender_policy`, `manual_review` sends the localized
mapping notice and records a mapping request without storing the message, while
`create_standalone` creates a new Human Principal bound to that LINE `userId`.

## Materialize Attachments

Inside the webhook transaction, `Conversations` commits admitted messages with
pending attachment rows—ensuring unmapped senders never trigger downloads—and
spawns a supervised background task to download the media from
`api-data.line.me`, write it to the file service ([Files](../Files.md)), and
finalize the entry without delaying the `200` webhook response:

- If the download task cannot start, the webhook returns an error so LINE
  redelivers against the already committed pending observation.
- On redelivery, the adapter reuses any attachment that the current Agent
  already materialized and re-fetches anything still missing (including
  in-flight downloads from earlier tasks whose liveness cannot be proved);
  `Conversations` never overwrites an already materialized file path for that
  Agent with a pathless update, and moving a route to a different Agent fetches
  that Agent's own copy.
- For LINE-transcoded video and audio, the download task waits a bounded interval
  for transcoding to finish. Files up to 25 MB are stored locally; larger files
  keep their provider metadata plus `provider_download_limit`, and externally
  hosted content retains only its external URL without creating a local file
  path.

## Send Replies and Actions

Because LINE webhook `replyToken`s expire after 60 seconds—shorter than many
Agent turns—all outbound sends use the Messaging API Push endpoint, which draws
from the Official Account's monthly push-message quota (covering Agent replies,
mapping notices, and failure notices alike, so operators should size their LINE
plan accordingly).

Using LINE message IDs as `provider_message_id`, the adapter splits outbound
text at 5,000 UTF-16 code units and packs up to five messages per Push request,
quoting the user's stored quote token in groups/rooms while omitting quotes in
1-on-1 chats, and rendering dividers as plain text separators. Because LINE bots
can send media only via public `https://` URLs and Ankole exposes no unauthenticated
public blob URLs, outbound file attachments fail permanently with
`outbound_attachments_not_supported` while text intents still deliver normally.

Interactive clarifications render up to four postback buttons beneath the prompt
text, where each button's postback payload (capped at 300 bytes) encodes only
the Signal ID, action index, and action fingerprint—recording the sent message
ID as the Signal's reply surface. When a user taps a button, the postback
webhook maps the LINE `userId` to a Principal, loads the full action from the
durable checkpoint and the reply surface from the originating Delivery intent,
and submits `signal.action.invoked` (stale tokens no-op cleanly).

## Failures and Secrets

Every Push request carries a deterministic `X-Line-Retry-Key` derived from the
Delivery intent key and request chunk index. Within LINE's 24-hour retry-key
window, repeating a successful Push returns HTTP `409` alongside the original
message IDs, which the adapter treats as confirmed success—allowing network and
`5xx` errors to retry safely and enabling `outbound_reconciliation` to replay
in-flight `pending` intents on startup rather than marking them `unknown`.

Once an intent passes 23 hours of age (a 24-hour window minus a 1-hour safety
margin), LINE does not guarantee retry-key deduplication across multi-chunk
replies; any recovered `pending` intent or post-failure retry outside that
window settles as `unknown` (operators can manually requeue a visible reply for
one explicit resend carrying a possible-duplicate notice). Auth/permission
errors require operator action, malformed `4xx` payloads fail permanently, and
HTTP `429` distinguishes per-second rate limits (retryable) from monthly quota
exhaustion (flagged for operator plan upgrade or monthly reset).

`AppConfigure` encrypts the channel secret and channel access token at rest and
excludes them from logs, error records, and stored raw webhook payloads.

## Tests

Automated tests cover plugin declarations, single-binding channel ownership,
`x-line-signature` verification, empty-batch Console **Verify** probes,
`webhookEventId` deduplication, UTF-16 mention stripping, quote detection, the
25 MB download cap and file-service storage, unsend events, profile-hydrated
identity admission, postback button tokens, Push chunking, `X-Line-Retry-Key` /
`409` reconciliation, and error classification. Live LINE acceptance testing
requires an operator Messaging API channel outside the repository.

Implementation paths:

- `plugins/line_adapter/lib/ankole/plugins/line_adapter.ex`
- `plugins/line_adapter/lib/ankole/plugins/line_adapter/`
