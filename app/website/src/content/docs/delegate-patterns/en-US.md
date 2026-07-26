---
title: Delegation patterns
description: The shapes of work an agent delegates to background jobs — fire-and-forget, ask-and-wait, continue-from, and watch-and-steer — and when each fits.
section: Guides
order: 307
---

Once an agent can delegate, the question stops being *how* and becomes *which shape*. This guide catalogs the delegation patterns the background-job tools support, and says when each one fits. It builds on the [background research job](../background-research-job/) walkthrough, which covers one pattern end to end; here we name them all.

The decisive property, stated up front: delegation is the agent's call, made with its own tools during a turn. You do not spawn jobs from the Console. Your job is to scope the request so the agent picks the right pattern; the agent's job is to translate that into the right tool call.

## The agent's delegation tools

Six tools, each a distinct move:

| Tool | What it does |
|---|---|
| `create_background_job` | spawn a new job (`title`, `task`, optional `workspace_template_id`) |
| `list_background_jobs` | list jobs, optionally filtered by `status` |
| `show_background_job_details` | read one job's detail and recent trajectory |
| `send_message_to_background_job` | send a message to a running or waiting job (`wait_reply` controls whether the call blocks for the reply) |
| `respawn_background_job` | create a new job that continues from a terminal one (`source_job_id`, `message`) |
| `stop_background_job` | cancel a job |

The agent decides which to call, and when. The patterns below are the shapes that decision takes.

## Pattern 1: Fire-and-forget

The agent spawns a job and does not wait for it. Use it when the human asked for something that takes time, and an immediate acknowledgment is enough.

- **Shape**: `create_background_job`, then a short reply in the channel ("on it, I'll post when it's done"), then the turn ends.
- **The job posts back** when it finishes (`background_agent_job.completed`), fails (`…failed`), or needs input (`…waiting`).
- **Fits**: research, summaries, anything where the human does not need to watch the work happen.

This is the [background research job](../background-research-job/) pattern. It is the default; reach for the others when it does not fit.

## Pattern 2: Ask-and-wait

The agent spawns a job, then within the same turn sends it a message and blocks for the reply. Use it when the agent needs the job's intermediate output to answer the human.

- **Shape**: `create_background_job`, then `send_message_to_background_job` with `wait_reply: true`.
- **The turn stays open** until the job replies, so the human sees a single answer, not a handoff.
- **Fits**: "summarize this thread, then translate the summary" — the translation needs the summary first.

The risk is holding the turn open for a long time; if the job is slow, prefer fire-and-forget and let the job post its own result.

## Pattern 3: Continue from a finished job

A job finished — succeeded or failed — and the human wants to take it further without restating the whole task. The agent respawns from the terminal job, carrying its context forward.

- **Shape**: `respawn_background_job` with the old job's id and a short `message` describing what to do next.
- **The new job** continues the workspace and trajectory of the source; the human does not re-explain.
- **Fits**: "you researched X yesterday — now do the same for Y," or "that failed run, retry it with this change."

This is why jobs are durable, not child processes: a terminal job is still a valid starting point.

## Pattern 4: Watch and steer

The human watches a job's progress and steers it mid-flight — answering questions, changing direction, narrowing scope.

- **Shape**: the job moves to `waiting_on_user` and posts a question; the human answers in the channel; the agent calls `send_message_to_background_job` (or the owning turn resumes it) with the answer; the job continues.
- **Repeated** as often as the job needs decisions.
- **Fits**: exploratory work where the direction is not known up front, or where a human's judgment is cheaper than the agent's guess.

The lever is the persona: a job that asks too often is annoying; one that never asks drifts. Tell the agent in its mission when to ask versus decide.

## Pattern 5: Scoped workspaces

Some work needs a prepared workspace — a checked-out repo, a document template, a configured toolchain. The agent picks a `workspace_template_id` on `create_background_job` when the work needs one.

- **Shape**: `create_background_job` with `workspace_template_id: "<template-id>"`.
- **The template** is a plugin-declared workspace; the agent sees which templates are available and what each is for.
- **Fits**: coding tasks against a real checkout, document generation against a template, anything where "start from scratch" wastes the first ten tool calls.

If no template fits, the agent omits the field and the job runs without one. Templates are a capability, not a requirement.

## Choosing a pattern

A short decision guide, in the order the agent effectively makes it:

1. **Does the human need the answer now?** If yes and it is short, do not delegate — answer in the turn. If yes and it is long, use ask-and-wait, and watch the turn length.
2. **Does the work need a prepared workspace?** If yes, pick the right `workspace_template_id`.
3. **Will the work need human judgment along the way?** If yes, plan for watch-and-steer; write the "when to ask" rule into the persona.
4. **Is the work a continuation of something that already ran?** If yes, respawn from the source job.
5. **Otherwise** — fire-and-forget, and let the job post back.

## What delegation is not

It is not a way to make an agent faster — the work takes the time it takes, and a job that runs for an hour takes an hour whether you watch it or not. It is not a second agent; the job runs as the agent that spawned it, under that agent's authority and credentials. And it is not a replacement for good scoping; a badly-scoped job is a badly-scoped job, and the patterns above do not fix that — the request does.

## Next steps

- For one pattern in full, read [the background research job](../background-research-job/) guide.
- For the operator view of jobs (status vocabulary, retry budget, cancel), read [Background jobs (operator view)](../background-jobs-ops/).
- For the lifecycle and recovery model, read [Background Agent Jobs](../background-agent-jobs/).
