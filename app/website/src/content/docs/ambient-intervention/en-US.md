---
title: Ambient intervention
description: How the Agent decides whether to speak in a "May intervene" group, how its reply attaches to the person who asked, and how channel standing orders tell it when to speak.
section: User guide
order: 17
---

When a [signal binding](../signal-bindings/) sets the group message mode to **May intervene**, the Agent sees group messages that do not address it and routes each batch of new messages. Silence is the default. A useful batch can instead start a bounded reply, identify new work, or update one active background job.

This page explains how that judgment behaves and the two controls you have over it: channel standing orders and the binding itself.

## Each message is judged once

The Agent keeps a judgment cursor per channel. Each check judges only the messages that arrived after the last check; older messages appear only as background and are never re-evaluated. A message the Agent decided to leave alone does not suddenly get answered several rounds later.

Every judgment records its action, authorization source, and reason. A background handoff also records its exact target. When the Agent seems too quiet or too eager, operators can inspect the selected route instead of guessing.

## Four routes

- **No action (`NOOP`)** keeps the Agent silent. This is the usual result for chatter, acknowledgements, duplicated answers, or work already handled by a person.
- **Foreground reply (`FOREGROUND_REPLY`)** starts one concise visible turn for an answer, clarification, coordination, status report, or small bounded lookup. This route cannot create or respawn a background job.
- **New work (`NEW_WORK`)** identifies a distinct, substantive task. A direct human request or a matching standing order authorizes the normal owner turn. Without either source, the Agent can only ask whether it should take the work on; it gets no tools and cannot start a job in that confirmation turn.
- **Handoff (`HANDOFF`)** silently sends the new messages to exactly one matching live background job from the same Agent, owner session, channel, and binding. An ambiguous or incomplete candidate set cannot produce a handoff.

The recognizer never creates a background job. It only selects the route and authorization source. The normal owner turn still applies the usual approval and background-work rules.

## Replies attach to the person who asked

When the Agent decides to speak, it separates two cases:

- **Someone is asking it** — one of the new messages actually asks or addresses the Agent, even without an @ mention. Its reply then anchors to that message: on channels that support it, this renders as a quote reply or a thread reply, so the room can see whom it is answering.
- **Volunteering** — nobody addressed it, but the Agent judges that adding information helps now (or a standing order matched). The reply goes out as a normal group message.

The attribution is validated: the identified ask must exist in the judged batch, come from a human, and its author must still be the latest speaker. The Agent does not dig up an old question after the room has moved on; that case degrades to a normal proactive reply.

## Channel standing orders

Standing orders are one durable policy text attached to a channel. They tell the Agent when to speak proactively in that room. Examples:

- "Only speak when CI turns red or a deploy fails."
- "After 18:00, when someone posts a daily report, summarize it; stay quiet otherwise."
- "This is a customer group. Do not join unless someone asks a technical question directly."

**You set them by telling the Agent in the channel.** Any channel member can say "from now on, only speak here when CI turns red"; the Agent stores it as this channel's standing orders and records who asked. A change is a full replacement: when you ask it to amend the orders, it stores the complete new text. Say "clear this channel's standing orders" to remove them.

Standing orders reach two places: the route judgment treats them as the operator policy of the room and can use a semantic match to authorize `NEW_WORK`, while a visible owner turn also sees them in its context.

Two boundaries:

- **They activate only in May intervene mode.** Under other binding modes the text is stored but fully inert, and the Agent tells you it is inactive after saving. Switching the binding to May intervene activates it without further steps.
- One orders text holds at most 4000 characters.

The Console can also read and write standing orders; see the `/signal-channels/:channel_id/standing-orders` endpoints in the [Console API reference](../console-api/).

## Still speaking too much or too little

- **Too much**: tighten or clear the standing orders first, then tighten the Agent's role instructions; for a group that only needs question-and-answer behavior, switch the binding back to **Addressed messages only**.
- **Too little**: confirm the binding mode is May intervene, and give the channel one explicit standing order — the judgment defaults to conservative, and without orders the Agent speaks only when someone actually needs it.
- **Orders saved but nothing changes**: read the Agent's reply after it saves the orders — it reports whether they are active. Inactive almost always means the channel's binding mode is not May intervene.

## Next steps

- Group message modes and binding configuration: read [Signal bindings](../signal-bindings/).
- How messages become Agent work items: read [SignalsGateway](../signals-gateway/).
