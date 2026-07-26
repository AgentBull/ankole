---
title: Incident commander agent
description: How to set up an agent that coordinates an ongoing incident — tracks the timeline, summarizes status, and keeps the channel aligned without taking risky action itself.
section: Guides
order: 335
---

An incident commander agent lives in the incident channel during an active incident. It does not fix the problem — it coordinates: tracks the timeline, summarizes the current status for latecomers, points to the runbook, and asks "who is doing what?" so the human responders stay aligned. This guide is the practical shape of that agent.

The decisive property, stated up front: the incident commander **coordinates, it does not remediate**. It reads the channel, maintains the timeline, and posts status summaries. The humans diagnose and act. The agent's value is keeping everyone aligned during chaos, not replacing the human commander.

## What you need

- **A signal binding** to the incident channel (Slack, Lark, Teams — wherever the team coordinates during incidents).
- **`unaddressed_group_message_policy: may_intervene`** — the agent must see all messages in the incident channel to track the timeline. See [Ambient intervention](../ambient-intervention/).
- **`primary` profile bound** — synthesizing a status update from a fast-moving channel requires reasoning.
- **Brain knowledge curated** — your incident-response runbook, the service dependency map, the escalation tree, and the comms template.

## The three behaviors during an incident

1. **Track** — the agent observes every message in the incident channel and builds a mental timeline: who reported what, what was tried, what worked, what failed.
2. **Summarize** — periodically (or on demand), the agent posts a status summary: current state, what is known, what is being tried, who is working on what, and the next decision point. This is for latecomers and for the commander.
3. **Point** — the agent points to the relevant runbook entry, the known-issue pattern in Brain, or the person who owns the affected service. It does not propose actions beyond what the runbook says.

## The status summary

The agent's most valuable output is the **status summary** — a structured, concise snapshot of where the incident stands. A good template:

```text
**Incident status — <timestamp>**
- **Impact**: <what users see>
- **Known**: <root cause if identified, else "investigating">
- **In progress**: <what is being tried, by whom>
- **Next decision**: <what the team is waiting on>
- **Runbook**: <link to the relevant Brain entry>
```

The agent posts this on a cadence (every 15 minutes for a critical, every hour for a warning) or when someone asks "status?". It does not post between updates — noise during an incident is costly.

## What the persona controls

- **The cadence** — "post a status summary every 15 minutes during a critical incident, every 30 during a warning."
- **The escalation** — "if no one has acknowledged the incident within 5 minutes, page @on-call."
- **The boundaries** — "do not propose restarts, rollbacks, or config changes. Point to the runbook; the commander decides."
- **The tone** — calm, structured, factual. No drama.

## How it relates to the alert triage agent

The [alert triage agent](../alert-triage-agent/) handles the first five minutes — classifying the alert and drafting a runbook. The incident commander agent handles the next two hours — coordinating the response once the incident is confirmed. They are different agents for different phases, or the same agent with a persona that shifts from triage to coordination.

## A worked example

Set up an incident commander agent on Slack:

1. Create the agent, bind `primary`/`light`/`heavy`/`embedding`.
2. Set the Slack binding's policy to `may_intervene`.
3. Author `MISSION.md`: "You are the incident commander in #incidents. Track the timeline from channel messages. Post a status summary every 15 minutes during a critical, every 30 during a warning. Point to runbooks and service owners from Brain. Do not propose actions — the human commander decides. Escalate to @on-call if unacknowledged for 5 minutes."
4. Curate Brain knowledge: incident runbooks, service dependency map, escalation tree, comms template.
5. When an incident starts, the team @-mentions the agent or it wakes from an alert webhook. It tracks, summarizes, and points until the incident is resolved.

## What this guide is not

It is not an automated remediation system — the agent coordinates; humans act. It is not a replacement for a human incident commander — it assists the commander by tracking and summarizing; the commander still makes the calls. And it is not a postmortem generator — after the incident, the team writes the postmortem; the agent's timeline is raw material, not the final document.

## Next steps

- For the alert triage phase, read [Alert triage agent](../alert-triage-agent/).
- For incident response (the operational discipline), read [Incident response](../incident-response/).
- For the group-message policy, read [Ambient intervention](../ambient-intervention/).
- For Brain knowledge (runbooks, dependency maps), read [Brain](../brain/) and [Brain review](../brain-review-ops/).
