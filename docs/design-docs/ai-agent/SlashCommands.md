# Slash Commands

Slash commands enter BullX through IM adapters. Commands that can be answered at
the IM boundary are handled before IMGateway handoff. Other slash commands,
including unknown command names, are delivered through MailBox as
`bullx.command.invoked`.

## Catalog

`BullX.AIAgent.CommandCatalog` is code-owned. It defines canonical English
command names, display slashes, localized aliases, and descriptions.

Current IMGateway-direct commands:

- `command`
- `status`
- `root_init`
- `webauth`

Current AIAgent commands:

- `new`
- `compress`
- `retry`
- `steer`
- `stop`
- `undo`

Localized aliases are normalized by adapters before they set
`data.command.name` and `data.routing_facts.command_name`. Unknown slash command
names are still delivered as command events so the Receiver can decide how to
respond.

## IMGateway-Direct Commands

These commands are handled inside the provider adapter before IMGateway handoff
or MailBox routing:

- `/root_init <code>`
- `/webauth`
- `/command`
- `/status`

`/root_init` and `/webauth` are restricted to direct/private contexts by the
adapters. `/command` and `/status` return boundary-owned status/help text. These
commands do not depend on IMGateway storage, MailBox routing, or AIAgent
conversations.

## AIAgent Handling

`BullX.AIAgent.Commands` handles `bullx.command.invoked` mail for canonical
AIAgent commands:

- `new`: cancels any active generation, closes the active conversation, and
  creates a fresh active conversation for the same key.
- `compress`: runs manual compression when no generation is active.
- `retry`: starts generation again from the selected trigger context.
- `steer`: appends a steering note while generation is active.
- `stop`: cancels active generation, interrupts generating messages, and
  recalls visible delivery targets when possible.
- `undo`: rewinds the last exchange and recalls visible delivery targets when
  possible.

Visible command responses are control-plane output. They use the current IM
reply address for provider delivery and are not mirrored to `im_messages`.

## Stop Preemption

During streaming generation, Runner polls the conversation generation lease.
`/stop` is a MailBox control entry and is claimed before normal entries in the
same receiver queue; the command handler cancels the generation lease. The
poller observes that cancellation and interrupts the visible stream.

## Invariants

- Canonical command names in AIAgent are English ids.
- IMGateway-direct commands are adapter-local.
- AIAgent does not parse addressed message text for slash commands.
- Command responses are not persisted as IM message facts.
- Command idempotency is owned by AIAgent conversation and generation state, not
  by MailBox retries.
