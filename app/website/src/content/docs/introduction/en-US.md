---
title: Introduction
description: What the Ankole Agent Harness and Company Brain provide, and how a private deployment instance works.
section: Getting started
order: 1
---

**Ankole is the open source Claude Tag alternative with a Company Brain. Its enterprise Agent Harness gives Agents the context, authority, tools, and feedback required to make decisions and show their evidence.**

Durable Agents combine shared company knowledge, Pod workspaces, live signals, enterprise access control, Agent Computer Workers, and persistent execution across everyday company work.

While a language model can only reason over the context that it receives, the Harness assembles current company facts, enforces access rules, grants bounded capabilities, recovers in-flight work after failures, and records outcomes to inform future decisions.

## What the Harness provides

- **Provenance-rich memory:** Brain keeps every piece of knowledge attached to its source, timestamp, holder, confidence level, conflicts, and permitted audience.
- **Inspectable reasoning:** Evidence, uncertainty, competing hypotheses, and missing information stay visible for human review.
- **Event-driven activation:** Ankole routes chat messages, schedules, webhooks, and external business events to wake the Agent responsible for the work.
- **Runtime access control:** Ankole enforces each Agent's authority through Principal identity, AuthZ grants, approvals, audit records, and escalation paths.
- **Durable execution:** Sessions and Background Agent Jobs can run for hours or days, accept new input mid-run, recover after process crashes, and deliver results back to the originating conversation.
- **Continuous learning:** Operators and Agents can feed corrections and observed outcomes back into Company Brain before the next decision begins.

## The parts of a deployment instance

The following core concepts appear throughout the documentation:

| Part | What it is | More |
|---|---|---|
| **Agent** | A working identity with its own mission, permissions, tools, and outbound persona. Operators define its mission and delivery standards in editable Markdown files, and one deployment instance can host multiple Agents. | [Agents](../agents/) |
| **Pod** | The shared workspace where humans and Agents collaborate across hierarchical pages, real-time documents, relational Base tables, Applets, and multiplayer Pod Chat. | [Architecture](../architecture/) |
| **Brain** | Shared company knowledge tracking sources, claims, timestamps, confidence, conflicts, and audience boundaries so authorized Agents work from the same current facts. | [Brain](../brain/) |
| **Session** | The unit of Agent execution that owns conversation context, workspace state, steering, cancellation, and crash recovery. | [Sessions](../sessions/) |
| **Signal routing rule** | A rule that connects an Agent to a signal source and defines what it may observe and do there. | [Signal routing rules](../signal-bindings/) |
| **Background job** | A durable task that runs outside a conversation Session—often for hours—and delivers its result back to the originating channel. | [Background Agent Jobs](../background-agent-jobs/) |
| **Skill** | An approved procedure for a repeatable kind of work. Agents can accumulate dated cautions, and humans maintain the shared procedure across Sessions. | [Skills](../skills/) |
| **Principal** | The accountable subject representing a person, Agent, or system service. The runtime evaluates permissions and records audit trails against each Principal. | [Principal and AuthZ](../principal-authz/) |
| **Function Runtime** | The stateless `ankole-function-runtime` service that runs isolated TypeScript programs for deterministic tool orchestration and backend functions in Pod Applets. | [Architecture](../architecture/) |
| **Agent Computer Worker** | The isolated compute environment that executes shell commands, file edits, browsers, and Codex Jobs while the control plane drives the main model loop. | [Agent Computer Worker](../agent-computer-worker/) |

Agents can also launch [Deep Research](../deep-research-job/) for multi-source investigations and use [browser automation](../browser-automation/) to interact with live web pages.

## Decision work it supports

Ankole is designed for consequential digital work that demands inspectable evidence and verifiable results—such as industry research across competing hypotheses, product and market evaluations backed by scenario models, and deep data analysis with reproducible code and causal checks.

Depending on the problem, a single Agent can own a decision end to end, or a Workflow can split the analysis across independent subagent contexts when separate contexts help reduce correlated errors. Throughout each run, Company Brain and incoming signals supply the working context, bounded Principal authority governs what the Agent can do, and new evidence and observed outcomes inform subsequent decisions.

## Current status

Ankole runs in production as a complete enterprise Agent Harness. Organizations can self-host the Elixir control plane, Pod workspaces, Function Runtime (`ankole-function-runtime`), Agent Computer Workers, Rust Kernel, Company Brain, and operator Console on their own infrastructure. We verify critical code paths and core state machines with formal methods, and run end-to-end test suites covering message routing, crash recovery, concurrency, and upgrades.

Ankole carries no public API backwards-compatibility guarantee, so releases may introduce breaking changes.

## Next steps

To bring up a local deployment, follow the [quick start](../quickstart/). To see how the components fit together, read the [architecture overview](../architecture/).
