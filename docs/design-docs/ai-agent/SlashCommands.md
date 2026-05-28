# Slash Commands

Slash commands enter BullX through IM adapters. Adapter-local setup/auth
commands are handled before IMGateway handoff; AIAgent commands are normalized
and delivered through MailBox.

## Catalog

`BullX.AIAgent.CommandCatalog` is code-owned. It defines canonical English
command names, display slashes, localized aliases, and descriptions.

Current system commands:

- `command`
- `status`

Current AIAgent commands:

- `new`
- `compress`
- `retry`
- `steer`
- `stop`
- `undo`

Localized aliases are normalized by adapters before they set
`data.routing_facts.command_name`.

## Adapter-Local Commands

These commands are handled inside the provider adapter:

- `/root_init <code>`
- `/webauth`

They are restricted to direct/private contexts by the adapters and do not depend
on IMGateway storage, MailBox routing, or AIAgent conversations.

## AIAgent Handling

`BullX.AIAgent.Commands` handles canonical AIAgent commands:

- `new`: cancels any active generation, closes the active conversation, and
  creates a fresh active conversation for the same key.
- `compress`: runs manual compression when no generation is active.
- `retry`: starts generation again from the selected trigger context.
- `steer`: appends a steering note while generation is active.
- `stop`: cancels active generation, interrupts generating messages, and
  recalls visible delivery targets when possible.
- `undo`: rewinds the last exchange and recalls visible delivery targets when
  possible.

Visible command responses go through IMGateway.

## Stop Preemption

During streaming generation, Runner checks later pending entries in the same
MailBox session for an authorized `stop` command. When found, it cancels the
generation lease and interrupts the visible stream.

## Invariants

- Canonical command names in AIAgent are English ids.
- Setup/auth commands are adapter-local.
- Command responses do not bypass IMGateway.
- Command idempotency is owned by AIAgent conversation and generation state, not
  by MailBox retries.
