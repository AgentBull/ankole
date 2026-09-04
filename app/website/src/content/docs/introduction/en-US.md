---
title: Introduction
description: What the Ankole Agent Harness and Company Brain provide, and how a private deployment instance works.
section: Getting started
order: 1
---

**Ankole is the open source Claude Code alternative with a Company Brain. Its enterprise Agent Harness gives Agents the context, authority, tools, and feedback required to make decisions and show their evidence.**

Durable Agents use shared company knowledge, live signals, enterprise authority, Agent Computer workers, and persistent execution across company work.

A model reasons over the context it receives. The Harness selects current company facts, applies access rules, grants capabilities, restores work after failure, and records results for later decisions.

## What the Harness provides

- Brain keeps knowledge attached to its source, time, holder, confidence, conflicts, and audience.
- Evidence, uncertainty, competing hypotheses, and missing information remain visible for review.
- Messages, schedules, webhooks, and external events wake the Agent responsible for the work.
- Identity, AuthZ, approvals, audit records, and escalation paths enforce the authority of each Agent.
- Work can run for hours or days, accept new input, recover after process failure, and deliver to its original context.
- Corrections and observed outcomes can revise Company Brain before the next decision begins.

## The parts of a deployment instance

The following terms appear throughout the documentation.

| Part | What it is | More |
|---|---|---|
| **Agent** | A working identity with its own mission, access, tools, and outbound identity. Editable files hold its mission and delivery standards. One deployment instance can hold several Agents. | [Agents](../agents/) |
| **Brain** | Shared company knowledge with sources, claims, time, confidence, conflicts, and audience boundaries. Authorized Agents use the same current company context. | [Brain](../brain/) |
| **Session** | The unit of execution that owns context, workspace state, steering, cancellation, and recovery. | [Actor runtime](../actor-runtime/) |
| **Signal routing rule** | Connects an Agent to a signal source and sets the boundary of what it can do there. | [Signal routing rules](../signal-bindings/) |
| **Background job** | A task that runs outside a Session for hours and delivers its result to the originating channel. | [Background Agent Jobs](../background-agent-jobs/) |
| **Skill** | An approved procedure for one kind of work. An Agent can propose an improvement, and a human approves it for the next Session. | [Skills](../skills/) |
| **Principal** | The permission subject for a person or Agent. The runtime applies permissions and audit rules to each Principal. | [Principal and AuthZ](../principal-authz/) |
| **Agent Computer Worker** | The environment that runs the LLM loop, tools, files, terminal state, and streaming output. | [Agent Computer Worker](../agent-computer-worker/) |

An Agent can also use [Deep Research](../deep-research-job/) for long research across several sources and [browser automation](../browser-automation/) to work with real web pages.

## Decision work it supports

Ankole fits consequential digital work that produces inspectable evidence and observable results.

Examples include industry research with competing hypotheses, product and market selection with scenario models, and deep data analysis with reproducible methods and causal alternatives.

The Harness supports many kinds of work. One Agent can own a decision. A Workflow can divide it across independent Agent contexts when separate contexts reduce correlated errors.

Company knowledge and signals establish context. Bounded authority lets the Agent act. Evidence and observed outcomes update later decisions.

## Current status

Ankole runs in production as a complete enterprise Agent Harness. A company can host the control plane, Agent Computer Worker, kernel, Company Brain, and operator console on its own infrastructure.

Ankole is still defining its public API compatibility contract. Releases can include breaking changes.

## Next steps

Local setup starts with the [quick start](../quickstart/). The [architecture overview](../architecture/) explains each component and boundary.
