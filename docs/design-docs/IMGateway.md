# IMGateway

IMGateway is the current IM boundary. It stores the provider room/message facts
that BullX owns, then hands an internal CloudEvents mail item to MailBox.

The implementation lives in `BullX.IMGateway` and `BullX.IMGateway.*`.

## Responsibility

IMGateway owns:

- `im_rooms`
- `im_messages`
- human actor resolution before human IM facts are written
- provider message upsert and lifecycle updates
- outbound IM fact creation and delivery status updates

IMGateway does not own:

- MailBox routing rules or receiver dispatch
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
4. calls `BullX.IMGateway.accept_cloud_event/2`.

`accept_cloud_event/2` treats these event types as IM facts:

- `bullx.im.message.addressed`
- `bullx.im.message.ambient`
- `bullx.command.invoked`
- `bullx.action.submitted`
- `bullx.message.edited`
- `bullx.message.recalled`
- `bullx.message.deleted`

Any other CloudEvents map is passed directly to `BullX.MailBox.route/2`.

## Human Actor Rule

If `data.actor` is a human actor, IMGateway calls
`BullX.Principals.ensure_human_from_channel_actor/1` before inserting the
message. The resulting Principal id and external identity id are copied back
into the actor map and the `im_messages` row.

A human `im_messages` row must have `actor_principal_id`; PostgreSQL enforces
this with `im_messages_human_actor_has_principal`.

Addressed, command, and action mail from a human channel actor is routed only
when the channel external identity has `verified_at`. Unverified human actors
can still be stored as IM facts. Ambient and lifecycle mail is routed even when
the identity is unverified.

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
- actor kind, Principal id, external identity id, provider actor id, and raw
  actor map
- `message_kind`, `text`, `content`, `attachments`, and `mentions`
- `reply_address`
- provider timestamps, received/sent timestamps, and `safe_error`

Within one room, `provider_message_id` and `provider_occurrence_id` each have
unique partial indexes when present.

## Inbound Flow

```text
normalized provider CloudEvent
  -> ensure human actor Principal when needed
  -> upsert im_rooms
  -> insert or update im_messages
  -> build BullX IM mail
  -> MailBox.route/2 when routeable
```

IMGateway builds internal mail with:

- `source = bullx://im-gateway/<provider>/<source_id>`
- `type = bullx.im.message.received` or an IM lifecycle type
- `subject = im://<provider>/<source_id>/<room_id>/<message_id>`
- `data.im_message_id`
- `data.im_room_id`
- channel, scope, actor, refs, reply address, routing facts, and raw reference

AIAgent later reads the current message through `BullX.IMGateway.get_message/1`.

## Outbound Flow

Receivers send visible IM output through `BullX.IMGateway.send_message/2`.

```text
receiver output
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
- The adapter id in a normalized event must match the plugin extension id.
- Outbound visible IM output goes through IMGateway, not directly to adapters.
