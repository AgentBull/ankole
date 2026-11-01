---
title: Ambient intervention
description: How the Agent decides whether to speak in a "May intervene" group, how its reply attaches to the person who asked, and how channel standing orders tell it when to speak.
section: User guide
order: 17
---

When **May intervene** is enabled for a group conversation, the Agent observes messages that do not explicitly address it and evaluates each incoming batch of human messages. You can enable this mode either through the group message mode on an external channel's [signal binding](../signal-bindings/) or through an Agent participant's `may_intervene` policy in a native **Pod Chat** group thread. Silence is the default; when a batch warrants action, the Agent can post a bounded reply, take on new work, or forward the messages to an active background job.

Group behavior in this mode is governed by two settings: conversation `standing_orders` and the group intervention toggle (configured on the Signal Binding for external channels, or via per-Agent `may_intervene` in Pod Chat group threads, which run without a Signal Binding).

## Each message is judged once

Each Agent maintains its own evaluation cursor for a Conversation, so multiple Agents in the same group share messages and standing orders without sharing judgment progress. Only **human** messages trigger ambient checks—Agent messages never wake other Agents. On each check, the recognizer evaluates only the human messages that arrived since its previous cursor; older messages appear strictly as background context and are never re-evaluated. As a result, a message that the Agent chose to leave alone will not suddenly receive an answer several turns later.

Every judgment records its chosen route, authorization source, and reasoning—plus the exact target job for background handoffs—so when an Agent seems too quiet or too talkative, operators can inspect the recorded route instead of guessing.

## Four routes

- **No action (`NOOP`)** — keeps the Agent silent, which is the standard outcome for side chatter, acknowledgements, duplicate answers, or requests that a person has already handled.
- **Foreground reply (`FOREGROUND_REPLY`)** — opens a single concise visible turn to answer a quick question, clarify context, coordinate, report status, or run a small bounded lookup. Turns on this route cannot create or respawn background jobs.
- **New work (`NEW_WORK`)** identifies a distinct, substantive task. A direct human request or a matching standing order starts a normal owner turn. Resource access uses only the executing Agent’s permissions; `turn_authority` and `WorkAccess` check instruction validity. Without either authorization source, the Agent runs a tool-free confirmation turn that can only ask whether it should take on the work and cannot start a job.
- **Handoff (`HANDOFF`)** — silently forwards the new messages to a single matching live background job belonging to the same Agent, owner Session, and Conversation (and the same Signal Binding when triggered from an external channel). If candidate matching is ambiguous or incomplete, Ankole skips the handoff.

The ambient recognizer itself never spawns a background job; it only selects the route and authorization source, leaving the owner turn to enforce normal approval and background-work rules.

## Replies attach to the person who asked

When the Agent decides to speak, it distinguishes between two cases:

- **Someone is asking it** — one of the new messages asks or addresses the Agent, even without an `@` mention. The Agent anchors its reply to that message, which renders as a quote reply or thread reply on platforms that support it so everyone in the room can see whom the Agent is answering.
- **Volunteering** — nobody addressed the Agent directly, but adding context helps right now (or a standing order matched). The Agent posts its reply as a regular group message.

Ankole validates reply attribution before anchoring: the identified question must belong to the evaluated batch, come from a human, and come from the latest speaker in the room. If the conversation has already moved on, the Agent does not reach back to anchor an older question; instead, the reply degrades to a normal proactive group message. Similarly, if the external platform later deletes an accepted source message, Ankole clears the message anchor and marks the stored attribution as degraded while keeping the judgment record and cursor intact.

## Channel standing orders

Standing orders are a single durable policy text attached to a Conversation and shared across all of its Agent participants, telling Agents when to speak up proactively in that room. Examples:

- "Only speak when CI turns red or a deploy fails."
- "After 18:00, when someone posts a daily report, summarize it; stay quiet otherwise."
- "This is a customer group. Do not join unless someone asks a technical question directly."

**You set them by telling the Agent directly in the channel.** Any channel member can say, "From now on, only speak here when CI turns red," and the Agent saves that policy as the channel's standing orders along with who set it. Every update replaces the full text—when you ask the Agent to amend the orders, it writes the complete updated version—and saying "clear this channel's standing orders" removes them.

Standing orders feed into two places: the ambient recognizer evaluates them as the room's operator policy (allowing a semantic match to authorize `NEW_WORK`), and any visible owner turn also receives them in its prompt context.

Keep two boundaries in mind:

- **They activate only in May intervene mode.** When May intervene is off—under another Signal Binding mode on an external channel, or when `may_intervene` is disabled for the Agent participant in a Pod Chat group thread—Ankole stores the text on the Conversation (`standing_orders`) in an inert state, and the Agent notes in its confirmation reply that the orders are currently inactive. Enabling May intervene activates the stored orders immediately.
- Standing orders hold at most 4000 characters per Conversation.

Operators can also read and update standing orders through the Console; see the `/api/v2/conversations/:conversation_id/standing-orders` endpoints in the [Console API reference](../console-api/).

## Still speaking too much or too little

- **Too much**: tighten or clear the channel's standing orders first, then refine the Agent's role instructions. If a room only needs direct question-and-answer replies, switch an external channel's binding back to **Addressed messages only** or disable `may_intervene` for that Agent participant in a Pod Chat group thread.
- **Too little**: verify that May intervene is enabled (on the external channel's Signal Binding or on the Agent participant's `may_intervene` setting in Pod Chat), and add an explicit standing order—ambient judgment defaults to conservative silence unless someone clearly needs help or a standing order matches.
- **Orders saved but nothing changes**: check the Agent's reply when it saved the orders, which reports whether they are active. If reported as inactive, enable May intervene on the external channel's Signal Binding or on that Agent participant in the Pod Chat group thread.

## Next steps

- Group message modes and binding configuration: read [Signal bindings](../signal-bindings/).
- How messages become Agent work items: read [Signals](../signals/).
