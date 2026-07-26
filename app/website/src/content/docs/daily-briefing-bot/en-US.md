---
title: A daily briefing bot
description: Combine a cron schedule, the agent's web tools, and a chat binding to post a researched briefing every morning — no code, all configuration.
section: Guides
order: 301
---

This guide builds on [Your first Lark bot](../lark-first-bot/) (or any working chat binding) and adds the one thing that turns a reactive bot into a proactive colleague: a schedule. The agent wakes on its own each morning, researches the topics you care about, and posts a briefing to the channel — hands-free.

The flow, in one line: **pick a channel → set the agent's briefing task → schedule it → verify the first fire → let it remember.**

No code is involved. The pieces — the agent's loop, `web_search`, `web_fetch`, the cron schedule, the binding — already exist. This guide wires them together for one scenario.

## What you are building

A scheduled turn that fires once a day:

1. **09:00 in your timezone** — the cron schedule fires a `scheduled_task` turn on the agent's session.
2. **The agent runs its loop** — it reads its `MISSION`/`SOUL` persona and the `task` you set on the schedule.
3. **`web_search` and `web_fetch`** pull current sources on the topics the mission names.
4. **The agent synthesizes** a short briefing from what it found.
5. **Delivery** lands the briefing in the bound channel — Lark, Slack, DingTalk, or Microsoft 365 — as the binding's reply mode dictates.

## Prerequisites

- A working Ankole installation with at least one agent and one chat binding. If you do not have one yet, follow [Your first Lark bot](../lark-first-bot/) first.
- The agent's `web_search` profile bound to a provider that serves web search (see [Providers and models](../providers-and-models/)). Without it, the agent has nothing to research with.
- A channel the agent is bound to and can post in.

## Step 1: Give the agent its briefing mission

The schedule carries a short `task`, but the *style* of the briefing lives in the agent's persona. Author a `MISSION.md` that names the topics and the format:

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/library-documents/mission \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "content": "You produce a daily briefing for the team.\n\nTopics: releases of the libraries we depend on, security advisories affecting our stack, and notable moves from our two named competitors.\n\nFormat: three sections, one per topic. Each section is a short paragraph and at most three links. No filler, no preamble." }'
```

The persona is the place for the topics and the format; the schedule only says *when* to run and *what* in short form. Splitting it this way lets you tune the style without editing the schedule.

## Step 2: Bind the web-search profile

Confirm the agent has a `web_search` model profile bound, pointing at a provider that serves web search. Without it, the agent will run its loop but produce a briefing from memory rather than current sources, which is not what a daily briefing is for. See [Providers and models](../providers-and-models/) for the slot.

## Step 3: Create the cron schedule

Create the schedule on the agent's session, pointing at the binding the briefing should post through:

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "binding_name": "main",
    "name": "morning-briefing",
    "schedule": { "cron": "0 9 * * *", "kind": "cron" },
    "timezone": "Asia/Shanghai",
    "payload": { "task": "Produce today'\''s briefing." }
  }'
```

Two fields are easy to get wrong:

- **`timezone`** — the cron expression is evaluated in this timezone. A 09:00 schedule without a timezone is ambiguous; set it explicitly so the briefing lands at 09:00 *where your team is*, not where the server happens to be.
- **`binding_name`** — the briefing posts through this binding, which decides the channel and reply mode. Use the binding that points at the channel your team reads.

See [Schedules](../schedules/) for the full field set, including pause, resume, and manual run.

## Step 4: Verify with a manual run

Do not wait until 09:00 to learn whether the schedule works. Fire it manually:

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules/<cron_schedule_id>/runs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

A manual run produces a concrete fire event, recorded in the runs list just like a naturally fired one. Watch the bound channel for the briefing; inspect the run and the worker logs if it does not appear. Common failures at this stage:

- **No briefing posted** — the binding is disabled, or the agent's `web_search` profile is unbound. The schedule fired, but the turn had nowhere to post or nothing to search with.
- **Briefing from memory, not current sources** — `web_search` resolved to a provider that does not actually serve search; check the profile's selector.
- **Briefing at the wrong time** — `timezone` is set wrong; a manual run does not reveal this, so double-check it against where your team is.

## Step 5: Let it remember across days

A daily briefing is more useful when the agent notices what changed since yesterday. Two optional moves:

- **Brain curated knowledge** — through the [Brain](../brain/) surface, curate a few rows of durable facts (which competitors matter, which libraries are in your stack). Recall reads these during the turn, so the briefing stays anchored to what you actually care about.
- **Session continuity** — the schedule fires on one session, so the agent's turn naturally has access to that session's recent context. If you want each day's briefing to reference the previous day's, keep them on the same session rather than resetting it.

Curated knowledge is the higher-leverage of the two: it is reviewed, durable, and scoped to the agent, where session memory is ephemeral.

## Operate it day to day

- **Pause for a holiday** — `POST .../cron-schedules/:id/pause`. Status moves to `paused`; no briefing fires.
- **Resume** — `POST .../cron-schedules/:id/resume`. Re-arms the planner.
- **Change the time** — `PATCH` the schedule's `schedule` field; the planner re-arms.
- **Run one now** — `POST .../cron-schedules/:id/runs`, regardless of the cron rhythm.

## Variations

- **Multiple briefings a day** — a schedule with a more frequent cron expression (every six hours, twice a day). Keep the `task` the same; the persona decides the format.
- **Different channel per briefing** — two schedules on the same agent, each with a different `binding_name`.
- **Briefing plus on-demand answers** — keep the schedule, and let the team @-mention the same agent during the day. One agent, two ways to wake it.

## What this guide is not

It is not a code tutorial — there is no script to write, no deployment to build beyond the installation you already have. And it is not a promise that any LLM produces a good briefing on the first try; the persona and the curated knowledge are where you tune quality, over a few days of watching what the agent actually posts.

## Next steps

- For the schedule surface, read [Schedules](../schedules/).
- For the memory the briefing can draw on, read [Brain](../brain/).
- For the binding the briefing posts through, read [Signal bindings](../signal-bindings/) and your adapter page.
