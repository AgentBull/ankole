---
title: Onboarding agent
description: How to set up an agent that helps new team members get up to speed — answers questions from Brain knowledge, points to docs, and escalates to a buddy when stuck.
section: Guides
order: 332
---

An onboarding agent lives in the team channel and helps new hires find their way — answers questions about the codebase, the team's conventions, the setup process, and who owns what. It is a specialized form of the [customer support agent](../customer-support-agent/), turned inward: the customers are your new teammates. This guide is the practical shape of that agent.

The decisive property, stated up front: an onboarding agent is **a knowledgeable, patient colleague who never gets tired of the same question**. It answers from curated Brain knowledge (your onboarding docs, your architecture decisions, your team conventions), points to the right document or person, and escalates to a designated buddy when the new hire is stuck. The value is not in being smart — it is in being consistently available.

## What you need

- **A working chat binding** to the team's onboarding channel (Slack, Lark, DingTalk, or Teams).
- **`primary`/`light`/`heavy` profiles bound**, plus **`embedding`** for Brain recall.
- **`unaddressed_group_message_policy: may_intervene`** — the agent should observe the channel and help when a new hire asks something it knows, without waiting for an @-mention. See [Ambient intervention](../ambient-intervention/).
- **Brain knowledge curated** — your onboarding handbook, setup guide, architecture overview, and team conventions, uploaded as sources and reviewed. See [Brain sources](../brain-sources/) and [Brain review](../brain-review-ops/).

## The three behaviors

Same shape as the support agent, adapted for internal use:

1. **Answer** — when a new hire asks "how do I set up the dev environment?" or "who owns the payments service?", answer from Brain knowledge with a link to the doc.
2. **Point** — when the answer is a person, not a document ("who should review my first PR?"), point to the right person. Maintain a "who owns what" knowledge entry in Brain.
3. **Escalate to a buddy** — when the new hire is stuck on something the agent does not know, or the question is about team culture, salary, or HR, escalate to the designated onboarding buddy. "I'm not sure about this — @buddy can you help?"

## What makes onboarding different from support

- **The knowledge is internal** — setup guides, architecture decisions, codebase conventions, team roster. These are Brain sources you upload and curate, not customer-facing docs.
- **The audience is small and trusting** — new hires expect the agent to be helpful, not perfect. The escalation is to a colleague, not a support ticket.
- **The questions repeat** — every new hire asks the same setup questions. Brain recall makes the agent consistent across hires; dreaming proposes new knowledge from the questions it could not answer.

## A worked example

Set up an onboarding agent on Slack:

1. Create the agent, bind profiles (`primary`/`light`/`heavy`/`embedding`).
2. Set the Slack binding's policy to `may_intervene`.
3. Author `MISSION.md`: "You are the onboarding agent in #new-hires. Answer setup, codebase, and convention questions from Brain knowledge. Point to the right person when the answer is a person. Escalate to @buddy when you don't know or it's an HR question. Be patient — the same question from a different person is still a good question."
4. Upload the onboarding handbook, setup guide, and architecture overview as Brain sources. Run learning. Review the knowledge.
5. Curate a "who owns what" knowledge entry — service owners, PR review rotation, on-call schedule.
6. Add a monthly dreaming run to learn from questions the agent could not answer.

## The "who owns what" entry

This is the single most valuable Brain entry for an onboarding agent. Maintain it as curated knowledge:

- **Service owners** — "the payments service is owned by @alice."
- **PR review** — "frontend PRs go to @bob, backend to @carol."
- **On-call** — "the current on-call rotation is in the schedule doc."

When a new hire asks "who do I talk to about X?", the agent recalls this entry and points them to the right person.

## What this guide is not

It is not an HR system — the agent does not manage access, provisioning, or payroll. It answers questions and points to people. It is not a replacement for a human buddy — the agent handles the repeatable questions; the buddy handles the context, the culture, and the "I'm not sure who to ask" moments. And it is not a static FAQ — Brain knowledge evolves through dreaming and review, so the agent's answers improve as it observes more questions.

## Next steps

- For the support-agent pattern this builds on, read [Customer support agent](../customer-support-agent/).
- For Brain knowledge curation, read [Brain sources](../brain-sources/) and [Brain review](../brain-review-ops/).
- For the group-message policy, read [Ambient intervention](../ambient-intervention/).
- For the first-bot setup, read [Your first Slack bot](../slack-first-bot/) (or the equivalent for your platform).
