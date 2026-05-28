# BullX — AgentOS for AI Colleagues

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19-48205D?logo=elixir)](https://elixir-lang.org)

[English](./README.md) | [简体中文](./README.zh-Hans.md) | [日本語](./README.ja.md)

> :warning: **BullX is in early development. Some capabilities described here are still planned for later releases.**

BullX is an AgentOS for working side by side with self-directed AI Colleagues.

Built on Elixir/OTP, PostgreSQL, and Redis, BullX is designed for durable digital work across enterprises, teams, and one-person companies.

OTP's lightweight processes, supervision trees, and message-passing isolation map naturally onto fleets of long-running, fault-tolerant AI Agents — see [Why OTP is a better runtime for multi-agent orchestration](https://ding.ee/en-US/why-otp-is-a-better-runtime-for-multi-agent-orchestration/) for the longer argument.

Chatbots made LLMs conversational. The [OpenClaw](https://grokipedia.com/page/OpenClaw) and [Hermes-Agent](https://hermes-agent.nousresearch.com/docs/user-stories) generation gave agents hands: channels, tools, skills, shell and browser access, memory files, subagents, and scheduled work. [Dify](https://docs.dify.ai/en/use-dify/getting-started/key-concepts), RPA, and RAG workflow builders made it easier to package AI into specific business apps. BullX is designed for the next step: AI Colleagues that do accountable work over time, inside an operating model that can be audited, recovered, governed, and improved.

BullX is built around AI Agents as colleagues, not RAG support bots or digital assistants waiting for instructions. A BullX Agent can carry a long-term mission, track KPI/OKR-style success metrics, hold responsibility, work over long horizons, collaborate with humans or other Agents, and improve from trajectory data.

BullX does not optimize for "one more chat interface." It turns AI Colleagues into a durable work system:

- **Agents** carry long-term missions, responsibilities, permissions, memory, outbound identity, and KPI/OKR-style success metrics.
- **IMGateway and other gateways** save external-world facts and emit CloudEvents mail.
- **MailBox** creates internal delivery entries for receivers such as AIAgents, Workflows, SubAgents, gateways, and blackholes.
- **Receivers** do the work: most commonly an AIAgent for flexible judgment or a Workflow for explicit process structure.
- **Principals**, **Budgets**, and human collaboration paths make responsibility explicit before expensive or risky work happens.
- **Capabilities** expose models, tools, browsers, sandboxes, messaging channels, APIs, and external agent harnesses without hiding power inside prompts.
- **Brain** provides long-term memory and a reasoning world model: not a raw vector log, not a giant Markdown memory file, and not a fully predefined ontology, but evolvable knowledge extracted from conversations, events, actions, and outcomes.

## Three Models, One Distinction

Many systems now call themselves agents or digital workers, but they optimize for different things.

- **OpenClaw / Hermes-style assistants** are prompt-driven Agentic Loops. They are good at personal assistance, tool use, channel integration, cron, memory files, skills, and subagents. The main subject is still an assistant session that acts when prompted, scheduled, or messaged.
- **Dify / RPA / RAG workflow digital workers** are app- or workflow-driven automations. They are useful for bounded jobs such as customer-service bots, BI report bots, invoice review bots, document extraction, and other repeatable pipelines.
- **BullX AI Colleagues** are mission-driven work subjects. A mission is a long-term objective, closer to a KPI or OKR than a one-off task. They have permissions, budgets, memory, outbound identity, and responsibility. They can observe the world, decide what matters, collaborate with humans or other Agents, and improve from trajectory data.

| Dimension | OpenClaw / Hermes-style assistant | Dify / RPA / RAG workflow worker | BullX AI Colleague |
| --- | --- | --- | --- |
| Primary unit | Agentic Loop or assistant session. | App, bot, RPA flow, or workflow run. | Agent with long-term mission, responsibility, Work, and MailBox-routed context. |
| Autonomy | Reacts to prompts, messages, cron, or user-configured tasks. | Executes a defined process for a specific business scenario. | Observes Events, prioritizes work, asks for help, delegates, and advances long-term objectives. |
| Actions | Tool calls, shell/browser work, messages, files, subagents. | Form fills, API calls, extraction, routing, approvals, report generation. | Governed Capabilities, AIAgent actions, and explicit Workflow steps where process structure is needed. |
| Memory and reasoning | Session memory, markdown files, skill notes, or external memory layers. | RAG knowledge bases, workflow variables, and app-specific state. | Brain as a reasoning world model that grows from conversations, events, actions, relationships, outcomes, and domain objects. |
| Self-evolution | Learns new skills or notes from past sessions. | Improves when the workflow or knowledge base is manually revised. | Uses trajectory data to improve planning, Skills, policy, and future execution. |
| Permissions and budgets | Usually tool policy, model config, and local runtime controls. | App credentials, node permissions, rate limits, and workflow settings. | Principal identity, delegated authority, Budget limits, outbound identity, and audit boundaries. |
| Human collaboration | Often an approval prompt, DM gate, or manual confirmation. | Approval nodes or manual review steps inside a specific process. | Humans can be managers, peers, or assignees: approve, correct, escalate, take over, provide missing context, help with real-world tasks, or receive tasks from an Agent. |
| External events | Channels, cron, webhooks, and integrations feed the assistant loop. | Triggers start a predefined app or workflow. | Gateways save external facts, MailBox delivers CloudEvents mail, and receivers update long-running Work through business records. |
| Accountability | Transcript and tool history explain what happened in a session. | Workflow logs explain one app run. | Product facts record who acted, who approved, what budget was spent, what changed, and how later behavior should improve. |

## Why BullX

BullX keeps the useful surfaces of earlier agent systems: channels, tools, Skills, sandboxes, browsers, SubAgents, schedules, and conversational entry points. The difference is where product truth lives. In BullX, durable work belongs to business records such as Work, Conversation, ApprovalRequest, ChildRun, Principal, Budget, Brain, domain records, and trajectory data, not only to an assistant session or a workflow run log.

BullX also differs from Palantir-style ontology programs. Brain is inspired by ontology and the semantic web, but BullX does not start by asking experts to predefine a complete business graph. Its world model should grow through work: conversations, Events, domain records, decisions, handoffs, corrections, and outcomes gradually teach an AI Colleague the business, the industry, the company, and the unwritten ways people actually get work done.

The result BullX is aiming for is not "a better bot" or "a smarter workflow app." It is an operating system for AI Colleagues that can watch, decide, delegate, wait, ask, spend, remember, and act with product-level accountability.

## What It Should Feel Like

**A group chat can be observed without adding noise.** A customer-success Agent can notice risk in a group conversation, create Work, and privately alert the account owner without replying in the group.

**One input can reach the right work path.** A budget-freeze message is saved by its gateway, delivered through MailBox, and reaches a receiver. That receiver can be an AIAgent that handles the case directly or a Workflow that expresses explicit branching, approval, parallelism, and deterministic steps.

**Memory can include the world, not only the chat.** A research Agent should combine conversations with market, policy, product, operational, and external events, then retrieve context through an ontology-backed world model that grew from actual work.

**The world model can mature like a human colleague.** After joining a team, a BullX Agent should become progressively more familiar with the business, the industry, internal norms, recurring exceptions, and tacit knowledge, without requiring the organization to model everything upfront.

**Agents can own long-term missions, not just tasks.** A coding Agent, research Agent, or customer-success Agent can work across many interactions, coordinate with humans or other Agents, and improve future planning from trajectory data.

**Humans can be managers, peers, or assignees.** A human can approve or correct an Agent, work as a peer, take over a case, provide missing real-world input, or receive an assigned task such as checking a fact offline or scanning a login QR code.

**High-risk work can be gated.** Customer-facing, financial, legal, permission-changing, or irreversible side effects should pass through explicit approval or policy gates before execution.

## Getting Started

**Prerequisites:** Elixir 1.19+, PostgreSQL, Bun

Make sure PostgreSQL is running and `DATABASE_URL` in `.env.dev` or `.env.local` points at it.

```sh
# Bootstrap Elixir deps, JS deps, database, and assets
bun setup

# Start Phoenix and the Rsbuild development asset server
bun dev
```

Open `http://localhost:4000`. The current app shell redirects `/` to `/setup`.

In development, Phoenix starts Rsbuild as an endpoint watcher. The browser entry point remains `http://localhost:4000`; Rsbuild listens on `http://localhost:5173` for React/Inertia hot reload. If those ports are already in use, set `PORT` and `RSBUILD_PORT` in `.env.local`, for example `PORT=4001` and `RSBUILD_PORT=5174`.

Useful project commands:

```sh
# Install/update JS dependencies
bun install

# Run the full project check used before committing
bun precommit

# Run frontend tests and cross-language lint checks
bun run test
bun run lint
```

## Rsbuild Asset Builds

The React/Inertia app entry is `webui/src/app.jsx`, with SPA pages under `webui/src/apps/`. For deployable assets, Rsbuild writes `priv/static/assets/.rsbuild/manifest.json`, and Phoenix resolves scripts and styles from that manifest outside development.

Run Bun from the repository root; Rsbuild uses `webui/src/` for application source and `assets/css/` for the Phoenix CSS entry.

```sh
# Build Rsbuild assets and manifest
mix assets.build

# Build production assets, including digests
mix assets.deploy
```

`mix assets.deploy` runs compilation, the Rsbuild build, and `phx.digest`. Run it before building a production release.

**Production:**

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
_build/prod/rel/bullx/bin/bullx start
```

## Environment Files

BullX loads dotenv files from the repository root. Later files override earlier ones; variables already present in the OS environment take precedence over dotenv values.

| Environment | Load order |
|---|---|
| Development | `.env` -> `.env.dev` -> `.env.local` |
| Test | `.env` -> `.env.test` |
| Production | `.env` -> `.env.prod` |

`.env.local` is gitignored and intended for machine-specific secrets. `.env`, `.env.dev`, and `.env.test` may be committed as shared non-secret team defaults.

## Project Status

BullX runs IMGateway, MailBox, and the AIAgent receiver end-to-end today, with channel adapters for Discord, Feishu (Lark), and Telegram, on an Elixir/OTP, PostgreSQL, and Phoenix/Inertia foundation. Feishu IM messages can be normalized, stored as `im_messages`, routed through MailBox, handled by AIAgent, and replied to through outbound `im_messages`. Brain, Budget, durable Work/Task records, the Workflow receiver, and trajectory-driven self-evolution are still being built.

See [docs/Architecture.md](./docs/Architecture.md) for the architecture source of truth, and [docs/design-docs/](./docs/design-docs/) for detailed designs.
