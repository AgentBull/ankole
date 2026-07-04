# @ankole/agent-computer

Agent Computer is the Bun + TypeScript worker runtime for Ankole actor turns.
It runs the model loop, tools, browser/terminal/file behavior, skill access, and
worker-side RuntimeFabric lanes inside the Linux worker image.

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
- Worker-local tools: `todo`, browser tools, `command`,
  `interactive_terminal`, `read_file`, `patch`, `reply_attachment`,
  `skill_view`, `skill_append`, `check_back_later`, and `cron`.
- Workspace behavior: per-session roots under `/workspace/.sessions`, shared
  user files, agent-installed skill files, temporary files, tmux state, and
  browser artifacts.
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
- `src/runtime.ts` - startup environment parsing and lifecycle envelopes.
- `src/runtime_fabric.ts` - host JSON shape around kernel protobuf codecs.
- `src/runtime_fabric_sender.ts` - bounded retry for RuntimeFabric sends.
- `src/actor_lane.ts` and `src/turn_envelopes.ts` - actor envelope mapping.
- `src/rpc_lane.ts` - worker/control-plane RPC contracts.
- `src/file_transfer_lane.ts` - RuntimeFabric worker-file protocol.
- `src/workspace.ts` - per-turn workspace preparation and readiness checks.
- `src/core/turns/` - turn handlers, message shaping, ambient recognition,
  scheduling integration, and telemetry.
- `src/tools/` - model-facing tools bound to the container workspace.
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

Optional timeout tuning:

```text
ANKOLE_TEXT_TURN_TIMEOUT_MS
```

Optional capacity tuning:

```text
ANKOLE_MAX_CONCURRENT_TURNS=9
```

This is the per-worker cap on active turns. A turn is one currently running
actor execution; idle conversations do not consume slots, and the same
`{agent_uid, session_id}` remains serialized by the control plane. The default
of 9 is sized for the typical worker shape of at least 2 vCPU / 4 GiB: LLM
streaming is mostly I/O wait, while browser, Jupyter, and shell-heavy turns can
raise memory pressure. Lower it for tool-heavy workers; raise it after measuring
memory and latency under representative traffic.

Image/runtime path configuration, normally provided by the Dockerfile defaults:

```text
ANKOLE_WORKSPACE_ROOT=/workspace
ANKOLE_WORKSPACE_SESSIONS_ROOT=/workspace/.sessions
ANKOLE_SHARED_FS_ROOT=/workspace/shared
ANKOLE_USER_FILES_ROOT=/workspace/shared/user-files
ANKOLE_AGENT_INSTALLED_SKILLS_ROOT=/workspace/shared/skills/agents
ANKOLE_BUILTIN_SKILLS_ROOT=/repo/app/library/skills
ANKOLE_AGENT_COMPUTER_BUN_WORKDIR=/repo/app/agent_computer
```

Browser runtime:

```text
worker.remote_browser_cdp_config = nil
worker.local_browser_idle_ttl_ms = 1800000
```

By default the browser tools use the Chromium binary installed in the worker
image. Chromium is not started at container boot. The main Bun worker resolves
the effective browser backend for each turn; if no remote CDP config is present,
it lazily starts one headless Chromium sidecar through the in-process
`LocalSidecarManager`, polls `/json/version`, and persists CDP session metadata
under `/workspace/.sessions/<browser-session>/browser/session.json`.
Local session isolation uses Chromium CDP `Target.createBrowserContext`: each
browser session gets its own BrowserContext and page while sharing the same
Chromium process. The local adapter binds `Runtime.evaluate` to the main frame's
default execution context and waits primarily from Page lifecycle events instead
of high-frequency `document.readyState` polling. The local Chromium sidecar is
released after `worker.local_browser_idle_ttl_ms` of inactivity, defaulting to
30 minutes. Each browser action refreshes the idle timer; release is a
leak-prevention guard, not an aggressive cleanup policy.

Production `browser_*` tools call the Bun CDP engine directly. The
`ankole-browser` CLI remains a diagnostic/operator entrypoint, not the
model-facing runtime boundary. Tini remains PID 1 for signal forwarding and
zombie reaping.

Operators may set the encrypted scoped AppConfigure key
`worker.remote_browser_cdp_config` to override local Chromium with a remote
CDP endpoint for one agent or globally. The worker resolves browser runtime
settings through the generic `app_configure.resolve` RuntimeFabric RPC for the
active agent; decrypted headers and credentials stay in worker memory and are
only passed to the CDP connection.

Direct endpoint form:

```json
{
  "adapter": "cdp_endpoint",
  "endpoint_url": "wss://api.cloudflare.com/client/v4/accounts/.../browser-rendering/devtools/browser?keep_alive=600000",
  "headers": { "Authorization": "Bearer ..." },
  "connect_timeout_ms": 30000
}
```

Session-request form:

```json
{
  "adapter": "cdp_session_request",
  "request": {
    "url": "http://rayobrowse.lan:3000/connect?headless=true&os=windows",
    "method": "GET",
    "response": { "type": "text" }
  },
  "connect_timeout_ms": 120000
}
```

There is no HTTP fetch browser fallback. If local Chromium is unavailable and
no remote CDP config is set, browser tools fail closed in `browser_doctor` and
session launch.

`browser_run` may pass `ANKOLE_BROWSER_START_URL` to the helper script for that
single tool call; it is not a worker startup setting.

## Filesystem Contract

The image provides these stable worker-visible roots:

```text
/workspace
/workspace/.sessions
/workspace/shared
/workspace/shared/user-files
/workspace/shared/skills/agents
/repo/app/library/skills
```

For each turn, `prepareTurnWorkspace` creates:

```text
/workspace/.sessions/<agent_uid>/<session_id>/temp
/workspace/.sessions/<agent_uid>/<session_id>/user-files -> /workspace/shared/user-files
```

Built-in skills are read from `/repo/app/library/skills`. Agent-installed
skills are read from `/workspace/shared/skills/agents/<agent_uid>/...`. Skill
overlays are database-backed semantic data accessed through RuntimeFabric RPC,
not mutable files in the worker workspace.

## Docker Image

Build from the repository root:

```shell
docker build -f app/agent_computer/Dockerfile -t ankole-agent-computer:0.1.0 .
```

The image includes Bun, the built kernel N-API module, bubblewrap, Chromium,
Python/Jupyter/document tooling, LibreOffice, `zstd`, and the built-in Ankole
skill library.

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
  --worker-id worker-a
```

The rendered command creates the host workspace directories and runs a command
equivalent to:

```shell
docker run --rm \
  --cap-add SYS_ADMIN \
  --security-opt seccomp=unconfined \
  --security-opt systempaths=unconfined \
  --add-host host.docker.internal=host-gateway \
  -e WORKER_ID=worker-a \
  -e RUNTIME_FABRIC_URL='tcp://:worker_auth_key@host.docker.internal:6010' \
  -v "$PWD/.ankole-worker/shared:/workspace/shared" \
  -v "$PWD/.ankole-worker/sessions:/workspace/.sessions" \
  ankole-agent-computer:0.1.0
```

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

Package tests run inside the Docker image and mount the local `bin/`, `src/`,
and `test/` directories into the container. Build the image once before running
them:

```shell
docker build -f app/agent_computer/Dockerfile -t ankole-agent-computer:0.1.0 .
bun run agent-computer:test
```

Rebuild the image after changes to the Dockerfile, package dependencies, the
kernel build output, image-level tools, or built-in library files. Plain
TypeScript source/test changes and browser CLI/bin changes are picked up by the
package test volume mounts, so most browser runtime debugging can use the
no-build `bun run agent-computer:test` path.

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
feedback; it also mounts local `bin/` so CLI/bin changes can be exercised
without rebuilding the image. The second mounts `/workspace` so artifacts
remain inspectable after failures.

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
