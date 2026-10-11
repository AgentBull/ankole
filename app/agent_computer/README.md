# @ankole/agent-computer

Agent Computer is the Bun + TypeScript Worker runtime for Ankole execution.
It runs environment tools, Skill materialization, invocation-scoped mcporter
configuration, CodexRunner Jobs, Automation Jobs, browser routing, and
Worker-side RuntimeFabric lanes inside the Linux Worker image. The Elixir
control plane runs the main Agent loop and owns its progress.

This package is not a standalone local CLI. The image contract supplies Chromium, Python/Jupyter/document tooling, and the Worker
supervisor. After Agent creation, the control plane requests its Worker in the background
(`docs/design-docs/AgentWorkers.md`); the Worker is that Agent's own computer.

## Ownership

Agent Computer owns live execution and rebuildable Worker-local state. The
Elixir control plane owns PostgreSQL state, conversation epochs, Job fences, final
commit authority, provider outboxes, runtime credentials, and recovery facts.
The Worker must not invent durable control-plane state.

The process serves only the Agent that `WORKER_ID` names. The control plane
creates it with:

```text
WORKER_ID=<agent_uid>
ANKOLE_RUNTIME_FABRIC_ENDPOINT=ws://control-plane:4000/runtime-fabric/worker
ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=<credential of this generation>
ANKOLE_WORKER_STORAGE=<mounted or adapter>
```

The Worker validates the endpoint, copies the credential into its in-memory
configuration, and removes it from the environment that child processes
inherit. The authenticated connection determines the Agent for every request.
The image supplies `ANKOLE_BUILTIN_SKILLS_ROOT=/repo/app/library`. An internal
image also supplies `/repo/internals/skills` and records it in
`/etc/ankole/worker-environ`. Development Docker mounts set the internal root
when they mount internal Skills. Lambda
launch hooks receive only the five runtime contract keys.

`DATABASE_URL` is not a Worker input.

## Filesystem contract

Each Agent has persistent Home storage at `/workspace`. Docker uses a local
volume per Agent. Kubernetes uses a PVC or a directory in a shared PVC.
Vercel uses an Agent Drive. Lambda mounts an Agent directory on EFS with NFS 4.1.
Cloudflare restores Home from R2 before startup and backs it up before a planned
stop; see the [adapter's storage limits](../../tools/deploy/cloudflare/agent-workers/README.md#storage-and-replacement).
The provider keeps Home when it deletes an instance, changes its image, or
rebuilds its cache.

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

The old `/agents/<agent_uid>` path is a symbolic link to `/workspace`. Path
checks resolve symbolic links before they compare a path with Agent Home.
Relative paths resolve from the current Session Workspace or Job Workspace.
The entry, supervisor, and credential-holding Bun Worker run as root.
`agentProcessArgv` starts model-driven commands, Codex, MCP servers, the browser,
and Automation scripts as uid 1000 with `no-new-privs` and no inherited or
ambient capabilities. They receive a clean environment and cannot read the
trusted processes' environment or signal them. Agent-writable files and CLI sockets belong to
uid 1000; control-plane documents and image Plugin projections use read-only modes.
The container is the Agent isolation boundary. The Agent has no sudo and cannot
install system software. A command's working directory must be inside the Agent Home.
Sessions and Jobs of the Agent can see one another's files.

`/var/share` holds per-process sockets and configuration files with random
names. `TMPDIR` selects a different temporary root for source runs. Do not store
Agent-owned or durable facts there.

For every turn:

```text
HOME=/workspace
CODEX_HOME=/workspace/.codex
CODEX_SQLITE_HOME=/var/cache/ankole/codex
```

Codex Home and its thread files are persistent. A Job's `.codex/config.toml`
is project configuration. SQLite and its process lock use the local cache
filesystem. A rebuild removes that cache; native Codex resume uses the thread
files in Home. An image change keeps a configured cache volume or PVC.

PostgreSQL is authoritative for SOUL, MISSION, DESIGN, and ConfidentialityPolicy. The uppercase files
are read-only projections. Environment workspace and Codex Job preparation
write them atomically from the control-plane document snapshot. A failed projection
stops that execution. Codex uses the supplied snapshot as its instructions; it
does not read a shared projection file as the source of those instructions. Pure
model turns read the control-plane facts directly.

Attachments, published files, Skills, and Automation scripts live in the Agent's
drive in the control plane (`docs/design-docs/Files.md`). The Worker reads and writes the drive through
the `files.*` RPCs; the turn-local `ankole-files` command gives the model the
same operations. The control plane derives the installed Skill catalog from
the drive. Before each environment workspace, Codex Job, and Automation Job the Worker brings
`installed-skills/` in step with `skills/` in the drive. A download failure
stops preparation; it cannot remove catalog entries or operator settings.
Session and Job workspaces are temporary working directories. Save sensitive
user files and deliverables in the source channel's `chats/<channel>/` drive
directory. System prompts name this directory and tell the Agent to leave other
conversations' files alone. Sessions and Jobs still share the Agent filesystem.
`reply_attachment` accepts only `drive_path` and runs in the control plane.
The common Outbox commit checks that a file under `chats/<channel>/` goes back
to that channel. Shared drive paths can be delivered anywhere.

## Session and Job setup

`WorkspaceOpen` creates the Agent Home and the direct Session Workspace
under `sessions/`. CodexRunner creates the direct Job Workspace under `jobs/`.
Both receive a `temp` directory.

CodexRunner first produces one `PreparedCodexJobExecution`. `CodexJobSession`
then owns the complete app-server lifecycle: it opens or resumes the declared
thread, applies the bounded recovery ladder, records each Turn, and closes the
session resources. A caller does not reconstruct part of this handoff.

Environment workspaces, Codex Jobs, and Automation Jobs prepare execution materials
through one owner. It resolves WorkerEnv values and materializes the optional
Lark credential, mcporter configuration, and browser runtime. Cleanup runs in
the fixed browser, mcporter, then Lark order and preserves the first failure.

Agent-installed Skill source is
`/workspace/installed-skills/<skill-name>`. A Job reads Skills through
the Ankole `skill_view` tool and keeps no Skill copy in its workspace. Database
overlays remain semantic control-plane state.

Built-in Skills and Agent Plugins ship under `/repo/app/library`; internal
images may also provide `/repo/internals/skills`. Plugin packages control
enablement and packaging. Skill discovery, paths, configuration, and execution
remain Skill semantics.

## Runtime behavior

The control-plane main Agent has foreground `command`, `read_file`, `replace`, `patch`, and
`reply_attachment` tools plus the allowlisted web, schedule, Skill, MCP,
and BackgroundAgentJob surfaces. Each model-facing command runs in its own
process group with a fresh environment; a cancellation or timeout ends the
whole group.

Skill-backed MCP stays behind the Skill and mcporter. Each execution receives
only the dependencies declared by its current enabled Skills, through one
invocation-scoped config that the Worker removes when the execution ends.

The command tool defaults to a 180-second foreground budget. Persistent or
asynchronous work uses `background_agent_job`. Jobs have no total wall-clock
cap; callers may steer or stop them. Codex JSON-RPC calls retain their
operation-specific timeouts.

`ANKOLE_MAX_CONCURRENT_SLOTS` limits environment workspaces and Codex turns on
the Worker. Model turns and control-plane tools use no Worker slot. The control
plane serializes each conversation; when the Worker is full, new environment
execution waits.

The image entrypoint, `scripts/ankole-worker-entry.sh`, prepares storage and the
old path link, then starts `tini -s -g -- ankole-worker-supervisor bun src/main.ts`
as root. The supervisor runs the Worker in its own session and forwards
SIGTERM and SIGINT to it once. A Worker exit of 0 (a
finished drain) ends the container. Any other exit ends the uid 1000 processes
and pending `setpriv` wrappers that the Worker left and starts it again after
1, 2, 4, … up to 60 seconds. The Worker
exits by itself after five minutes without a joined Channel, and at once when
the control plane refuses its join for a stale generation. Heartbeat messages report `active_tasks` and `idle_for_ms`, which the control
plane uses to stop an idle Worker.

Browser routes provide `ANKOLE_BROWSER_*` values that point to the execution's
local sockets and configuration files. Persistent Codex browser routes are Job-local;
rendered `web_fetch` fallback routes are short-lived.

## Source map

- `src/main.ts`: Worker lifecycle, environment workspace, and Codex dispatch.
- `src/worker/`: environment, lifecycle, Agent Home preparation, readiness.
- `src/core/`: turn handlers, Agent Home paths, CodexRunner.
- `src/skills/`: installed Skill materialization from the Agent's drive.
- `src/fabric/` and `src/lanes/`: RuntimeFabric envelopes and lanes.
- `src/tools/`: environment tools and Codex Skill support.
- `test/`: Bun unit tests that can run on the host.
- `test/integration/host/`: portable process and protocol integration tests.
- `test/integration/linux/`: supervisor and managed Codex tests for Linux hosts.
- `test/integration/worker-image/`: checks of the Worker image and its installed tools.

Run `bun run test` for the host unit suite. The host needs Bun, Bash, GNU
`timeout`, and Python 3. Use `bun run test ./test/example.test.ts` for one unit
test file. `bun run test:docker` runs the unit suite in Docker.

Run `bun run test:integration` for host integration tests. They use local
protocol fixtures and real Codex, MCPorter, `apply_patch`, and shell processes.
The host needs Codex 0.158.0, MCPorter 0.14.1 running with Bun, native
`apply_patch`, and GNU `stat` (`gstat` on macOS). `ANKOLE_CODEX_BINARY` can select
a local Codex binary. The command sets `TMPDIR=/tmp` to keep socket paths short.

On Linux, also run `bun run test:integration:linux` with `setsid` and util-linux
`flock` (`-F` support). Run `bun run test:integration:docker` for Worker image
checks: the entrypoint, image configuration, `tini`, pinned Codex bindings,
browser, OCR, and installed Lark CLI.

## Image configuration

The image provides the fixed Agent Home path, built-in Skill root,
browser binaries, the supervisor, and the Agent Computer Bun workdir. The entry
restores image variables from `/etc/ankole/worker-environ`. Internal images own
`ANKOLE_INTERNAL_SKILLS_ROOT`; development Docker sets it when it mounts internal
Skills. Operator-managed WorkerEnv values are resolved per Agent and injected
below explicit tool inputs. The control plane rejects reserved names at storage
and binding resolution. A binding-derived Lark tenant token is refreshed in a private
execution file and is not frozen in a long-lived shell environment.

Devkit resolves the immutable GHCR image for the current Git inputs when one is
published. If the Worker inputs changed, it builds a content-addressed local
image. For an explicit manual build, use a disposable name:

```shell
docker build \
  --build-arg "BASE_IMAGE=$(tr -d '\n' < app/agent_computer/base-image.lock)" \
  -f app/agent_computer/Dockerfile -t ankole-agent-computer:manual .
```
