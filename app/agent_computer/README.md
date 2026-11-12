# @ankole/agent-computer

Agent Computer is the Bun and TypeScript Worker runtime for Ankole execution.
Inside the Linux Worker image, it runs environment tools, materializes Skills,
manages `mcporter` configuration for each invocation, executes `CodexRunner`
Jobs, routes browser sessions, and serves the Worker side of
RuntimeFabric lanes. Meanwhile, the Elixir control plane runs the main Agent
loop and tracks its progress.

The Worker image bundles Chromium, Python, Jupyter, document tooling, and the
Worker supervisor. When a managed Agent is created, the control plane
provisions its Worker in the background. A user can also connect a device to
run a background Job for an Agent they own.

## Connect a device

Pair a device with the code from **Account → My devices** in Pod (where the
owner can also bind owned AI colleagues and inspect live binding health). Run
the launcher on the device that will execute the work. It needs a local Docker
Engine that runs Linux containers, plus network access to the site and its
approved Worker image registry. The device Worker exchanges Drive files through
`ankole-files`.

```sh
bun run agent-computer device pair --url https://ankole.example.com --code '<pairing-code>'
bun run agent-computer device run
```

From the repository root, `bun run agent-computer build:device` builds the
standalone launcher at `app/agent_computer/dist/ankole-worker` for the current
platform. It accepts the same `pair` and `run` commands. Use a single `run`
process per pairing. Keep it running under the local service manager if the
device should reconnect after a reboot. Use `--state <path>` on both commands
for a separate device profile. The default profile is
`${XDG_CONFIG_HOME:-$HOME/.config}/ankole-worker/device.json`.

The launcher pulls the site's approved image and starts a separate Agent
Computer container and named Home volume for each assigned Agent. A launcher
restart reuses those volumes, including after the control plane rotates the
Worker generation. Stopping the launcher stops its containers. Revoking a
device removes its containers when the launcher next contacts the site. Its
local Home volumes remain available to the device owner.

For a disposable acceptance device, `tools/e2e/runner-backtest <container>
<bull_detective-mono-checkout>` runs the sibling project's real backtest engine
and ClickHouse adapter in the Worker container. The test uses synthetic bars,
a throwaway TLS ClickHouse instance, and the sibling project's locked
dependencies. It installs those dependencies in a temporary project inside
the container, verifies both fills and final equity, and prints the resulting
JSON. It leaves the sibling checkout unchanged.

To also verify site pairing, pinned Job placement, reconnect in the same
workspace, and the report attachment in the original conversation, prepare
the complete Worker image from this checkout and run the dedicated FOSS test:

```sh
bun tools/devkit/src/local-worker-image.ts --scope complete --output tmp/runner-worker-image
export ANKOLE_E2E_WORKER_IMAGE="$(cat tmp/runner-worker-image)"
export ANKOLE_E2E_BACKTEST_MONO=/path/to/bull_detective/mono
cd app/control_plane
ANKOLE_EDITION=foss MIX_TEST_PARTITION=runner_backtest \
  mix test ../../tools/e2e/suites/runner_backtest_e2e_test.exs
```

The test uses the real Codex runtime with a deterministic model upstream. The
control plane starts its test HTTP listener on an available port, and the
Worker reaches it at Docker's host gateway. The fixture needs the local test
database and network access for the first locked Python dependency install.

## Ownership

Agent Computer owns live execution and rebuildable Worker-local state. The
Elixir control plane owns PostgreSQL state, conversation epochs, Job fences,
final commit authority, provider outboxes, runtime credentials, and recovery
facts. Because commit authority stays in the control plane, the Worker must not
invent durable control-plane state.

Each Worker process serves only the Agent named in `WORKER_ID`. The control
plane starts the process with four runtime variables:

```text
WORKER_ID=<agent_uid>
ANKOLE_RUNTIME_FABRIC_ENDPOINT=ws://control-plane:4000/runtime-fabric/worker
ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=<credential of this generation>
ANKOLE_WORKER_STORAGE=<mounted or adapter>
```

At startup, the Worker validates the endpoint, copies the credential into its
in-memory configuration, and removes that credential from the environment that
child processes inherit. Once connected, the authenticated channel identifies
the Agent for every request. Lambda launch hooks accept only these runtime fields plus
`ANKOLE_WORKER_STORAGE_NAME` and `ANKOLE_WORKER_NFS_SOURCE` for NFS storage.

In the container image, built-in Skills live under
`ANKOLE_BUILTIN_SKILLS_ROOT=/repo/app/library`. Internal images also include
`/repo/internals/skills` and record that path in `/etc/ankole/worker-environ`,
while development Docker setups set the internal root when mounting internal
Skills.

## Filesystem contract

Each Agent has persistent Home storage mounted at `/workspace`:

- **Docker**: mounts a local volume per Agent.
- **Kubernetes**: mounts an exclusive PVC or a directory in a shared PVC.
- **Vercel**: mounts an Agent Drive.
- **Lambda**: mounts an Agent directory on EFS over NFS 4.1.
- **Cloudflare**: restores Home from R2 before startup and backs it up before a
  planned stop; see the
  [adapter's storage limits](../../tools/deploy/cloudflare/agent-workers/README.md#storage-and-replacement).

Providers preserve Agent Home across planned instance replacements, image
updates, and cache rebuilds. Cloudflare restores the latest Home snapshot; an
abrupt platform stop can lose writes made since that snapshot.

```text
/workspace/
├── .codex/
├── AGENTS.md
├── DESIGN.md
├── .ankole/turn-skills/<job-signal-id>/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── AGENTS.md
    ├── .codex/config.toml
    └── temp/
```

`/agents/<agent_uid>` is a symbolic link to `/workspace`. Before comparing a
path against Agent Home, path validation resolves symbolic links so that checks
apply to the real target. Relative paths resolve from the current Session
Workspace or Job Workspace, and each command can use Agent Home or its execution's mounted Drive as its working directory. Because Sessions and Jobs of the same Agent share this
filesystem, they can read one another's files.

The container itself is the Agent isolation boundary. Inside the container, the
entrypoint, the supervisor, and the Bun Worker process that holds credentials
run as `root`. When starting model-driven commands, Codex, MCP servers, or the
browser, `agentProcessArgv` drops privileges to `uid 1000`
with `no-new-privs` and an empty capability bounding set. Commands and Codex
processes receive their execution's Drive and recovery mounts in a private mount
and PID namespace. These child
processes receive a clean environment, cannot read the environment of trusted
processes or send signals to them, have no `sudo` access, and cannot install
system software. Agent-writable files and CLI sockets belong to `uid 1000`,
whereas control-plane documents and Plugin projections from the image use
read-only file modes.

Per-process sockets and configuration files use random names in `/var/share`
(or under `TMPDIR` during source runs). Do not store Agent-owned or durable
facts there.

The Worker uses these roots when FUSE is unavailable:

```text
HOME=/workspace
CODEX_HOME=/workspace/.codex
CODEX_SQLITE_HOME=/var/cache/ankole/codex
```

With Drive mounted, Codex app-server instances use
`/workspace/.codex/scopes/<view-key>` and
`/var/cache/ankole/codex/scopes/<view-key>`. Each view has its own configuration,
SQLite process lock, and thread files. Views with the same permission scope share
the hot Drive cache; conversation views mount separate ChatDrives.

Codex Home and its thread files persist across restarts, while a Job's
`.codex/config.toml` holds project-scoped configuration. SQLite files and their
process lock live on the local cache filesystem. Rebuilding a Worker removes
that cache, so native Codex resume relies on the thread files in Home; updating
the image alone keeps a configured cache volume or PVC.

`Ankole.AIAgent.Library.Contracts` owns the organization and Agent contracts in PostgreSQL.
At every turn start and resume, the Worker atomically refreshes the complete
`~/AGENTS.md`, `~/DESIGN.md`, and `$CODEX_HOME/AGENTS.md` from the control-plane
snapshot. Native Codex combines its global AGENTS file with project-owned
instruction files; main, ambient, and Workflow prompts receive the complete
AGENTS contract directly from the control plane.

Attachments, published files, and shared workspace content live in the unified
Drive (`docs/design-docs/Files.md`). On Workers whose startup probe confirms
FUSE support, the supervisor mounts `/drive` so `/drive/Public`,
`/drive/AgentDrive`, `/drive/MyDrive`, and `/drive/ChatDrive` resolve directly
through the Files and Principal permission owners, allowing ordinary shell tools
to read and write those paths (including symlinks). On providers without FUSE
support, the Worker falls back to `files.*` RPCs and the `ankole-files` relay. Enabled Skill packages and effective contracts use an Agent-scoped, shared
read-only mount at `/drive/Skills`, `/drive/AGENTS.md`, and `/drive/DESIGN.md`.
Conversation views bind that mount instead of copying the packages each turn.
`/drive/Brain` remains read-only and uses the conversation disclosure boundary.
Background Agent Jobs materialize their allowed complete packages through
`skills.bundle` into `.ankole/turn-skills/<signal-id>/`; their initial capability
whitelist can shrink but cannot expand on resume. A download failure stops preparation.

Session and Job workspaces are temporary working directories, and Sessions and
Jobs share the Agent filesystem. Save conversation deliverables in the current
`/drive/ChatDrive`. `reply_attachment` accepts a Drive node UUID or a path; the
Worker resolves local symlinks, flushes pending bytes, and returns the authoritative
node ID before the control plane freezes the attachment object. `send_message`
uses the same path resolution. Delivery checks the node's actual conversation
root and permits a conversation attachment only in that conversation. A committed
tool receipt replays its frozen object without requiring the original mount.

## Session and Job setup

`WorkspaceOpen` creates Agent Home and the direct Session Workspace under
`sessions/`, while `CodexRunner` creates the direct Job Workspace under `jobs/`.
Both workspaces include a `temp` directory.

To run a Codex Job, `CodexRunner` first produces a `PreparedCodexJobExecution`.
`CodexJobSession` then manages the full app-server lifecycle: it opens or
resumes the declared thread, runs the bounded recovery ladder, records each
Turn, and closes session resources when finished. Callers pass this handoff as a
unit rather than reconstructing parts of it.

Environment workspaces and Codex Jobs prepare execution materials through a
single coordinator. It resolves `WorkerEnv` values, the active Turn MCP token,
`mcporter` configuration, and browser runtime. Cleanup closes the browser before
removing the MCP configuration and preserves the first failure encountered.
Remote credentials stay in the control-plane Connectors domain; local Git
authentication uses the active Turn through `GIT_ASKPASS`.

Agents read Skill manifests on demand through `skill_view`, and read referenced
files explicitly by relative path. Each enabled package is readable as a whole.
Per-Agent lessons remain semantic state in the control plane.

Built-in Skills and Agent Plugins ship under `/repo/app/library`, and internal
images may also provide `/repo/internals/skills`. Plugin packages control
enablement and packaging, whereas Skills own discovery, paths, configuration,
and execution.

## Runtime behavior

The main Agent in the control plane has foreground `command`, `read_file`,
`replace`, `patch`, and `reply_attachment` tools, plus allowlisted web,
schedule, Skill, MCP, and `BackgroundAgentJob` surfaces. Each model-facing
command runs in its own process group with a fresh environment, so cancelling or
timing out a command terminates the entire process group.

MCP servers backed by Skills stay behind the Skill and `mcporter`. For each
execution, the Worker writes an invocation-scoped configuration that exposes
only the dependencies declared by the currently enabled Skills, and removes that
configuration when the execution ends.

Foreground `command` calls default to a 180-second budget. Persistent or
asynchronous work runs through `background_agent_job`; those Jobs have no total
wall-clock cap, and callers can steer or stop them. Codex JSON-RPC calls keep
their operation-specific timeouts.

`ANKOLE_MAX_CONCURRENT_SLOTS` caps concurrent environment workspaces and Codex
turns on the Worker, whereas pure model turns and control-plane tools consume no
Worker slot. Because the control plane serializes each conversation, new
environment executions wait when all slots on the Worker are full.

At container startup, `scripts/ankole-worker-entry.sh` prepares storage and the
`/agents/<agent_uid>` symbolic link, then starts
`tini -s -g -- ankole-worker-supervisor bun src/main.ts` as `root`. The
supervisor runs the Worker in its own session and forwards `SIGTERM` and
`SIGINT` to it once. When the Worker exits with code `0` after finishing a
drain, the container exits cleanly. On any other exit code, the supervisor
terminates leftover `uid 1000` processes and leftover `root` `setpriv`,
`unshare`, and `ankole-rclone` helpers, lazily unmounts residual
`/run/ankole-drives` mountpoints, removes `/run/ankole/rclone.sock`, and
restarts the Worker with exponential backoff (`1, 2, 4, …` up to `60` seconds).
The Worker exits on its own after five minutes without a joined Channel, and
exits immediately if the control plane rejects its join for a stale generation.
Heartbeat messages report `active_tasks` and `idle_for_ms`, which the control
plane uses to stop idle Workers.

For browser access, the Worker sets `ANKOLE_BROWSER_*` variables that point to
the execution's local sockets and configuration files. Persistent Codex browser
routes live for the duration of the Job, while fallback routes for rendered
`web_fetch` calls are short-lived.

## Source map

- `src/main.ts`: Worker lifecycle, environment workspace, and Codex dispatch.
- `src/worker/`: environment, lifecycle, Agent Home preparation, and readiness.
- `src/core/`: turn handlers, Agent Home paths, and `CodexRunner`.
- `src/skills/`: projection and materialization of `Ankole.AIAgent.Library` Skill packages across `/drive/Skills` and `.ankole/turn-skills/`.
- `src/fabric/` and `src/lanes/`: RuntimeFabric envelopes and lanes.
- `src/tools/`: environment tools and Codex Skill support.
- `test/`: Bun unit tests that run on the host.
- `test/integration/host/`: portable process and protocol integration tests.
- `test/integration/linux/`: supervisor and managed Codex tests for Linux hosts.
- `test/integration/worker-image/`: checks for the Worker image and its installed tools.

Run `bun run test` for the host unit suite (or
`bun run test ./test/example.test.ts` for a single file). Running unit tests on
the host requires Bun, Bash, GNU `timeout`, and Python 3; `bun run test:docker`
runs the same unit suite inside Docker.

Run `bun run test:integration` for host integration tests, which exercise local
protocol fixtures alongside real Codex, MCPorter, `apply_patch`, and shell
processes. The host must provide Codex 0.166.0, MCPorter 0.16.0 running on Bun,
native `apply_patch`, and GNU `stat` (`gstat` on macOS). Set
`ANKOLE_CODEX_BINARY` to override the local Codex binary. The test runner sets
`TMPDIR=/tmp` so that Unix socket paths stay short.

On Linux, also run `bun run test:integration:linux`, which requires `setsid` and
util-linux `flock` with `-F` support. To verify the built Worker image—including
its entrypoint, image configuration, `tini`, pinned Codex bindings, browser,
OCR, MCPorter, and the Git credential helper—run `bun run test:integration:docker`.

## Image configuration

The Worker image defines the fixed Agent Home path, the built-in Skill root,
browser binaries, the supervisor, and the Bun working directory for Agent
Computer. At startup, the entrypoint loads image variables from
`/etc/ankole/worker-environ`. Internal images set
`ANKOLE_INTERNAL_SKILLS_ROOT`, and development Docker setups set the same
variable when mounting internal Skills. Operator-managed `WorkerEnv` values are
resolved per Agent and injected at lower precedence than explicit tool inputs;
the control plane rejects reserved variable names during both storage and
binding resolution. External Connector credentials stay on the control plane,
while local `git` commands authenticate per Turn through the control-plane Git
credential helper.

When a published immutable GHCR Worker image matches the current Git inputs,
devkit resolves and reuses it. If the Worker inputs have changed, devkit builds
a content-addressed local image: it reuses the pinned Agent OS base when
`Dockerfile.base` matches the lockfile, or builds the base from the current
recipe otherwise. Codex, MCPorter, OfficeCLI, Typst, `kubectl`, and the AWS CLI
are installed as layers of the Worker image. The OfficeCLI launcher disables
background self-updates by default, including in isolated Agent command
environments, so document rendering uses the version tested with that image.
Operators update the pinned version through the image recipe. An explicit
`OFFICECLI_SKIP_UPDATE=0 officecli ...` invocation enables upstream update behavior.
To run an explicit manual build on the pinned base, use a disposable tag:

```shell
docker build \
  --build-arg "BASE_IMAGE=$(tr -d '\n' < app/agent_computer/base-image.lock)" \
  -f app/agent_computer/Dockerfile -t ankole-agent-computer:manual .
```
