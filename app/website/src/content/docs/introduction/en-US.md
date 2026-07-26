---
title: Introduction
description: What Ankole is, how it differs from an assistant, and the parts you will meet in a private deployment instance.
section: Getting started
order: 1
---

**Ankole is a self-hosted AgentOS for building your own AI colleagues.** They take an objective, not a script: they pick up a job in your team's channel, break it down, run it, deliver it, and you judge them on the result.

The difference is easiest to see in a scene. Two colleagues in a research channel settle a rule between themselves — cyclicals use a seven-year percentile, not three — and nobody addresses the agent. Three days later a third person asks it for a valuation pass on the metals names, and the report comes back on the seven-year window. An assistant living in a private chat box cannot do this. It was never in the room.

## How it differs from an assistant

The difference is position, not ability. An assistant answers "how does it help me"; a colleague answers "who owns this work by default". In use, that shows up in five places.

- **It belongs to the channel, not to whoever brought it.** Its memory belongs to the venue, its permissions are granted per channel, its actions are visible to everyone, and its conclusions become the team's shared facts — all of it on your own servers, not in a vendor's tenant.
- **A seat is a slot of responsibility, not a bundle of skills.** Being able to do the job is not the same as owning it, and loading skills is not the same as carrying responsibility. Ankole supplies the layer that turns ability into a seat: its own identity, organizational authorization, an audit trail, escalation paths, and a metric to answer to.
- **It lives inside the loop of work, not reaching into one segment.** See the scene, weigh what matters, commit, push, track the result, handle the exception, answer to the organization. SaaS records the outcome, RPA performs the motions, chatbots handle the opening question — an Ankole agent owns the loop.
- **It does not just record order — it generates it.** When commitments, risks, standards, and deadlines form in natural language in the channel, it turns them into tracked, executable, retirable organizational reality on the spot. The valuation rule in the opening scene entered the ledger exactly that way, and nobody instructed it.
- **The daily loop is its by default; people step in at the edges.** Humans stay present for approvals, exceptions, and accountability. Deliverables, decisions, and committed actions sit in a durable ledger, and its output is built to be scored afterwards.

The generated order is only as good as the memory that holds it. Most agents keep an append-only log in which an old rule and its replacement are equals, with no timeline and nothing superseding anything. Ankole's memory adjudicates — a new rule takes the seat and the old one retires with the period it governed, contradictions are ranked by time, source, and confidence, and a prediction is checked against how things actually went.

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

## Seats it can hold

Remote from end to end, a named deliverable, and a number that settles it afterwards — a task with those three properties is a seat. An equity research analyst is graded on hit rate once the call is scored, a cloud cost engineer on spend per unit of work, a regulatory affairs specialist on first-pass approval rate and rounds of questions. The common shape is not "answer this question." It is **hold this seat, use the context you have, and answer for the result.**

## Current status

Ankole is a complete, self-hostable AgentOS running in production, and still early. The control plane, Agent Computer Worker, kernel, and operator console work end to end. The public APIs carry no compatibility contract yet, so expect breaking changes between releases until they do.

## Next steps

Get it running locally with the [quick start](../quickstart/). To see the whole shape first, read the [architecture overview](../architecture/).
