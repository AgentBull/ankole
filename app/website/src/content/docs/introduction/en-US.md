---
title: Introduction
description: What Ankole is, how it differs from a private chat box, and the product shape it enables.
section: Getting started
order: 1
---

**Ankole is a self-hosted AgentOS for shared AI colleagues.** One installation, many agents, real responsibilities — on infrastructure you control.

It moves AI work out of a private chat box and into the places where work already happens: channels, repositories, schedules, dashboards, internal systems, and long-running project context. An Ankole agent has its own identity, memory, permissions, tools, workspace, and responsibility boundary — so it can **own ongoing work**, not just answer a one-off message.

[Claude Tag](https://claude.com/product/tag) is a useful public reference point: tag an AI into a Slack thread, let it read the shared context, use organization tools, remember channel context, and follow up when work takes time. Ankole targets the broader open version of that pattern: **not only Slack, not only Claude, not only one agent, and not vendor-owned context.**

Ankole is for work that needs an owner, not just an answer. A good Ankole role has a visible result: code merged, a report shipped, a customer issue handled, an alert triaged, a market change noticed, or a backlog worked down.

## How Ankole is different

- **Shared by default, not private chat.** Agents join team-visible channels and provider contexts; multiple humans can observe, steer, and continue the same work.
- **Durable identity, not a prompt convention.** Humans and agents are Principals with permission grants and audit trails, so authorization is a runtime concern.
- **Long-running actor sessions, not request/response.** Sessions wake, receive signals, checkpoint, stream progress, hibernate, and recover with context.
- **Operator-owned context, not vendor-hosted.** Memory, configuration, credentials, and audit live in your infrastructure on a self-hosted installation.
- **Live control plus durable truth, not one or the other.** ZeroMQ RuntimeFabric carries live actor/worker/RPC traffic while PostgreSQL remains the source of replay, fences, and final commits.

## What Ankole adds

- **Many sources.** IM, webhooks, scheduled reminders, internal systems, and future provider adapters all become normalized signal input.
- **Many agents.** One installation can host multiple agents with different missions, access, tools, memory, and outbound identities.
- **Session actors.** The long-running execution unit is `actor_id = {agent_id, session_id}`. A session is where context, workspace state, steering, cancellation, and recovery meet.
- **Owned context.** Conversations, model turns, summaries, signal projections, decisions, corrections, and future domain records live in your infrastructure.
- **Operator control.** Access, configuration, Agent Library defaults, Control Plane Plugin activation, actor leases, outbox side effects, and audit surfaces belong to the installation operator.

## Product shape

Ankole should make these workflows natural:

- A **coding agent** watches an issue, reproduces the bug, changes code, opens a draft PR, and reports what still needs a human decision.
- A **customer-success agent** observes a shared group chat, records the important facts, updates work state, and escalates privately only when needed.
- A **research agent** monitors markets, policy, competitors, and internal notes, then follows up when a change matters.
- A **QA agent** works through a test backlog, gathers evidence, and hands off failures with enough context for review.
- An **operations agent** watches alerts, prepares a runbook, and asks for approval before taking risky action.

The common pattern is not "answer this question." It is **"hold this seat, use the available context, and be judged by the result."**

## Current status

Ankole is a complete, self-hostable AgentOS in production: the control plane, Agent Computer, kernel, and operator console run end to end. Its public APIs do not yet carry a compatibility contract; expect breaking changes between releases.

## Next steps

- Follow the [quick start](../quickstart/) to run Ankole locally from source.
- Read the [architecture overview](../architecture/) to understand the actor runtime and its components.
- Browse the source and open issues on [GitHub](https://github.com/AgentBull/ankole).
