# @ankole/agent-computer

Agent Computer is the Bun + TypeScript worker runtime for Ankole actor turns.
It runs the model loop, foreground computer tools, Skill access, native MCP
consumption, and worker-side RuntimeFabric lanes inside the Linux worker image.

This package is not a standalone local CLI. `bun run dev` and `bun run start`
intentionally fail because the worker depends on the Docker image contract:
native kernel bindings, bubblewrap, Chromium, Python/Jupyter/document tooling,
ZeroMQ transport, and the `/workspace` filesystem layout.

## Runtime Boundary

Agent Computer is a trusted first-party runtime node, not the sandbox itself.
The sandbox for model-facing command execution is `bubblewrap` inside the
worker. The control plane still owns durable state, final commit authority,
actor event completion, provider outbox writes, AppConfigure, credentials, and
PostgreSQL recovery facts.

The worker may request semantic state over RuntimeFabric RPC, but it must not
invent or persist control-plane-owned state locally. Live provider credentials
are requested only when needed, kept in memory for the turn, and must not be
written to logs, workspace files, shared files, skill overlays, or progress
payloads.

## What This Package Owns

- Worker process lifecycle: connect to RuntimeFabric, announce readiness,
  heartbeat, advertise capacity, run bounded concurrent turns, and handle retry
  control.
- Core turn execution: model/provider construction, prompt assembly, message
  shaping, tool loops, and ambient recognizer turns.
- Worker-local tools: `todo`; foreground `command`, `read_file`, `replace`, `patch`, and
  `reply_attachment`; `background_agent_job`; `clarify`; `web_search` and
  `web_fetch`; the Brain tools `memory_search`, `memory_open`, `memory_update`,
  `memory_browse`, and `memory_health_check`; the Skill tools `skill_view`,
  `skill_append`, and `skill_replace`; `check_back_later` and `cron`; and one
  conditional, Skill-allowlisted `mcp` surface.
- Workspace behavior: per-session roots under `/workspace/.sessions`, shared
  user files, agent-installed Skill files, temporary files, and rebuildable Job
  runtime files.
- RuntimeFabric worker lanes: actor envelopes, worker RPC replies, worker RPC
  requests to the control plane, and file transfer frames.

## What It Does Not Own

- PostgreSQL schema, durable actor state, transcript commits, provider mirror
  rows, outbox execution, AppConfigure, or Principal/AuthZ.
- Worker admission policy beyond presenting `WORKER_ID` and the worker auth
  key embedded in `RUNTIME_FABRIC_URL`.
- Enabling skills, assigning tools, or synthesizing fake
  `/workspace/library-containers` paths. Enabled skill metadata comes from the
  control plane; `skill_view` reads real built-in or installed skill files.
- Host execution. Model-facing commands run through bubblewrap in the worker
  container.

## Source Map

- `src/main.ts` - worker event loop and turn dispatch.
- `src/worker/` - startup environment parsing, lifecycle envelopes, workspace
  preparation, and readiness checks.
- `src/skills/` - installed skill filesystem observation, fingerprinting, and
  pre-turn registry sync.
- `src/fabric/` - RuntimeFabric envelope shape, kernel protobuf codec adapter,
  turn envelope builders, and bounded retry sender.
- `src/lanes/` - actor, RPC, and worker-file lane contracts.
- `src/core/turns/` - turn handlers, message shaping, ambient recognition,
  scheduling integration, and telemetry.
- `src/tools/` - model-facing tools bound to the container workspace, organized
  by feature.
- `src/prompts/` - system, ambient, and skill prompts.
- `test/` - package-local Bun tests. They are run inside the worker image.

## Runtime Contract

Required environment:

```text
WORKER_ID=worker-a
RUNTIME_FABRIC_URL=tcp://:worker_auth_key@host:port
```

`RUNTIME_FABRIC_URL` must use `tcp://`, must not include a username, and must
carry the worker auth key as the URL password. `WORKER_ID` is the worker
identity.

Forbidden environment:

```text
DATABASE_URL
ANKOLE_AGENT_UID
ANKOLE_SESSION_ID
ANKOLE_ACTOR_EPOCH
```

The worker is pool-scoped, not actor-scoped. Actor identity arrives in each
`turn_start` envelope.

Agent runtime policy is configured through scoped AppConfigure keys, not worker
environment variables:

```text
ai_agent.inactivity_timeout_ms
ai_agent.max_output_tokens
```

`ai_agent.inactivity_timeout_ms` is a model/provider no-activity watchdog. It is
not a wall-clock turn cap, and it is not a promise that every running tool has a
hidden timeout. Tool calls own their runtime lifecycle while they are active.

The model-facing `command` tool is foreground-only and defaults to `180s`.
Persistent, interactive, or asynchronous work goes through
`background_agent_job(start)`, which commits a durable BackgroundAgentJob and
returns immediately. The same tool exposes `list`/`status`/`steer`/`stop`.
CodexRunner uses durable execution state and commits completion before waking
the owner session. Jobs have no wall-clock cap; a workflow-specific deadline is
owned by the caller, which may steer or stop the Job. Individual JSON-RPC requests use `15s` for
`initialize`, `30s` for `thread/start`, and `60s` for other requests.

Optional capacity tuning:

```text
ANKOLE_MAX_CONCURRENT_TURNS=9
```

This is the per-worker cap on active turns. A turn is one currently running
actor execution; idle conversations do not consume slots, and the same
`{agent_uid, session_id}` remains serialized by the control plane. The default
of 9 is sized for the typical worker shape of at least 2 vCPU / 4 GiB: LLM
streaming is mostly I/O wait, while Jupyter, document, MCP stdio, and shell-heavy
turns can raise memory pressure. Lower it for tool-heavy workers; raise it after
measuring memory and latency under representative traffic.

Image/runtime path configuration, normally provided by the Dockerfile defaults:

```text
ANKOLE_WORKSPACE_ROOT=/workspace
ANKOLE_WORKSPACE_SESSIONS_ROOT=/workspace/.sessions
ANKOLE_SHARED_FS_ROOT=/workspace/shared
ANKOLE_USER_FILES_ROOT=/workspace/shared/user-files
ANKOLE_AGENT_INSTALLED_SKILLS_ROOT=/workspace/shared/skills/agents
ANKOLE_BUILTIN_SKILLS_ROOT=/repo/app/library
ANKOLE_INTERNAL_SKILLS_ROOT=/repo/internals/skills  # optional internal image only
ANKOLE_AGENT_COMPUTER_BUN_WORKDIR=/repo/app/agent_computer
ANKOLE_BROWSER_NODE=/opt/ankole-browser/node/bin/node
ANKOLE_BROWSER_DAEMON_ENTRY=/opt/ankole-browser/dist/daemon/main.js
ANKOLE_BROWSER_RUNNER=/opt/ankole-browser/dist/runner/bootstrap.js
ANKOLE_BROWSER_CHROMIUM_EXECUTABLE=/opt/ankole-browser/browsers/chromium/chrome-headless-shell
ANKOLE_BROWSER_MAX_ACTIVE_BROWSERS=4  # optional worker-local live-browser cap
```

Operator-managed variables are resolved per agent through `worker_env.resolve`
and injected into foreground commands, MCP stdio servers, and Codex Job
processes. An enabled inline Skill may declare MCP dependencies in
`agents/openai.yaml`. Agent Computer consumes them with the official MCP SDK and
exposes one `mcp` tool with `list`, single-tool `describe`, and single-tool
`call`. HTTP bearer values come from the declared WorkerEnv variable; the value
is never written to the Skill or workspace. Every remote catalog or call uses a
fresh connection that closes after the operation.

The main Agent has no direct browser dynamic tool. It may route interactive
work through the default long-running Browser Skill to a BackgroundAgentJob.
Immediately before that Job's Codex app-server starts, Agent Computer
materializes one persistent opaque route and projects only final
`ANKOLE_BROWSER_*` values plus read-only daemon-socket/material binds. Codex
uses the preconfigured `ankole-browser` CLI for short commands or LLM-authored
Playwright scripts; it never resolves backend/profile source settings.

`web_fetch` remains provider-first and uses a separate short-lived rendered
route only as a fallback. Agent Computer materializes the route immediately
before invoking `ankole-browser fetch`, returns the normalized page text, and
purges the route in `finally`. In both paths, source variables such as
`BROWSER_BACKEND_JSON` and `BROWSER_PROFILE_SEED_PATH` are removed before the
CLI or Codex process starts. `ankole-browser` receives only opaque routing and
final data-plane material and has no control-plane semantics.

BackgroundAgentJobs may select Agent Plugins from
`/repo/app/library/agent-plugins`. Each Job stores only selected Plugin IDs and
standalone Skill names. Before every execution or resume, CodexRunner resolves
the current enabled catalogs, installs the current complete packages, applies
every member's current state through `skills/config/write` by absolute
discovered path, and verifies the final `skills/list` result.

## Filesystem Contract

The image provides these stable worker-visible roots:

```text
/workspace
/workspace/.sessions
/workspace/shared
/workspace/shared/user-files
/workspace/shared/skills/agents
/repo/app/library
/repo/app/library/agent-plugins
```

For each turn, `prepareTurnWorkspace` creates:

```text
/workspace/.sessions/<agent_uid>/<session_id>/temp
/workspace/.sessions/<agent_uid>/<session_id>/user-files -> /workspace/shared/user-files
```

Built-in standalone and Agent Plugin member Skills use root-relative locators
under `/repo/app/library`; Agent Plugin packages are read from
`/repo/app/library/agent-plugins`; internal images may also mount
`/repo/internals/skills`. Agent-installed skills are read from
`/workspace/shared/skills/agents/<agent_uid>/...`. Before dispatching turn
handlers, the worker scans that installed-skill directory and sends
`skills.installed.replace` observations when the fingerprint changed. Skill
overlays are database-backed semantic data accessed through RuntimeFabric RPC,
not mutable files in the worker workspace.

## Docker Image

Build from the repository root:

```shell
docker build \
  --build-arg "BASE_IMAGE=$(tr -d '\n' < app/agent_computer/base-image.lock)" \
  -f app/agent_computer/Dockerfile -t ankole-agent-computer:0.1.0 .
```

`base-image.lock` is the digest-pinned development base. Production publication
does not use that lock: the paired runtime-image workflow builds the base from
the same Git revision and passes its resolved digest explicitly. A development
lock update is an explicit follow-up to a verified base publication.

The image includes Bun, the built kernel N-API module, bubblewrap, a private
Node runtime with pinned Playwright and matching Chromium for
`ankole-browser`, Python/Jupyter/document tooling, LibreOffice, `zstd`, and the
built-in Ankole Skill library. The private Node path does not alter the image's
global `node -> bun` convention.

For strong bubblewrap mode, run Docker with:

```text
--cap-add SYS_ADMIN
--security-opt seccomp=unconfined
--security-opt systempaths=unconfined
```

If strong bubblewrap is blocked by the container runtime, the worker may
downgrade to weak bubblewrap and emits a startup warning. It does not fall back
to unsandboxed model-facing command execution.

## Starting A Worker

Prefer the control-plane bootstrap task because it resolves the current global
worker auth key from AppConfigure and renders the mount contract:

```shell
cd app/control_plane
mix ankole.actor_runtime.worker_bootstrap \
  --endpoint tcp://127.0.0.1:6010 \
  --worker-id worker-a \
  --image ankole-agent-computer:0.1.0
```

The task resolves the current worker auth key and renders the versioned
`WorkerBootstrap` contract as a safe Docker command. The same contract supplies
the security settings, RuntimeFabric environment, and canonical shared/session
mounts used by local development and real worker E2E.

## Development

Install dependencies from the repository root:

```shell
bun install
```

Useful package commands:

```shell
bun run agent-computer:type-check
bun run --filter @ankole/agent-computer fmt:check
bun run --filter @ankole/agent-computer lint
```

Package tests ask Devkit for the control-plane `container` bootstrap contract,
then add only the local `src/`/`test/` mounts and Bun test command. Build the
image once before running them:

```shell
docker build \
  --build-arg "BASE_IMAGE=$(tr -d '\n' < app/agent_computer/base-image.lock)" \
  -f app/agent_computer/Dockerfile -t ankole-agent-computer:0.1.0 .
bun run agent-computer:test
```

Rebuild the image after changes to the Dockerfile, package dependencies, the
kernel build output, image-level tools, or built-in library files. Plain
TypeScript source/test changes are picked up by the package test volume mounts,
so most tool and rendered-fetch debugging can use the no-build `bun run
agent-computer:test` path.

## Worker E2E

The e2e suites exercise the real Docker worker, RuntimeFabric, worker
admission, turn delivery, RPC, tool execution, and the final commit path,
entered through a network-level fake Feishu server and the real Lark adapter.
The single entrypoint lives at the repository root:

```shell
tools/e2e/run            # gate suites (includes worker admission + computer tools)
tools/e2e/run --chaos    # worker kill / fabric restart recovery
```

Real provider coverage is excluded by default. To include it:

```shell
ANKOLE_REAL_LLM_E2E=1 OPENROUTER_API_KEY=... tools/e2e/run --real-llm
```

The e2e image name is currently `ankole-agent-computer:0.1.0`; preflight
builds it automatically when missing.

Development-only e2e helpers:

```text
ANKOLE_E2E_MOUNT_AGENT_COMPUTER_SRC=1
ANKOLE_E2E_HOST_WORKSPACE_ROOT=/tmp/ankole-worker-workspace
```

The first mounts local `src/` into the worker image for faster edit/run
feedback. The second retains each worker's isolated canonical workspace under
`<root>/<container-name>/`: artifacts are in `shared/user-files/`, installed
skills are in `shared/skills/agents/`, and session state is in `sessions/`.

## Logs And Failure Signals

The worker writes structured JSON lines to stdout/stderr. Common startup
failures are intentional guardrails:

- `Agent Computer worker must run inside the Linux Docker image` - host Bun
  execution was attempted.
- `RUNTIME_FABRIC_URL is required` - the worker cannot connect to RuntimeFabric.
- `RUNTIME_FABRIC_URL must be tcp://:worker_auth_key@host:port` - malformed
  endpoint/auth URL.
- `DATABASE_URL must not be set on an agent computer worker` - the worker was
  given direct database authority.
- `ANKOLE_AGENT_UID must not be set on an agent computer worker` - actor state
  was passed at process boot instead of via `turn_start`.
- `worker.bubblewrap_warning` - strong bubblewrap is unavailable and weak mode
  is being used.

## Related Docs

- `../../README.md` - repository overview and common development commands.
- `../../docs/TradeoffsAndKnownLimits.md` - accepted runtime and worker
  tradeoffs.
- `../../docs/design-docs/RuntimeFabric.md` - RuntimeFabric lanes, envelopes,
  and transport details.
- `../../docs/design-docs/MCPBackedSkills.md` - native MCP discovery,
  allowlisting, connection lifetime, and WorkerEnv credential boundaries.
