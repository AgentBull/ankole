# BullX — AgentOS for Working Side by Side with AI Colleagues

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)

[简体中文](./README.zh-Hans.md) | [日本語](./README.ja.md)


BullX is an AgentOS designed to help you collaborate with proactive AI colleagues over the long term.

Chatbots gave LLMs a way to talk. Systems in the OpenClaw and Hermes-Agent generation gave agents hands: channels, tools, skills, shell/browser control, memory files, subagents, and scheduled tasks. Dify, RPA, and RAG workflow builders made it easier to package AI into specific business applications. BullX focuses on the next step: enabling AI colleagues to take on long-running work the way a real hire does—owning the outcomes of a role, acting on their own judgment, and improving from results.

At the core of BullX is the AI colleague itself—not a re-skinned RAG customer service bot, and not a digital assistant that passively waits for commands. A BullX Agent is expected to have a long-term mission, KPI/OKR-style success metrics, clear responsibility boundaries, long-term memory, and an outbound identity. It can work over long horizons, collaborate with humans and other agents, and improve from trajectory data.

BullX does not try to be “just another chat entry point.” It organizes AI colleagues into a persistent work system:

- **Agent** carries long-term mission, responsibility boundaries, memory, outbound identity, and KPI/OKR-style success metrics.
- **ExternalGateway and other Gateways** preserve facts from the external world and deliver agent-relevant events directly to the bound agent as CloudEvents-style envelopes.
- **MailBox** creates internal delivery entries for receivers such as AIAgent, Workflow, SubAgent, gateway, and blackhole.
- **Receiver** performs the work: most commonly an AIAgent for flexible judgment, or a Workflow for explicit process structure.
- **Principal** and human collaboration mechanisms give a colleague a real identity and let it work alongside people—as a peer, a report, or a manager.
- **Capability** exposes models, tools, browser, sandbox, message channels, APIs, and external agent harnesses without hiding execution authority inside prompts.
- **Brain** provides long-term memory and world-model reasoning: not raw vector logs, not endlessly growing Markdown memory files, and not a fully predefined ontology; instead, knowledge extracted, revised, and integrated from conversations, events, actions, and outcomes.

## Who BullX Is For

BullX is for work you would otherwise **hire for**: a seat someone needs to own, that you can't, won't, or can't yet staff with a person.

The seats that fit share three traits:

- **Remote by nature.** A digital colleague has no hands, so the whole job has to be doable from a keyboard—the way a remote hire would do it.
- **Measured by a real outcome.** The role has a concrete success metric anyone can check: code that passes its tests, a strategy with a live P&L, a campaign that hits its ROAS, a report shipped on time with no factual errors, reach and growth numbers. That metric is what lets the colleague improve on its own—and what lets you trust the result and know it earned its keep.
- **Productive, not reactive.** The job *produces* something or *drives* a number, instead of waiting to answer requests.

That points at front-line individual-contributor roles—engineers, quant developers, researchers, performance-marketing and growth operators, community managers, QA—and **not** at:

- **a copilot to make you faster** — BullX does the work; it does not accelerate you doing it.
- **a customer-service or secretary bot** — answering requests over a knowledge base is what the previous generation of RAG assistants already covers.
- **an "AI executive"** — judgment, authority, and accountability stay with people; the colleague is a doer they manage.

You reach for BullX the moment a seat needs an owner and you are short one. From there you do not *operate* it like a tool—you *manage* it like a report: set the mandate and the metric, review the output, course-correct. It is closer to headcount than to software. And because BullX is open source and self-hosted, you *run* the colleague yourself—its wage is the compute it spends, and like any hire you keep it on only while the results justify the wage. No per-seat license, no vendor between you and the work.

## Three Model Types, One Key Difference

Many systems call themselves agents or digital employees, but optimize for different goals.

- **OpenClaw / Hermes-style assistants** are prompt-driven Agentic Loops. They are strong at personal assistance, tool calls, channel integration, cron, memory files, skills, and subagents. The core unit is still an assistant session that acts when triggered by prompts, schedules, or messages.
- **Dify / RPA / RAG workflow digital workers** are app- or workflow-driven automation. They fit bounded, repeatable processes such as customer service bots, BI reporting bots, invoice review bots, and document extraction.
- **BullX AI colleagues** are mission-driven work entities. Here mission means long-term purpose, closer to KPI or OKR than a one-off task. They have permissions, budget, memory, outbound identity, and responsibility boundaries. They can observe the world, decide what matters, collaborate with humans or other agents, and improve from trajectory data.

| Dimension | OpenClaw / Hermes-style assistants | Dify / RPA / RAG workflow digital workers | BullX AI colleagues |
| --- | --- | --- | --- |
| Core unit | Agentic Loop or assistant session. | App, bot, RPA flow, or workflow run. | An Agent with long-term mission, responsibility, and Work/MailBox routing context. |
| Autonomy | Responds to prompts, messages, cron, or user-configured tasks. | Executes predefined flows for a specific business scenario. | Observes events, prioritizes work, asks for help, delegates tasks, and advances long-term missions. |
| Actions | Tool calls, shell/browser operations, messages, files, subagents. | Form filling, API calls, extraction, routing, approvals, report generation. | The capabilities it can execute, AIAgent actions, and Workflow steps when explicit process structure is needed. |
| Memory & reasoning | Session memory, Markdown files, skill notes, or external memory layers. | RAG knowledge bases, workflow variables, and app-specific state. | Brain is a reasoning world model grown from conversations, events, actions, relationships, outcomes, and domain objects. |
| Self-evolution | Learns new skills or notes from past sessions. | Improves through manual workflow or knowledge-base updates. | Uses trajectory data to improve planning, skills, policies, and future execution. |
| Permissions & budget | Typically tool policy, model config, and local runtime controls. | App credentials, node permissions, rate limits, and workflow settings. | Principal identity, delegated authority, Budget, and outbound identity. |
| Human collaboration | Usually approval prompts, DM gates, or manual confirmations. | Approval nodes or human review steps inside a flow. | Humans can be managers, peers, or subordinates: approving, correcting, escalating, taking over, adding context, helping with real-world tasks, or receiving tasks from agents. |
| External events | Channels, cron, webhooks, and integrations enter assistant loops. | Triggers start predefined apps or workflows. | Gateways preserve external facts, MailBox delivers CloudEvents mail, Receivers update persistent Work via business records. |
| Accountability | Transcript and tool history explain one session. | Workflow logs explain one app run. | Product facts record the work done, outcomes against its success metrics, and how trajectory data improved future behavior. |

## Why BullX

BullX keeps the useful surfaces from prior agent systems: channels, tools, skills, sandbox, browser, subagents, scheduling, and conversational entry points. The difference is where product facts live. In BullX, persistent work belongs to business records such as Work, Conversation, ChildRun, Principal, Brain, domain records, and trajectory data—not only to a one-off assistant session or workflow run log.

BullX is also different from Palantir-style ontology engineering. Brain is inspired by ontology and semantic-web ideas, but BullX does not require experts to predefine a complete business graph. Its world model should grow naturally through work: conversations, events, domain records, decisions, handoffs, corrections, and outcomes gradually teach AI colleagues the business, industry, internal context, and tacit knowledge behind real work. This is also where the value compounds for you: the model intelligence underneath is rented and shared by everyone, but the context a colleague builds doing *your* work—on your own infrastructure—is yours alone, and it deepens the longer the colleague holds the seat.

BullX does not aim to be a “better bot” or a “smarter workflow app.” It aims to be an operating system where AI colleagues can observe, judge, delegate, wait, remember, and act—and be measured by the outcomes they own.

## The Experience It Should Enable

**Group chats can be observed instead of interrupted.** A customer-success agent can detect risk in a group chat, create Work, and notify the owner privately instead of jumping into the chat by default.

**One input can enter the right execution path.** A customer budget-freeze message is preserved by a gateway, delivered via MailBox, and routed to a Receiver. That Receiver can be an AIAgent handling the case directly, or a Workflow expressing explicit branches, approvals, parallelism, and deterministic steps.

**Memory can include the world, not just chat logs.** A research agent should interpret conversations together with markets, policy, product, operations, and external events, then retrieve context through an ontology-backed world model grown from real work.

**The world model can mature like a human colleague.** After onboarding, a BullX Agent should become increasingly familiar with the business, industry, internal rules, recurring exceptions, and tacit knowledge—instead of requiring the organization to model everything on day one.

**Agents can hold long-term missions, not just tasks.** Coding agents, research agents, or customer-success agents can work continuously across interactions, collaborate with humans and other agents, and improve future planning from trajectory data.

**Humans can collaborate above, beside, or below agents.** Humans can approve or correct agents, collaborate as peers, take over specific cases, add real-world context, or even receive tasks from agents—for example, checking something offline or scanning a login QR code.

**Work can be judged by results, not vibes.** A colleague holds a seat with a concrete success metric—code that passes its tests, a report delivered on time and free of factual errors, a campaign that hits its target—so its output can be verified and trusted the way a human teammate's is.

## Local Development Toolkit

This repository includes `@agentbull/devkit`, with entry scripts at the repo root:

```shell
bun run kit --help
```

Common commands:

```shell
# Create or update the VS Code workspace file
bun run workspace:update

# Start/stop local Postgres and Redis (official latest images by default)
bun run services:start
bun run services:stop
bun run services:status

# Create the app database; default DB name comes from app/.env.local or app/.env.development
bun run db:create

# Rebuild app database and run Drizzle migrations; destructive operation, explicit confirmation required
bun run db:rebuild --yes
```

Local Compose file: `tools/devkit/external-services.docker-compose.yml`, with default ports aligned to `app/.env.development`: Postgres `localhost:5433`, Redis `localhost:6379`.
