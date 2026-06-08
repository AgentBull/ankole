# BullX — AgentOS for Working Side by Side with AI Colleagues

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)

[简体中文](./README.zh-Hans.md) | [日本語](./README.ja.md)


BullX is an AgentOS designed to help you collaborate with proactive AI colleagues over the long term.

Chatbots gave LLMs a way to talk. Systems in the OpenClaw and Hermes-Agent generation gave agents hands: channels, tools, skills, shell/browser control, memory files, subagents, and scheduled tasks. Dify, RPA, and RAG workflow builders made it easier to package AI into specific business applications. BullX focuses on the next step: enabling AI colleagues to take on long-running work the way a real hire does—owning the outcomes of a role, acting on their own judgment, and improving from results.

At the core of BullX is the AI colleague itself—not a re-skinned RAG customer service bot, and not a digital assistant that passively waits for commands. A BullX Agent is expected to have a long-term mission, KPI/OKR-style success metrics, clear responsibility boundaries, long-term memory, and an outbound identity. It can work over long horizons, collaborate with humans and other agents, and carry durable history across interactions.

BullX does not try to be “just another chat entry point.” The current repository is organized around a smaller runtime surface:

- **Principal and AuthZ** give humans and agents stable identities, groups, external identity bindings, and permission grants.
- **Plugin runtime** loads trusted local plugins and lets them register External Gateway adapters, identity-provider adapters, web providers, and app-config definitions.
- **External Gateway** accepts normalized provider facts from chat adapters, keeps the latest visible external projection, delivers agent-relevant events to the bound agent, and executes explicit outbound intents through an outbox.
- **AIAgent runtime** owns conversations, messages, LLM turns, generation leases, addressed and ambient inputs, slash-command stubs, lifecycle revisions, clarification, compression, and web tools.
- **Setup and Console** own first-admin bootstrap, admin sessions, identity-provider setup, LLM provider configuration, agents, and chat-channel configuration.
- **PostgreSQL-backed state** is the durable source for principals, configuration, external projections, gateway input/outbox rows, and AIAgent conversation records. Redis visible-output streams are weak progress state, not final truth.

Several BullX product surfaces remain core to the model even though this repository does not fully support them yet:

- **Work** is the intended business-facing unit for owned outcomes, not just a chat turn or an assistant transcript.
- **Brain** is the intended long-term world model grown from conversations, external events, decisions, domain records, corrections, and results.
- **Trajectory data** is the intended learning substrate for improving future planning, skills, policies, and execution from what actually happened.

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
- **BullX AI colleagues** are mission-driven work entities. Here mission means long-term purpose, closer to KPI or OKR than a one-off task. They have permissions, configured models and tools, memory, outbound identity, and responsibility boundaries. They can observe the world, decide what matters, and collaborate with humans or other agents.

| Dimension | OpenClaw / Hermes-style assistants | Dify / RPA / RAG workflow digital workers | BullX AI colleagues |
| --- | --- | --- | --- |
| Core unit | Agentic Loop or assistant session. | App, bot, RPA flow, or workflow run. | A Principal-backed Agent with durable conversation and external-event context. |
| Autonomy | Responds to prompts, messages, cron, or user-configured tasks. | Executes predefined flows for a specific business scenario. | Observes events, prioritizes work, asks for help, delegates tasks, and advances long-term missions. |
| Actions | Tool calls, shell/browser operations, messages, files, subagents. | Form filling, API calls, extraction, routing, approvals, report generation. | AIAgent generation, configured tools and web providers, and provider-visible messages through External Gateway outbox. |
| Memory & reasoning | Session memory, Markdown files, skill notes, or external memory layers. | RAG knowledge bases, workflow variables, and app-specific state. | Durable conversations, summaries, LLM turns, external projections, and the intended Brain world model built from Work and domain facts. |
| Self-evolution | Learns new skills or notes from past sessions. | Improves through manual workflow or knowledge-base updates. | Uses trajectory data to improve later planning, skills, policies, and execution; current durable conversation and turn records are the foundation. |
| Permissions & budget | Typically tool policy, model config, and local runtime controls. | App credentials, node permissions, rate limits, and workflow settings. | Principal identity, group membership, permission grants, external identities, and configured provider credentials. |
| Human collaboration | Usually approval prompts, DM gates, or manual confirmations. | Approval nodes or human review steps inside a flow. | Humans can be managers, peers, or subordinates: approving, correcting, escalating, taking over, adding context, helping with real-world tasks, or receiving tasks from agents. |
| External events | Channels, cron, webhooks, and integrations enter assistant loops. | Triggers start predefined apps or workflows. | External Gateway preserves provider-visible facts and delivers CloudEvents-style events into AIAgent conversation state. |
| Accountability | Transcript and tool history explain one session. | Workflow logs explain one app run. | Work and product facts should explain owned outcomes; current durable records explain accepted external facts, conversation state, assistant outputs, model turns, and provider-visible side effects. |

## Why BullX

BullX keeps the useful surfaces from prior agent systems: channels, tools, web access, plugin-provided integrations, and conversational entry points. The difference is where durable facts live. In this repository, persistent state belongs to PostgreSQL records such as Principal/AuthZ rows, External Gateway projections and outbox rows, AIAgent conversations, messages, summaries, and LLM turns. The intended product model extends that foundation into Work, Brain, domain records, and trajectory data rather than stopping at a one-off assistant session transcript.

BullX is also different from Palantir-style ontology engineering. Brain should grow naturally through Work instead of requiring experts to predefine a complete business graph on day one. The current code does not fully implement Brain yet, but conversations, external events, decisions, corrections, summaries, and future domain records are the material from which it can grow. This is also where the value compounds for you: the model intelligence underneath is rented and shared by everyone, but the context a colleague builds doing *your* work—on your own infrastructure—is yours alone, and it deepens the longer the colleague holds the seat.

BullX does not aim to be a “better bot” or a “smarter workflow app.” It aims to be an operating system where AI colleagues can observe, judge, delegate, wait, remember, and act—and be measured by the outcomes they own.

## The Experience It Should Enable

**Group chats can be observed instead of interrupted.** A customer-success agent can mirror relevant group-chat facts, decide whether they matter, and eventually create or update Work before notifying an owner privately instead of jumping into the chat by default.

**One input can enter the right execution path.** A customer budget-freeze message is preserved by External Gateway and delivered as an agent event. The AIAgent records the input in the right conversation, can batch related addressed messages, can keep ambient messages separate, and can enqueue explicit provider-visible replies.

**Memory can include the world, not just chat logs.** A research agent should interpret conversations together with markets, policy, product, operations, and external events. The current storage foundation is conversations, summaries, LLM turns, and external projections; Brain and richer domain memory can build on top of those facts.

**The world model can mature like a human colleague.** After onboarding, a BullX Agent should become increasingly familiar with the business, industry, internal rules, recurring exceptions, and tacit knowledge—instead of requiring the organization to model everything on day one.

**Agents can hold long-term missions, not just tasks.** Coding agents, research agents, or customer-success agents can work continuously across interactions, collaborate with humans and other agents, and use trajectory data and durable history to inform later planning.

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
