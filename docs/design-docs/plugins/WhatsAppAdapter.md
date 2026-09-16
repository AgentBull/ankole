# WhatsApp Adapter

The WhatsApp Adapter connects one WhatsApp Business phone number to one Agent
binding through the WhatsApp Business Platform Cloud API. WhatsApp is a consumer
IM. The category changes catalog and Console presentation only; the adapter uses
the same SignalsGateway contracts as every other Signal adapter.

Read [SignalsGateway](../SignalsGateway.md), [Principal](../Principal.md), and
[Local Password Identity Provider](../LocalPasswordIdentityProvider.md) for the
common message and identity rules.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `whatsapp-adapter` |
| Signal adapter ID | `whatsapp` |
| Adapter category | `consumer_im` |
| Signal configuration | `signals_gateway.whatsapp.bindings.<id>` |
| Webhook handler ID | `whatsapp` |
| Cloud API client | Project `Req` client against the Graph API, version `v25.0` |

The settings are the Meta App ID, the encrypted App secret, the encrypted verify
token, the phone number ID, and the encrypted System User access token. The
adapter uses no WhatsApp SDK and does not use the On-Premises API.

A channel is bound to the phone number that received its messages, and the
channel ID holds that number. If an operator moves a binding to another phone
number, replies to the older chats stop with an operator-action
`binding_phone_number_mismatch` error instead of going out from a number the
user never wrote to. Restoring the original number releases those replies on the
next binding save; keeping the new number leaves the older chats closed.

One phone number can belong to only one enabled binding, because two Agents
behind one number would both answer every message. Several phone numbers can
share one Meta App. Those bindings then share one callback URL, so enabled
bindings with the same App ID must carry the same App secret and the same verify
token; a save that breaks this is refused.

The adapter accepts one-to-one chats only. Meta serves WhatsApp groups through
the separate Groups API, which only an Official Business Account can use, so a
message that carries a group ID is ignored. The binding therefore supports the
`addressed_only` group message mode alone, which the Console preselects.

Inbound capabilities are `entry_receive` and `action_event`. The Cloud API
delivers no edit event and no removal event, so the adapter declares neither
`entry_removed` nor reactions: a message the user deletes in the WhatsApp app
never reaches the webhook.

Outbound capabilities are `post_entry`, `reply_entry`, `divider`, and `card`.
The Cloud API cannot edit or delete a sent message, so the adapter does not
declare `edit_entry` or `delete_entry`. It declares no reply-preview module,
because a sent message cannot change and a live preview would only add messages.
It also does not declare `outbound_reconciliation`: a message send has no
idempotency key and no read-back, so a repeat can duplicate the reply.

## Receive Webhooks

The Cloud API has no polling or socket transport. Meta owns the callback URL at
App level, so the route instance segment is the Meta App ID:

```text
https://<host>/webhooks/v1/whatsapp/<appId>/events
```

A GET verifies the subscription. Meta sends `hub.mode`, `hub.verify_token`, and
`hub.challenge`; the handler answers status 200 with the raw challenge as
`text/plain` when the mode is `subscribe` and the token matches the stored
verify token, and status 403 otherwise.

A POST carries the events. The handler checks the `x-hub-signature-256` header,
which is `sha256=` and the lowercase hex HMAC-SHA256 of the exact request bytes
keyed with the App secret. SignalsGateway keeps those bytes for every provider
webhook. A request with a wrong signature gets status 401 and an unknown App ID
gets status 404, before the handler reads any event.

One App can serve several phone numbers, and only some of them belong to this
installation. The handler reads `value.metadata.phone_number_id` of each change
and dispatches to the binding that owns that number. A change for a number no
binding serves is ignored and still gets status 200, so one unconfigured number
never blocks the others.

The handler completes durable SignalsGateway ingress for every message in the
request before it returns status 200. Meta retries a delivery that did not get a
200 for up to seven days and can also send the same message twice. The message
ID is its `source_event_id`, so the gateway stores a repeated message once.

Operator setup in the Meta App Dashboard:

1. Add the **WhatsApp** product to the App and connect the WhatsApp Business
   Account that owns the phone number.
2. Copy the App ID, the App secret, and the phone number ID into the binding,
   choose a verify token, and put the same token into the binding.
3. Set the callback URL above in **WhatsApp > Configuration**, enter the same
   verify token, and press **Verify and save**.
4. Subscribe the App to the `messages` webhook field. No other field is used.
5. Create a System User with the `whatsapp_business_messaging` permission, issue
   a permanent token for it, and copy that token into the binding. A user token
   expires and stops the Agent.

## Receive Messages

Every message is a one-to-one message and is explicit input. The channel ID
holds the phone number ID and the sender's `wa_id`. The Cloud API has no
threads, so the adapter records no provider thread: the chat is the channel, and
a quoted message is the only reply relation. The message ID is both the source
event ID and the source entry ID.

Text, image, video, audio, document, sticker, location, and contacts messages
enter the common message projection. A media caption becomes the entry text, a
document keeps the sender's file name, and a location or a shared contact card
becomes a short text line. A quick reply of a template message enters as its
plain button text.

A `reaction`, `unsupported`, `system`, `request_welcome`, or `order` message is
ignored, and so is a message with no text and no attachment. Delivery states
under `value.statuses` write nothing; a `failed` state is logged with its error
codes, because the message never reached the user.

## Admit WhatsApp Identities

The author provider is always `whatsapp`, and the stable external identity is
the `wa_id`. The webhook already carries the sender's WhatsApp profile name, so
the adapter declares no author hydrator.

The `wa_id` is the sender's phone number, which Meta verified before it issued
the account. The adapter therefore normalizes `+<wa_id>` to E.164 and supplies
it as the author mobile number. A Principal whose mobile number is that number
is matched at once, exactly as for an enterprise IM adapter with a directory
mobile number. A number the kernel cannot normalize is left out instead of
being stored in a broken form.

The binding owns `unmatched_sender_policy`. One standard consumer IM setup uses
this sequence:

1. An administrator signs in through LocalPassword and creates a human
   Principal.
2. The WhatsApp binding selects `manual_review`.
3. An unmatched user receives the fixed mapping notice. SignalsGateway creates a
   mapping request with the WhatsApp profile name and the phone number, and does
   not store the original message.
4. The administrator maps the WhatsApp external identity to the existing
   Principal.
5. The user sends the message again, and SignalsGateway admits it to the Agent.

This sequence describes a common setup. It is not a dependency between
LocalPassword and WhatsApp. The mapping target can be any existing human
Principal.

## Materialize Attachments

SignalsGateway first commits the admitted message with a pending attachment
observation inside the webhook request. A supervised task then reads the
temporary media URL, downloads the bytes, writes them to the Agent's
`user-files` lane, and updates the same entry. The webhook answer does not wait
for the download. If the task cannot start, the webhook fails and Meta delivers
the message again; the pending observation is already durable, so that
redelivery fetches the file. An unmatched sender cannot make Ankole download a
file.

A redelivered message keeps a result this Agent already holds and fetches
everything else again, including a download whose earlier task never finished,
because the adapter cannot prove that such a task is alive. SignalsGateway never
replaces an attachment this Agent can read with a later observation from this
Agent that has no path, so a second download that overlaps the first cannot lose
the file. A copy that another Agent downloaded does not count: when a route
moves to another Agent, that Agent fetches its own copy.

The media URL expires five minutes after Ankole reads it, so the download
follows at once. Ankole applies its own budget of 25 MB. For a larger file, the
adapter keeps the provider file metadata and a clear `provider_download_limit`
restriction. It never creates a local path for such a file or claims that the
Agent can read it.

## Send Replies and Actions

Every outbound operation is a Cloud API message send to
`POST /<version>/<phoneNumberId>/messages` with the System User token. The
adapter uses the returned `wamid` values as source entry IDs and keeps every
sent ID on the outbox row, because a long reply is several messages.

The adapter splits text at 4,096 characters and sends one request for each
chunk. A reply puts the human message ID in `context.message_id` of the first
chunk, so WhatsApp shows the quoted message. A divider is a text separator.

A pending clarification renders its choices as one interactive message. Up to
three choices become reply buttons with titles of at most 20 characters; more
become one list section with row titles of at most 24 characters.
SignalsGateway allows at most eight choices, which stays inside the Cloud API
limit of ten list rows. The button that opens a list carries a fixed localized
label, because it only opens the rows and does not repeat the question. Each
button or row carries a short token of at most 256 bytes that names the
ActorEvent, the action index, and the action fingerprint; it does not contain
the action.

Every title starts with its ordinal, as in "1. Approve the release". The Cloud
API refuses a whole interactive message whose titles repeat, and two long
choices cut to the title limit read the same, so the ordinal keeps them apart.
It also tells the user which choice a short title stands for: when a button
title cannot hold its label, the numbered full labels follow the prompt under a
blank line, and a cut row title keeps its full text in the row description.

A reply that asks for a choice is several messages: the text chunks first and
the interactive message last. The adapter records the ID of that interactive
message as the ActorEvent's reply surface, because that is the message the
buttons live on. The row's created entry ID stays the first message, as for
every other reply.

On an interactive reply, the adapter resolves the WhatsApp user to a Principal,
restores the action from the durable checkpoint, and checks that the reply's
`context.id` names that same reply surface before it submits the standard
SignalsGateway action event. A stale token, a token that answers from another
message, and a reply that names a text chunk of the same answer instead of the
interactive message all produce no visible change.

An outbound attachment is uploaded first with
`POST /<version>/<phoneNumberId>/media` and then sent by its media ID. The
Cloud API accepts one message type for each media class:

| Message type | Accepted content | Size limit |
| --- | --- | --- |
| `image` | JPEG, PNG | 5 MB |
| `video` | MP4, 3GPP | 16 MB |
| `audio` | AAC, MP4, MPEG, AMR, OGG | 16 MB |
| `document` | The Meta document list, such as PDF, plain text, and the Word, Excel, and PowerPoint formats | 100 MB |

A file that is larger than the limit of its type, or whose content type is not
in these lists, stops that attachment row with a permanent
`outbound_attachment_unsupported` error. The text row still goes out, because
the gateway stores each attachment in its own outbox row.

## The Customer Service Window

Meta closes the customer service window 24 hours after the user's newest
message. A free-form message after that is rejected, and only a paid template
message can open a new window. Templates are outside this adapter's contract.

Before every send, the adapter reads the newest human message of the channel. If
that message is older than the window, less a five minute margin, the row stops
with a permanent `customer_service_window_closed` error and no request reaches
Meta. A reply that a background job or a scheduled push produces more than 24
hours after the user wrote therefore never arrives. An operator can use the
Retry action of the Signal Routing page in Console to give that stopped row one
more send after the user writes again.

Meta re-opens the window on any user action, and a button or list reply is one.
The adapter keeps the time of the newest interactive reply on the channel,
exactly as WhatsApp reports it on the message, and reads the newer of that time
and the newest human message. A user who answers a clarification after 24 hours
can therefore still receive the Agent's answer, while a tap that Meta delivers
late does not open a window that has already closed. The adapter records that
time under the channel row lock and keeps the newest one, so an older tap that
Meta delivers later cannot move the window back. A callback whose token does not
resolve leaves no fact, so a stale token does not re-open the window.

A channel that holds no human message at all, such as the one that carries the
mapping notice to a held sender, never had a window to close, so the adapter
sends it.

## Failures and Secrets

A message send has no idempotency key, and the Cloud API offers no read-back of
a request whose answer was lost. A transport failure or a server error on a send
is therefore uncertain, and so is any failure after an earlier message of the
same reply already landed. The adapter reports `unknown` for those cases; the
gateway then applies its possible-duplicate flow, and the retry that carries the
duplicate notice sends. A failure on the media upload, before any message
request, is an ordinary retryable failure.

The adapter classifies the Graph error code and the HTTP status:

- An expired or revoked token (code 190), a phone number that a quality or spam
  signal restricted (code 131048), and status 401 or 403 require operator
  action.
- The throughput limit (code 130429), the per-pair limit (code 131056), the
  generic failure that Meta asks the caller to repeat (code 131000), an
  unavailable service (code 131016), status 429, and a server error are
  retryable.
- A closed customer service window (code 131047), an unreachable number (code
  131026), an unsupported message type (code 131051), rejected media (code
  131053), an unregistered number (code 133010), and every other status 400 are
  permanent.

An asynchronous `failed` status that arrives after a successful send is logged
only. The outbox row already recorded a success, so Ankole cannot repair that
delivery by itself.

AppConfigure encrypts the App secret, the verify token, and the access token.
They do not enter logs, persisted errors, or stored raw provider payloads.

## Tests

Repository tests cover declaration validation, phone number ownership and
shared-App credential consistency, subscription verification, signature
validation, fan-out by phone number ID, redelivery deduplication, message and
attachment projection, ignored message kinds, identity policies including the
mobile match, attachment limits and materialization into the user-files lane,
interactive button and list replies with token resolution, outbound request
construction, media upload, uncertain sends, failure classification, and the
customer service window check. Real WhatsApp acceptance needs an operator App
and phone number that the repository does not contain.

The implementation sources are:

- `plugins/whatsapp_adapter/lib/ankole/plugins/whatsapp_adapter.ex`
- `plugins/whatsapp_adapter/lib/ankole/plugins/whatsapp_adapter/`
