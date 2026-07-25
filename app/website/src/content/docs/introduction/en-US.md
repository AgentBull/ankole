---
title: Introduction
description: What Ankole is, why it is not a chat box, and the work it is built to hold.
section: Getting started
order: 1
---

**Ankole is a self-hosted AgentOS for shared AI colleagues.** One installation runs many agents, each with a real job, on infrastructure you own.

The premise is simple. Chat boxes answer one question at a time; work needs an owner who stays with a task for hours or days, reads the surrounding context, and is judged by the result. Ankole gives an agent the things an owner needs: an identity, memory, permissions, tools, a workspace, and a clear scope. Then it lets work reach that agent from the channels where it already happens — chat, webhooks, schedules, internal systems — instead of forcing a person to copy context into a prompt.

A useful public reference point is [Claude Tag](https://claude.com/product/tag): tag an AI into a Slack thread, let it read the shared context, use the organization's tools, and follow up when the work takes time. Ankole aims at the open version of that pattern. Not only Slack, not only Claude, not only one agent, and not vendor-hosted context.

## How Ankole is different

Most AI products optimize the single turn. Ankole optimizes the seat.

- **Shared, not private.** Agents live in team-visible channels and provider contexts, so several people can watch, steer, and continue the same work.
- **Identity is a runtime fact, not a prompt.** Humans and agents are Principals with permission grants and audit trails, so authorization is enforced at the boundary instead of asked of the model.
- **Long-running actors, not request/response.** A session wakes, receives signals, checkpoints, streams progress, hibernates, and recovers with its context intact.
- **You own the context.** Memory, configuration, credentials, and audit live in your infrastructure, behind your control plane — not in a vendor's tenant.
- **Live control plus durable truth.** ZeroMQ RuntimeFabric carries live actor and worker traffic; PostgreSQL remains the source of replay, fences, and final commits. You do not trade one for the other.

## What an Ankole installation gives you

- **Many sources, one shape.** IM, webhooks, scheduled reminders, internal systems, and future provider adapters all become normalized signal input.
- **Many agents.** One installation hosts several agents, each with its own mission, access, tools, memory, and outbound identity.
- **Session actors.** The long-running unit is `actor_id = {agent_id, session_id}`. Context, workspace state, steering, cancellation, and recovery all meet there.
- **Owned context.** Conversations, model turns, summaries, signal projections, decisions, corrections, and future domain records stay in your infrastructure.
- **Operator control.** Access, configuration, Agent Library defaults, Control Plane Plugin activation, actor leases, outbox side effects, and audit all belong to the operator of the installation.

## Where Ankole fits

Ankole earns its keep when the work has a visible result and needs someone to own it.

- A **coding agent** watches an issue, reproduces the bug, changes the code, opens a draft PR, and tells you which decisions still need a human.
- A **customer-success agent** reads a shared group chat, records the facts that matter, updates the work state, and escalates privately only when it should.
- A **research agent** tracks markets, policy, competitors, and internal notes, and follows up only when a change actually matters.
- A **QA agent** works through a test backlog, gathers evidence, and hands failures off with enough context to review.
- An **operations agent** watches alerts, drafts a runbook, and asks before it takes a risky action.

The common shape is not "answer this question." It is **hold this seat, use the context that is there, and be judged by the result.**

## Current status

Ankole is a complete, self-hostable AgentOS, running in production. The control plane, Agent Computer, kernel, and operator console work end to end. The public APIs do not yet carry a compatibility contract, so expect breaking changes between releases until that changes.

## Next steps

- Run Ankole locally from source with the [quick start](../quickstart/).
- Read the [architecture overview](../architecture/) to see how the actor runtime and its components fit together.
- Browse the source and open issues on [GitHub](https://github.com/AgentBull/ankole).
