---
title: A background research job
description: Let an agent delegate a long research task to a durable background job, watch it from the Console, answer its questions, and read the result — without holding the conversation turn.
section: Guides
order: 302
---

This guide covers the shape of work that does not fit in one turn: a literature scan, a competitor deep-dive, a multi-source synthesis that takes many tool calls. Instead of making the human wait, the agent delegates the work to a **background job** — durable work that runs out of the conversation, reports back when it finishes or needs input, and survives worker loss.

The flow, in one line: **ask the agent for the research → the agent spawns a job → watch the job run → answer its questions → read the result.**

The important shift from [Your first Lark bot](../lark-first-bot/): there, the agent answered in one turn. Here, the agent *creates* a Background Agent Job during a turn, and the job runs on its own. You are operating the job, not the conversation.

## What you are building

A delegation pattern that looks like this:

1. **You ask** the agent, in the bound channel, for a piece of long research.
2. **The agent spawns a job** using its `create_background_job` tool, with a `title` and a `task`, and tells you it has done so.
3. **The job runs** out of your turn — many tool calls, many web fetches, hours if it needs them.
4. **The job posts back** when it finishes (`background_agent_job.completed`), fails (`…failed`), or needs a human decision (`…waiting`).
5. **You read the result** in the channel, or answer the question and let the job resume.

The agent that owns the job stays free to talk to you while the job runs. That is the point: long work does not block short questions.

## Prerequisites

- A working Ankole installation with at least one agent and one chat binding. If you do not have one yet, follow [Your first Lark bot](../lark-first-bot/) first.
- The agent's `primary`, `light`, and `heavy` model profiles bound (the required slots — see [Providers and models](../providers-and-models/)).
- For research that fetches sources, the agent's `web_search` and `web_fetch` profiles bound.
- A Codex account configured (see [Console operations](../console-operations/)) — background jobs run on a Codex account, default `aigateway`.

## Step 1: Ask for the research

In the bound channel, ask the agent for something that genuinely takes time. Be specific about scope, or the job will wander:

> Research our two named competitors' pricing pages and public changelogs from the last two quarters. Summarize what changed, with links. Take your time — this does not need to be fast.

The "take your time" cue matters: it signals to the agent that this is delegation-shaped, not a quick answer. A well-scoped prompt produces a well-scoped `task` on the job.

## Step 2: Watch the agent spawn the job

The agent decides the work is long and calls `create_background_job` with a `title` (short, human-readable) and a `task` (the full instruction, derived from your request and the agent's persona). It may also pick a `workspace_template_id` if the work needs a prepared workspace. The agent replies in the channel that it has handed the work off.

You do not call `create_background_job` yourself — it is the agent's tool, not yours. Your job is to scope the request well; the agent's job is to translate that into a job.

## Step 3: Watch the job run

The job is now durable state. Track it through the Console:

```bash
curl https://ankole.example.com/api/v1/background-agent-jobs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

List with `GET /background-agent-jobs`, read one with `GET /background-agent-jobs/:job_id`. The job moves through `queued` → `running` → (optionally) `waiting_on_user` → `succeeded` or `failed`. Read [Background jobs (operator view)](../background-jobs-ops/) for what each status means and the retry budget (at most five execution attempts, five consecutive turn failures).

A job in `running` is occupying one of the agent's running slots (at most three per agent). Do not panic if it runs for a while — research is supposed to take time, and a long run usually means the model is working, not stuck.

## Step 4: Answer when it asks

Some research hits a decision the agent cannot make alone — which of two directions to pursue, whether a source is authoritative, whether to spend more. The job transitions to `waiting_on_user`, releases its running slot, and posts a `background_agent_job.waiting` event back to the owning session. The question lands in the bound channel.

Answer in the channel. The owning turn resumes the job with your answer, the job moves back to `running`, and it continues. You did not have to find the job in a console and type into a form — the wake-up reached you where the conversation already lives.

## Step 5: Read the result

When the job finishes, it posts a `background_agent_job.completed` event with the result. Read it in the channel where the agent posted, or pull the full `result` field through `GET /background-agent-jobs/:job_id`. If the result is not what you wanted, the lever is the original prompt's scope and the agent's persona — re-scope and ask again, rather than editing the job.

If the job failed, read the `error`. A transient failure (provider timeout) is retried up to the budget automatically; a configuration failure means the model profiles or provider credentials need attention before the work can succeed at all.

## Operate jobs day to day

- **Cancel a runaway job** — `POST /background-agent-jobs/:job_id/cancel`. The job moves to `stopped`; an in-flight turn is allowed to finish, then the cancellation takes hold.
- **Watch for stuck `queued`** — the agent may already have three jobs running. Cancel one, or wait for one to finish.
- **Resume a `waiting_on_user`** — answer in the channel; do not leave it waiting, it is holding a slot-shaped place in your workflow even though it released the running slot.
- **Let a failed job retry or fail out** — do not manually restart it on every error; the retry budget exists for transient failures.

## When to use a job, and when not

A background job is the right shape when the work is long, multi-step, or needs isolation from the conversation. It is the wrong shape when the answer is short — spawning a job to answer "what time is it?" is overhead with no benefit. The agent decides, but your prompt scopes the decision: ask for a quick answer when you want one, and reserve the "take your time" cue for work that actually takes time.

## What this guide is not

It is not a tutorial on writing research code — the agent does the research with its own tools. It is not a guarantee that any research job succeeds on the first run; scope, persona, and the quality of the model profiles decide that, and you tune them over a few runs. And it is not a replacement for the operator surface — read [Background jobs (operator view)](../background-jobs-ops/) for the full status vocabulary, and the [Background Agent Jobs](../background-agent-jobs/) developer page for the lifecycle internals.

## Next steps

- For the operator view of jobs, read [Background jobs (operator view)](../background-jobs-ops/).
- For the lifecycle and recovery model, read [Background Agent Jobs](../background-agent-jobs/).
- For the model profiles a research job leans on, read [Providers and models](../providers-and-models/).
