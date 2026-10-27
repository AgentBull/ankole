# @ankole/agent-computer

Agent Computer is the Bun and TypeScript Worker runtime for Ankole execution.
Inside the Linux Worker image, it runs environment tools, materializes Skills,
manages `mcporter` configuration for each invocation, executes `CodexRunner`
Jobs and Automation Jobs, routes browser sessions, and serves the Worker side of
RuntimeFabric lanes. Meanwhile, the Elixir control plane runs the main Agent
loop and tracks its progress.

This package is not a standalone local CLI. The Worker image bundles Chromium,
Python, Jupyter, document tooling, and the Worker supervisor. After an Agent is
created, the control plane provisions a dedicated Worker in the background
(`docs/design-docs/AgentWorkers.md`) to serve as that Agent's own computer.

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
the Agent for every request. Lambda launch hooks receive only the five keys in
the runtime contract.

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

Across all providers, Agent Home is preserved when the provider deletes an
instance, updates its image, or rebuilds its cache.

```text
/workspace/
├── .codex/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── ConfidentialityPolicy.md
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── AGENTS.md
    ├── .codex/config.toml
    └── temp/
```

`/agents/<agent_uid>` is a symbolic link to `/workspace`. Before comparing a
path against Agent Home, path validation resolves symbolic links so that checks
apply to the real target. Relative paths resolve from the current Session
Workspace or Job Workspace, and every command's working directory must stay
inside Agent Home. Because Sessions and Jobs of the same Agent share this
filesystem, they can read one another's files.

The container itself is the Agent isolation boundary. Inside the container, the
entrypoint, the supervisor, and the Bun Worker process that holds credentials
run as `root`. When starting model-driven commands, Codex, MCP servers, the
browser, or Automation scripts, `agentProcessArgv` drops privileges to `uid 1000`
with `no-new-privs` and no inherited or ambient capabilities. These child
processes receive a clean environment, cannot read the environment of trusted
processes or send signals to them, have no `sudo` access, and cannot install
system software. Agent-writable files and CLI sockets belong to `uid 1000`,
whereas control-plane documents and Plugin projections from the image use
read-only file modes.

Per-process sockets and configuration files use random names in `/var/share`
(or under `TMPDIR` during source runs). Do not store Agent-owned or durable
facts there.

For every turn, the Worker sets:

```text
HOME=/workspace
CODEX_HOME=/workspace/.codex
CODEX_SQLITE_HOME=/var/cache/ankole/codex
```

Codex Home and its thread files persist across restarts, while a Job's
`.codex/config.toml` holds project-scoped configuration. SQLite files and their
process lock live on the local cache filesystem. Rebuilding a Worker removes
that cache, so native Codex resume relies on the thread files in Home; updating
the image alone keeps a configured cache volume or PVC.

PostgreSQL is authoritative for `SOUL`, `MISSION`, `DESIGN`, and
`ConfidentialityPolicy`, while the corresponding uppercase files in `/workspace`
are read-only projections. When preparing an environment workspace or a Codex
Job, the Worker writes these files atomically from the document snapshot
supplied by the control plane; if writing a projection fails, execution stops.
Codex also receives that snapshot directly as its instructions, and pure model
turns read these facts directly from the control plane.

Attachments, published files, Skills, and Automation scripts live in the Agent's
drive in the control plane (`docs/design-docs/Files.md`). The Worker reads and
writes the drive through the `files.*` RPCs, and the turn-local `ankole-files`
command exposes the same operations to the model. The control plane derives the
installed Skill catalog from the drive. Before starting each environment
workspace, Codex Job, or Automation Job, the Worker synchronizes
`installed-skills/` with `skills/` in the drive; if a download fails,
preparation stops without removing catalog entries or operator settings.

Session and Job workspaces are temporary working directories, and Sessions and
Jobs share the Agent filesystem. Save sensitive user files and deliverables in
the `chats/<channel>/` drive directory for the source channel; system prompts
name this directory and instruct the Agent to leave files from other
conversations alone. For outbound attachments, `reply_attachment` accepts only
`drive_path` and runs in the control plane. During Outbox commit, the control
plane verifies that any file under `chats/<channel>/` is delivered back to that
same channel, whereas files under shared drive paths can be delivered anywhere.

## Session and Job setup

`WorkspaceOpen` creates Agent Home and the direct Session Workspace under
`sessions/`, while `CodexRunner` creates the direct Job Workspace under `jobs/`.
Both workspaces include a `temp` directory.

To run a Codex Job, `CodexRunner` first produces a `PreparedCodexJobExecution`.
`CodexJobSession` then manages the full app-server lifecycle: it opens or
resumes the declared thread, runs the bounded recovery ladder, records each
Turn, and closes session resources when finished. Callers pass this handoff as a
unit rather than reconstructing parts of it.

Environment workspaces, Codex Jobs, and Automation Jobs prepare execution
materials through a single coordinator. It resolves `WorkerEnv` values and
materializes the optional Lark credential, `mcporter` configuration, and browser
runtime. Cleanup runs in the fixed order `browser`, `mcporter`, then `Lark`, and
preserves the first failure encountered.

Agent-installed Skill sources live at `/workspace/installed-skills/<skill-name>`,
and Jobs read Skills on demand through the Ankole `skill_view` tool. Database
overlays remain semantic state in the control plane.

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
terminates leftover `uid 1000` processes and pending `setpriv` wrappers, then
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
- `src/skills/`: materialization of installed Skills from the Agent's drive.
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
processes. The host must provide Codex 0.164.0, MCPorter 0.16.0 running on Bun,
native `apply_patch`, and GNU `stat` (`gstat` on macOS). Set
`ANKOLE_CODEX_BINARY` to override the local Codex binary. The test runner sets
`TMPDIR=/tmp` so that Unix socket paths stay short.

On Linux, also run `bun run test:integration:linux`, which requires `setsid` and
util-linux `flock` with `-F` support. To verify the built Worker image—including
its entrypoint, image configuration, `tini`, pinned Codex bindings, browser,
OCR, and installed Lark CLI—run `bun run test:integration:docker`.

## Image configuration

The Worker image defines the fixed Agent Home path, the built-in Skill root,
browser binaries, the supervisor, and the Bun working directory for Agent
Computer. At startup, the entrypoint loads image variables from
`/etc/ankole/worker-environ`. Internal images set
`ANKOLE_INTERNAL_SKILLS_ROOT`, and development Docker setups set the same
variable when mounting internal Skills. Operator-managed `WorkerEnv` values are
resolved per Agent and injected at lower precedence than explicit tool inputs;
the control plane rejects reserved variable names during both storage and
binding resolution. When a Lark tenant token is derived from a binding, the
Worker refreshes it in a private file for that execution instead of freezing it
in a long-lived shell environment.

When a published immutable GHCR Worker image matches the current Git inputs,
devkit resolves and reuses it. If the Worker inputs have changed, devkit builds
a content-addressed local image: it reuses the pinned Agent OS base when
`Dockerfile.base` matches the lockfile, or builds the base from the current
recipe otherwise. Codex, MCPorter, OfficeCLI, Typst, `kubectl`, and the AWS CLI
are installed as layers of the Worker image. To run an explicit manual build on
the pinned base, use a disposable tag:

```shell
docker build \
  --build-arg "BASE_IMAGE=$(tr -d '\n' < app/agent_computer/base-image.lock)" \
  -f app/agent_computer/Dockerfile -t ankole-agent-computer:manual .
```
