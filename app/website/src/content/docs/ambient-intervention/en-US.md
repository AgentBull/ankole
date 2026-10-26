---
title: Ambient intervention
description: How the Agent decides whether to speak in a "May intervene" group, how its reply attaches to the person who asked, and how channel standing orders tell it when to speak.
section: User guide
order: 17
---

When **May intervene** is enabled — either through the group message mode on a [signal binding](../signal-bindings/) for an external channel or through an Agent participant's `may_intervene` policy in a native **Pod Chat** group thread — the Agent sees group messages that do not address it and routes each batch of new human messages. Silence is the default. A useful batch can instead start a bounded reply, identify new work, or update one active background job.

Group behavior in this mode depends on two controls: conversation `standing_orders` and the group intervention setting (the Signal Binding configuration for external channels, or per-Agent `may_intervene` in Pod Chat group threads, which operate without a Signal Binding).

## Each message is judged once

Each Agent keeps its own judgment progress for a Conversation. Agents in the same group Conversation share messages and standing orders, but they do not share judgment progress. Only **human** messages trigger ambient checks — Agent messages never wake Agents. Each check judges only the messages that arrived after the last check; older messages appear only as background and are never re-evaluated. A message the Agent decided to leave alone does not suddenly get answered several rounds later.

Every judgment records its action, authorization source, and reason. A background handoff also records its exact target. When the Agent seems too quiet or too eager, operators can inspect the selected route instead of guessing.

## Four routes

- **No action (`NOOP`)** keeps the Agent silent. This is the usual result for chatter, acknowledgements, duplicated answers, or work already handled by a person.
- **Foreground reply (`FOREGROUND_REPLY`)** starts one concise visible turn for an answer, clarification, coordination, status report, or small bounded lookup. This route cannot create or respawn a background job.
- **New work (`NEW_WORK`)** identifies a distinct, substantive task. A direct human request or a matching standing order authorizes the normal owner turn. Human-triggered turns run under the **`Human ∩ Agent` permission intersection** (`interactive_principal = waking_human`), so both the waking human and the Agent must hold permission for each accessed resource. Without either authorization source, the Agent can only ask whether it should take the work on; it gets no tools and cannot start a job in that confirmation turn.
- **Handoff (`HANDOFF`)** silently sends the new messages to one matching live background job from the same Agent, owner Session, and Conversation (and the same binding when triggered from an external channel). An ambiguous or incomplete candidate set cannot produce a handoff.

The recognizer never creates a background job. It only selects the route and authorization source. The normal owner turn still applies the usual approval and background-work rules.

## Replies attach to the person who asked

When the Agent decides to speak, it separates two cases:

- **Someone is asking it** — one of the new messages actually asks or addresses the Agent, even without an @ mention. Its reply then anchors to that message: on channels that support it, this renders as a quote reply or a thread reply, so the room can see whom it is answering.
- **Volunteering** — nobody addressed it, but the Agent judges that adding information helps now (or a standing order matched). The reply goes out as a normal group message.

The attribution is validated: the identified ask must exist in the judged batch, come from a human, and its author must still be the latest speaker. The Agent does not dig up an old question after the room has moved on; that case degrades to a normal proactive reply. If the platform later deletes an accepted ask, the stored attribution becomes degraded with no message anchor. The judgment and its progress remain.

## Channel standing orders

Standing orders are one durable policy text attached to a Conversation and shared by its Agent participants. They tell the Agent when to speak proactively in that room. Examples:

- "Only speak when CI turns red or a deploy fails."
- "After 18:00, when someone posts a daily report, summarize it; stay quiet otherwise."
- "This is a customer group. Do not join unless someone asks a technical question directly."

**You set them by telling the Agent in the channel.** Any channel member can say "from now on, only speak here when CI turns red"; the Agent stores it as this channel's standing orders and records who asked. A change is a full replacement: when you ask it to amend the orders, it stores the complete new text. Say "clear this channel's standing orders" to remove them.

Standing orders reach two places: the route judgment treats them as the operator policy of the room and can use a semantic match to authorize `NEW_WORK`, while a visible owner turn also sees them in its context.

Two boundaries:

- **They activate only in May intervene mode.** When May intervene is off (under another Signal Binding mode on an external channel, or when `may_intervene` is disabled for the Agent participant in a Pod Chat group thread), the text is stored on the Conversation (`standing_orders`) but remains inert, and the Agent reports that it is inactive after saving. Enabling May intervene activates it immediately.
- One orders text holds at most 4000 characters.

The Console can also read and write standing orders; see the `/api/v2/conversations/:conversation_id/standing-orders` endpoints in the [Console API reference](../console-api/).

## Still speaking too much or too little

- **Too much**: tighten or clear the standing orders first, then tighten the Agent's role instructions; for a group that only needs question-and-answer behavior, switch an external channel's binding back to **Addressed messages only** or disable `may_intervene` for that Agent participant in a Pod Chat group thread.
- **Too little**: confirm that May intervene is enabled (on the external channel's Signal Binding or on the Agent participant's `may_intervene` setting in Pod Chat), and give the conversation one explicit standing order — the judgment defaults to conservative, and without orders the Agent speaks only when someone actually needs it.
- **Orders saved but nothing changes**: read the Agent's reply after it saves the orders — it reports whether they are active. Inactive means May intervene is not enabled on the external channel's Signal Binding or on that Agent participant in the Pod Chat group thread.

## Next steps

- Group message modes and binding configuration: read [Signal bindings](../signal-bindings/).
- How messages become Agent work items: read [Signals](../signals/).
