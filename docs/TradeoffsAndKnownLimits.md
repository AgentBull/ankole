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
  skill overlays, progress rows, final proposals, or debug artifacts;
- the control plane still owns final commit authority, turn fencing, provider
  outbox truth, and durable transcript writes.

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

- actor input journals and consumption facts;
- turn status, revisions, and fences;
- assistant transcript writes;
- provider-visible outbox rows;
- app configuration and provider configuration;
- skill registry, enablement, and overlay metadata.

Workers may propose effects, request semantic state, and transfer files, but
they do not directly own final transcript commit. Final assistant output lands
through a control-plane transaction that checks turn fences and writes durable
state.

This is why `mailbox_updated`, worker progress, and live fabric delivery are not
durable ownership signals by themselves. They are runtime signals around
PostgreSQL-owned facts.

## Provider Configuration and Credentials

Provider configuration can be durable control-plane state. Live provider
credentials are different.

The accepted boundary is:

- durable provider metadata and model profile wiring may live in PostgreSQL;
- live secrets are requested by the worker when needed;
- credential handoff happens over RuntimeFabric/ZMQ RPC;
- worker-side credentials remain memory-only;
- secrets must not be written into workspace files, shared files, skill
  overlays, progress payloads, proposals, or logs.

Operator-facing worker authentication should expose one concept: the worker
`pre auth token`. ZAP, PLAIN username/password mapping, and key revision details
are transport implementation details unless the task is specifically about the
transport layer.

The current auth story assumes first-party workers and private fabric endpoints.
CURVE/TLS, public worker admission, and hostile-network hardening are not part
of the current mainline.

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
- protocol invariants shared by Elixir and Bun.

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
- `command`.

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
- actor input construction;
- provider-visible outbox execution.

It does not own:

- worker-internal AI SDK loops;
- session actor scheduling;
- final assistant commit;
- arbitrary rule routing;
- plugin discovery or provider setup persistence;
- universal raw-provider audit logging.

Provider ack and provider-visible reply must stay separate. A webhook HTTP 200
means transport acknowledgement after the gateway has accepted or rejected the
fact; it is not an agent reply.

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
RuntimeFabric, and sometimes real provider credentials.

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
- workflow/subagent/search/cron surfaces;
- provider-generated synchronous webhook response bodies;
- hidden text scraping for outbound file attachments.

When one of these becomes product work, it needs its own design and validation
path.
