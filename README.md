# Ankole - Open AgentOS for Shared AI Colleagues

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)

[简体中文](./README.zh-Hans.md) | [日本語](./README.ja.md)

Ankole is an open-source, self-hosted AgentOS for shared AI colleagues.

The goal is to move AI work out of a private chat box and into the places where work already happens: channels, repositories, schedules, dashboards, internal systems, and long-running project context. An Ankole agent is meant to have its own identity, memory, permissions, tools, workspace, and responsibility boundary.

[Claude Tag](https://claude.com/product/tag) is a useful public reference point: tag an AI into a Slack thread, let it read the shared context, use organization tools, remember channel context, and follow up when work takes time. Ankole targets the broader open version of that pattern: not only Slack, not only Claude, not only one agent, and not vendor-owned context.

Ankole is for work that needs an owner, not just an answer. A good Ankole role has a visible result: code merged, a report shipped, a customer issue handled, an alert triaged, a market change noticed, or a backlog worked down.

## What Ankole Adds

- **Shared work, not private chat.** Agents can be brought into shared channels and provider contexts where multiple humans can observe, steer, and continue the work.
- **Durable identity.** Humans and agents are represented as Principals with external identities, groups, and permission grants.
- **Many sources.** IM, webhooks, scheduled reminders, internal systems, and future provider adapters all become normalized signal input.
- **Many agents.** One installation can host multiple agents with different missions, access, tools, memory, and outbound identities.
- **Session actors.** The long-running execution unit is `actor_id = {agent_id, session_id}`. A session is where context, workspace state, steering, cancellation, and recovery meet.
- **Owned context.** Conversations, model turns, summaries, signal projections, decisions, corrections, and future domain records live in your infrastructure.
- **Operator control.** Access, configuration, plugin activation, actor leases, outbox side effects, and audit surfaces belong to the installation operator.

## Product Shape

Ankole should make these workflows natural:

- A coding agent watches an issue, reproduces the bug, changes code, opens a draft PR, and reports what still needs a human decision.
- A customer-success agent observes a shared group chat, records the important facts, updates work state, and escalates privately only when needed.
- A research agent monitors markets, policy, competitors, and internal notes, then follows up when a change matters.
- A QA agent works through a test backlog, gathers evidence, and hands off failures with enough context for review.
- An operations agent watches alerts, prepares a runbook, and asks for approval before taking risky action.

The common pattern is not "answer this question." It is "hold this seat, use the available context, and be judged by the result."

## Actor Runtime

Ankole is an actor-oriented runtime for long-running AI work. Each active session is an addressable virtual actor: it can wake, receive messages, checkpoint, stream progress, hibernate, recover, and continue without pretending an agent is just an HTTP request or a queue job.

The runtime is built around five technical bets:

- **Virtual Actors for AI work.** A session is a stateful work identity with an address, mailbox, lifecycle, and recovery path, not loose background work.
- **OTP Supervision Trees as failure domains.** If one agent hangs, times out, or crashes, Ankole can isolate or restart that branch without turning it into a deployment-wide failure.
- **ZeroMQ Activation Fabric for live control.** Wakeups, steering, checkpoints, streaming, and backpressure move through a low-latency routing layer while the agent is still working.
- **Agent Computer as the execution substrate.** The LLM loop, tools, MCP servers, files, terminal state, and streaming output run inside a Bun + TypeScript computer close to the workspace.
- **Durable Ledger for recovery and audit.** Mailboxes, turns, reminders, decisions, and committed side effects outlive processes. Streaming is progress; committed work is truth.

For users and operators, the promise is simple: agents can work for hours or days, receive new input while running, fail independently, recover with context, and keep their side effects accountable. A longer version of the runtime argument is in [Why OTP Is a Better Runtime for Multi-Agent Orchestration](https://ding.ee/en-US/why-otp-is-a-better-runtime-for-multi-agent-orchestration/).

That is the technical bet: actor model for long-lived work identity, OTP for failure semantics, ZeroMQ for live activation, and Agent Computer for local execution. Ankole is closer to a distributed operating system for AI work than a chatbot backend.

## Current Repository

This repository is the early Ankole control-plane and runtime foundation. It is not yet a polished end-user distribution.

- `app/control_plane` - Phoenix control plane for Principal/AuthZ, AppConfigure, plugins, SignalsGateway, setup, console, and web shell.
- `app/kernel` - shared native foundation for runtime-neutral mechanisms such as crypto, hashing, identifiers, and policy helpers.
- `app/agent_computer` - Bun + TypeScript Agent Computer runtime for the local LLM loop, tools, files, terminal state, and worker daemon.
- `app/webapps` - Vite-powered frontend applications mounted by the Phoenix shell.
- `libs/uikit` - shared UI primitives for Ankole webapps.
- `libs/feishu_openapi` - local Lark/Feishu OpenAPI client library.
- `plugins` and `internals/plugins` - trusted first-party Elixir plugins. Plugins are installation-global and default-on, with a global disable list.
- `docs/design-docs` - current design documents for principal identity, authorization, configuration, signals, plugins, and provider adapters.

SignalsGateway is the provider-ingress layer. It lets Ankole observe chats, webhooks, and provider events without confusing external source facts with agent execution. Signals become actor input; actor scheduling and execution stay in the runtime.

## Development

Ankole defaults to Bun for workspace scripts and Elixir/Phoenix for the control plane.

```shell
bun install

# Local support services and workspace helpers
bun run kit --help
bun run services:start
bun run services:status

# Control plane
bun run control-plane:setup
bun run control-plane:dev
bun run control-plane:test

# Agent Computer container image and tests
docker build -f app/agent_computer/Dockerfile -t ankole-agent-computer:0.1.0 .
bun run agent-computer:test
bun run agent-computer:type-check

# Other Bun packages
bun run webapps:build
bun run feishu-openapi:test
```

Agent Computer is designed to run as a Linux container runtime. For strong
bubblewrap command isolation, run Docker with `--cap-add SYS_ADMIN`,
`--security-opt seccomp=unconfined`, and
`--security-opt systempaths=unconfined` unless you provide an equivalent custom
seccomp/profile setup. In Kubernetes, put the equivalent
`capabilities.add: ["SYS_ADMIN"]`, `seccompProfile`, and `procMount: Unmasked`
on the Agent Computer container `securityContext`. If strong bubblewrap is
unavailable, the worker may downgrade to weak bubblewrap (container `/proc`
bind-mounted into bwrap) and emits a startup warning. It never falls back to
unsandboxed model-facing commands.

Package-local validation is preferred while the workspace is moving quickly:

```shell
bun run --filter @ankole/control-plane test
bun run agent-computer:test
bun run --filter @ankole/agent-computer type-check
bun run --filter @ankole/webapps type-check
bun run --filter @ankole/feishu-openapi test
```

Production bootstrap configuration uses standard infrastructure names such as `DATABASE_URL`, `SECRET_KEY_BASE`, and `REDIS_URL`. Runtime application configuration belongs in Ankole's PostgreSQL-backed AppConfigure surface rather than process-local environment variables.
