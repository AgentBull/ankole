# Ambient And Event Messages

AIAgent distinguishes addressed input, ambient input, and commands after
MailBox delivery. IMGateway best-effort mirrors provider message and lifecycle
facts; AIAgent consumes normalized message input, lifecycle revision signals,
and command input from MailBox rather than reading IM mirror rows.

## Message Mail

Message mail uses source-neutral CloudEvents types:

- `bullx.message.received`
- `bullx.message.edited`
- `bullx.message.recalled`
- `bullx.message.deleted`

IMGateway mail includes:

- `data.queue_key`
- `data.source_fact`
- `data.conversation_context`
- `data.actor_principal_uid`
- `data.content`
- `data.channel`
- `data.scope`
- `data.refs`
- `data.reply_address`
- `data.routing_facts`

MailBox entries carry derived attention:

- `addressed`
- `ambient`
- `command`
- `action`
- `lifecycle`
- `system`

AIAgent uses `addressed` and `ambient` attention to classify
`bullx.message.received` mail, `command` attention for command mail, and
`lifecycle` attention for edit/recall/delete control mail. It uses
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

When source `group_message_mode` is `observe_all`, the message is context only.
When it is `engage_all`, the ambient batch worker can produce an `im_ambient`
introspection message and trigger generation.

Ambient normal messages are skipped by prompt rendering and normal compression.
Ambient introspection messages can be rendered as user-facing context when they
trigger generation.

## Commands

Adapters normalize localized slash aliases before setting `data.command.name`
and `data.routing_facts.command_name`. Unknown slash command names are still
delivered as command mail.

Command events enter AIAgent through MailBox and are handled by
`BullX.AIAgent.Commands`. Command visible responses are control-plane output
sent through the current IM reply address and are not mirrored to `im_messages`.

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

Provider edit/recall/delete events route as source-neutral lifecycle mail and
may update the `im_messages` mirror when the mirror row exists:

- `bullx.message.edited`
- `bullx.message.recalled`
- `bullx.message.deleted`

AIAgent handles these events as revisions to existing conversation context. It
resolves the target message from provider refs, ignores revisions outside the
current mailbox queue/conversation scope or outside the transcript rendered
after the latest compatible compression, and never treats lifecycle mail as a
fresh user message.
The target is chosen from provider refs, not from the edited payload's current
addressedness; if a user edits an `@agent` request into "never mind" while the
agent is still generating, AIAgent cancels the active generation and recalls any
recallable visible output instead of republishing the edited text.

When a historical target is still eligible, AIAgent appends a stable ref marker
to the original message and appends an introspection message such as "ref id ...
的消息被编辑为..." or "已被删除". This changes future context without immediately
triggering generation. Latest addressed revisions that already produced or are
producing visible output may cancel generation, recall output, and republish the
new message content as `bullx.message.received`.

For coalesced IM batches, `data.im_batch.items` stores the ordered source
items. Edits update only the matching item, recalls and deletes remove that
item from the active batch, and the effective batch lane is recomputed from
active items. If any active item is addressed, the whole batch is addressed. If
a formerly addressed batch loses all active addressed items, `engage_all`
sources may republish remaining deliverable items as ambient; addressed-only or
otherwise ignored remainder cancels or revises the old output without creating a
new AIAgent turn.

## Invariants

- IMGateway owns the IM boundary and best-effort IM mirror.
- MailBox owns the receiver delivery entry and derived attention.
- AIAgent owns conversation interpretation and generation.
- AIAgent input is message data, lifecycle revision signals, and command data.
- Ambient observation does not automatically mean visible reply.
- Visible assistant replies do not bypass IMGateway; command feedback is
  non-persisted control output.
