# Ambient And Event Messages

AIAgent distinguishes addressed input, ambient input, commands, actions, and IM
lifecycle events after MailBox delivery. IMGateway stores the same provider IM
message fact regardless of whether a receiver later treats it as addressed or
ambient.

## IMGateway Mail

IMGateway emits internal mail with:

- `data.im_message_id`
- `data.im_room_id`
- `data.actor_principal_id`
- `data.content`
- `data.channel`
- `data.scope`
- `data.refs`
- `data.reply_address`
- `data.routing_facts`
- `data.original_event_type`

MailBox delivery rules attach entry attention:

- `addressed`
- `ambient`
- `command`
- `action`
- `lifecycle`
- `system`

AIAgent uses the entry attention to classify received IM mail.

## Addressed Messages

Addressed messages create or reuse an addressed conversation key. AIAgent reads
the current IM message with `BullX.IMGateway.get_message/1`, appends a normal
user message once per MailBox entry, and starts generation unless the text is a
recognized slash command.

Visible addressed replies use the IM message reply address and are sent through
IMGateway.

## Ambient Messages

Ambient messages create or reuse an ambient conversation key. AIAgent appends
the ambient fact once as an `im_ambient` normal message.

When `unmentioned_group_messages` is `observe_only`, the message is context
only. When it is `may_intervene`, the ambient batch worker can produce an
`im_ambient` introspection message and trigger generation.

Ambient normal messages are skipped by prompt rendering and normal compression.
Ambient introspection messages can be rendered as user-facing context when they
trigger generation.

## Commands

Adapters normalize localized slash aliases into canonical English command names
before setting `data.routing_facts.command_name`.

Command events enter AIAgent through MailBox and are handled by
`BullX.AIAgent.Commands`. Command visible responses go through IMGateway.

System setup/auth commands are adapter-local and never require MailBox:

- `/root_init`
- `/webauth`

## Actions

`bullx.action.submitted` events are stored by IMGateway when they are IM events
and then delivered through MailBox. AIAgent handles supported action data
according to the current command/action implementation.

## Edits And Recalls

Provider edit/recall/delete events update the current `im_messages` row.
IMGateway then emits lifecycle mail types:

- `bullx.im.message.edited`
- `bullx.im.message.recalled`
- `bullx.im.message.deleted`

AIAgent currently handles edit and recall lifecycle events. Message revision
logic updates or marks relevant conversation state according to the current
implementation. Unsupported lifecycle events are ignored with telemetry.

## Invariants

- IMGateway owns the IM message fact.
- MailBox owns the receiver delivery entry and attention.
- AIAgent owns conversation interpretation and generation.
- Ambient observation does not automatically mean visible reply.
- Visible replies do not bypass IMGateway.
