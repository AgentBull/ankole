---
title: Design review agent
description: How to set up an agent that reviews a design document or architecture proposal — checks for gaps, risks, and alternatives before the team commits.
section: Guides
order: 362
---

A design review agent reads a design document or architecture proposal — an ADR, a design doc, a proposal — and reviews it for gaps, risks, unconsidered alternatives, and assumptions that need validation. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **reviews the document, it does not approve the design**. It raises questions and identifies gaps; the team resolves them. The value is in the second pair of eyes that catches what the author missed, not in the authority to approve.

## What you need

- **`primary` profile bound** — design review requires deep reasoning.
- **`embedding` profile bound** — Brain recall for past decisions, existing architecture constraints, and the project's design priorities.
- **A signal binding** to the channel where review feedback posts.
- **The design document delivered** — pasted text, an uploaded file, or a URL.

## The workflow

1. **A design document arrives** — pasted in the channel, uploaded, or linked.
2. **The agent reads the document** — the proposed design, its context, its assumptions.
3. **The agent recalls context** — Brain knowledge for past decisions, the project's architecture constraints, and design priorities (from `AGENTS.md` or the project's design docs).
4. **The agent reviews** — identifies: missing considerations, unstated assumptions, risks not addressed, alternatives not evaluated, and inconsistencies with existing architecture.
5. **The agent posts feedback** — structured review questions, not a verdict.

## The review format

```text
**Design review — <document title>**

**Strengths**: <what the design gets right>
**Questions** (the team should answer):
- <question 1>: <why it matters>
- <question 2>: <why it matters>
**Risks** (not addressed in the document):
- <risk 1>: <what could go wrong>
**Alternatives** (not evaluated):
- <alternative>: <why it might be worth considering>
**Consistency**: <does the design align with the project's existing architecture and constraints?>
```

The format is questions, not answers. The agent raises what the author should address; the team decides how.

## What the persona controls

- **Review depth** — "high-level: missing considerations and risks" vs "detailed: line-by-line consistency check."
- **Context recall** — "check the design against Brain's architecture decisions and the project's design priorities."
- **Tone** — "constructive. Raise questions, do not dismiss. Every question should be answerable."
- **What not to do** — "do not approve or reject the design. Do not rewrite the document. Raise questions only."

## A worked example

Set up a design review agent for an engineering team:

1. Create the agent, bind `primary`/`heavy`/`embedding`.
2. Author `MISSION.md`: "When a design document is shared, read it. Recall Brain's architecture decisions and the project's design priorities. Review for: missing considerations, unstated assumptions, unaddressed risks, unevaluated alternatives, and inconsistency with existing architecture. Post structured feedback: strengths, questions, risks, alternatives, consistency. Do not approve or reject. Raise questions only."
3. Curate Brain knowledge: past ADRs, architecture constraints, the project's design priorities.
4. In the channel: "Review the design for the new notification service: <link or paste>."
5. The agent reads, recalls, reviews, and posts the structured feedback.

## What this guide is not

It is not an architecture approver — the agent raises questions; the team approves. It is not a code reviewer — it reviews design documents, not code. And it is not a rubber stamp — a design review that says "looks good" without raising questions is worthless. The value is in the questions, not the approval.

## Next steps

- For Brain knowledge (past decisions, architecture), read [Brain](../brain/) and [Brain review](../brain-review-ops/).
- For the project's design priorities, read [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md).
- For the code review pattern (reviewing code, not design), read [Code review workflow](../code-review-workflow/).
- For the summarization pattern (reading long documents), read [Summarization agent](../summarization-agent/).
