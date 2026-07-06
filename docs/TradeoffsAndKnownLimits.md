# Tradeoffs and Known Limits

This document records accepted tradeoffs, deployment constraints, and known
limits in Ankole. It is a living engineering note, not a replacement for the
design documents under `docs/design-docs/`.

Use it to answer two questions before changing the system:

- Is this behavior an intentional boundary?
- If it is intentional, what must an operator or implementer know?

## Installation Boundary

Ankole currently treats one installation as the operating domain. It is not
modeled as a SaaS-style tenant boundary where every customer is isolated from
every other customer by default.

That keeps the control plane and worker model simpler:

- PostgreSQL owns installation-wide durable state.
- Runtime workers are first-party processes launched by the operator.
- Principal/AuthZ still matters inside the installation, but it is not a
  substitute for hard infrastructure-level tenant isolation.

Stronger tenant isolation is outside this boundary. It requires a separate
installation/runtime isolation design.

## Worker and Sandbox Trust

An Agent Computer worker is a trusted first-party runtime node. It is not itself
the sandbox.

The sandbox is the `bubblewrap` execution boundary inside the worker. This
distinction is deliberate:

- the worker may read app configuration and request live credentials;
- live secrets may exist in worker memory while a turn is running;
- secrets must not be persisted into PostgreSQL payloads, workspace files,
  skill overlays, progress rows, AI gateway requests, or debug artifacts;
- the control plane still owns final commit authority, turn fencing, provider
  outbox truth, and the durable AI message log.

This means a worker compromise is serious, but it is not the same failure mode
as code escaping a single `bubblewrap` command sandbox. The worker is part of
the trusted computing base; the sandbox is the untrusted tool/process boundary.

## Bubblewrap Deployment Modes

Ankole prefers strong `bubblewrap` mode. Strong mode mounts a fresh `/proc`
inside the inner sandbox.

Nested container deployments can block that mode. This is constrained by the
same class of kernel/container-runtime issues described in
[containers/bubblewrap#505](https://github.com/containers/bubblewrap/issues/505):
running `bubblewrap` inside Docker or Kubernetes may require explicit container
security settings.

The current Docker e2e shape uses flags equivalent to:

```text
--cap-add SYS_ADMIN
--security-opt seccomp=unconfined
--security-opt systempaths=unconfined
```

Kubernetes deployments need an equivalent allowance for the same kernel surface,
often including an unmasked `/proc` policy and compatible seccomp/capability
settings. The exact production manifest should be reviewed against the target
cluster policy.

If strong mode is unavailable, the worker may downgrade to weak mode. Weak mode
is still `bubblewrap`; it still uses namespace and filesystem isolation, but it
binds the already-isolated container `/proc` instead of mounting a fresh procfs
for the inner sandbox. This is weaker than strong mode, but it is not an
unsandboxed host fallback. Startup logs must make the downgrade visible.

If neither strong nor weak mode is available, the worker should fail rather than
running tool commands without `bubblewrap`.

## Multi-Node Workers and Shared Files

Workers can be deployed across multiple nodes, but multi-node deployment needs a
shared file layer when user files or agent-installed skills must be visible
across workers.

Practical options include NFS, S3FS, a Kubernetes CSI-backed shared filesystem,
or another deployment-specific shared mount. The important contract is not the
specific storage product; it is that the worker-visible roots are coherent for
the workers that may run turns for the same agent.

The durable split is:

- PostgreSQL owns semantic state: conversations, turns, proposals, outbox rows,
  skill registry/enablement, skill overlays, and file observations.
- Shared files own large or user-editable bytes: user files and
  agent-installed skill files.
- RuntimeFabric worker-file lane moves bytes between the control plane and a
  worker-visible root when needed.

The control plane should not become an implicit NFS scanner. Installed-skill
rows and file observations should be refreshed through explicit worker/file-lane
or registry flows. File presence alone is not the domain source of truth.

Single-node deployments may use local directories for the same roots, but that
choice should not leak into API semantics.

## RuntimeFabric and ZeroMQ

Ankole uses ZeroMQ as the live RuntimeFabric between the control plane and
workers. It supports:

- actor turn/control traffic;
- duplex RPC for worker requests into control-plane semantic state;
- worker file management for byte transfer.

ZeroMQ should not be understood as a durable message queue. It is closer to a
better socket abstraction for connected workers: route identities, explicit
send failure, multipart frames, bounded buffering, and a shared connection for
multiple lanes.

The durable split is:

- ZeroMQ carries live routing, backpressure, worker liveness, RPC envelopes, and
  file frames.
- PostgreSQL journals facts required for replay, fencing, reconciliation, and
  final commit.

The system must not recover actor state by asking ZeroMQ what happened. If a
fact matters after process death, it belongs in PostgreSQL.

See `docs/design-docs/RuntimeFabric.md` for lane and frame details.

## RuntimeFabric Is the Physical Transport Name

The physical transport surface is RuntimeFabric. `ActorBus` is domain vocabulary
only when it describes actor semantics. It is not a second transport API,
environment-variable family, or compatibility layer.

## PostgreSQL and Commit Authority

The control plane owns durable semantic state:

- the actor event journal (`actor_events`), with completion recorded as the
  `completed_at` timestamp — there is no consumption table;
- delivery fences, revisions, and session activations;
- the AIGateway stateful message log (`ai_gateway_messages` and
  `ai_gateway_conversations`);
- provider-visible outbox rows;
- app configuration and provider configuration;
- skill registry, enablement, and overlay metadata.

Workers execute tools, request semantic state, and transfer files, but they
never write the AI message log, the conversations table, or the outbox. Final
AI output lands through AIGateway's terminal commit: one control-plane
transaction that checks the delivery fence, marks the final message row
`complete`, sets `actor_events.completed_at`, and clears the live delivery —
committed before the terminal frame reaches the worker.

This is why `mailbox_updated`, worker progress, and live fabric delivery are not
durable ownership signals by themselves. They are runtime signals around
PostgreSQL-owned facts.

## Memory V1

Memory belongs to the channel/place where it was observed. Layer A curated
notes are scoped to `{agent_uid, signal_channel_id}` and exposed only through
the current-channel `memory_note` tool. The limits are intentional: at most 40
notes per agent/channel and 500 characters per note. When the list is full, the
agent must merge, update, or forget before saving another note.

Historical recall uses `signal_gateway_entries` as ground truth. ParadeDB BM25
requires a unique key field, so `signal_gateway_entries.document_id` is enforced
unique before it can be used as `key_field='document_id'`. The document id stays
derived from `{signal_channel_id, source_entry_id}`; the database constraint is
the guarantee, not a comment in the projection code.

Phase 1 is BM25 search plus browse and has no model-profile dependency. Phase 2
adds channel episodes and embeddings, but only when `memory.recall.model_agent_uid`
points at an existing agent with both `light` and `embedding` profiles. If that
model owner is missing or incomplete, summary and embedding jobs report
unavailable and do not advance cursors. Invalid summarizer output is retried,
but after the worker exhausts its attempts the window is skipped, the cursor is
advanced, and telemetry records the skipped window so a poison window cannot
burn model calls forever. A valid episode whose embedding fails is kept with
`embedding_state = 'failed'`; search degrades to BM25 and reports the vector-route
degradation.

Current-channel `memory_search` deliberately excludes hot context: entries from
roughly the last 2 hours or latest 80 observed current-channel entries are left
out because they should already be in the active turn context. Use
`memory_browse` with an explicit time range when the caller needs exact recent
transcript rows. Cross-channel search is limited to channels observed through
`actor_events`, and non-DM current channels exclude `im_dm` sources.

Episode scanning also skips channels whose entire unprocessed tail is still
inside the young-tail guard. Those rows remain in `signal_gateway_entries` and
become eligible once they age out or the backlog threshold is reached; this
avoids low-volume channels producing empty summarizer jobs forever.

Memory token budgeting uses the kernel `o200k_base` estimator from
`tiktoken-rs`, independent of provider/model selection. AIGateway compaction
is separate: it uses upstream provider usage metadata recorded on history
messages, except for the pre-compaction nudge that asks the normal agent/tool
loop to persist durable facts via `memory_note` before automatic compaction
proceeds.

Layer A notes are intentionally injected into the system prompt for the current
channel. That makes them powerful and also means a channel participant who can
cause the agent to save a note can create durable prompt pressure. This is an
accepted v1 tradeoff, mitigated by current-channel scope, the 40-note cap,
explicit list/update/forget tools, and operator-visible persisted rows.

## Provider Configuration and Credentials

Provider configuration can be durable control-plane state. Live provider
credentials are different.

The accepted boundary is:

- durable provider metadata and model profile wiring may live in PostgreSQL;
- external provider secrets stay in the control plane;
- workers request an agent-scoped AIGateway API key over RuntimeFabric/ZMQ RPC
  when needed;
- worker-side AIGateway credentials remain memory-only;
- secrets must not be written into workspace files, shared files, skill
  overlays, progress payloads, proposals, or logs.

Operator-facing worker authentication should expose one concept: the worker
`pre auth token`. ZAP, PLAIN username/password mapping, and key revision details
are transport implementation details unless the task is specifically about the
transport layer.

The current auth story assumes first-party workers and private fabric endpoints.
CURVE/TLS, public worker admission, and hostile-network hardening are not part
of the current mainline.

The 30-day agent-scoped AIGateway key is the only AI credential a worker ever
holds. External provider secrets never reach worker memory.

## China-Market Provider Compatibility Headers

The `zai_coding_plan` provider keeps a desktop-client-compatible default
`User-Agent` because the upstream coding endpoint has been observed to behave
like a client-oriented compatibility surface. This is a pragmatic compatibility
default, not an identity or compliance guarantee.

Operators can override `connection_options.user_agent` for that provider. If
the upstream endpoint no longer requires a desktop-style UA, the configured
value should be replaced with an Ankole-specific UA or removed by setting an
empty value only after a real-provider smoke confirms the endpoint still works.

## AIGateway Stateful Responses

These are settled decisions of the stateful Responses design, not open items.
See `docs/design-docs/AIGateway.md` for the mechanism.

Continuation is derived, never stored. `ai_gateway_conversations` keeps no
active-generation lease and no "current position" pointer; the continuation
base is re-derived from the message graph as the latest visible leaf. A stored
pointer would be a second source of truth that drifts from the graph on
compaction, retraction, branching, and reconnect. Deriving costs a query;
repairing a drifted pointer costs correctness.

There is no half-stream recovery. The log keeps no stable item snapshots and no
content version counter. A broken provider stream costs one round: the stale
`generating` row goes to `error` by `updated_at` staleness, and the round is
re-sent from the last `complete` anchor. Retry is a new `actor_event_id` with
`retry_of_actor_event_id`, not a resurrected stream.

Token budgeting for automatic compaction uses upstream provider usage metadata
already recorded on history messages. AIGateway does not estimate these counts
from message content; when usage metadata is absent, it is not replaced by a
character-length heuristic.

Compaction covers text-bearing items only. A media item without an auditable
summary or durable ref stays outside the covered prefix. When `truncation=auto`
drops media or opaque items from provider-facing input, the run records them in
`metadata.auto_truncation.dropped_opaque_messages`; media is never silently
lost, but it is also not summarized yet.

Retracted rows are skipped without replacement. Projection omits a retracted
row's content and generates no note for the model. The audit fact stays on the
row; the model simply no longer sees it.

The security model is two rules: the 30-day per-agent token proves agent
identity, and every query filters by that agent's `agent_uid`. There are no
per-event tokens, no claims, no actor-event liveness checks, and no generation
lease. Finer-grained permission layers here are treated as harmful complexity,
not as missing features — the worker fleet is first-party and already inside
the trusted fabric.

There is no `DELETE /responses/:id` and no cancel endpoint. IM deletion has its
own mapping in SignalsGateway, and a running generation is cancelled through
actor event control. Stateless responses use transport-only `tmp_resp_*` ids
that can never be retrieved or chained.

One WebSocket connection runs one in-flight response, and `background=true` is
unsupported. The worker loop is strictly sequential per actor event; parallel
generations for one session are excluded at the ActorRuntime layer, not by an
AIGateway lock.

## Rust Kernel Boundary

The Rust kernel is a business-runtime component, not merely a utility crate for
NIF/N-API glue.

`app/kernel` should own shared native mechanisms where exact parity matters
across host runtimes.

It is appropriate for Rust to own logic where Rust gives the system a better
boundary:

- ZeroMQ socket ownership and thread affinity;
- RuntimeFabric framing and protobuf validation;
- ZAP/auth mechanics;
- native performance-sensitive checks;
- deterministic validators, normalizers, matchers, evaluators, or decision
  algorithms that would otherwise need separate Elixir and Bun implementations;
- protocol invariants shared by Elixir and Bun, including the worker-file lane
  zstd block codec (compress/decompress one independent frame per `DATA` chunk).

Placement should bias toward the kernel when a behavior can be expressed as a
deterministic function over explicit inputs without storage, network, runtime
process state, or product lifecycle ownership. Shared behavior should live in
the Rust core first, with Rustler and napi-rs bindings translating host types
and errors only.

The limit is also explicit: Rust should not become the PostgreSQL domain owner.
Elixir owns durable control-plane semantics, schema changes, commits, and
recovery facts. Bun owns worker-side AI/tool runtime behavior. Rust owns the
shared native runtime boundary where that is the simpler and safer
implementation.

## Session Actor Isolation

The stable actor identity is:

```text
session actor = {agent_uid, session_id}
```

The current isolation model is one active Agent Computer session, and therefore
one `bubblewrap` sandbox family, per active session actor.

Runtime-local state is session-local:

- `/workspace/temp`;
- tmux/session process state;
- browser profile;
- Jupyter state;
- background processes;
- temporary credentials.

Workplace files are intentionally more shared. `/workspace/user-files` and
agent-installed skill files may be visible across sessions of the same agent.
That is a product choice: sessions isolate live execution state, not every file
the agent can see.

## Skills and Overlays

Tool and skill exposure is allowlisted. Do not infer a broader toolset just
because the worker can technically run a command.

The current tool surface is intentionally narrow:

- `todo`;
- browser tools;
- `patch`;
- `read_file`;
- `interactive_terminal`;
- `command`;
- `codex_delegate`;
- `reply_attachment`;
- `skill_view`;
- `skill_append`;
- `check_back_later`;
- `cron`.

### Tool Runtime Bounds

Ankole does not add a universal worker-side wall-clock timeout around every
tool call. That is intentional and follows Hermes as the semantic reference:
tools have their own lifecycle contracts, and the AI agent inactivity watchdog
is a model/provider no-activity watchdog, not a blanket tool killer.

For shell execution, the `command` tool has a foreground default of `180s`.
Background command runs have no default command timeout. They are tracked by
workspace and execution scope, expose `status`, `kill`, and `list`, and keep a
bounded output tail. The in-memory registry evicts only finished entries when
it exceeds its capacity; running background commands are not evicted or killed
by that capacity rule. A caller can still pass `timeout` to opt into an
explicit command budget.

Codex delegation is a separate managed tool path. `codex_delegate` starts a
Codex app-server subprocess and uses request-class timeouts rather than one
global delegation timeout: `initialize` is `15s`, `thread/start` is `30s`, and
generic app-server requests are `60s`. These are deliberately a little wider
than Hermes' app-server request classes because Ankole's typical delegated
tasks are longer and more likely to cold-start.

The current skill surface is also explicit:

- `jupyter-live-kernel`;
- `nano-pdf`;
- `powerpoint`.

Skill storage follows the shared-file/PG split:

- built-in skills live in the repo/image;
- agent-installed skills live as real files under the worker-visible shared
  skills root;
- registry, enablement, overlays, observations, and hashes belong in
  PostgreSQL;
- `skill_view` reads the base skill file and merges the database overlay;
- `skill_append` replaces the database overlay for that skill.

## SignalsGateway Scope

SignalsGateway is the provider ingress and provider-visible outbox boundary. It
is not the worker runtime, not the actor scheduler, and not a universal audit
system.

It owns:

- normalized provider ingress;
- binding admission and group-message policy;
- provider mirror updates;
- actor event construction;
- live streamed-reply preview delivery (`AIReplyPreview`) and final-reply
  mirror recovery (`RecoveryScan`);
- provider-visible outbox execution.

It does not own:

- the AIGateway Responses loop, message log, or compaction;
- session actor scheduling;
- final AI output commit;
- arbitrary rule routing;
- plugin discovery or provider setup persistence;
- universal raw-provider audit logging.

Provider ack and provider-visible reply must stay separate. A webhook HTTP 200
means transport acknowledgement after the gateway has accepted or rejected the
fact; it is not an agent reply.

Streamed IM delivery is at-least-once and best-effort, not exactly-once.
Preview continuity is transient: the provider-side preview message id is never
persisted into message rows, and a dead preview process leaves a stale card
until recovery delivers the final content. A reply can be re-sent in rare crash
windows. Error terminals are not rendered to IM at all in the current policy —
a failed generation posts no new provider message.

Streamed AI reply recovery is best-effort in v1. The `RecoveryScan` process is a
single control-plane GenServer, and it only scans terminal AI messages older than
the configured grace window. That window is the accepted protection against
racing the live preview/finalize path. Do not add a database or advisory-lock
mutex around recovery resend in the current single-instance deployment; it would
not turn the provider-visible path into exactly-once delivery and would add a
second coordination layer. If Ankole later runs multiple recovery scanners, add
an explicit resend mutex as part of that multi-instance deployment design.

The e2e assertion for a normal streamed reply is the terminal
`ai_gateway_messages` row plus the `signal_gateway_entries.ai_message_id` final mirror.
It is not an outbox row; only explicit side effects assert the outbox.

See `docs/design-docs/SignalsGateway.md` for the detailed ingress/outbox model.

## Frontend and Control Plane Shell

Phoenix is the control-plane web host and HTML shell. It owns routing, auth,
sessions, setup entry points, and static asset mounting.

Vite owns the SPA bundles under `app/webapps`. The current frontend split should
stay:

- Phoenix renders the HTML shell and serves the authenticated route boundary.
- Vite builds JavaScript/CSS chunks for SPA entrypoints.
- `libs/uikit` is the shared UI package.
- `phoenix_vite` is reference material, not a dependency to add by default.

Generated API clients and generated frontend surfaces should be treated as
generated artifacts. Do not hand-edit generated output unless the generation
pipeline itself is the task.

## Worker E2E and Validation

Worker/runtime e2e tests are intentionally separate from the default test suite.
They require real runtime dependencies such as Docker, the Agent Computer image,
RuntimeFabric, AIGateway configuration, and sometimes real provider access.

The normal rule is:

- keep `mix test` focused on normal control-plane tests;
- run worker/container e2e through explicit Mix/Bun commands;
- validate runtime changes with the smallest package-local checks first;
- use real provider/container tests before claiming the main chain truly works.

Static review is useful for finding inconsistencies, but it does not prove the
runtime chain. A runnable main-chain claim needs live validation.

## Current Non-Goals and Limits

These surfaces are not part of the current mainline:

- public untrusted worker admission;
- hostile-network RuntimeFabric hardening beyond the current private endpoint
  assumption;
- arbitrary user-configured rule routing for SignalsGateway;
- a durable ZeroMQ queue;
- a control-plane NFS scanner as semantic truth;
- workflow/subagent/search surfaces beyond the schedule primitives;
- provider-generated synchronous webhook response bodies;
- hidden text scraping for outbound file attachments;
- multi-instance recovery-scan claim/lock coordination;
- AIGateway hosted server-side tools (`ankole:*` extension slugs);
- named branch projections over the message graph;
- the OpenAI Conversations API public object surface;
- response delete/cancel endpoints;
- non-AI actor-event executors (a future workflow runtime owns its own durable
  run tables instead of writing into `ai_gateway_messages`).

When one of these becomes product work, it needs its own design and validation
path.
