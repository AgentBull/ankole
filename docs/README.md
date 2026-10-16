# Ankole Documentation

[简体中文](./README.zh-Hans.md)

Use this page to understand how Ankole works and where each part of the system
lives. Follow the links when you need the detailed contract for one module.

## Product Boundary

Ankole is a private, self-hosted system for Agents that do long-running digital
work. One site can contain several tenants. Each tenant owns its Agents,
accounts, provider connections, configuration, and stored data. Site operators
manage shared infrastructure. See [Tenants](design-docs/Tenants.md).

A Principal identifies the person or Agent responsible for an action. AuthZ
decides what that Principal can do.

An Agent receives work from native Pod messages, provider messages,
schedules, and Background Agent Jobs. It can use tools and resume work after a
process fails. PostgreSQL stores the data that Ankole needs after a restart.

## System Map

```text
Providers and schedules
          |
          v
Conversations --> Signals --> Sessions --> AIGateway --> model providers
                          |               |
                          +-- PostgreSQL -+
                          |
                   environment tools / Codex
                          v
                     Agent Computer
```

| Part | What it does | Detailed document |
| --- | --- | --- |
| Conversations | Owns shared conversations, public Messages, provider observations, and Delivery | [Conversations](design-docs/Conversations.md) |
| Signals | Accepts stimuli, routes CloudEvents, and stores authorization and target facts | [Signals](design-docs/Signals.md) |
| Sessions | Drives each Agent's model loop and recovers durable steps | [Sessions](design-docs/Sessions.md) |
| AIGateway | Selects model providers and stores Responses for each Principal | [AIGateway](design-docs/AIGateway.md) |
| Brain | Stores tenant-shared knowledge and finds it when an Agent needs it | [BrainV3](design-docs/BrainV3.md) |
| RuntimeFabric | Carries live messages and RPC calls; coordinates HTTP file relay | [RuntimeFabric](design-docs/RuntimeFabric.md) |
| Files | Keeps each Agent's durable files in a drive in the control plane | [Files](design-docs/Files.md) |
| Agent Workers | Creates, stops, and replaces the one Worker of each Agent | [Agent Workers](design-docs/AgentWorkers.md) |
| Agent Computer | Runs Codex and environment tools | `app/agent_computer/` |
| PostgreSQL | Stores facts that must survive a restart | Migrations in `app/control_plane/priv/repo/migrations/` |

Schedule creates a `Signal` through the same intake when work becomes due. A `BackgroundAgentJob`
runs work outside the Session that created it. AppConfigure stores settings
that an operator can change while Ankole runs.

Pod sends native messages through Conversations and Signals to Sessions.
Native and provider Messages use shared public history. Each Agent's model
history remains separate from that Conversation.

## What Each Process Does

The Elixir control plane runs Phoenix and OTP. It writes to PostgreSQL, supervises
services, stores provider credentials, and serves the public APIs.

The Rust kernel provides shared native functions. These functions handle
cryptography, CEL evaluation, protobuf validation, compression, and object storage. The kernel does not decide or store a work item's state.

Agent Computer runs in the Worker of one Agent: a Bun process in its own
container. It runs environment tools and manages Codex sessions. Its local
execution state can be rebuilt; its Home files are persistent. It does not write control-plane records.

RuntimeFabric carries live traffic. PostgreSQL records completed decisions and
work. The worker connection cannot provide earlier traffic during recovery.

## Agent Filesystem

Agent Home is `/workspace` on storage that survives Worker instance deletion
and image changes. It contains:

- `SOUL.md`, `MISSION.md`, and `DESIGN.md`
- `.codex/` for Codex configuration and thread files
- `installed-skills/` for copies of the drive's `skills/` files
- `sessions/<workspace-id>/` for Session workspaces; PostgreSQL allocates IDs from 10000
- `jobs/<workspace-owner-job-id>/` for BackgroundAgentJob workspaces

`/agents/<agent_uid>` links to Home so persisted old paths still work. Path
checks resolve symbolic links. Codex SQLite is rebuildable and lives at
`/var/cache/ankole/codex`, outside persistent Home.

PostgreSQL stores domain documents and work state. The Worker materializes
some records as Home files at each turn. The Agent's drive separately holds
attachments, generated images, published files, installed Skills, and
Automation scripts, and is available while its Worker is absent. See
[Files](design-docs/Files.md) and [Agent Workers](design-docs/AgentWorkers.md).

## Repository Map

| Path | What it contains |
| --- | --- |
| `app/control_plane/` | Elixir control plane, Phoenix APIs, Ecto schemas, and migrations |
| `app/kernel/` | Shared Rust kernel and host bindings |
| `app/agent_computer/` | Bun worker, tools, Codex runner, and browser runtime |
| `app/webapps/` | Auth, setup, Pod, and console React applications |
| `app/library/` | Built-in Skills, Agent Plugins, and Agent templates |
| `app/locales/` | Shared translation catalogs |
| `plugins/` | First-party control-plane plugins |
| `libs/` | Provider clients and shared UI code |
| `tools/devkit/` | Workspace development commands |
| `tools/e2e/` | End-to-end runner, support services, and suites |
| `docs/` | Current public architecture and operations documents |

Current Control Plane Plugins under `plugins/` provide the Lark, DingTalk,
Slack, Microsoft 365, Google Workspace, WeCom, Telegram, Discord, LINE,
WhatsApp, and Email adapters. Telegram, Discord, LINE, and WhatsApp are
consumer IM adapters: they connect a bot to one Agent and map each sender to a
Principal by hand, by a known mobile number, or as a standalone account. The
Email adapter connects a dedicated mailbox and admits a sender only through an
explicit `email` identity binding. The local password identity provider is
part of the control plane.
The China-market provider plugin contributes AIGateway providers.

## Control-Plane Boot Order

`Ankole.Application` attaches the request log handler before it starts the children.
It starts the children in this order:

1. Repo, PubSub, and OIDC signing key
2. AppConfigure registry and cache
3. Observability, I18n catalog, and setup bootstrap
4. Worker provider configuration and seed, then Oban
5. Plugin cohort and local-password retry guard
6. AIGateway credential pool, task and response-stream supervisors, and WorkerFiles supervisor
7. Sessions and Workflow supervisors
8. Optional identity startup sync
9. AIGateway model metadata cache and DNSCluster
10. Phoenix endpoint

This order is a contract. A later child can use a service that started before
it. The endpoint starts after the subsystems that serve requests.

## What Survives a Restart

PostgreSQL keeps the following data because Ankole needs it after a restart:

- Principals, humans, Agents, groups, memberships, and permission grants
- AppConfigure values and encrypted provider configuration
- Signal routing rules, Signals, callback Endpoints, Conversations, Messages, external references, tombstones, and Delivery intents
- Schedules and scheduled events
- AIGateway conversations, messages, compaction artifacts, and provider rows
- Brain pages, versions, chunks, claims, timelines, links, sources, schema packs, contradictions, and skill lessons
- BackgroundAgentJob rows and their turn records
- Session workspace epochs and tool receipts

Session drivers rebuild their progress from these facts. A process exit
does not delete the work history.

## Message Lifecycle

This sequence shows how Ankole handles a provider message addressed to an Agent.

1. The provider adapter converts the event to Ankole's common format.
2. Conversations.Observe applies the Binding policy and records the shared public Message and its provider reference.
3. IM batching groups related input; Signals.accept_in_tx records one authorized stimulus and a durable Session wakeup.
4. Sessions starts or wakes the Session Driver. Admission claims the input and advances the workspace epoch.
5. The driver prepares the Agent context and asks AIGateway to create a stateful Response.
6. AIGateway stores the Response and streams its live events to current subscribers.
7. The driver runs control-plane tools in database transactions. It requests a Worker only for environment tools or Codex Jobs.
8. One transaction records a complete tool round, consumes applied input, and removes its tool receipts. The next Response continues that tape.
9. At the end of the run, one transaction checks the epoch, completes the input, and records provider Delivery intents.
10. The provider adapter delivers each intent. Provider confirmation records the public Agent Message and external reference.

A terminal Response does not complete a Session run. After a driver exits,
the next driver recovers the run from the stored input, tape, and tool receipts.

Live provider previews can disappear. A final external reply comes from a stored
Delivery intent. Native replies commit directly as public Agent Messages. Neither
path uses the model Response tape as the public Conversation transcript.

## Do Not Mix These IDs

| Identifier | Meaning |
| --- | --- |
| `source_event_id` | One provider event and its duplicate-prevention key |
| `provider_conversation_id` | One opaque provider room or thread identity |
| `provider_message_id` | One provider-visible message |
| `conversation_id`, `message_id` | Public Conversation and Message UUIDs |
| `signal_id` | One accepted Ankole stimulus |
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
- Add a main Agent tool under `app/control_plane/lib/ankole/sessions/tools/`.
  Add an environment or Codex Job tool under `app/agent_computer/src/tools/`
  and regenerate its declared Worker catalog.
- Add a message provider through `signals.adapter` with `observe_module` and `deliver_module`.
- Add a worker RPC in the Sessions RPC lane and its worker requester.
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
```

The default E2E mode covers the gate suites. Real-provider modes need operator
credentials.

## Reading Order

1. Read this page to learn what each module does and how data moves.
2. Read [Tradeoffs and Known Limits](TradeoffsAndKnownLimits.md).
3. Read the design document for the subsystem that you will change.

## Document Index

| Document | Subject |
| --- | --- |
| [Tenants](design-docs/Tenants.md) | Site administration, data contexts, isolation and tenant lifecycle |
| [AIGateway](design-docs/AIGateway.md) | Model providers, Response history, compaction, and generated files |
| [Agent Token Quota](design-docs/AgentTokenQuota.md) | Per-Agent token limits, periods, resets, and the rejection contract |
| [Conversations](design-docs/Conversations.md) | Shared public history, provider observation, Delivery, and Pod SSE |
| [Signals](design-docs/Signals.md) | Single intake, authorization, routing rules, and CloudEvents Endpoints |
| [Sessions](design-docs/Sessions.md) | Agent execution, model rounds, unread history, and recovery |
| [BrainV3](design-docs/BrainV3.md) | Tenant-shared knowledge, scoped disclosure, learning, and Dreaming |
| [Brain Markdoc](design-docs/BrainMarkdoc.md) | Brain page body syntax and Object editing in the Console (Chinese) |
| [Skill Lessons](design-docs/SkillLessons.md) | Leased per-skill field notes from finished work |
| [RuntimeFabric](design-docs/RuntimeFabric.md) | Worker channel messages, RPC calls, and file relay |
| [Agent Workers](design-docs/AgentWorkers.md) | The one Worker of each Agent: providers, lifecycle, persistent Home, and cache |
| [Schedule](design-docs/Schedule.md) | Checkbacks, cron schedules, and wake events |
| [BackgroundAgentJob](design-docs/BackgroundAgentJob.md) | Durable background work and Codex execution |
| [Automation Jobs](design-docs/AutomationJobs.md) | Agent-owned scripts that consume a trigger without a model turn |
| [Workflow](design-docs/Workflow.md) | One fixed program that runs bounded subagent tasks |
| [Principal](design-docs/Principal.md) | Human and Agent identities, including linked provider accounts |
| [Local Password Identity Provider](design-docs/LocalPasswordIdentityProvider.md) | Built-in email and password sign-in without an external service |
| [Human Offboarding](design-docs/HumanOffboarding.md) | Human disablement, authentication revocation, and task start checks |
| [Browser Sessions](design-docs/BrowserSessions.md) | Browser identity, authentication freshness, concurrent login, and logout |
| [OIDC Server](design-docs/OIDCServer.md) | OIDC protocol ownership, Client policy, tokens, and logout |
| [AuthZ](design-docs/AuthZ.md) | Groups, grants, and CEL decisions |
| [AppConfiguration](design-docs/AppConfiguration.md) | Startup settings and settings that can change while Ankole runs |
| [Plugins](design-docs/Plugins.md) | Control Plane Plugins and Agent Plugins |
| [MCP-backed Skills](design-docs/MCPBackedSkills.md) | MCP Skill execution and secrets |
| [Web tools](design-docs/WebTools.md) | Web search, fetch, and rendered fallback |
| [I18n](design-docs/I18n.md) | Language selection and translation files |
| [Logger](design-docs/Logger.md) | Structured log format |
| [Tradeoffs and Known Limits](TradeoffsAndKnownLimits.md) | Deliberate limits and recovery boundaries |

Provider-specific documents are under `design-docs/plugins/`.

`design-docs/` contains technical architecture, implementation design, and generic
contracts. Incident records, reproductions, and verification results are not
part of `docs/`; the changelog records what each release changed.
