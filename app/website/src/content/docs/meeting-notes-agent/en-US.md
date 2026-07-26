---
title: Meeting notes agent
description: How to set up an agent that captures meeting notes from a transcript or channel discussion — structures them, identifies action items, and posts them for review.
section: Guides
order: 337
---

A meeting notes agent takes the raw material of a meeting — a transcript, a channel discussion, or a set of shared notes — and turns it into structured notes with action items, owners, and decisions. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **structures, it does not decide**. It reads the raw discussion, extracts what was said, and organizes it. The action items it identifies are proposals for the team to confirm, not assignments the agent makes. The value is speed of structuring, not authority of decision.

## What you need

- **`primary` profile bound** — structuring a discussion into notes requires synthesis.
- **A signal binding** to the channel where notes post.
- **A way to deliver the raw material** — either the meeting transcript is pasted into the channel, the agent reads a channel discussion (with `may_intervene` or after the meeting), or the transcript is uploaded as a file.

## The workflow

1. **The raw material arrives** — a transcript pasted in the channel, a channel discussion the agent observed, or an uploaded file.
2. **The agent structures** — identifies the topics discussed, the decisions made, and the open questions.
3. **The agent extracts action items** — "who said they would do what by when," as proposals.
4. **The agent posts structured notes** — topics, decisions, action items (with proposed owners), open questions. Asks for confirmation on the action items.

## The notes template

A good meeting-notes structure the agent posts:

```text
**Meeting notes — <date>**
**Topics**: <what was discussed>
**Decisions**: <what was agreed>
**Action items**:
- [ ] @alice — draft the API spec by Wednesday (proposed)
- [ ] @bob — review the security audit by Friday (proposed)
**Open questions**: <what was left unresolved>
```

Action items are marked "proposed" — the agent extracted them from the discussion, but the team confirms who owns what.

## What the persona controls

- **Structure** — the template, the sections, the level of detail.
- **Action-item extraction** — "extract explicit commitments only, not implied tasks." vs "extract everything that sounds like a task."
- **Tone** — concise summary vs detailed transcript-with-commentary.
- **The ask** — "post notes and ask for confirmation on action items. Do not assign tasks."

## A worked example

Set up an agent that captures notes from a Slack standup channel:

1. Create the agent, bind `primary`/`light`/`heavy`.
2. Author `MISSION.md`: "After the daily standup in #standup, summarize the discussion. Structure as: topics, decisions, action items (proposed), open questions. Post to #notes. Mark action items as proposed — the team confirms."
3. Add a schedule that fires 30 minutes after the standup ends: `cron: "30 10 * * 1-5"` (10:30 AM weekdays).
4. The agent reads the morning's discussion, structures it, posts the notes.

## What this guide is not

It is not a transcription service — the agent does not convert audio to text. The raw material must be text (a transcript, a channel discussion, or notes). It is not a task tracker — it proposes action items; the team's task system assigns them. And it is not a decision-maker — it records what was decided; it does not decide.

## Next steps

- For scheduling, read [Cron schedules](../cron-schedules-ops/).
- For the group-message policy (observing the channel), read [Ambient intervention](../ambient-intervention/).
- For Brain memory (storing decisions for recall), read [Brain](../brain/).
- For the daily-briefing pattern (a related scheduled agent), read [A daily briefing bot](../daily-briefing-bot/).
