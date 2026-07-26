---
title: Email digest agent
description: How to set up an agent that summarizes a batch of emails or messages into a daily digest — extracting what needs action, what is informational, and what to ignore.
section: Guides
order: 342
---

An email digest agent takes a batch of incoming messages — emails, notifications, channel summaries — and produces a structured daily digest: what needs action, what is informational, what to ignore. This is a variant of the [summarization agent](../summarization-agent/) applied to a recurring batch of inputs, and a close cousin of the [daily briefing bot](../daily-briefing-bot/).

The decisive property, stated up front: the digest is **triaged, not exhaustive**. The agent does not summarize every email word-for-word; it classifies each message into a category (action needed, FYI, ignore) and summarizes only what the persona says matters. The value is in the triage, not in the compression.

## What you need

- **`primary` profile bound** — classification and summarization require reasoning.
- **A signal binding** to the channel where the digest posts.
- **A schedule** — daily, at the start of the workday. See [Cron schedules](../cron-schedules-ops/).
- **A way to deliver the batch** — the messages arrive as a channel discussion, a pasted batch, a webhook delivering notifications, or a file the agent reads.

## The digest structure

A good daily digest the agent posts:

```text
**Daily digest — <date>**
**Action needed** (respond or decide today):
- <sender>: <subject> — <one-line summary of what they want>
**FYI** (read when you have time):
- <sender>: <subject> — <one-line summary>
**Ignored** (auto-classified, no action):
- <count> messages from monitoring, newsletters, or automated systems
```

The three-tier structure (action/FYI/ignore) is the core value. A flat summary of 50 emails is not a digest; it is a slightly shorter inbox. A triaged digest of 3 action items and a count of 47 ignored messages is useful.

## What the persona controls

- **Classification rules** — "classify as 'action needed' if the email asks a question, requests a review, or mentions a deadline. 'FYI' if it is informational. 'Ignore' if it is from a monitoring system, a newsletter, or an automated notification."
- **Summarization depth** — "one line per action item; just the count for ignored."
- **The threshold** — "if there are zero action items, post 'No action needed today' and the FYI/ignore counts. Do not post an empty digest."
- **Delivery** — "post to the channel at 9 AM."

## A worked example

Set up a daily email digest agent for a team lead:

1. Create the agent, bind `primary`/`light`.
2. Author `MISSION.md`: "Every morning, read the overnight batch of emails forwarded to the digest channel. Classify each into Action needed / FYI / Ignore. Summarize action items in one line each. Count FYI and ignore. Post the digest at 9 AM. If no action items, say 'No action needed today.'"
3. Set up email forwarding to the channel (through a webhook or an integration that delivers emails as messages).
4. Add a daily schedule: `cron: "0 9 * * 1-5"` (9 AM weekdays).
5. The agent reads the batch, classifies, summarizes, and posts the digest.

## What this guide is not

It is not an email client — the agent reads and digests; it does not send, reply, or manage the inbox. It is not a spam filter — it classifies messages for the digest, but the inbox still receives everything. And it is not a replacement for reading important emails — the digest tells you what to read; it does not replace reading the action items.

## Next steps

- For the summarization pattern, read [Summarization agent](../summarization-agent/).
- For the daily-briefing pattern, read [A daily briefing bot](../daily-briefing-bot/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).
- For webhook triggers, read [Automation blueprints](../automation-blueprints/).
