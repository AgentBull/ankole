# Ankole Documentation

[简体中文](./README.zh-Hans.md)

Use this page to understand how Ankole works and where each part of the system
lives. Follow the links when you need the detailed contract for one module.

## Product Boundary

Ankole is a private, self-hosted system for Agents that do long-running digital
work. Each enterprise operates one private deployment instance. That instance
contains its Agents, accounts, provider connections, configuration, and stored
data.

A Principal identifies the person or Agent responsible for an action. AuthZ
decides what that Principal can do.

An Agent receives work from provider messages, schedules, and Background Agent
Jobs. It can use tools and resume work after a process fails. PostgreSQL stores
the data that Ankole needs after a restart.

## System Map

```text
Providers and schedules
          |
          v
SignalsGateway ---- PostgreSQL ---- AIGateway ---- model providers
          |                              ^
          | turn_start                   | response.create
          v                              |
     Agent Computer ---------------------+
     model loop and tools
```

| Part | What it does | Detailed document |
| --- | --- | --- |
| SignalsGateway | Receives provider events, starts Agent turns, and sends replies | [SignalsGateway](design-docs/SignalsGateway.md) |
| AIGateway | Selects model providers and stores Responses for each Principal | [AIGateway](design-docs/AIGateway.md) |
| Brain | Stores useful knowledge and finds it when an Agent needs it | [Brain](design-docs/Brain.md) |
| RuntimeFabric | Carries live messages, RPC calls, and files between processes | [RuntimeFabric](design-docs/RuntimeFabric.md) |
| Agent Computer | Runs the model loop, Codex, and tools | `app/agent_computer/` |
| PostgreSQL | Stores facts that must survive a restart | Migrations in `app/control_plane/priv/repo/migrations/` |

Schedule creates an `ActorEvent` when work becomes due. A `BackgroundAgentJob`
runs work outside the conversation that created it. AppConfigure stores settings
that an operator can change while Ankole runs.

## What Each Process Does

The Elixir control plane runs Phoenix and OTP. It writes to PostgreSQL, supervises
services, stores provider credentials, and serves the public APIs.

The Rust kernel provides shared native functions. These functions handle
cryptography, CEL evaluation, protobuf validation, compression, and ZeroMQ
sockets. The kernel does not decide or store a work item's state.

Agent Computer runs in a Bun worker. It executes one turn, runs tools and
sandboxes, and manages Codex sessions. Its local state can be rebuilt.
It does not write control-plane records.

RuntimeFabric carries live traffic. PostgreSQL records completed decisions and
work. ZeroMQ cannot provide earlier traffic during recovery.

## Agent Filesystem

Agent Home is `/agents/<agent-key>`. The directory contains these shared
resources:

- `.codex` for Agent-scoped Codex state
- `SOUL.md`, `MISSION.md`, and `DESIGN.md`
- `user-files` for user artifacts
- `installed-skills` for copies of installed Skills that the worker can use
- `sessions/<base64url-session-id>` for Session workspaces
- `jobs/<job-id>` for private BackgroundAgentJob workspaces

Agent Home contains Session and Job workspaces. `/workspace` is not an
Agent path. Jobs for the same Agent share that Agent's `.codex` state.

PostgreSQL stores domain documents and work state. The control plane materializes
some of those records as Agent Home files that workers can use.

## Repository Map

| Path | What it contains |
| --- | --- |
| `app/control_plane/` | Elixir control plane, Phoenix APIs, Ecto schemas, and migrations |
| `app/kernel/` | Shared Rust kernel and host bindings |
| `app/agent_computer/` | Bun worker, tools, Codex runner, and browser runtime |
| `app/webapps/` | Auth, setup, and console React applications |
| `app/library/` | Built-in Skills, Agent Plugins, and Agent templates |
| `app/locales/` | Shared English and Simplified Chinese catalogs |
| `plugins/` | First-party control-plane plugins |
| `libs/` | Provider clients and shared UI code |
| `tools/devkit/` | Workspace development commands |
| `tools/e2e/` | End-to-end runner, support services, and suites |
| `docs/` | Current public architecture and operations documents |

Current provider adapters cover Lark, DingTalk, Slack, Microsoft 365, and
Google Workspace. The China-market provider plugin contributes AIGateway
providers.

## Control-Plane Boot Order

`Ankole.Application` starts children in this order:

1. Telemetry, Repo, and the Brain task supervisor
2. AppConfigure registry and cache
3. I18n catalog and setup bootstrap
4. Oban
5. Plugin registry and plugin supervisor
6. PubSub and AIGateway response-stream supervisor
7. SignalsGateway supervisor
8. Optional identity startup sync and RuntimeEvents
9. AIGateway model metadata cache
10. DNSCluster and the Phoenix endpoint

This order is a contract. A later child can use a service that started before
it. The endpoint starts after the subsystems that serve requests.

## What Survives a Restart

PostgreSQL keeps the following data because Ankole needs it after a restart:

- Principals, humans, Agents, groups, memberships, and permission grants
- AppConfigure values and encrypted provider configuration
- Signal routing rules (`SignalBinding` records), channels, entries, tombstones, ActorEvent rows, and outbox rows
- Schedules and scheduled events
- AIGateway conversations, messages, compaction artifacts, and provider rows
- Brain entries, blocks, relations, sources, citations, episodes, cursors, and audit rows
- BackgroundAgentJob rows and their turn records

Ankole can rebuild deliveries, activations, worker assignments, and
connected-worker rows. Losing those rows does not delete the work history.

## Message Lifecycle

This sequence shows how Ankole handles a provider message addressed to an Agent.

1. The provider adapter converts the event to Ankole's common format.
2. SignalsGateway checks the Agent's message policy and updates its copy of the provider message.
3. SignalsGateway groups related input and writes one `ActorEvent` work item.
4. ActorRuntime assigns a worker and sends a `turn_start` message with the turn fence for this attempt.
5. Agent Computer prepares the Agent files, Session workspace, context, and tools.
6. The worker asks AIGateway to create a stateful Response.
7. AIGateway stores the Response and streams its live events to current subscribers.
8. The worker runs tool calls and links each later Response to the previous one.
9. The worker reports the final Response ID when the turn ends.
10. SignalsGateway checks the turn fence and the Response chain.
11. One database transaction completes the `ActorEvent` and records the replies to send.
12. The provider adapter sends each reply and records the provider's result.

A terminal Response does not complete an Actor turn. If ActorRuntime does not
receive the completion message, it can assign the work again.

Live previews can disappear. The final reply always comes from a stored outbox
row. Ankole records the provider's success before it treats the reply as sent.

## Do Not Mix These IDs

| Identifier | Meaning |
| --- | --- |
| `source_event_id` | One provider event and its duplicate-prevention key |
| `source_entry_id` | One provider-visible entry |
| `actor_event_id` | One Ankole work item stored in PostgreSQL |
| `ai_message_id` | One stored AIGateway message row |

Do not use one identifier as a substitute for another. The module responsible
for the data assigns and checks its identifier.

## How Plugins and Skills Differ

Ankole trusts the Elixir code in a Control Plane Plugin. Such a plugin can add
configuration, adapters, model providers, and supervised processes.

An Agent Plugin is a standard Codex Plugin package that groups related Agent
capabilities. It can include a `workspace-template/` directory for a new Job.

A Skill remains independent of both plugin systems. Ankole finds, configures,
and runs Skills without help from a Control Plane Plugin.

## Where to Change Code

- Add a model provider under `app/control_plane/lib/ankole/ai_gateway/providers/`
  or through the `ai_gateway.provider` plugin contract.
- Add a worker tool under `app/agent_computer/src/tools/` and register it in the
  code that assembles the tool list for a turn.
- Add a signal provider as a plugin with declared ingress and outbox modules.
- Add a worker RPC in the ActorRuntime RPC lane and its worker requester.
- Add a runtime setting through AppConfigure in the owning subsystem.
- Add a built-in Skill under `app/library/skills/<name>/`.
- Add console APIs through OpenAPI controllers and regenerate the web client.

Do not use local worker files for a result that must survive a restart. Use a
control-plane RPC or an AIGateway API that writes the required PostgreSQL row.

## Development Workflow

```sh
bun install
bun run services:start
bun run control-plane:setup
bun run dev
```

Use these current validation entry points:

```sh
bun run test
bun run type-check
bun run lint
bun run fmt:check
bun run e2e
tools/e2e/run --chaos
tools/e2e/run --real-provider --providers=available
tools/e2e/run --real-llm
tools/e2e/run --brain-real-llm
```

The default E2E mode covers the gate suites. Real-provider modes need operator
credentials. The dedicated Brain real-model suite is not part of `--all`.

## Reading Order

1. Read this page to learn what each module does and how data moves.
2. Read [Tradeoffs and Known Limits](TradeoffsAndKnownLimits.md).
3. Read the design document for the subsystem that you will change.
4. Read [Brain operations](operations/Brain.md) before Brain deployment work.

## Document Index

| Document | Subject |
| --- | --- |
| [AIGateway](design-docs/AIGateway.md) | Model providers, Response history, compaction, and generated files |
| [SignalsGateway](design-docs/SignalsGateway.md) | Provider input, Agent work, previews, and replies |
| [Brain](design-docs/Brain.md) | Knowledge, recall, retained sources, and Dreaming |
| [Brain operations](operations/Brain.md) | PostgreSQL requirements and operational recovery |
| [RuntimeFabric](design-docs/RuntimeFabric.md) | ZeroMQ messages, RPC calls, and file transfer |
| [Schedule](design-docs/Schedule.md) | Checkbacks, cron schedules, and wake events |
| [BackgroundAgentJob](design-docs/BackgroundAgentJob.md) | Durable background work and Codex execution |
| [Principal](design-docs/Principal.md) | Human and Agent identities, including linked provider accounts |
| [AuthZ](design-docs/AuthZ.md) | Groups, grants, and CEL decisions |
| [AppConfiguration](design-docs/AppConfiguration.md) | Startup settings and settings that can change while Ankole runs |
| [Plugins](design-docs/Plugins.md) | Control Plane Plugins and Agent Plugins |
| [MCP-backed Skills](design-docs/MCPBackedSkills.md) | MCP Skill execution and secrets |
| [Web tools](design-docs/WebTools.md) | Web search, fetch, and rendered fallback |
| [I18n](design-docs/I18n.md) | Language selection and translation files |
| [Logger](design-docs/Logger.md) | Structured log format |
| [Tradeoffs and Known Limits](TradeoffsAndKnownLimits.md) | Deliberate limits and recovery boundaries |

Provider-specific documents are under `design-docs/plugins/`.
