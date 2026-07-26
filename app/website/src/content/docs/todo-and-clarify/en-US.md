---
title: Todo and clarify
description: How an Ankole agent plans a complex task and resolves a real ambiguity mid-task — the todo tool (per-session, at most one item in progress) and the clarify tool (one decision question, durably recorded, ends the turn). What the agent uses each for, and what an operator should not expect them to do.
section: Developer guide
order: 124
---

`todo` and `clarify` are the agent's structured planning tools. One keeps the plan inside a session; the other asks you a single question when the answer genuinely changes the result. Both ship with the worker in `app/agent_computer/src/tools/`. They are not memory and they are not a chat surface — they are how the agent keeps its own footing and how it asks for one decision.

The decisive property, stated up front: the todo list is ephemeral and per-session, and a `clarify` call ends the turn. The list does not survive across sessions, and once the agent asks, it waits for your reply as the next message. Neither tool is durable truth — that role belongs to [Memory](../memory/).

## What each tool is

- **`todo`** (`tools/todo/todo-tool.ts`, line 182) — manage the task list for the current session. Use it for complex tasks with three or more steps, or when the user provides multiple tasks. List order is priority. Only one item is `in_progress` at a time. Mark items completed the moment they are done; if something fails, cancel it and add a revised item.
- **`clarify`** (`tools/clarify/clarify-tool.ts`, line 39) — ask the user one decision question when an ambiguity materially changes the result. Use it for real tradeoffs, missing requirements, and post-task feedback. Do not ask when a safe low-risk default is available. On success it returns the normalized question and choices, records them durably, and ends the current turn.

The todo list lives in a `TodoStore` that is scoped to the session. It is working state, not a record. Four states are allowed: `pending`, `in_progress`, `completed`, `cancelled`.

## When the agent uses todo

The agent reaches for `todo` when the work has enough steps that holding them in context alone becomes a liability. Three or more steps, or multiple tasks handed over at once, are the trigger. Once the list exists, the agent follows three rules:

1. **List order is priority.** The first item is the one the agent means to do next.
2. **At most one item in progress.** The agent does not start the second step before it finishes or cancels the first.
3. **Mark items completed immediately.** A step that is done leaves the list as `completed`, not as the current item. A step that fails is `cancelled` and a revised item is added.

What the todo list is not: it is not a durable plan, and it is not a way to hand work to the next session. A fresh session starts with an empty list. If a plan must outlive the session, it goes into [Memory](../memory/), not into `todo`.

## When the agent uses clarify

`clarify` is for the one question whose answer genuinely forks the result. The contract is narrow on purpose. The agent asks one question, takes optional choices (each at most 500 characters), and then stops. On a successful call three things happen:

- the normalized question and choices are recorded durably, so the decision is traceable later;
- the current turn ends — the agent emits no further answer and calls no further tools;
- your reply arrives as the next user message, and the agent picks the work back up from there.

This means a `clarify` call is a clean hand-back, not a pause in a longer turn. You answer in your own time, and the turn that continues is a new turn that begins with your answer.

When the agent should not ask: when a safe, low-risk default is available. If the agent can pick a reasonable path and tell you what it picked, it should pick — not interrupt you. Reserve `clarify` for real tradeoffs, missing requirements, and post-task feedback, where guessing wrong would force a rework.

## How clarify connects to background jobs

Inside a [background job](../background-jobs/), a `clarify` call moves the job into the `waiting_on_user` state. The job does not run further until you reply, and your reply is what moves it back to running. From your side, this looks like the job pausing to ask exactly one question. From the agent's side, it is the same contract — ask, end the turn, wait for the next message — applied inside a job lifecycle. See [Background Agent Jobs](../background-jobs/) for the state model and how you spot a job that is waiting on you.

## What the operator does not touch

The todo store, the clarify durable record, and the turn-ending behavior are worker internals, not Console-tunable settings. If an agent never asks when it should, or asks too often, the fix is in the agent's persona and capability set — see [Agents](../agents/) — not in a worker flag. The recorded decisions are auditable through the same worker surface that wrote them; an operator does not edit them by hand.

## Next steps

- For the persona and capabilities that shape when an agent plans versus asks, read [Agents](../agents/).
- For durable knowledge that does survive a session, read [Memory](../memory/).
- For the `waiting_on_user` Job state and how a clarify inside a Job pauses it, read [Background Agent Jobs](../background-jobs/).
- For the worker that runs these tools during a turn, read the [Agent Computer Worker](../agent-computer-worker/) developer page.
