# Ankole Documentation

[简体中文](./README.zh-Hans.md)

Start here. This page is the single architecture entrypoint for Ankole: it
explains what the system is, shows the runtime topology, maps subsystems to
code, walks one message through the whole runtime, and points to the design
contract you should read next.

## What Ankole Is

Ankole is a self-hosted Agent Operating System for long-running digital work.
One Ankole Installation runs one operating domain: its agents, its provider
connections, its data. There is no SaaS-style multi-tenant boundary inside an
installation, and code must not invent one.

An agent in Ankole is not a chat completion wrapper. It is a durable actor:
it receives work items from chat platforms, webhooks, and schedules; it runs
a tool loop against real environments (shell, files, browser); its
conversation state lives in PostgreSQL and survives process crashes; and it
can wake itself up later. Humans and agents are both Principals with
permission grants, so authorization is a runtime concern, not a prompt
convention.

## Coming From the Vercel AI SDK

If your mental model is "my route handler assembles `messages`, calls
`streamText` with `tools`, loops until no tool call, then persists in
`onFinish`", the same responsibilities exist in Ankole but live in different
processes:

| In an ai-sdk app | In Ankole |
| --- | --- |
| `streamText`/`generateText` with a `messages` array you assemble | The worker sends `response.create` over a WebSocket to AIGateway. History is server-side: rows in `ai_gateway_messages` chained by `previous_response_id`. Requests carry only new input items, never history. |
| Provider packages (`@ai-sdk/openai`, …) in your app process | Elixir provider modules behind AIGateway (`Ankole.AIGateway.Providers.*` plus plugin providers). Upstream API keys never leave the control plane; workers hold only a 30-day agent-scoped AIGateway key. |
| `tools:` + `maxSteps` loop in your server function | Tool registry and loop in the Bun worker (`app/agent_computer/src/tools/`, `src/core/agent-loop.ts`), executing next to a real sandboxed workspace. Stop policy is enforced server-side. |
| `onFinish` callback that persists the result | AIGateway's terminal commit: one PostgreSQL transaction marks the final row `complete`, sets `actor_events.completed_at`, and clears the live delivery — before the worker even sees the terminal frame. |
| An HTTP request from your own UI | A durable actor event produced by SignalsGateway from IM messages, webhooks, or schedules. It stays in `actor_events` forever; completion is a timestamp. |
| Streaming tokens to the browser (`useChat`) | Streaming a provider-native preview (e.g. a Feishu card) that is edited as text grows and replaced by the final content. |
| Serverless function lifetime | Long-running session actors with activation leases, delivery fences, retries, and crash recovery. |

The deepest difference is durability. Every hop in Ankole is designed around
the question "what survives if this process dies right now?" — and the answer
is always "the PostgreSQL rows, nothing else".

## System Map

```text
   Feishu / Slack / webhooks / schedules
                  |
                  v
        +------------------+     writes      +--------------------------+
        |  SignalsGateway  | --------------> |  PostgreSQL              |
        |  ingress, mirror,|                 |  signal_gateway_channels |
        |  delivery        |                 |  signal_gateway_entries  |
        +------------------+                 |  actor_events            |
                  |                          |  actor_event_deliveries  |
                  |                          |  ai_gateway_messages     |
                  | actor_events             |  ai_gateway_conversations|
                  v                          |  signal_gateway_outbox   |
        +------------------+                 |  actor_scheduled_events  |
        |   ActorRuntime   |                 +--------------------------+
        |  scheduling,     |                        ^
        |  fences, retry   |                        | terminal commit
        +------------------+                        |
                  | turn_start (ZeroMQ,      +------------------+
                  | RuntimeFabric)           |    AIGateway     |
                  v                          |  providers, the  |
        +------------------+  WebSocket      |  stateful message|
        |  Agent Computer  | -------------> |  log, tool-loop  |
        |  (Bun worker)    | response.create|  state, compaction|
        |  tools, sandbox  |                +------------------+
        +------------------+                        |
                                                    v
                                          upstream LLM providers
```

Seven pieces, one sentence each:

- **SignalsGateway** (Elixir) receives provider events, mirrors what the
  provider shows, decides what wakes an agent, and delivers replies back.
  Owns `signal_gateway_channels`, `signal_gateway_entries`, `actor_events`,
  `signal_gateway_outbox`. Read `design-docs/SignalsGateway.md`.
- **ActorRuntime** (Elixir) schedules actor events onto workers, one event per
  execution, with fences that stop stale workers from committing. Owns
  `actor_event_deliveries` and session activations.
- **AIGateway** (Elixir) is the AI boundary: provider credentials and routing,
  plus the stateful Responses log — model history, tool-loop state,
  compaction, and the terminal commit. Owns `ai_gateway_messages` and
  `ai_gateway_conversations`. Read `design-docs/AIGateway.md`.
- **Memory** (Elixir + Bun tools) owns curated channel notes and historical
  recall over provider mirrors. Owns `memory_notes`, `memory_episodes`, and
  `memory_channel_cursors`. Read `design-docs/memory/Basic.md`; the detailed
  v1 design lives in `internals/docs/Memory.zh.md`.
- **RuntimeFabric** (Rust + ZeroMQ) is the live transport between the control
  plane and workers: turn envelopes, RPC, file bytes. It is never durable
  truth. Read `design-docs/RuntimeFabric.md`.
- **Agent Computer** (Bun worker) executes tools: shell, files, browser, and
  worker-local state for the current turn. It drives the model loop over
  WebSocket but keeps no conversation state.
- **PostgreSQL** holds every durable fact. If it matters after a crash, it is
  a row here, and Elixir owns the write.

Schedule (`design-docs/Schedule.md`) turns time into actor events. Principal
and AuthZ (`design-docs/Principal.md`, `design-docs/AuthZ.md`) own identity
and permissions. AppConfiguration (`design-docs/AppConfiguration.md`) splits
boot env vars from operator-managed runtime settings. Plugins
(`design-docs/Plugins.md`) are trusted first-party Elixir extensions, such as
the Feishu adapter (`design-docs/plugins/FeishuAdapter.md`).

## Runtime Topology

A running installation is one Phoenix/OTP control plane, one PostgreSQL, and
N Agent Computer worker containers. Browsers talk to Phoenix; providers talk
to plugin adapters; workers talk to the control plane over two channels:
ZeroMQ (RuntimeFabric) for turn control and RPC, WebSocket/HTTP (AIGateway
API) for model calls.

```text
   Feishu / providers          Browser (operator)
        |  long conn / webhook      |  HTTPS
        v                           v
  +---------------------------------------------+
  |  Control plane (Elixir/Phoenix, one BEAM)   |
  |  SignalsGateway | ActorRuntime | AIGateway  |
  |  Principal/AuthZ | AppConfigure | Plugins   |
  |  Rust kernel (Rustler NIF): crypto, CEL,    |
  |  protobuf codec, ZeroMQ ROUTER              |
  +---------------------------------------------+
     |  SQL                  ^            ^
     v                       |            |
  PostgreSQL          ZeroMQ (fabric)  WebSocket /api/v1/ai-gateway
  (durable truth)     ROUTER <-> DEALER   (Responses wire shape)
                             |            |
                      +---------------------------------+
                      |  Agent Computer worker (Bun,    |
                      |  Docker): agent loop, tools,    |
                      |  bubblewrap sandbox, browser,   |
                      |  Rust kernel (N-API): DEALER    |
                      +---------------------------------+
                             |
                             v
                      upstream LLM providers (called from the
                      control plane, never from the worker)
```

Default local ports: Phoenix on `4000`, devkit PostgreSQL on `5433`, Vite dev
server for the SPAs on `3035`, RuntimeFabric endpoint wherever the operator
binds it (the README example uses `tcp://127.0.0.1:6010`).

Two transports, one rule:

- **RuntimeFabric (ZeroMQ)** is live transport only: turn envelopes, RPC,
  file bytes, heartbeats, backpressure. Never durable truth. The system must
  never recover state by asking ZeroMQ what happened.
- **PostgreSQL** owns every fact that matters after a crash: actor events,
  the AI message log, mirrors, outbox rows, fences, configuration. Elixir
  owns all writes.

## Language Ownership

Three runtimes, hard boundaries. Do not move responsibilities across them
because one side is easier to edit or test.

| Runtime | Owns | Must not |
| --- | --- | --- |
| **Elixir** (`app/control_plane`) | PostgreSQL semantics and migrations, supervision, setup/console/auth surfaces, Principal/AuthZ facades, AppConfigure, SignalsGateway, ActorRuntime scheduling and fences, AIGateway providers and the stateful message log, terminal commit authority, plugin registry | Push durable-state ownership into workers or the kernel |
| **Rust kernel** (`app/kernel`) | Deterministic shared mechanisms where Elixir/Bun parity matters: crypto (AEAD, key derivation), UUIDv7, JWT, phone normalization, xxh3, zstd block codec, CEL evaluation for AuthZ and signal filters, protobuf envelope codec + validation, ZeroMQ socket ownership (ROUTER/DEALER/ZAP threads) | Touch PostgreSQL, own product lifecycle state, grow into a domain owner |
| **Bun worker** (`app/agent_computer`) | The agent loop, tools, prompts, terminal/browser state, bubblewrap sandboxing, worker-local filesystem, the AIGateway client | Invent control-plane state; anything that must survive a restart goes through RPC or the AIGateway API and lands in PostgreSQL |

The kernel is compiled twice from one crate: as a Rustler NIF for Elixir
(wrapped by `Ankole.Kernel` in `app/kernel/lib/ankole/kernel.ex`) and as an
N-API module for Bun (`app/kernel/index.js`, types in `index.d.ts`). Put
logic in Rust when it is a deterministic function over explicit inputs that
both hosts need — the CEL AuthZ evaluator and the envelope codec are the
canonical examples.

## Repository Map

| Path | What lives there |
| --- | --- |
| `app/control_plane/` | Phoenix/OTP control plane. Domain contexts under `lib/ankole/`, web surface under `lib/ankole_web/`, migrations under `priv/repo/migrations/`. |
| `app/kernel/` | Rust kernel crate. `src/common/` (crypto/ids/jwt/zstd), `src/authz/` (CEL), `src/runtime_fabric/` (protobuf + ZeroMQ), `proto/` (envelope schema), `src/nif_exports.rs` / `src/napi_exports.rs` (binding surfaces). |
| `app/agent_computer/` | Bun worker. `src/main.ts` daemon, `src/core/` agent loop + turns, `src/tools/`, `src/prompts/`, RuntimeFabric lanes (`actor_lane.ts`, `rpc_lane.ts`, `file_transfer_lane.ts`). Docker-only runtime. |
| `app/webapps/` | Three Vite + React SPAs (`auth/`, `console/`, `setup/`) built into `app/control_plane/priv/static/assets/`. Generated OpenAPI client. |
| `app/library/` | Built-in skills (`skills/nano-pdf`, `skills/jupyter-live-kernel`, `skills/powerpoint`) and agent starter templates (`templates/MISSION.md`, `templates/SOUL.md`). |
| `app/locales/` | TOML message catalogs (`en-US.toml`, `zh-Hans-CN.toml`) consumed by both the Elixir I18n context and the SPAs. |
| `plugins/` | Public first-party Elixir plugins: `lark_adapter` (Feishu chat + identity provider), `china_market_ai_providers` (AIGateway providers). |
| `internals/` | Private first-party material: `plugins/`, `skills/` (e.g. financial-data CLI), `helm-chart/`, extra worker Dockerfiles, internal test notes. |
| `libs/` | `feishu_openapi` (Elixir Lark client: tokens, WS long connection, crypto) and `uikit` (shared React components, Tailwind 4). |
| `tools/devkit/` | Workspace CLI: `bun run kit ...` (external services via Docker Compose, codegen, analysis). |
| `tools/e2e/` | E2E harness and suites (fake Feishu, fake OpenAI, real Docker worker), driven by `mix e2e.*` aliases. |
| `docs/` | This page, `TradeoffsAndKnownLimits.md`, `design-docs/`. |

## Control Plane Boot Order

`Ankole.Application` (`app/control_plane/lib/ankole/application.ex`) starts,
in order: Telemetry -> Repo -> `AppConfigure.Registry` ->
`AppConfigure.Cache` -> `Setup.Bootstrap` -> Oban -> `Plugins.Registry`
(discover + validate + activate) -> `Plugins.Supervisor` (children
contributed by active plugins) -> PubSub -> SignalsGateway preview
registry/supervisor -> `InboundBatchFinalizer` and `RecoveryScan`
(config-gated) -> `ActorRuntime.Supervisor` ->
`AIGateway.ModelMetadata.Cache` -> `I18n.Catalog` -> DNSCluster -> Endpoint.

The order is load-bearing, not decorative: configuration must exist before
plugins read it, plugins must register their AppConfigure definitions before
anything resolves them, and the HTTP endpoint comes up last.

## Core Subsystems

### SignalsGateway — provider ingress and provider-visible side effects

`Ankole.SignalsGateway` (`lib/ankole/signals_gateway/`). Adapters call
`emit_entry/emit_reaction/emit_action` with normalized facts. For each one,
the gateway checks the binding (`bindings.ex`), applies CEL filters (evaluated
in the kernel), guards against tombstoned entries, upserts the provider mirror
(`channel.ex`, `entry.ex`), and batches IM bursts
(`inbound_batch*.ex`). Closing a batch writes one `actor_events` row in one
transaction, then acks the provider. Outbound explicit side effects take a
separate path: `outbox.ex` / `outbox_entry.ex`, executed by the binding's
outbox adapter. Streamed replies are not outbox rows. Instead,
`ai_reply_preview.ex` subscribes to AIGateway chunk events and drives the
provider-native preview, and `recovery_scan.ex` re-sends completed finals
whose mirror is missing.

Owns tables: `signal_gateway_bindings`, `signal_gateway_channels`, `signal_gateway_entries`,
`signal_gateway_input_tombstones`, `signal_gateway_inbound_batches`,
`signal_gateway_outbox`.

### ActorRuntime — scheduling turns onto workers, with fences

`Ankole.ActorRuntime` (`lib/ankole/actor_runtime/`). It supervises session
controllers, the `ActivationManager` (session activation leases), the
`WorkerPool` (connected workers, capacity), a `Reconciler`, and a `Watchdog`.
For each session, one ready actor event at a time becomes a `turn_start`
envelope (`turn_envelope.ex`), sent over the fabric by `transport/broker.ex`.
Every delivery carries the fence (`ActorTurnRef`): activation uid, actor
epoch, actor event id, revision. A stale worker's echo fails the equality
check and cannot commit into newer actor state. Retries do not resurrect a
stream — they create a fresh actor event tagged
`retry_of_actor_event_id`.

Owns tables (UNLOGGED, rebuildable runtime projections):
`actor_event_deliveries`, `actor_session_activations`,
`actor_session_worker_assignments`, `agent_computer_workers`. The durable
work journal `actor_events` itself is written by SignalsGateway/Schedule and
completed by AIGateway's terminal commit.

### AIGateway — providers plus the stateful Responses log

`Ankole.AIGateway` (`lib/ankole/ai_gateway/`). Two halves:

- **Provider boundary.** `providers.ex` registers built-in provider modules
  (`providers/openai.ex`, `openai_compatible.ex`, `openrouter.ex`,
  `google_ai_studio_openai.ex`, `claude.ex`, `azure_openai.ex`, `jina.ex`)
  and plugin providers discovered via the `ai_gateway.provider` contract
  (today: `xiaomi_mimo`, `volcengine_ark`, `alibaba_cn`, `zai_coding_plan`
  from `plugins/china_market_ai_providers`). A provider module returns a
  `provider_definition()` — settings schema, base URL, capabilities with a
  `prepare/1` that builds a `UniversalAIRequest`. The actual HTTP/SSE
  transport to the upstream runs in the kernel's `universal_ai_client`
  (feature-gated Rust, NIF-driven). Operator instances live in
  `ai_gateway_providers` rows (encrypted credential, base URL override);
  agents bind model aliases (`primary`, `light`, `heavy`, `embedding`,
  `rerank`) in `agents.options["ai_agent"]["models"]`.
- **Stateful Responses log.** `stateful_responses.ex` owns the run-row
  lifecycle. On `start_response_run` it validates the anchor (exactly one of
  `conversation` / `previous_response_id`), expands history by walking the
  `previous_message_id` graph (skipping `retracted`, collapsing prefixes
  covered by compaction rows), and auto-compacts when the chars/4 estimate is
  over budget (`compaction.ex`, summarized with the agent's `light` profile).
  It then writes the row `status = "generating"`, streams provider chunks to
  PubSub, and commits terminally under an optimistic
  `WHERE status = 'generating'` guard. A terminal commit at the chain tail
  also sets `actor_events.completed_at` and clears the delivery. Orphaned
  `generating` rows recover to `error` by `updated_at` staleness (300 s
  grace).

The wire surface is the OpenAI Responses shape: workers connect to
`GET /api/v1/ai-gateway/responses` (WebSocket,
`AnkoleWeb.AIGatewayResponsesSocket`) and send `response.create` frames with
`store=true`; ids are rewritten to `resp_<message-row-uuid>`; HTTP routes
exist for stateless calls, retrieval, manual compaction, embeddings, and
rerank. Owns tables: `ai_gateway_messages`, `ai_gateway_conversations`,
`ai_gateway_providers`.

### RuntimeFabric — the live ZeroMQ transport

Design in `docs/design-docs/RuntimeFabric.md`; mechanics in
`app/kernel/src/runtime_fabric/`. One ROUTER socket on the control plane
(owned by a dedicated Rust thread, commanded from
`Ankole.ActorRuntime.Transport.Broker`), one DEALER per worker (owned by a
Rust thread, driven from `src/runtime_fabric_sender.ts`). Workers
authenticate with ZAP PLAIN: username `WORKER_ID`, password = the
installation worker auth key (AppConfigure-owned, encrypted at rest).

Envelopes are protobuf
(`app/kernel/proto/ankole/runtime_fabric/v1/envelope.proto`) and are
validated in Rust before either host sees them. They travel over four lanes:
CONTROL (`worker_ready`, heartbeat, capacity, `turn_control`, shutdown),
TURN (`turn_start`, `mailbox_updated`, `turn_accepted`, `turn_error`,
`turn_noop_completed`), PROGRESS (`worker_progress`, observability only),
and RPC (`rpc_request`/`rpc_response`/`rpc_error`). A separate raw-frame
file lane (`ANKOLE_FILE/1`, 2 MiB zstd blocks, credit flow control) moves
bytes between the control plane and the worker-visible roots `user_files`
and `agent_installed_skills`
(`lib/ankole/actor_runtime/file_transfer_lane.ex` <->
`src/file_transfer_lane.ts`).

Worker->control-plane RPC methods are registered in
`lib/ankole/actor_runtime/rpc_lane.ex`:
`ai_gateway.api_key_for.create_or_find_by_agent`,
`agent_conversation.context.resolve`, `skills.overlay.resolve` / `.replace`,
`schedule.check_back_later.create`, the `schedule.cron.*` family,
`memory_note.*`, `memory_search`, and `memory_browse`.

### Agent Computer — the Bun worker

`app/agent_computer/src/`. `main.ts` parses env (`WORKER_ID`,
`RUNTIME_FABRIC_URL` of the form `tcp://:worker_auth_key@host:port`), starts
the DEALER, announces `worker_ready`, heartbeats every 15 s, and dispatches
envelopes. A `turn_start` runs the turn pipeline in `core/turns/`
(`text_turn.ts` for text turns). That pipeline resolves conversation context
and an AIGateway API key over RPC, builds the system prompt
(`src/prompts/`), and assembles tools. It then drives `core/agent-loop.ts`,
which sends `response.create` via the official `openai` SDK with a custom
WebSocket transport for the stateful path (`core/llm.ts`), executes returned
tool calls locally, feeds `function_call_output` items back chained on
`previous_response_id`, and stops when a response has no tool call. Steering
arrives as `mailbox_updated` and is injected between rounds; `turn_control`
aborts.

The model-visible tool surface is deliberately narrow (see
`docs/TradeoffsAndKnownLimits.md` before widening it): `todo`
(`src/tools/todo/todo-tool.ts`); the computer tools `command`,
`interactive_terminal`, `read_file`, `patch`, and `reply_attachment`
(`src/tools/computer/`); the browser tools `browser_open`, `browser_run`,
`browser_extract`, and `browser_doctor` (`src/tools/browser/`); the schedule
tools `check_back_later` and `cron` (`src/tools/schedule/schedule-tools.ts`); and the
memory tools `memory_note`, `memory_search`, and `memory_browse`
(`src/tools/memory/`); and the skill tools `skill_view` and `skill_append`
(`src/tools/library/`). Shell
commands run inside bubblewrap — strong mode preferred, weak mode with a
startup warning, never unsandboxed (`src/tools/computer/bubblewrap.ts`).
There is no MCP support in the current tree; if it arrives, it belongs at
this worker boundary as another local tool source.

The worker is stateless by contract: it holds the WebSocket, tool-local
state, and the current turn; everything durable is a PostgreSQL row reached
via RPC or the AIGateway API. Kill a worker and the turn retries elsewhere.

#### User-visible context limits

Ankole keeps provider mirrors and AI Gateway history durable, but a single turn
does not receive an unlimited raw room transcript.

- **Addressed batches**: closely adjacent addressed messages are merged before
  they become one `actor_events` row. The addressed batch stops at 8 entries or
  about 4,000 text characters; a long-text continuation may extend the hard cap
  to about 8,000 characters. If exact older details matter, restate them in the
  current request or ask the agent to use memory/history tools.
- **Ambient recall**: when `may_intervene` is enabled, the ambient recognizer
  receives a bounded room snapshot. The snapshot is capped at 80 observed
  messages from the relevant channel/thread window; the separate recent-history
  helper is capped at 10 messages. Ambient decisions should therefore be treated
  as local-room awareness, not full-history search.
- **Practical rule**: repeat critical IDs, dates, constraints, and desired
  success criteria when assigning work. Durable memory can help with stable
  facts, but the safest current-turn context is still what the user states
  explicitly in that turn.

### Principal and AuthZ — identity and permissions

`Ankole.Principals` and `Ankole.AuthZ` (`lib/ankole/principals/`,
`lib/ankole/authz/`). Principals are installation-wide subjects with
lowercase text `uid` primary keys and `type` human | agent, plus per-type
rows (`human_users`, `agents`) and `external_identities` (platform subjects,
channel actors, login subjects, outbound actors). AuthZ owns groups (static
and CEL-computed, with built-in `admin` / `all_humans`), grants
(`owner + resource_pattern + action + condition`), memberships, and external
bindings synced from identity providers. An authorize call builds an explicit
snapshot (`authz/snapshot.ex`) and hands it to the kernel
(`Ankole.Kernel.authz_authorize/1`) for deterministic CEL + pattern
evaluation. The kernel never touches the database.

### AppConfigure — operator-managed runtime settings

`Ankole.AppConfigure` (`lib/ankole/app_configure/`). Every runtime setting is
a declared key (`AppConfigure.define/1` or pattern definitions), stored in
the `app_configure` table as `{scope, key, value}` with scope `global` or
`agent:<id>`. Resolution falls back agent -> global -> code default. Secret
values are sealed with the kernel's AEAD using per-row derived keys, and an
ETS cache fronts reads. Environment variables are only for process bootstrap
(`DATABASE_URL`, `SECRET_KEY_BASE`, fabric endpoint); anything an operator
manages at runtime belongs here, not in env.

### Plugins — trusted first-party Elixir extensions

`Ankole.Plugins` (`lib/ankole/plugins/`). At boot, `Discovery` loads plugin
sources from `plugins/` and `internals/plugins/` (override with
`ANKOLE_PLUGIN_PATHS`). A plugin is a module implementing the
`Ankole.Plugins.Plugin` behaviour: `plugin_id/0`, `api_version/0` (= 1), and
optionally `display_name/0`, `description/0`, `app_config_definitions/0`,
`app_config_patterns/0`, `setup_metadata/0`, `adapter_declarations/0`,
`children/0`. The registry then validates specs, skips ids listed in the
`plugins.disabled_ids` config, registers active plugins' config definitions,
starts their supervised children, and indexes adapter declarations by
contract id — `signals_gateway.adapter` for chat/provider adapters and
`ai_gateway.provider` for model providers. There is no dynamic third-party
loading, no marketplace, no hot activation. Plugins are trusted code shipped
with the installation.

`plugins/lark_adapter` is the reference adapter. It opens one long connection
per `{domain, app_id}` (via `libs/feishu_openapi`), normalizes ingress for
messages/recalls/reactions/card actions, provides an outbox adapter for
posts, replies, edits, deletes, reactions, and streaming CardKit cards, and
exposes a separate identity-provider contract (OIDC login + user/department
sync into Principals).

### Schedule — time as actor events

`Ankole.Schedule` (`lib/ankole/schedule/`). Two primitives: checkbacks
(one-shot `check_back_later`) and cron schedules, stored in
`actor_scheduled_events` and `actor_cron_schedules`. Oban is the wake edge
only. `FireScheduledEvent` claims the row with a guarded
`status = 'scheduled'` update, appends an actor event with a stable
`source_event_id` (`check_back_later:<id>:wakeup`, `cron:<id>:<slot>`), and,
for cron, plans the next occurrence in the same transaction. Workers create
schedules through the `schedule.*` RPCs (that is what the `check_back_later`
and `cron` tools call); operators manage them through the console REST API.

### Skills and the library

Built-in skills ship in the worker image from `app/library/skills/` (each a
`SKILL.md` plus assets); agent-installed skills are real files under the
shared skills root, moved over the file lane. On each worker process' first
turn for an agent, and again when that directory fingerprint changes, the
worker sends `skills.installed.replace` observations before resolving context.
PostgreSQL owns the registry, enablement, overlays, and observations (`Ankole.AIAgent.Library`,
`lib/ankole/ai_agent/library/`). Models see `skill://enabled/...`
references; `skill_view` reads the base file and merges the database
overlay, `skill_append` replaces the overlay. Do not synthesize fake
`/workspace/skills` paths.

## Life of a Message, With Code Pointers

The canonical chain: a user mentions an agent in a Feishu group, the agent
answers after one shell command.

1. **Ingress.** `plugins/lark_adapter/.../inbound.ex` receives
   `im.message.receive_v1` on the long connection and calls
   `Ankole.SignalsGateway.emit_entry/3`. The gateway resolves the binding,
   evaluates filters (kernel CEL), checks the tombstone, upserts
   `signal_gateway_channels` / `signal_gateway_entries`, and opens or extends an inbound
   batch.
2. **One work item.** `InboundBatchFinalizer` closes the batch; one
   transaction writes one `actor_events` row with
   `type = "im.message.addressed"`, unique on
   `(agent_uid, binding_name, source_event_id)`, and then the provider is
   acked. This row is the durable work item. It stays forever, with
   `completed_at` set once the work is done.
3. **Dispatch.** ActorRuntime's session controller picks the next ready event
   (`input_state = 'open' AND completed_at IS NULL`, no live delivery). The
   `ActivationManager` holds the activation lease, the `WorkerPool` assigns a
   worker, `TurnLifecycle.start_worker_turn` writes the
   `actor_event_deliveries` fence row, and `Transport.Broker` sends the
   `turn_start` envelope (built in `turn_envelope.ex`) over ZeroMQ. No
   history travels — just one fence, one actor event, and one model ref.
4. **Worker turn setup.** `src/main.ts` dispatches to
   `core/turns/text_turn.ts`, which fetches the conversation context and an
   agent-scoped AIGateway key over RPC, builds the system prompt, and
   assembles the tool set.
5. **First model call.** `core/agent-loop.ts` sends `response.create`
   (`store=true`, `conversation`, the user's text as input items, and
   `metadata.actor_event_id`) over the AIGateway WebSocket.
   `AnkoleWeb.AIGatewayResponsesSocket` hands it to
   `StatefulResponses.start_response_run`, which expands history,
   auto-compacts if over budget, and writes the `generating` row. The
   provider's `prepare/1` plus the kernel `universal_ai_client` then stream
   the upstream call. Chunks go to PubSub, never to the database.
6. **Live preview.** `SignalsGateway.AIReplyPreview` subscribes to those
   chunks and drives a streaming Feishu card through the lark adapter's
   CardKit calls: send on first chunk, edit as text grows.
7. **Tool execution.** The model returns a `function_call`; AIGateway commits
   the row `complete` (input items + output items in one `content` array) and
   sends the terminal frame. The worker runs the shell command inside
   bubblewrap, then sends the next `response.create` with the
   `function_call_output`, chained via `previous_response_id`.
8. **Terminal commit.** A round with no tool call is the chain tail — the
   final AI output of this actor event. In one transaction AIGateway commits
   it `complete`, sets `actor_events.completed_at`, and clears the delivery.
   Only then does the worker see the terminal frame. The worker itself
   reports nothing on success; `turn_error` and `turn_noop_completed` cover
   the other endings.
9. **Finalize.** `AIReplyPreview` replaces the card with the final content.
   On confirmed provider success it upserts the final mirror: a
   `signal_gateway_entries` row with `ai_message_id` pointing at the final message
   row. That row is the proof of delivery.
10. **Recovery.** If anything died between steps 8 and 9, `RecoveryScan`
    finds the completed final without a mirror and re-sends it (at-least-once
    by design). A worker that dies mid-turn surfaces as a fence-failed
    delivery; the retry is a fresh actor event tagged
    `retry_of_actor_event_id`. An orphaned `generating` row ages into
    `error`, and the next run re-anchors on the last `complete` row.

Side chains reuse the same shapes:

- **Scheduled wakeups**: `check_back_later` / `cron` tool -> `schedule.*` RPC
  -> `actor_scheduled_events` row + Oban job -> fire writes a new actor event
  -> same dispatch path.
- **Explicit side effects** (attachments, reactions, command feedback):
  `reply_attachment` and friends become `signal_gateway_outbox` rows at
  terminal commit; the outbox executor calls the binding's outbox adapter and
  records the provider outcome.
- **Steering**: a new message during a running turn becomes an actor event
  whose arrival is pushed as `mailbox_updated`; the worker injects it between
  model rounds. `/steer` is acknowledged when that nudge is sent or queued for
  the active turn, not when the model proves it consumed the steer.
- **`/compress`**: an IM command that writes a compaction row through
  `POST /api/v1/ai-gateway/responses/compact`.
- **Recall**: a recalled provider message tombstones the mirror and, for
  completed work, hard-deletes or retracts the tail of the message chain.

## Identity Layers

Four id layers appear everywhere. They are never interchangeable:

| Layer | Identifies | Example |
| --- | --- | --- |
| `source_event_id` | one provider event; the ingress idempotency key | Feishu `Event.id` |
| `source_entry_id` | one provider entry (message, post) | Feishu `message_id` |
| `actor_event_id` | one Ankole work item (`actor_events.id`) | uuid |
| `ai_message_id` | one stored model output (`ai_gateway_messages.id`) | uuid |

The canonical definition lives in `design-docs/SignalsGateway.md` under
Identity Layers.

## Data Model Essentials

Durable tables (crash truth): `principals`, `human_users`, `agents`,
`external_identities`, `principal_groups`, `permission_grants`,
`app_configure`, `signal_gateway_bindings`, `signal_gateway_channels`, `signal_gateway_entries`,
`signal_gateway_outbox`, `actor_events`, `actor_cron_schedules`,
`actor_scheduled_events`, `ai_gateway_conversations`, `ai_gateway_messages`,
`ai_gateway_providers`, `memory_notes`, `memory_episodes`,
`memory_channel_cursors`, plus the skill library tables.

Runtime projections (UNLOGGED, rebuildable): `actor_event_deliveries`,
`actor_session_activations`, `actor_session_worker_assignments`,
`agent_computer_workers`.

Conventions to match (see `CLAUDE.md`):

- Principal uids are lowercase text primary keys used directly as foreign
  keys; do not add shadow UUIDs.
- Opaque row ids are UUIDv7 generated in application code
  (`Ankole.Ecto.UUIDv7` in schemas, `Ankole.Kernel.gen_uuid_v7/0`
  elsewhere) — never `gen_random_uuid()` defaults.
- Prefer PostgreSQL-native modeling: enums via `Ecto.Enum`, `jsonb` for
  declared payloads, check constraints for invariants that must survive
  crashes.
- State machines are status columns guarded by transactional `WHERE`
  clauses (optimistic commits), not advisory locks.

## Where to Make a Change

**Add an AI model provider.** Write a provider module returning a
`provider_definition()` (follow `lib/ankole/ai_gateway/providers/openai.ex`
or the plugin providers in `plugins/china_market_ai_providers/`): a settings
schema, a default base URL, and capabilities with a `prepare/1` that builds a
`UniversalAIRequest` against one of the kernel's API resolvers
(responses / chat-completions / claude / embedding / rerank shapes). Built-in
providers register in `Ankole.AIGateway.Providers`; plugin providers declare
the `ai_gateway.provider` contract. Optional: `check_connection/1`,
`models_metadata_source/1`. Operators then create an `ai_gateway_providers`
row via the console and bind agent model profiles. Smoke-test with
`mix e2e.ai_gateway_real_provider`.

**Add a worker tool.** Implement it under `app/agent_computer/src/tools/`
(Zod parameter schema + `execute`), register it in the turn assembly in
`src/core/turns/text_turn.ts`, and route any command execution through the
bubblewrap helpers. The tool surface is an allowlist and a product decision,
so update `docs/TradeoffsAndKnownLimits.md` when you widen it. Durable
effects must go through an RPC or the AIGateway API, not local files. Test
inside the image: `bun run agent-computer:test`. Cross-boundary behavior
belongs in `tools/e2e/suites/worker_computer_e2e_test.exs`.

**Add a chat/signal provider adapter.** New Elixir plugin under `plugins/`
implementing `Ankole.Plugins.Plugin`, declaring `signals_gateway.adapter`
with your inbound and outbox modules, setup metadata, and config patterns
for credentials. Inbound code normalizes provider events into
`SignalsGateway.emit_*` facts; the outbox module implements only the
operations you can honestly support. Long connections run as plugin
`children/0`. `plugins/lark_adapter` is the reference; the contract lives in
`design-docs/SignalsGateway.md` and `design-docs/plugins/FeishuAdapter.md`.
For E2E, run a fake provider server following
`tools/e2e/support/fake_feishu/`.

**Add a worker->control-plane RPC.** Handler on the Elixir side registered in
`lib/ankole/actor_runtime/rpc_lane.ex`; validate the turn ref and the
authenticated route like the existing brokers. Call it from the worker via
`src/rpc_lane.ts`. If the payload matters after a crash, the handler writes
PostgreSQL; the worker never does.

**Add a runtime setting.** Declare the key (`AppConfigure.define/1` in the
owning subsystem, or a plugin's `app_config_definitions/0`), mark secrets
encrypted, read through `AppConfigure.get/2`. Do not add a new environment
variable for anything an operator manages at runtime.

**Add a built-in skill.** Directory under `app/library/skills/<name>/` with
`SKILL.md` plus assets; it ships in the worker image. Enablement and overlays
are PostgreSQL rows (`Ankole.AIAgent.Library`); nothing else needs to change
for `skill_view` / `skill_append` to work.

**Add a console API + UI.** OpenAPI-spec'd controller (open_api_spex) under
the `:console_api` pipeline in `lib/ankole_web/router.ex`, regenerate the
typed client in `app/webapps` (`openapi/` + TanStack Query hooks), build the
screen from `libs/uikit` components. Generated client code is a build
artifact — never hand-edit it.

## Development Workflow

```shell
bun install                      # workspace deps
bun run services:start           # devkit Docker Compose: PostgreSQL on :5433
bun run control-plane:setup      # mix deps.get + ecto.create/migrate/seed
bun run control-plane:dev        # Phoenix on :4000 (serves built SPAs)
bun run webapps:dev              # optional: Vite on :3035 with HMR

# Worker image (required for worker tests and e2e)
docker build -f app/agent_computer/Dockerfile -t ankole-agent-computer:0.1.0 .

# Render the docker run command for an external worker against local fabric
cd app/control_plane
mix ankole.actor_runtime.worker_bootstrap \
  --endpoint tcp://127.0.0.1:6010 --worker-id worker-a
```

Test tiers — keep the fast path fast, and validate runtime claims at the
right tier (see `docs/TradeoffsAndKnownLimits.md` § Worker E2E):

| Tier | Command | Needs |
| --- | --- | --- |
| Control-plane unit/integration | `bun run control-plane:test` (= `mix test`) | PostgreSQL only |
| Worker tools | `bun run agent-computer:test` | Docker + worker image (bubblewrap is container-only) |
| Type/lint/format | `bun run type-check`, `bun run lint`, `bun run fmt` | — |
| Main-chain e2e | `cd app/control_plane && mix e2e.gate` | Docker worker image; fake Feishu + fake OpenAI |
| Chaos / perf | `mix e2e.chaos`, `mix e2e.perf` | same as above |
| Real providers | `mix e2e.real_llm` (`ANKOLE_REAL_LLM_E2E=1`), `mix e2e.ai_gateway_real_provider` | real credentials |

The e2e harness (`tools/e2e/`) runs a fake Feishu platform that speaks the
real WS protocol against the real `lark_adapter`, a fake OpenAI endpoint,
and a real Agent Computer container wired through RuntimeFabric. So "the main
chain works" is a runnable claim, not a static-review claim. `bun run kit`
exposes devkit helpers (`external-services`, `analyze`, codegen), and package
filters (`bun run --filter @ankole/... test`) keep validation package-local
while the workspace moves quickly.

## Glossary

- **actor event**: one durable work item for one agent session. A row in
  `actor_events`. It stays after completion; `completed_at` marks the finish.
- **actor session**: `{agent_uid, session_id}`. Signal-backed sessions derive
  `session_id` from the channel; one channel, one session actor.
- **binding**: one configured provider ingress for one agent, e.g. one Feishu
  app connected to one agent.
- **run row**: the `ai_gateway_messages` row written for one
  `response.create` call. Holds request input items and model output items in
  one `content` array.
- **compaction row**: an `ai_gateway_messages` row (`type = "compaction"`)
  that summarizes an older history prefix so future runs fit the model
  context.
- **anchor**: the row a new run chains from (`previous_message_id`; rendered
  as `previous_response_id` at the API edge).
- **visible leaf**: a `complete` row no other row chains from. Implicit
  continuation always picks the latest one.
- **source mirror**: `signal_gateway_channels` + `signal_gateway_entries`, the current
  picture of what the provider shows. Not a queue, not model history.
- **outbox**: `signal_gateway_outbox`, the durable table of explicit
  provider-visible side effects (attachments, reactions, command feedback).
  Streamed replies do not go through it.
- **preview / finalize**: the streamed reply lifecycle — send a provider
  message on the first chunk, edit it while streaming, replace it with the
  final content at the terminal event.
- **final mirror**: the `signal_gateway_entries` row (with `ai_message_id`) written
  after a confirmed final send/edit. Proof of delivery.
- **fence** (`ActorTurnRef`): the equality check (activation, epoch, actor
  event id, revision) that stops a stale worker from committing into newer
  actor state.
- **turn**: one worker execution of one actor event — possibly many model
  calls, one completion.
- **dead letter**: an actor event marked undeliverable (`input_state =
  'dead_letter'`). Not the same as completed.
- **checkback**: a one-shot self-wakeup (`check_back_later`) the agent
  schedules for itself.
- **tombstone**: a short-lived guard row that stops a removed provider entry
  from being re-mirrored by late deliveries.

## Settled Decisions — Read Before "Fixing"

`docs/TradeoffsAndKnownLimits.md` records the tradeoffs that look like gaps
but are decided. The ones newcomers trip over:

- Streamed IM delivery is at-least-once; a stale preview card left behind
  until recovery is accepted; error terminals post no IM message.
- Continuation is derived from the message graph (latest visible leaf) —
  there is no stored cursor, no generation lease, and no half-stream
  recovery; a broken stream costs one round.
- Token budgeting is chars/4 on purpose; no tokenizer dependency.
- AIGateway security is two rules: the 30-day agent token proves identity,
  and every query filters by `agent_uid`. Workers are trusted first-party
  nodes; bubblewrap is the untrusted-process boundary, not the worker.
- One WebSocket runs one in-flight response; sequencing is enforced by
  ActorRuntime, not an AIGateway lock.
- ZeroMQ is never a durable queue; UNLOGGED runtime tables are rebuildable
  projections, not truth.

If a change touches one of these, it is a design change: update the design
doc first, then the code.

## Reading Order

1. This page.
2. `design-docs/AIGateway.md` — if you work on the AI side: providers, the
   stateful message log, the tool loop, compaction.
3. `design-docs/SignalsGateway.md` — if you work on the IM/provider side:
   ingress, batching, commands, streamed delivery, recovery.
4. `design-docs/memory/Basic.md` — if you work on channel memory, historical
   recall, BM25/vector retrieval, or memory tools. Use
   `internals/docs/Memory.zh.md` for the detailed v1 design.
5. `design-docs/RuntimeFabric.md` and `design-docs/Schedule.md` — transport
   and time, when you touch them.
6. `design-docs/Principal.md`, `design-docs/AuthZ.md`,
   `design-docs/AppConfiguration.md`, `design-docs/Plugins.md`,
   `design-docs/I18n.md` — reference as needed.
7. `TradeoffsAndKnownLimits.md` — read once early. It records the decisions
   that look like gaps but are settled: at-least-once streamed delivery, the
   two-rule security model, derived continuation, chars/4 budgeting, and the
   current non-goals.

## Design Doc Index

| Document | Read when you touch |
| --- | --- |
| `docs/README.md` | Anything — the system map, code-level map, change guide, and glossary |
| `design-docs/AIGateway.md` | Providers, message log, tool loop, compaction |
| `design-docs/SignalsGateway.md` | Ingress, mirrors, outbox, delivery, commands |
| `design-docs/memory/Basic.md` | Channel notes, historical recall, BM25/vector search |
| `design-docs/RuntimeFabric.md` | Envelopes, lanes, sockets, file transfer |
| `design-docs/Schedule.md` | Checkbacks, cron, Oban wake edge |
| `design-docs/Principal.md`, `design-docs/AuthZ.md` | Identity, groups, grants, CEL |
| `design-docs/AppConfiguration.md` | Config keys, scopes, encryption |
| `design-docs/Plugins.md`, `design-docs/plugins/FeishuAdapter.md` | Plugin contracts, the Lark adapter |
| `design-docs/I18n.md` | Locale catalogs |
| `docs/TradeoffsAndKnownLimits.md` | Any time behavior looks like a bug |
