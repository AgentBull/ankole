---
title: Introduction
description: What the Ankole digital headquarters, Agent Harness, and Meta Ankole Company Brain provide, and how a private deployment instance works.
section: Getting started
order: 1
---

**Ankole is the open-source digital headquarters and enterprise Agent Harness built around Meta Ankole's Company Brain. It pairs collaborative Pod workspaces with Personal Assistants and specialist AI Colleagues—giving Agents the context, authority, tools, and feedback required to execute ongoing work and show their evidence.**

Inside a private deployment, humans and Agents collaborate across Pod Docs, sharded Bases, React + TypeScript Applets, Pod Chat, and external IM channels, backed by shared company knowledge, Unified Connectors, Function Runtime, and dedicated Agent Computer Workers.

While a bare language model can only reason over the prompt it receives, Ankole assembles current company facts, enforces Principal and Drive permissions at runtime, delegates across isolated contexts, recovers in-flight work after crashes, and feeds corrections and real-world outcomes back into future work.

## What Ankole provides

- **A Pod digital headquarters:** Teams co-author hierarchical Docs, model operational data in physically sharded Bases, build React + TypeScript Applets with published zero-LLM Applet Actions, and collaborate in multiplayer Pod Chat alongside Slack, Microsoft Teams, Lark/Feishu, DingTalk, and WeCom.
- **Personal Assistants and AI Colleagues:** Every internal member gets a 1:1 Personal Assistant that acts within its owner's collaboration permissions, while specialist AI Colleagues operate under their own Principal permissions, propose Action Cards for human approval, and accept isolated Peer A2A delegation (`send_to_agent`).
- **Meta Ankole (`Brain`, `Skills`, and contracts):** Meta Ankole unifies the Company Brain ontology graph (tracking sources, claims, timestamps, confidence, conflicts, and audience scopes) with shared `Skills` and composable `AGENTS.md` and `DESIGN.md` behavioral and visual contracts.
- **Unified Connectors and MCP gateway:** `Ankole.Connectors` manages shared application credentials, personal member OAuth grants (`/connectors`), and the control-plane MCP gateway for Lark/Feishu, GitHub, Linear, and Skill-declared remote MCP servers without exposing raw secrets to Workers or Applet isolates.
- **Event-driven, crash-recoverable execution:** Chat messages, schedules, webhooks, and Connector triggers wake Sessions, Background Agent Jobs, or deterministic Applet Actions—recovering cleanly from PostgreSQL across process restarts.
- **Continuous learning:** Dreaming automatically activates 7-day leased Skill cautions from real Job trajectories and grades forecasts against actual outcomes, while humans curate permanent cautions and shared Skills.

## The parts of a deployment instance

The following core concepts appear throughout the documentation:

| Part | What it is | More |
|---|---|---|
| **Pod** | The shared digital headquarters where humans and Agents collaborate across hierarchical Docs, physically sharded Base tables, React + TypeScript Applets (with published Applet Actions), Unified Drive, and multiplayer Pod Chat. | [Architecture](../architecture/) |
| **Personal Assistant & AI Colleague** | Two Agent roles: a 1:1 **Personal Assistant** per member that projects its owner's collaboration access, and specialist **AI Colleagues** that act under their own Principal grants and collaborate via isolated Peer A2A (`send_to_agent`). | [Agents](../agents/) |
| **Meta Ankole (`Brain`, `Skills`, contracts)** | The shared institutional layer combining the **Brain** ontology graph and provenance-tracked claims, reusable **Skills** (with per-Agent leased cautions), and composable `AGENTS.md` / `DESIGN.md` Agent contracts. | [Brain](../brain/), [Skills](../skills/), [Agent Library](../agent-library/) |
| **Unified Connectors** | Tenant application connections (`authConfigId`), personal member OAuth (`/connectors`), external event subscriptions, and the control-plane MCP gateway serving Toolkits (such as Lark, GitHub, and Linear) to Workers and Function Runtime. | [Using MCP](../using-mcp/) |
| **Principal** | The accountable `(tenant_id, uid)` subject representing a person, Agent, or internal `system` service (`system`, `ankole_brain`). `Ankole.AuthZ` evaluates permissions and audit attribution against each Principal at runtime. | [Principal and AuthZ](../principal-authz/) |
| **Session** | The unit of Agent execution within a conversation or Peer A2A exchange, owning context, steering, cancellation, cold-wake rotation, and crash recovery. | [Sessions](../sessions/) |
| **Signal routing rule** | A rule that connects an IM channel, webhook, schedule, Base/Applet event, or Connector trigger to a target Agent Session or published Applet Action. | [Signal routing rules](../signal-bindings/) |
| **Background Agent Job** | A durable Codex-backed task that runs asynchronously on the Agent's Worker—often for hours—and delivers results or mid-run questions back to the originating conversation. | [Background Agent Jobs](../background-agent-jobs/) |
| **Function Runtime** | The stateless `ankole-function-runtime` service that runs isolated TypeScript programs for Pod Applet backends, published zero-LLM Applet Actions ([Automation Jobs](../automation-jobs/)), Programmatic Tool Calling, and Workflows, bridged to the control-plane MCP host. | [Architecture](../architecture/) |
| **Agent Computer Worker** | Each Agent's dedicated compute environment running shell tools, headless browsers, Codex Jobs, MCPorter, Git helpers, persistent `/workspace` Home, and `/drive` FUSE mounts of Unified Drive, Brain, Skills, and contracts. | [Agent Computer Worker](../agent-computer-worker/) |

Agents can also launch [Deep Research](../deep-research-job/) for multi-source investigations and use [browser automation](../browser-automation/) to interact with live web pages.

## Decision and operational work it supports

Ankole is designed for consequential digital work that demands inspectable evidence and verifiable artifacts—such as industry research across competing hypotheses, product and market evaluations backed by scenario models, reproducible data analysis, and ongoing cross-system operations across Pod Bases, Applets, GitHub, Linear, and enterprise IMs.

Depending on the task, a member's Personal Assistant can handle work directly within their permissions, delegate specialized tasks to an AI Colleague over Peer A2A (`send_to_agent`), fan an investigation across isolated subagent contexts in a [Workflow](../workflows/), or schedule zero-LLM Applet Actions for deterministic syncs and checks. Throughout every run, Meta Ankole and incoming Signals supply current context, Principal and AuthZ boundaries govern every action, and observed outcomes refine future work.

## Current status

Ankole runs in production as a complete enterprise digital headquarters and Agent Harness. Organizations self-host the Elixir control plane, Pod workspaces, Function Runtime (`ankole-function-runtime`), Agent Computer Workers, Rust Kernel, Meta Ankole, Unified Connectors, and operator Console on their own infrastructure. We verify critical code paths and core state machines with formal methods, and run end-to-end test suites covering message routing, Drive ACLs, crash recovery, concurrency, and upgrades.

Ankole carries no public API backwards-compatibility guarantee, so releases may introduce breaking changes.

## Next steps

To bring up a deployment, follow the [quick start](../quickstart/). To see how the components fit together, read the [architecture overview](../architecture/).
