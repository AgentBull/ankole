---
title: Content writer agent
description: How to set up an agent that drafts content — blog posts, announcements, documentation — from a brief, using Brain knowledge and the persona to match the brand voice.
section: Guides
order: 343
---

A content writer agent takes a brief — "write a blog post about our new feature," "draft an announcement for the pricing change" — and produces a draft that matches the brand voice, uses the product's terminology, and follows the team's content conventions. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **drafts, it does not publish**. The draft is a starting point for a human editor, not a finished publication. The value is speed of first draft; the judgment on whether to ship is the human's.

## What you need

- **`primary` profile bound** — content quality depends on a strong model.
- **Brain knowledge curated** — brand voice guidelines, product terminology, style guide, and past content as reference material.
- **A signal binding** to the channel where drafts post.
- **The `pdf` skill (optional)** — if the deliverable must ship as a PDF.

## The workflow

1. **A brief arrives** — a channel message, a scheduled task, or a webhook.
2. **The agent reads the brief** — what to write, for whom, in what format, at what length.
3. **The agent recalls Brain knowledge** — brand voice, product terminology, relevant past content, the style guide.
4. **The agent drafts** — the content in the requested format, matching the voice and the conventions.
5. **The agent posts the draft** — with a note asking for review.

## What the persona controls

- **Voice** — "write in a confident, technical but accessible tone. Short sentences. Active voice. No hype words."
- **Terminology** — "use the product's official names from the Brain glossary. Do not abbreviate product names."
- **Structure** — "blog posts: intro, 3 sections, conclusion. Announcements: what changed, why, what to do."
- **Length** — "blog posts: 800-1200 words. Announcements: 200 words max."
- **The ask** — "post the draft and ask for review. Do not publish."

## A worked example

Set up a content writer for a developer-tools company:

1. Create the agent, bind `primary`/`heavy` + `embedding`.
2. Author `MISSION.md`: "Draft content from briefs. Match the brand voice: technical, direct, no marketing fluff. Use the product terminology from Brain. Blog posts: 800-1200 words, intro + 3 sections + conclusion. Post the draft and ask for review."
3. Curate Brain knowledge: brand voice guidelines, product glossary, style guide, links to 3 reference posts.
4. In the channel: "Write a blog post about our new webhook feature. Audience: backend developers. Key points: what it does, how to set it up, one example."
5. The agent recalls the voice guide, drafts the post, and posts it for review.

## What this guide is not

It is not a publishing pipeline — the agent drafts; the human edits and publishes. It is not a content strategy tool — the agent writes from a brief; it does not decide what to write about. And it is not a replacement for a human editor — the draft is a starting point; the editor shapes the final voice and catches what the model missed.

## Next steps

- For Brain knowledge (voice, glossary), read [Brain](../brain/) and [Brain review](../brain-review-ops/).
- For the PDF skill (if the deliverable is a PDF), read [PDF generation](../pdf-generation/).
- For the summarization pattern (related text processing), read [Summarization agent](../summarization-agent/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).
