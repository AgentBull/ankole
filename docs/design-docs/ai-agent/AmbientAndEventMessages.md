# Ambient And Event Messages

AIAgent distinguishes addressed input, ambient input, and commands after
MailBox delivery. IMGateway stores provider IM facts and lifecycle facts;
AIAgent consumes normalized message input, lifecycle revision signals, and
command input.

## Message Mail

Message mail uses source-neutral CloudEvents types:

- `bullx.message.received`
- `bullx.message.edited`
- `bullx.message.recalled`
- `bullx.message.deleted`

IMGateway mail includes:

- `data.source_fact`
- `data.conversation_context`
- `data.actor_principal_uid`
- `data.content`
- `data.channel`
- `data.scope`
- `data.refs`
- `data.reply_address`
- `data.routing_facts`

MailBox delivery rules attach entry attention:

- `addressed`
- `ambient`
- `command`
- `system`

AIAgent uses entry attention to classify `bullx.message.received` mail and uses
`data.conversation_context` as the preferred source for conversation identity.

## Addressed Messages

Addressed messages create or reuse an addressed conversation key. AIAgent
appends a normal user message once per MailBox entry and starts generation.
Slash commands are not parsed from addressed message text at this layer.

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

Adapters normalize localized slash aliases before setting `data.command.name`
and `data.routing_facts.command_name`. Unknown slash command names are still
delivered as command mail.

Command events enter AIAgent through MailBox and are handled by
`BullX.AIAgent.Commands`. Command visible responses go through IMGateway.

IMGateway-direct commands are adapter-local and never require MailBox:

- `/root_init`
- `/webauth`
- `/command`
- `/status`

## Actions

Provider action callbacks that should continue a conversation are normalized as
`bullx.message.received` mail with an action content block. AIAgent sees the
selected action as ordinary user message content, not as a separate event type.

## Edits, Recalls, And Deletes

Provider edit/recall/delete events update the current `im_messages` row, then
route as source-neutral lifecycle mail:

- `bullx.message.edited`
- `bullx.message.recalled`
- `bullx.message.deleted`

AIAgent handles these events as revisions to existing conversation context. It
resolves the target message from provider refs, ignores revisions outside the
current mailbox session or outside the branch rendered after the latest
compatible compression, and never treats lifecycle mail as a fresh user message.

When a historical target is still eligible, AIAgent appends a stable ref marker
to the original message and appends an introspection message such as "ref id ...
的消息被编辑为..." or "已被删除". This changes future context without immediately
triggering generation. Latest addressed revisions that already produced or are
producing visible output may cancel generation, recall output, and republish the
new message content as `bullx.message.received`.

## Invariants

- IMGateway owns the IM message fact.
- MailBox owns the receiver delivery entry and attention.
- AIAgent owns conversation interpretation and generation.
- AIAgent input is message data, lifecycle revision signals, and command data.
- Ambient observation does not automatically mean visible reply.
- Visible replies do not bypass IMGateway.
