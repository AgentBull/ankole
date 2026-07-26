---
title: Incident postmortem
description: How to set up an agent that drafts an incident postmortem from the channel timeline, logs, and Brain audit trail — structured, blameless, and ready for human review.
section: Guides
order: 354
---

An incident postmortem agent reads the incident's raw material — the channel timeline, the structured logs, the Brain audit trail — and drafts a blameless postmortem: timeline, impact, root cause, contributing factors, and action items. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **drafts, it does not conclude**. It assembles the raw material into a structured document, but the root-cause analysis and the action items are proposals for the team to confirm. The value is in assembling the timeline and the evidence fast — the first 80% of a postmortem that is pure data gathering — not in the final judgment.

## What you need

- **`primary` profile bound** — synthesizing a timeline and drafting analysis requires reasoning.
- **`embedding` profile bound** — Brain recall for past incidents with similar patterns.
- **A signal binding** to the channel where the postmortem drafts post.
- **The incident's raw material** — the channel discussion (observed with `may_intervene` or pasted), the structured logs (a file or a fetched batch), and the Brain audit trail.

## The postmortem template

A blameless postmortem the agent drafts:

```text
**Postmortem — <incident> — <date>**
**Summary**: <one-paragraph what happened>
**Impact**: <users affected, duration, severity>
**Timeline**:
- <time>: <what happened>
- <time>: <detection>
- <time>: <response began>
- <time>: <mitigation>
- <time>: <resolution>
**Root cause** (proposed): <the agent's analysis>
**Contributing factors**: <what made it worse or slower to detect>
**What went well**: <what worked in the response>
**Action items** (proposed):
- [ ] <preventive action> — owner: TBD
- [ ] <detection improvement> — owner: TBD
- [ ] <response improvement> — owner: TBD
```

The "proposed" markers are the key — the agent assembles the evidence and proposes the analysis, but the team confirms the root cause and assigns the action items.

## The workflow

1. **An incident is resolved** (or the human asks for a draft mid-incident).
2. **The agent reads the timeline** — from the channel discussion, the structured logs, and the Brain audit trail.
3. **The agent assembles** — constructs the chronological timeline, identifies the detection-to-resolution gap, and extracts what happened at each step.
4. **The agent proposes** — root cause (from the evidence and Brain's past-incident patterns), contributing factors, what went well, and action items.
5. **The agent posts the draft** — with "proposed" markers, asking for team review and confirmation.

## What the persona controls

- **Tone** — "blameless. Focus on systems and processes, not individuals. No names in the 'what went wrong' section."
- **Depth** — "full timeline with timestamps" vs "summary timeline with key milestones only."
- **Action items** — "propose preventive, detection, and response improvements. Do not assign owners — the team does."
- **Recall** — "check Brain for past incidents with similar patterns. If this is a recurrence, flag it."

## A worked example

Set up a postmortem agent for a team's incident channel:

1. Create the agent, bind `primary`/`heavy`/`embedding`.
2. Set the binding's policy to `may_intervene` (so it observes the incident as it unfolds).
3. Author `MISSION.md`: "After an incident is resolved, draft a blameless postmortem from the channel timeline and logs. Structure: summary, impact, timeline, root cause (proposed), contributing factors, what went well, action items (proposed). Check Brain for similar past incidents — if recurrence, flag it. Post the draft and ask for review."
4. When the incident is resolved, @-mention the agent: "Draft the postmortem for today's database outage."
5. The agent reads the timeline, assembles, proposes, and posts the draft.

## What this guide is not

It is not a root-cause authority — the agent proposes; the team confirms. It is not an action-item tracker — the agent proposes items; the team's task system assigns them. And it is not a substitute for a human postmortem review — the draft is a starting point; the team adds the context only humans have.

## Next steps

- For the incident-response procedure, read [Incident response](../incident-response/).
- For the incident-commander pattern (coordination during the incident), read [Incident commander agent](../incident-commander/).
- For Brain memory (past-incident recall), read [Brain](../brain/) and [Audit trail](../audit-trail/).
- For the group-message policy, read [Ambient intervention](../ambient-intervention/).
