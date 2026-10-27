# WhatsApp Adapter

The WhatsApp Adapter connects one WhatsApp Business phone number to one Agent
binding via the WhatsApp Business Platform Cloud API. Although WhatsApp belongs
to the `consumer_im` catalog category—which affects only Console and catalog
grouping—the adapter implements the exact same `Signals` and `Conversations`
contracts as every other messaging adapter.

See [Signals](../Signals.md), [Conversations](../Conversations.md),
[Sessions](../Sessions.md), [Principal](../Principal.md), and
[Authentication](../Authentication.md) for the shared messaging and identity
contracts.

## Provider and Public Identity

On inbound webhooks, the adapter reports an opaque `provider_conversation_id`
and `provider_message_id`, which `Conversations` resolves to a shared public
Conversation UUID and Message UUID. Every Agent observing that WhatsApp chat
within the same tenant reads those shared public records while running in its
own `conversation:<public UUID>` Session—a Binding defines an observation and
delivery route rather than owning the WhatsApp thread.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `whatsapp-adapter` |
| Signal adapter ID | `whatsapp` |
| Adapter category | `consumer_im` |
| Signal configuration | `signals.whatsapp.bindings.<id>` |
| Webhook handler ID | `whatsapp` |
| Cloud API client | Project `Req` client against the Graph API, version `v25.0` |

Each binding configures the Meta App ID, encrypted App secret, encrypted webhook
verify token, WhatsApp phone number ID, and encrypted permanent System User
access token, calling Meta's Graph API directly over `Req` without a WhatsApp
SDK or On-Premises API deployment.

Every conversation binds to the specific `phoneNumberId` that received its
messages (encoded inside `provider_conversation_id`). If an operator later
switches a binding to a different phone number, outbound replies to older chats
halt with an operator-action `binding_phone_number_mismatch` error rather than
replying from a number that the user never messaged; restoring the original
phone number unblocks those pending replies on save, whereas keeping the new
number leaves the older chats closed.

Each phone number ID can belong to at most one enabled WhatsApp binding so two
Agents never double-answer a single number. Multiple phone numbers (and
bindings) may share one Meta App—and therefore share one App-level webhook
URL—provided all enabled bindings under that `appId` supply identical App
secrets and verify tokens (saves that introduce a mismatch are rejected).

Only 1-on-1 chats are supported: because WhatsApp groups require Meta's separate
Official Business Account Groups API, group-tagged webhook payloads are ignored
and the Console preselects `addressed_only` as the sole supported group mode.
Inbound capabilities are `entry_receive` and `action_event` (the Cloud API emits
no message-edit or message-delete webhooks—so messages that users delete in
WhatsApp never reach Ankole—and reactions are ignored). Outbound capabilities
are `post_entry`, `reply_entry`, `divider`, and `card`; because sent Cloud API
messages cannot be edited or deleted and carry neither caller idempotency keys
nor read-back endpoints, the adapter omits `edit_entry`, `delete_entry`, live
reply previews, and `outbound_reconciliation`.

## Receive Webhooks

Meta configures WhatsApp Cloud API webhooks at the Meta App level rather than per
phone number, posting and verifying against:

```text
https://<host>/webhooks/v1/whatsapp/<appId>/events
```

- **Subscription verification (`GET`):** checks `hub.mode == "subscribe"` and
  compares `hub.verify_token` against the stored verify token, returning HTTP
  `200` with `hub.challenge` as `text/plain` on match or `403` otherwise.
- **Event delivery (`POST`):** looks up `<appId>` (returning `404` if unknown)
  and validates `x-hub-signature-256` (`sha256=` plus lowercase hex HMAC-SHA256
  over the exact raw request bytes keyed by the App secret, returning `401` on
  mismatch) before inspecting any event payload.

Because a single Meta App can own multiple phone numbers—only some of which may
be bound in Ankole—the handler inspects `value.metadata.phone_number_id` on each
change entry, routing owned numbers to their binding while ignoring unconfigured
numbers with HTTP `200` so unmapped numbers never block active ones. Durable
`Conversations.Observe` finishes for every message in the payload before the
handler returns `200`; Meta retries non-`200` deliveries for up to seven days,
and Ankole deduplicates redeliveries using the WhatsApp message ID
(`source_event_id`).

Operator setup in the Meta App Dashboard:

1. Add the **WhatsApp** product to the Meta App and link the WhatsApp Business
   Account owning the phone number.
2. Copy the App ID, App secret, and phone number ID into the Ankole binding
   alongside a chosen verify token.
3. Under **WhatsApp > Configuration**, set the callback URL above with that same
   verify token and click **Verify and save**.
4. Subscribe the App to the `messages` webhook field (no other fields are
   needed).
5. Provision a Business Manager System User granted
   `whatsapp_business_messaging`, mint a permanent access token, and store it on
   the binding (short-lived user tokens expire and stall the Agent).

## Receive Messages

Every accepted message is an explicit 1-on-1 turn whose
`provider_conversation_id` pairs `phoneNumberId` and the sender's `wa_id` and
whose `wamid` serves as both `source_event_id` and `provider_message_id` (since
WhatsApp has no threads, `provider_thread_id` stays empty and quoting is the
sole reply relation).

Text, image, video, audio, document, sticker, location, and contact-card
messages project into `Conversations`: media captions become entry text,
documents keep the sender's filename, locations and contact cards format as
concise text lines, and template quick-reply taps enter as plain button text.
By contrast, `reaction`, `unsupported`, `system`, `request_welcome`, `order`,
and empty payloads are ignored, and outbound delivery receipts under
`value.statuses` write no database rows (logging error codes on `failed`
statuses for operator visibility).

## Admit WhatsApp Identities

Inbound authors use provider namespace `whatsapp` keyed by `wa_id`. Because
webhook payloads already include the sender's WhatsApp profile display name, no
`author_hydrator` call is needed. Moreover, because `wa_id` is a Meta-verified
phone number, the adapter normalizes `+<wa_id>` to E.164 via the Rust kernel and
supplies it as a verified mobile number—matching existing Principals by mobile
number immediately just like enterprise IM adapters (omitting any number that
cannot be normalized cleanly rather than storing malformed phone text).

Under `unmatched_sender_policy`, `manual_review` sends the localized mapping
notice and creates a mapping request pre-populated with the WhatsApp profile
name and normalized phone number without storing the message body, whereas
`create_standalone` creates a new Human Principal bound to that `wa_id`.

## Materialize Attachments

Inside the webhook transaction, `Conversations` commits admitted media messages
with pending attachment rows—ensuring unmapped senders never trigger
downloads—and spawns a supervised background task to resolve the temporary media
URL (which expires 5 minutes after lookup), download the bytes into the file
service ([Files](../Files.md)), and finalize the entry without delaying the
`200` webhook acknowledgement:

- If the background task cannot start, the webhook fails so Meta redelivers
  against the already committed pending observation.
- On redelivery, the adapter keeps any attachment that this Agent already
  materialized and re-fetches anything still missing (including downloads from
  earlier tasks whose liveness cannot be proved); `Conversations` never replaces
  an already materialized file path for that Agent with a pathless update, and
  reassigning a route to another Agent fetches that Agent's own copy.
- Files up to Ankole's 25 MB download cap are stored locally; larger files
  retain their provider metadata plus `provider_download_limit` without creating
  a local file path or claiming local readability.

## Send Replies and Actions

Outbound sends post to `POST /<version>/<phoneNumberId>/messages` using the
System User token, recording every returned `wamid` on the Delivery intent.
Prose splits at 4,096 characters into sequential requests—setting
`context.message_id` on the first chunk of a `reply` so WhatsApp renders a
visual quote—and dividers send as text separators.

Interactive clarifications (`Conversations` allows up to eight choices) render
after any preceding text chunks as one trailing interactive message whose
`wamid` is recorded as the Signal's reply surface (while the Delivery row's
created entry ID remains the first chunk):

- Up to three choices render as reply buttons (20-character title limit); four
  to eight choices render as a single list section (24-character row-title
  limit, well inside Meta's 10-row ceiling) opened by a fixed localized
  list-drawer button.
- Every button or row title starts with its 1-based ordinal (for example,
  `"1. Approve the release"`) so truncated labels never collide—Meta rejects
  interactive messages containing duplicate titles—and whenever a label
  truncates, button prompts append the full numbered options beneath the prompt
  text while list rows place the full label in the row description.
- Each option's callback ID (up to 256 bytes) encodes only the Signal ID, action
  index, and action fingerprint. When a user taps an option, the adapter maps
  `wa_id` to a Principal, loads the checkpointed action, and verifies that the
  reply's `context.id` matches the recorded interactive reply surface before
  emitting `signal.action.invoked` (stale tokens or replies quoting an earlier
  text chunk quietly no-op).

Outbound attachments upload first via `POST /<version>/<phoneNumberId>/media`
and then send by media ID under Meta's per-type constraints:

| Message type | Accepted content | Size limit |
| --- | --- | --- |
| `image` | JPEG, PNG | 5 MB |
| `video` | MP4, 3GPP | 16 MB |
| `audio` | AAC, MP4, MPEG, AMR, OGG | 16 MB |
| `document` | Meta's supported document formats (such as PDF, plain text, Word, Excel, and PowerPoint) | 100 MB |

Attachments exceeding their class size cap or using an unsupported MIME type
fail permanently with `outbound_attachment_unsupported` on their attachment
Delivery intent while sibling text intents still deliver independently.

## The Customer Service Window

Meta closes the free-form customer service window 24 hours after the user's
latest message, rejecting free-form sends afterward unless re-opened by a paid
template message (templates are outside this adapter's scope).

Before dispatching any outbound send on an existing chat, the adapter checks the
chat's latest user activity timestamp:

- If that timestamp is older than 23 hours 55 minutes (24 hours minus a 5-minute
  safety margin), the Delivery intent halts immediately with permanent
  `customer_service_window_closed` without calling Meta—so background Job or
  cron notifications finishing more than 24 hours after the user last spoke will
  not deliver automatically (once the user writes again, an operator can trigger
  one retry from the Console Signal Routing page).
- Because tapping an interactive reply button or list row also re-opens Meta's
  24-hour window, the adapter records the provider-reported timestamp of each
  valid interactive reply under the channel row lock (keeping `max` so
  out-of-order late webhooks never move the timestamp backward, and ignoring
  unresolved/stale tokens) and compares against the newer of the latest human
  message and latest valid interactive tap.
- Channels with zero prior human messages—such as a one-off mapping notice sent
  to an unmapped sender—have no closed window to enforce and send immediately.

## Failures and Secrets

Because Cloud API message sends carry no idempotency key and offer no read-back
on dropped connections, network or `5xx` errors during message send—or failures
after an earlier chunk of a multi-message reply already succeeded—settle as
`unknown` (operators can manually requeue a visible reply once with a
possible-duplicate notice; media upload failures prior to sending any message
remain safely retryable). Graph API and HTTP errors classify into three buckets:

- **Operator action required:** expired/revoked tokens (`190`), quality/spam
  phone restrictions (`131048`), and HTTP `401` / `403`.
- **Retryable:** throughput caps (`130429`), pair rate limits (`131056`),
  Meta-advised transient errors (`131000`), service unavailability (`131016`),
  HTTP `429`, and `5xx` responses.
- **Permanent:** closed customer-service window (`131047`), undeliverable/unreachable
  recipient (`131026`), unsupported message type (`131051`), media rejection
  (`131053`), unregistered sender number (`133010`), and all other HTTP `400`
  errors.

Asynchronous `failed` status webhooks arriving after an HTTP-accepted send are
logged for diagnostics only, since the Delivery intent has already settled as
confirmed. `AppConfigure` encrypts the App secret, verify token, and System User
access token at rest and keeps them out of logs, error rows, and stored raw
payloads.

## Tests

Automated tests cover plugin declarations, single-binding phone ownership and
shared-App secret consistency, `GET` hub challenge verification,
`x-hub-signature-256` checks, multi-number webhook routing, `wamid`
deduplication, message/media projection, ignored message types, E.164 mobile
identity matching, the 25 MB download cap and file-service storage, ordinal
button/list rendering and `context.id` verification, media uploads, `unknown`
send handling, Graph error-code classification, and 24-hour customer-service
window enforcement. Live WhatsApp acceptance testing requires an operator Meta
App and Business phone number outside the repository.

Implementation paths:

- `plugins/whatsapp_adapter/lib/ankole/plugins/whatsapp_adapter.ex`
- `plugins/whatsapp_adapter/lib/ankole/plugins/whatsapp_adapter/`
