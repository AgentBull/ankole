---
title: Customer support agent
description: How to set up an agent that observes a support channel, answers common questions, escalates to a human when needed, and remembers what it learned.
section: Guides
order: 330
---

A customer support agent watches a shared support channel, answers common questions from its knowledge, escalates to a human when it cannot help, and remembers what it learned for next time. This is one of the highest-value Ankole patterns — it combines signal bindings, Brain memory, group-message policy, and the escalate-or-answer judgment. This guide is the practical shape of that agent.

The decisive property, stated up front: a support agent is **observant, helpful, and knows its limits**. It watches the channel (`may_intervene`), answers when it can, escalates when it cannot, and never pretends to know something it does not. The judgment lives in the persona; the memory lives in Brain; the escalation is a message, not a silent failure.

## What you need

- **A working chat binding** (Lark, Slack, DingTalk, or Teams). See the adapter guides.
- **`primary`/`light`/`heavy` profiles bound.** Support answers need a model that can reason about the customer's problem.
- **`embedding` profile bound.** Brain recall uses embeddings to find relevant knowledge.
- **The `unaddressed_group_message_policy` set to `may_intervene`.** The agent must see non-mention messages to observe the channel. See [Ambient intervention](../ambient-intervention/).
- **Brain knowledge curated.** Upload your FAQ, your product docs, your known issues as Brain sources, run learning, and review the extracted knowledge.

## The three behaviors

A support agent does three things, and the persona must name all three:

1. **Answer** — when a customer asks a question the agent knows (from Brain knowledge or product docs), answer concisely with a link to the source.
2. **Escalate** — when the agent does not know, or the question is about a billing dispute, a security incident, or an emotional customer, escalate to a human. The escalation is a message in the channel: "I'm not sure about this — @on-call can you help?"
3. **Stay quiet** — when the channel is just chatting, or someone is already answering, or the question is outside the agent's scope. Silence is correct behavior, not a failure.

## The memory loop

Brain is what makes a support agent improve over time:

- **Curated knowledge** — the product docs, FAQ, and known issues, curated through [Brain review](../brain-review-ops/). Recall reads these during the turn.
- **Source-chat recall** — the agent can recall what was said in this channel before, so it knows "we discussed this yesterday."
- **Dreaming proposals** — Brain's dreaming process reads the channel's history and proposes new knowledge entries. A human reviews them; the approved ones expand what the agent knows.

Set up a weekly dreaming run (`POST /brain/dreaming-runs`) and review the proposals. This is how the agent learns from the conversations it observed.

## A worked example

Set up a support agent for a SaaS product on Slack:

1. Create the agent, bind profiles (`primary`/`light`/`heavy`/`embedding`).
2. Set the Slack binding's `unaddressed_group_message_policy` to `may_intervene`.
3. Author `MISSION.md`: "You are the support agent in #help. Answer product questions from Brain knowledge. Escalate to @support-team when: you don't know, it's billing or security, or the customer is frustrated. Stay quiet when someone is already helping. Never guess — if you're not sure, escalate."
4. Upload product docs as Brain sources, run learning, review the knowledge.
5. Add a weekly schedule to run dreaming and review proposals.
6. Watch the agent for a week, tune the persona's "when to answer vs escalate" boundary.

## The escalation discipline

The hardest part of a support agent is the escalation boundary. Too eager — it escalates everything and adds no value. Too reluctant — it answers questions it should not and erodes trust. The persona is the lever:

- Name the **topics** the agent handles (product features, setup, common errors).
- Name the **topics** it always escalates (billing, security, data loss, legal).
- Name the **signal** for escalation (customer frustration, repeated follow-ups, the agent's own uncertainty).

Tune the persona over a week of watching, not on day one.

## What this guide is not

It is not a chatbot tutorial — the agent reasons about the customer's problem through its model and knowledge, not through keyword matching. It is not a ticketing integration — Ankole does not replace your ticket system; the agent can escalate to a human in the channel, who uses the ticket system. And it is not a substitute for human support — it handles the common cases; the hard cases still need a person.

## Next steps

- For the group-message policy, read [Ambient intervention](../ambient-intervention/) and [Team assistant](../team-assistant/).
- For Brain knowledge, read [Brain](../brain/) and [Brain review](../brain-review-ops/).
- For the first-bot setup, read [Your first Slack bot](../slack-first-bot/) (or the Lark/DingTalk/Teams equivalent).
- For memory tools, read [Memory](../memory/).
