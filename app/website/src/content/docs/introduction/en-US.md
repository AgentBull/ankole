---
title: Introduction
description: What Ankole is, how autonomous labor differs from a copilot, and the parts in a private deployment instance.
section: Getting started
order: 1
---

**Ankole is the open-source AI Workforce OS. It turns AI agents into autonomous labor that performs business functions and is measured by outcomes.**

Give an Agent an investment research function, authority boundaries, tools, and performance measures. It maintains hypotheses, produces reports, tracks calls, and compares them with later outcomes.

A copilot waits for the next prompt because the person owns the work. An Ankole Agent owns the next action within its function and returns to people at approval, exception, and accountability boundaries.

## How autonomous labor differs from a copilot

- **A business function, not a chat persona.** Each Agent has ongoing responsibility, expected deliverables, operating context, and a result measure.
- **Outcomes, not activity.** Work is scored by the number that matters to the business, such as return, risk, ranking, approval rate, or cost per unit.
- **An execution loop, not next-step suggestions.** The Agent plans, uses tools, follows up, recovers from failure, and delivers.
- **Authority with boundaries.** Identity, AuthZ, approvals, audit records, and escalation paths define what the Agent can do.
- **Long-running work, not one request.** Sessions can run for hours or days, receive new input, recover after failure, and retain operating context.

Autonomous work depends on current context. Ankole records rules, decisions, corrections, and outcomes with time and source, instead of treating every old message as equally true.

Brain retires stale rules, resolves conflicts, and compares predictions with later results. Each run starts from a more accurate operating picture.

## The parts of a deployment instance

These words recur throughout the rest of the docs, so here they are once.

| Part | What it is | More |
|---|---|---|
| **Agent** | A working identity with its own mission, access, tools, memory, and outbound identity; the mission and delivery standards are files you can edit at any time. One deployment instance can hold several. | [Agents](../agents/) |
| **Session** | The long-running unit of execution, and where context, workspace state, steering, cancellation, and recovery meet. | [Actor runtime](../actor-runtime/) |
| **Signal routing rule** | Connects an Agent to a signal source and sets the boundary of what it can do there. | [Signal routing rules](../signal-bindings/) |
| **Background job** | Work sent out of a session that can run for hours, then delivers back to the channel it came from. | [Background Agent Jobs](../background-agent-jobs/) |
| **Memory** | Channel rules plus long-horizon memory — a world model that predicts from experience and is corrected by reality. | [Memory](../memory/), [Brain](../brain/) |
| **Skill** | The settled way to do one kind of job. An agent can propose an improvement; a human approves it for the next session. | [Skills](../skills/) |
| **Principal** | People and agents are the same kind of subject, so the runtime enforces permissions and audit for both. | [Principal and AuthZ](../principal-authz/) |
| **Agent Computer Worker** | The execution floor: the LLM loop, tools, files, terminal state, and streaming output all run here. | [Agent Computer Worker](../agent-computer-worker/) |

An Agent can also use [Deep Research](../deep-research-job/) for long, multi-source research and [browser automation](../browser-automation/) to work with real web pages.

## Business functions it can perform

Ankole fits work that can be done digitally, produces inspectable deliverables, and has a declared outcome measure.

Examples include performance marketing measured by incremental ROAS, trading measured by risk-adjusted return, SEO measured by ranking movement, and patent prosecution measured by grant rate.

The unit is a business function, not an Agent count. Multi-agent coordination is an implementation choice, not the product promise.

The common contract is: **define the function, grant bounded authority, let the Agent work, and score the outcome.**

## Current status

Ankole is a complete, self-hostable AI Workforce OS running in production, and it is still early. The control plane, Agent Computer Worker, kernel, and operator console work end to end.

The public APIs do not have a compatibility contract yet. Expect breaking changes between releases until they do.

## Next steps

Get it running locally with the [quick start](../quickstart/). To see the whole shape first, read the [architecture overview](../architecture/).
