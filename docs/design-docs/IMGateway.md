# IMGateway

IMGateway is the current IM boundary. It validates normalized provider events,
routes source-neutral IM mail to MailBox, and best-effort mirrors provider
room/message facts into `im_rooms` and `im_messages` for future memory use.
Mail routing and outbound delivery do not depend on those mirror rows.

The implementation lives in `BullX.IMGateway` and `BullX.IMGateway.*`.

## Responsibility

IMGateway owns:

- source-neutral IM CloudEvents mail construction
- inbound event idempotency before MailBox delivery
- human actor resolution before routing or mirroring human IM messages
- best-effort `im_rooms` and `im_messages` mirrors for message and lifecycle
  facts
- mirror-only blackhole decisions for IM facts that should not become receiver
  mail
- outbound adapter delivery and best-effort outbound mirror updates

IMGateway does not own:

- MailBox routing rules or Agent dispatch
- AIAgent conversations or LLM turns
- room membership
- provider setup storage
- non-IM gateway facts

## Input

Plugin adapters call `BullX.IMGateway.ChannelAdapter.accept_inbound/4`.

The adapter boundary:

1. fetches the enabled channel adapter extension;
2. calls `normalize_inbound/2`;
3. validates `data.channel.adapter` against the extension id;
4. calls `BullX.IMGateway.accept_message_event/2`.

`accept_message_event/2` accepts these IM event types:

- `bullx.message.received`
- `bullx.command.invoked`
- `bullx.action.submitted`
- `bullx.message.edited`
- `bullx.message.recalled`
- `bullx.message.deleted`

Any other message event type is rejected by IMGateway. Command and legacy action
events may be accepted for routing or skip decisions, but they are not mirrored
to `im_messages`. Non-IM CloudEvents enter MailBox through the gateway that owns
those facts, not through IMGateway.

## Human Actor Rule

If `data.actor` is a human actor, IMGateway calls
`BullX.Principals.ensure_human_from_channel_actor/1` before routing or
mirroring the message. The resulting Principal uid and external identity id are
copied back into the actor map and, when a mirror row is written, into
`im_messages`.

Addressed received messages and command mail from a human channel actor are
routed only when the channel external identity has `verified_at`. Unverified
human actors can still be stored as IM facts. Ambient received messages can be
routed without identity verification. Lifecycle facts are routed as
source-neutral lifecycle mail and mirrored on a best-effort basis. Legacy action
facts are skipped and not mirrored; provider actions that continue a
conversation should be normalized as `bullx.message.received` with an action
content block.

## Tables

`im_rooms` mirrors provider room identity:

- `provider`
- `source_id`
- `provider_realm_id`
- `provider_room_id`
- `kind`: `direct`, `group`, or `unknown`
- `title`
- `parent_room_id`
- `metadata`

`provider`, `source_id`, and `provider_room_id` are unique together.
Provider channels are normalized as `group`; thread identity is encoded in
`provider_room_id` when the provider scope carries a thread id.

`im_messages` mirrors inbound and outbound IM message facts:

- `room_id`
- `direction`: `inbound` or `outbound`
- `status`: `pending`, `received`, `sent`, `edited`, `recalled`, `deleted`, or
  `failed`
- provider message and occurrence ids
- actor kind, Principal uid, external identity id, provider actor id, and raw
  actor map
- `message_kind`, `text`, `content`, `attachments`, and `mentions`
- `reply_address`
- provider timestamps, received/sent timestamps, and `safe_error`

Within one room, `provider_message_id` and `provider_occurrence_id` each have
unique partial indexes when present.

## Inbound Flow

```text
normalized provider message event
  -> dedupe by provider event id for the inbound window
  -> ensure human actor Principal when needed
  -> build source-neutral BullX CloudEvents mail
  -> MailBox.route/2 when the fact is routeable receiver input,
     or blackhole after mirroring when the source mode says observe only
  -> best-effort mirror message/lifecycle facts to im_rooms + im_messages
```

IMGateway builds internal mail with:

- `source = bullx://im-gateway/<provider>/<source_id>`
- `type = bullx.message.received`, `bullx.message.edited`,
  `bullx.message.recalled`, `bullx.message.deleted`, or
  `bullx.command.invoked` for routeable AIAgent input
- `subject = im://<provider>/<source_id>/<provider_room_id>`
- `data.queue_key = im://<provider>/<source_id>/<provider_room_id>`
- `data.source_fact.gateway = "im_gateway"`
- `data.source_fact.kind = "im_message"`
- `data.source_fact.id`
- `data.source_fact.room_key`
- `data.source_fact.provider_message_id`
- `data.source_fact.provider_occurrence_id`
- `data.source_fact.event_type`
- optional `data.source_fact.revision` for lifecycle mail
- `data.attention`
- `data.coalesce.window_ms = 6000` and `data.coalesce.max_chars = 8000`
- `data.conversation_context`
- optional `data.command` for command events
- channel, scope, actor, refs, reply address, routing facts, and raw reference

The mail data contains the normalized content and source-neutral conversation
context AIAgent needs for conversation handling. Provider edit/recall/delete
events create lifecycle mailbox entries and may update the mirror row when the
mirror exists. AIAgent handles those entries as revisions to existing
conversation context; it does not call back into IMGateway to reconstruct
context. Lifecycle mail is routeable by provider source refs even when the
edited payload is no longer addressed; a user editing an `@agent` request into
"never mind" must still reach AIAgent so the already-triggered turn can be
cancelled or recalled.

Group message handling is one three-value mode:

- `addressed_only`: adapters normally emit only DMs, mentions, replies,
  commands, and other explicitly addressed input.
- `observe_all`: unaddressed group messages are mirrored and blackholed instead
  of being forwarded to MailBox.
- `engage_all`: unaddressed group messages are mirrored and forwarded as
  ambient mail.

When multiple received messages from the same actor are coalesced, the batch is
addressed if any active item in the batch is addressed. If an edit, recall, or
delete arrives before a pending coalesced receive entry has been materialized
into conversation state, MailBox applies the lifecycle fact to that pending
entry instead of delivering stale content. If the receive entry is already
leased but has not materialized, MailBox defers the lifecycle entry briefly; if
the target message has materialized, the lifecycle entry dispatches immediately
so AIAgent can cancel an active generation.

## Outbound Flow

Agents send visible assistant output through `BullX.IMGateway.send_message/2`.

```text
agent output
  -> send_message/2
  -> ChannelAdapter.deliver/3
  -> best-effort mirror outbound result to im_rooms + im_messages
```

The outbound adapter payload contains:

- `id`
- `op`, defaulting to `send`
- `content`
- optional `target_external_id`

Successful adapter delivery normally mirrors the message as `sent`. A delivery
result with status `recalled` mirrors it as `recalled`. Adapter errors are
returned to the caller and, when the mirror write succeeds, mirrored as `failed`
with a safe error map. Mirror failures do not change the adapter delivery
result.

## Channel Adapter Contract

`BullX.IMGateway.ChannelAdapter` is the common plugin contract. Current adapter
ids use the regex `[a-z][a-z0-9_]*`.

Callbacks:

- `normalize_inbound(source, provider_input)`
- `deliver(source, reply_address, outbound, opts)`
- `fetch_source(source_id)`
- `consume_stream(source, reply_address, stream_id, opts)`
- `capabilities()`

The optional `consume_stream/4` callback is used by visible streaming output.

## Invariants

- Routeable IM mail does not depend on `im_rooms` or `im_messages` primary keys.
- Commands, command replies, and legacy action events are not persisted to
  `im_messages`.
- MailBox entries reference source-neutral mail data and queue keys, not
  `im_messages` rows.
- Human actor resolution happens before routing or mirroring human IM messages.
- The adapter id in a normalized message event must match the plugin extension id.
- Assistant visible IM output goes through IMGateway, not directly to adapters.
