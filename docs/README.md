# Ankole Documentation

This overview explains how Ankole is put together, where each subsystem lives in the repository, and how work flows from an external event to a durable reply. Follow the links in each section when you need the full specification for a specific module.

## Product Boundary

Ankole is a private, self-hosted platform where AI Agents carry out long-running digital work alongside humans. A single site deployment can host multiple tenants: site operators manage shared infrastructure, while each tenant owns its Agents, user accounts, provider connections, configuration, and business data. See [Tenants](design-docs/Tenants.md).

Every action in Ankole runs on behalf of a **Principal**—either a human user or an Agent—and **AuthZ** determines what that Principal is permitted to do.

Agents receive work from native Pod conversations, external chat providers, scheduled triggers, and Background Agent Jobs. Because PostgreSQL persists all durable state, an Agent can invoke tools, survive process restarts, and pick up unfinished work cleanly after a crash.

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

| Part | Role in the system | Detailed contract |
| --- | --- | --- |
| Pod | Hosts workspace pages, Base tables, Applets, and file embeds | [Pod Content Model](design-docs/PodContentModel.md) |
| Conversations | Manages shared conversations, public Messages, provider observations, and outbound Delivery | [Conversations](design-docs/Conversations.md) |
| Signals | Ingests incoming triggers, routes CloudEvents, and records authorization and target decisions | [Signals](design-docs/Signals.md) |
| Sessions | Drives each Agent's model loop and recovers in-flight steps across restarts | [Sessions](design-docs/Sessions.md) |
| AIGateway | Routes model calls across providers and stores Response chains per Principal | [AIGateway](design-docs/AIGateway.md) |
| Brain | Stores tenant-shared organizational knowledge and retrieves it within each caller's disclosure scope | [BrainV3](design-docs/BrainV3.md) |
| RuntimeFabric | Multiplexes live Worker traffic and RPC calls, and coordinates one-time HTTP file relays | [RuntimeFabric](design-docs/RuntimeFabric.md) |
| Files | Stores each Agent's durable Drive files in the control plane | [Files](design-docs/Files.md) |
| Agent Workers | Provisions, stops, and replaces each Agent's dedicated Worker instance | [Agent Workers](design-docs/AgentWorkers.md) |
| Agent Computer | Executes Codex jobs and environment tools inside the Worker container | `app/agent_computer/` |
| Function Runtime | Executes stateless Applet backend functions and deterministic TypeScript programs | [Pod Content Model](design-docs/PodContentModel.md), [Workflow](design-docs/Workflow.md) |
| PostgreSQL | Stores all authoritative control-plane facts and sharded physical Base tables | Migrations in `app/control_plane/priv/repo/migrations/` |

Other subsystems plug into this same pipeline: **Schedule** emits a `Signal` through the standard intake whenever a timer fires, **BackgroundAgentJob** runs long-lived Codex work outside the Session that spawned it, and **AppConfigure** holds runtime settings that operators can update without restarting the cluster.

Native Pod messages flow through Conversations and Signals into Sessions just like external chat messages, sharing a single public Conversation history while keeping each Agent's internal model tape private.

## What Each Process Does

- **Elixir control plane (`app/control_plane/`)**: Runs on Phoenix and OTP. It owns PostgreSQL transactions, supervises background workers, protects encrypted provider credentials, and serves Ankole's HTTP and WebSocket APIs.
- **Rust kernel (`app/kernel/`)**: Supplies stateless native primitives for cryptography, AuthZ CEL evaluation, Markdown and Brain Markdoc parsing, UTF-16 page diffing, AI provider HTTP/WebSocket transport, image transcoding, SSRF-checked web proxying, and object storage. It never decides or persists workflow state.
- **Function Runtime (`ankole-function-runtime`)**: Runs stateless Supabase Edge Runtime isolates for Pod Applet backends and deterministic PTC or Workflow TypeScript programs, holding no durable state of its own.
- **Agent Computer (`app/agent_computer/`)**: Runs as a Bun process inside each Agent's dedicated Worker container, executing environment tools and supervising Codex sessions. Its Agent Home directory (`/workspace`) persists across container replacements, while local process state is rebuildable; it never writes directly to control-plane tables.

Live traffic travels over **RuntimeFabric**, whereas completed decisions and state transitions live in **PostgreSQL**. During crash recovery, Ankole reconstructs state strictly from PostgreSQL rather than replaying transient Worker channel traffic.

## Agent Filesystem

Each Agent's persistent Home directory is mounted at `/workspace` on storage that survives Worker restarts, instance replacements, and image upgrades:

- `SOUL.md`, `MISSION.md`, and `DESIGN.md` — materialized Agent identity documents
- `.codex/` — Codex configuration and persistent thread history
- `installed-skills/` — materialized copies of `skills/` from the Agent's Drive
- `sessions/<workspace-id>/` — per-Session working directories (PostgreSQL allocates stable IDs starting at `10000`)
- `jobs/<workspace-owner-job-id>/` — working directories for `BackgroundAgentJob` runs

`/agents/<agent_uid>` symlinks to `/workspace`, and all path checks resolve symlinks before validating access. Rebuildable Codex SQLite state lives outside persistent Home under `/var/cache/ankole/codex`.

PostgreSQL remains the source of truth for domain documents and task state, and the Worker refreshes materialized Home files at the start of each turn. Separately, the control-plane **Drive** stores attachments, generated images, published artifacts, installed Skills, and Automation scripts so they remain accessible even when the Agent's Worker is stopped. See [Files](design-docs/Files.md) and [Agent Workers](design-docs/AgentWorkers.md).

## Repository Map

| Path | Contents |
| --- | --- |
| `app/control_plane/` | Elixir control plane: domain modules, Phoenix APIs, OTP supervision trees, release/upgrade tasks, Mix tasks, configuration, migrations, and tests |
| `app/function_runtime/` | Stateless Edge Runtime host for Applet backends and deterministic PTC/Workflow TypeScript programs |
| `app/kernel/` | Shared Rust native primitives and language bindings |
| `app/agent_computer/` | Bun Worker daemon, environment tools, Codex runner, and browser integration |
| `app/ankole-browser/` | Local Chromium daemon for rendered `web_fetch` and browser automation |
| `app/webapps/` | React web applications for Authentication, Setup, Pod, and Console |
| `app/library/` | Built-in Skills, Agent Plugins, and starter Agent templates |
| `app/locales/` | Shared translation catalogs |
| `plugins/` | First-party Control Plane Plugins and provider adapters compiled into the control plane |
| `libs/` | Shared TypeScript and Rust libraries, including transport codecs, the Feishu frame codec, and `@ankole/uikit` |
| `tools/devkit/` | Local development orchestration commands and container recipes |
| `tools/e2e/` | End-to-end test runner, fake provider services, and test suites |
| `docs/` | Architecture specifications, operational guides, and known system tradeoffs |

First-party Control Plane Plugins under `plugins/` ship messaging adapters for Lark/Feishu, DingTalk, Slack, Microsoft 365, Google Workspace, WeCom, Telegram, Discord, LINE, WhatsApp, and Email, plus China-market model providers for AIGateway:

- **Consumer IM adapters** (Telegram, Discord, LINE, and WhatsApp) connect a bot to a single Agent and resolve each sender to a Principal either through an explicit account link or as a standalone external account.
- **Email adapter** connects a dedicated mailbox and admits incoming mail only when the sender matches an explicit `email` identity binding. (Transactional site verification emails use the core [Authentication](design-docs/Authentication.md) SMTP settings instead.)

## Control-Plane Boot Order

Before starting its supervision tree, `Ankole.Application` initializes the OpenFeature provider, validates the site administration Console path and site identity sources, and attaches the structured request log handler. It then boots child supervisors in strict dependency order:

1. `Repo`, `Pod.BaseCluster`, `PubSub`, `PodPresence`, and the OIDC signing key
2. `AppConfigure` registry and runtime cache
3. Observability, I18n catalogs, and initial setup bootstrap
4. Worker runtime configuration, `Oban`, the active plugin cohort, Worker provider seeds, and the authentication rate limiter
5. AIGateway credential pool, `FunctionRuntime` supervisor, task supervisors, response-stream supervisor, and `WorkerFiles` supervisor
6. Outbound Delivery, `AgentWorkers`, `Sessions`, and `Workflow` supervisors
7. Optional startup directory sync for external identity sources
8. AIGateway model metadata cache, `DNSCluster`, and finally the public Phoenix HTTP/WebSocket endpoint

This boot sequence is a hard architectural contract: each stage may rely on services started in earlier stages, and Phoenix accepts external traffic only after every backing subsystem is ready.

## What Survives a Restart

PostgreSQL persists every domain fact needed to resume operations seamlessly after a restart:

- Principals (humans and Agents), site credentials, linked external identities, invitations, authentication challenges, groups, memberships, and AuthZ permission grants
- Browser sessions, authentication records, and OIDC clients, sessions, authorization codes, and tokens
- Pod pages, revisions, and both inline and physical Base tables, fields, views, and records
- `AppConfigure` settings and encrypted provider credentials
- Signal routing rules, accepted Signals, callback Endpoints, Conversations, public Messages, external provider references, deletion tombstones, and outbound Delivery intents
- Schedules and scheduled wake events
- AIGateway conversations, Response messages, compaction checkpoints, and provider configurations
- Brain pages, versions, retrieval chunks, claims, timelines, links, sources, schema packs, contradiction records, and Skill Lessons
- `BackgroundAgentJob` runs and turn leases, `Workflow` runs and sub-calls, and `AutomationJob` definitions and execution logs
- Session workspace epochs and idempotent tool receipts

When a Session Driver process restarts, it reconstructs its exact execution point from these tables—a process exit never loses committed work history.

## Message Lifecycle

Here is how an incoming chat message from an external provider travels through Ankole to produce a reply:

1. **Provider intake**: The messaging adapter normalizes the incoming webhook or socket event into Ankole's canonical format.
2. **Observation**: `Conversations.Observe` evaluates the channel's Binding policy and records the shared public `Message` alongside its external provider reference.
3. **Batching and Signal admission**: After optional IM debounce batching groups rapid follow-up messages, `Signals.accept_in_tx` commits an authorized `Signal` and schedules a durable Session wakeup.
4. **Session admission**: `Sessions` starts or wakes the Agent's Session Driver, which claims the pending input and advances the workspace epoch.
5. **Model invocation**: The Driver assembles the Agent's prompt context and calls `AIGateway` to generate a stateful `Response`.
6. **Streaming**: `AIGateway` persists the `Response` row and streams live model events to any connected subscribers.
7. **Tool execution**: Control-plane tools run directly inside Elixir transactions; the Driver provisions or wakes the Agent's Worker only when a turn calls an environment tool or launches a Codex Job.
8. **Round checkpoint**: A single PostgreSQL transaction commits the completed tool round, marks newly steered input as consumed, and clears temporary tool receipts so the next `Response` continues cleanly along the tape.
9. **Run completion**: Once the model finishes its final answer, one transaction verifies the Driver epoch fence, marks the `Signal` complete, and writes outbound `Delivery` intents.
10. **External delivery**: The messaging adapter sends each `Delivery` intent to the provider and, upon confirmation, records the public Agent `Message` and its external message ID.

Note two recovery invariants in this flow:
- Finishing a model `Response` does not by itself finish a Session run; if a Driver crashes mid-run, the replacement Driver resumes from the stored input rows, Response tape, and tool receipts.
- Ephemeral streaming previews on chat platforms are best-effort. Final external replies always originate from durable `Delivery` intents, while native Pod replies commit directly as public Agent `Message` rows—neither path exposes the internal AIGateway `Response` tape as the public Conversation transcript.

## Do Not Mix These IDs

| Identifier | What it identifies |
| --- | --- |
| `source_event_id` | A single upstream provider webhook/socket event (used for deduplication) |
| `provider_conversation_id` | An opaque room, channel, or thread identifier on the external chat platform |
| `provider_message_id` | A single user-visible message on the external chat platform |
| `conversation_id`, `message_id` | Ankole's canonical UUIDs for public `Conversations` and `Messages` |
| `signal_id` | One authorized `Signal` admitted into Ankole |
| `ai_message_id` | One internal message row stored in `AIGateway` |

Never substitute one identifier for another; each owning subsystem allocates and validates its own ID space.

## How Plugins and Skills Differ

- **Control Plane Plugins** are Elixir packages compiled directly into the release and activated site-wide at boot. They can register messaging or model adapters, supervised OTP processes, HTTP plugs, extension JSON:API routes, transaction hooks, `AppConfigure` schemas, and typed Console UI slots.
- **Agent Plugins** are standard Codex Plugin bundles that package related Agent tools, Skills, and an optional `workspace-template/` directory for specialized Jobs (such as Deep Research).
- **Skills** are self-contained `SKILL.md` capability packages that Ankole discovers, configures, and executes without requiring any Control Plane Plugin code.

## Where to Change Code

- **Add a model provider**: Implement it under `app/control_plane/lib/ankole/ai_gateway/providers/` or via the `ai_gateway.provider` plugin contract.
- **Add an Agent tool**: Place control-plane tools under `app/control_plane/lib/ankole/sessions/tools/`. Place Worker environment or Codex Job tools under `app/agent_computer/src/tools/` and regenerate the declared Worker tool catalog.
- **Add a messaging adapter**: Register a `signals.adapter` plugin providing both an `observe_module` and a `deliver_module`.
- **Add a Worker RPC**: Define the handler on the `Sessions` RPC lane alongside its requester in `app/agent_computer/`.
- **Add an operator setting**: Declare an `AppConfigure` key inside the owning subsystem.
- **Add a built-in Skill**: Create `app/library/skills/<name>/`.
- **Add `/api/v2` JSON:API endpoints**: Declare them on the owning Ash resource and domain, then run `mix ankole.openapi.check --write` and `bun run openapi:generate` to refresh the OpenAPI specs and generated TypeScript clients.

Never store durable business state solely in local Worker files; route every durable write through a control-plane RPC or AIGateway endpoint backed by PostgreSQL.

## Development Workflow

```sh
bun install
bun run services:start
bun run control-plane:setup
bun run dev
```

Run these commands to verify changes locally:

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

`bun run e2e` runs the standard gate suites against local fake services, whereas `--real-provider` and `--real-llm` require live operator credentials.

## Reading Order

1. Start with **this page** to see how subsystems fit together and how messages move end to end.
2. Read [Tradeoffs and Known Limits](TradeoffsAndKnownLimits.md) to understand Ankole's deliberate architectural boundaries.
3. Read the **design document** below for the specific subsystem you plan to modify.

## Document Index

| Document | Scope |
| --- | --- |
| [Tenants](design-docs/Tenants.md) | Site administration, explicit tenant contexts, Base shard isolation, and tenant lifecycle |
| [AIGateway](design-docs/AIGateway.md) | Model provider routing, stateful Response graphs, context compaction, and generated artifacts |
| [Agent Token Quota](design-docs/AgentTokenQuota.md) | Per-Agent token budgets, billing windows, resets, and quota rejection behavior |
| [Conversations](design-docs/Conversations.md) | Shared public conversation history, provider observation, outbound Delivery, and Pod SSE streams |
| [Signals](design-docs/Signals.md) | Unified trigger intake, sender authorization, routing rules, and CloudEvents Endpoints |
| [Sessions](design-docs/Sessions.md) | Session Drivers, model tool rounds, unread history tracking, and crash recovery |
| [BrainV3](design-docs/BrainV3.md) | Tenant-shared knowledge graph, scoped disclosure, active learning, and background Dreaming |
| [Brain Markdoc](design-docs/BrainMarkdoc.md) | Brain page Markdoc syntax and structured Object editing in Console |
| [Skill Lessons](design-docs/SkillLessons.md) | Leased per-Skill operational field notes distilled from completed runs |
| [RuntimeFabric](design-docs/RuntimeFabric.md) | Worker Phoenix Channel multiplexing, RPC lanes, and HTTP file relay |
| [Agent Workers](design-docs/AgentWorkers.md) | Per-Agent Worker provisioning, cloud providers, lifecycle fences, persistent Home, and cache disks |
| [Schedule](design-docs/Schedule.md) | One-shot checkbacks, recurring cron schedules, and scheduled wakeups |
| [BackgroundAgentJob](design-docs/BackgroundAgentJob.md) | Long-running asynchronous Codex jobs, turn leases, and progress reporting |
| [Automation Jobs](design-docs/AutomationJobs.md) | Deterministic Agent-owned scripts that handle triggers without spending a model turn |
| [Workflow](design-docs/Workflow.md) | Fixed TypeScript orchestrations that fan out and aggregate bounded subagent calls |
| [Principal](design-docs/Principal.md) | Unified Human and Agent identities and linked external provider accounts |
| [Authentication](design-docs/Authentication.md) | Passwordless email OTP, enterprise SSO, personal OAuth credentials, and Pod login policies |
| [Passwordless authentication upgrade](upgrades/passwordless-authentication.md) | Credential preflight checks, offline OIDC session evidence, and CLI admin recovery |
| [Human Offboarding](design-docs/HumanOffboarding.md) | Disabling departed Humans, revoking sessions, and admission checks on new work |
| [Browser Sessions](design-docs/BrowserSessions.md) | Cookie session identity, authentication freshness, multi-account switching, and logout |
| [OIDC Server](design-docs/OIDCServer.md) | Built-in OIDC provider endpoints, Client policies, token issuance, and Back-Channel Logout |
| [AuthZ](design-docs/AuthZ.md) | Principal groups, permission grants, and Rust-backed CEL policy evaluation |
| [Pod Content Model](design-docs/PodContentModel.md) | Collaborative Pod pages, inline and physical Base tables, Applets, and rich embeds |
| [AppConfiguration](design-docs/AppConfiguration.md) | Bootstrap environment variables vs. live operator settings in `AppConfigure` |
| [Plugins](design-docs/Plugins.md) | Compile-time Control Plane Plugins and Codex-compatible Agent Plugins |
| [MCP-backed Skills](design-docs/MCPBackedSkills.md) | Executing MCP tools through Skills with scoped credential injection |
| [Web tools](design-docs/WebTools.md) | `web_search`, HTTP `web_fetch`, and headless Chromium fallback |
| [I18n](design-docs/I18n.md) | Locale resolution and shared translation catalogs |
| [Logger](design-docs/Logger.md) | Structured JSON and console log formatting |
| [Tradeoffs and Known Limits](TradeoffsAndKnownLimits.md) | Deliberate non-goals, trust boundaries, and failure recovery limits |

Adapter-specific protocol specifications live under `design-docs/plugins/`.

Files in `design-docs/` state current architectural contracts rather than historical incident postmortems or one-off test logs; release-by-release changes live in `CHANGELOG.md`.
