---
title: FAQ bot
description: How to set up a focused agent that answers frequently asked questions from curated Brain knowledge — the simplest useful agent, and the right starting point for many teams.
section: Guides
order: 344
---

An FAQ bot is the simplest useful Ankole agent: it answers questions from curated knowledge, points to the right document when it does not know, and stays quiet outside its scope. It is a stripped-down [customer support agent](../customer-support-agent/) — no channel observation, no escalation to multiple people, no dreaming. Just: question in, answer out, from Brain. This guide is the practical shape of that agent.

The decisive property, stated up front: an FAQ bot is **addressed-only, knowledge-bounded, and honest about its limits**. It answers when @-mentioned, from Brain knowledge, and says "I don't know" when the answer is not there. It does not guess, does not search the web, and does not observe the channel.

## What you need

- **`primary` profile bound** — answering questions requires reasoning.
- **`embedding` profile bound** — Brain recall uses embeddings to find the relevant knowledge entry.
- **A signal binding** with `unaddressed_group_message_policy: addressed_only` (or `ignore`) — the agent wakes on @-mention, not on every message.
- **Brain knowledge curated** — your FAQ entries, product docs, and common-issue answers, reviewed and approved.

## The workflow

1. **Someone @-mentions the agent** with a question.
2. **The agent recalls Brain knowledge** — `memory_search` finds the relevant entries.
3. **The agent answers** — from the knowledge, with a link to the source document.
4. **If the answer is not in Brain** — the agent says "I don't have an answer for that. Try asking @team or checking <doc-link>."

## What makes it different from the support agent

| | FAQ bot | Support agent |
|---|---|---|
| Wakes on | @-mention only (`addressed_only`) | any message (`may_intervene`) |
| Knowledge source | Brain curated knowledge only | Brain + web search + session context |
| Escalation | "ask @team" | escalates to specific people by topic |
| Complexity | minimal — the right starting point | full — observes, judges, escalates |

An FAQ bot is what you build first. A support agent is what you evolve it into once the FAQ bot is answering well and you want it to be more proactive.

## What the persona controls

- **Scope** — "answer questions about product setup, pricing, and common errors. For anything else, say you don't know."
- **Format** — "answer concisely (2-3 sentences) with a link to the full doc."
- **Honesty** — "if the answer is not in Brain, say 'I don't have an answer for that.' Do not guess. Do not search the web."
- **Tone** — "helpful, direct, no filler."

## A worked example

Set up an FAQ bot for a product team:

1. Create the agent, bind `primary`/`light`/`embedding`.
2. Set the binding's policy to `addressed_only`.
3. Author `MISSION.md`: "Answer @-mentioned questions from Brain knowledge. Scope: product setup, pricing, common errors. Concise answers with doc links. If not in Brain, say you don't know. Do not guess."
4. Curate Brain knowledge: the top 20 FAQ entries, the setup guide, the pricing page content, the error-reference doc.
5. Test: @-mention the agent with "how do I reset my password?" — it should answer from Brain and link to the setup doc.

## Growing the knowledge

The FAQ bot improves as the knowledge grows:

- **Add new FAQs** when a question the bot could not answer reveals a gap. Upload the answer as a Brain source, run learning, review.
- **Run dreaming weekly** to propose new knowledge from the questions the bot received.
- **Review the audit log** to see what questions were asked and whether the answers were right.

## What this guide is not

It is not a search engine — it answers from Brain knowledge, not from the web. It is not a chatbot — it does not do small talk; it answers scoped questions. And it is not a finished product — it improves as the knowledge grows, and it should evolve into a support agent once the team is ready for proactive help.

## Next steps

- For Brain knowledge curation, read [Brain](../brain/) and [Brain review](../brain-review-ops/).
- For the support agent (the evolution), read [Customer support agent](../customer-support-agent/).
- For the first-bot setup, read [Your first Lark bot](../lark-first-bot/) or the Slack/DingTalk/Teams equivalent.
- For the binding policy, read [Signal bindings](../signal-bindings/).
