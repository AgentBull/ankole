# IMGateway

IMGateway is the current IM boundary. It stores the provider room/message facts
that BullX owns, then hands routeable conversation input or command mail to
MailBox.

The implementation lives in `BullX.IMGateway` and `BullX.IMGateway.*`.

## Responsibility

IMGateway owns:

- `im_rooms`
- `im_messages`
- human actor resolution before human IM facts are written
- provider message upsert and lifecycle updates
- outbound IM fact creation and delivery status updates

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

`accept_message_event/2` treats these message event types as IM facts:

- `bullx.message.received`
- `bullx.command.invoked`
- `bullx.action.submitted`
- `bullx.message.edited`
- `bullx.message.recalled`
- `bullx.message.deleted`

Any other message event type is rejected by IMGateway. Non-IM CloudEvents enter
MailBox through the gateway that owns those facts, not through IMGateway.

## Human Actor Rule

If `data.actor` is a human actor, IMGateway calls
`BullX.Principals.ensure_human_from_channel_actor/1` before inserting the
message. The resulting Principal uid and external identity id are copied back
into the actor map and the `im_messages` row.

A human `im_messages` row must have `actor_principal_uid`; PostgreSQL enforces
this with `im_messages_human_actor_has_principal`.

Addressed received messages and command mail from a human channel actor are
routed only when the channel external identity has `verified_at`. Unverified
human actors can still be stored as IM facts. Ambient received messages can be
routed without identity verification. Lifecycle facts are stored by IMGateway
and routed as source-neutral lifecycle mail. Legacy action facts are stored by
IMGateway but skipped; provider actions that continue a conversation should be
normalized as `bullx.message.received` with an action content block.

## Tables

`im_rooms` stores provider room identity:

- `provider`
- `source_id`
- `provider_realm_id`
- `provider_room_id`
- `kind`: `direct`, `group`, `channel`, `thread`, or `unknown`
- `title`
- `parent_room_id`
- `metadata`

`provider`, `source_id`, and `provider_room_id` are unique together.

`im_messages` stores inbound and outbound IM facts:

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
  -> ensure human actor Principal when needed
  -> upsert im_rooms
  -> insert or update im_messages
  -> build source-neutral BullX CloudEvents mail
  -> MailBox.route/2 when the fact is routeable agent input
```

IMGateway builds internal mail with:

- `source = bullx://im-gateway/<provider>/<source_id>`
- `type = bullx.message.received`, `bullx.message.edited`,
  `bullx.message.recalled`, `bullx.message.deleted`, or
  `bullx.command.invoked` for routeable AIAgent input
- `subject = im://<provider>/<source_id>/<room_id>/<message_id>`
- `data.source_fact.gateway = "im_gateway"`
- `data.source_fact.kind = "im_message"`
- `data.source_fact.id`
- `data.source_fact.room_id`
- `data.source_fact.event_type`
- optional `data.source_fact.revision` for lifecycle mail
- `data.conversation_context`
- optional `data.command` for command events
- channel, scope, actor, refs, reply address, routing facts, and raw reference

The mail data contains the normalized content and source-neutral conversation
context AIAgent needs for conversation handling. Provider edit/recall/delete
events update the `im_messages` fact and create lifecycle mailbox entries.
AIAgent handles those entries as revisions to existing conversation context; it
does not call back into IMGateway to reconstruct context.

## Outbound Flow

Agents send visible IM output through `BullX.IMGateway.send_message/2`.

```text
agent output
  -> send_message/2
  -> upsert outbound room from reply_address
  -> insert or update outbound im_messages(status = pending)
  -> ChannelAdapter.deliver/3
  -> update outbound im_messages(status/provider_message_id/safe_error)
```

The outbound adapter payload contains:

- `id`
- `op`, defaulting to `send`
- `content`
- optional `target_external_id`

Successful adapter delivery normally marks the message `sent`. A delivery result
with status `recalled` marks it `recalled`. Adapter errors mark it `failed` with
a safe error map.

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

- IM facts are stored before routeable IM mail is handed to MailBox.
- MailBox entries reference IM facts; they do not duplicate the provider
  message as business truth.
- Human IM message rows must reference a Principal.
- The adapter id in a normalized message event must match the plugin extension id.
- Outbound visible IM output goes through IMGateway, not directly to adapters.
