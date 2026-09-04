# @ankole/agent-computer

Agent Computer is the Bun + TypeScript Worker runtime for Ankole actor turns.
It runs model loops, foreground computer tools, Skill access, invocation-scoped
mcporter configuration, CodexRunner Jobs, Automation Jobs, browser routing, and
Worker-side RuntimeFabric lanes inside the Linux Worker image.

This package is not a standalone local CLI. The image contract supplies native
kernel bindings, bubblewrap, Chromium, Python/Jupyter/document tooling,
ZeroMQ, and the shared Agent filesystem.

## Ownership

Agent Computer owns live execution and rebuildable Worker-local state. The
Elixir control plane owns PostgreSQL state, actor and delivery fences, final
commit authority, provider outboxes, runtime credentials, and recovery facts.
The Worker must not invent durable control-plane state.

The process is pool-scoped. Actor identity arrives in `turn_start`; it is not a
Worker environment variable. RuntimeFabric authentication uses:

```text
WORKER_ID=worker-a
ANKOLE_RUNTIME_FABRIC_ENDPOINT=tcp://host:port
ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=worker_auth_key
ANKOLE_AGENTS_ROOT=/agents
```

The Worker validates the endpoint, copies the auth key into its in-memory
configuration, and removes the key from the environment that child processes
inherit.

`DATABASE_URL`, `ANKOLE_AGENT_UID`, `ANKOLE_SESSION_ID`, and
`ANKOLE_ACTOR_EPOCH` are not Worker inputs.

## Filesystem contract

The durable shared writable runtime mount is `/agents`:

```text
/agents/<agent-key>/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── user-files/
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── .ankole/skills/
    └── temp/
```

The model-visible absolute path is the container path. The Worker does not
translate paths or create alias mounts. Relative paths resolve from the current
Session Workspace or Job Workspace. Computer tools use the current Bubblewrap
filesystem view without a second path policy. The view mounts the current Agent
Home read-write and the built-in and internal Skill roots read-only. Same-Agent
Sessions and Jobs can therefore see one another's files; this is an accepted
best-effort isolation model, not a security boundary for mutually hostile
workloads.

Every sandbox can also read and write `/var/share`. This directory is local to
one Worker and can be lost when the Worker stops. Use it only for disposable
cache and coordination files. Do not store Agent-owned or durable facts there.

For every turn:

```text
HOME=/agents/<agent-key>
CODEX_HOME=/var/lib/ankole/codex/<agent-key>/.codex
```

The Agent Home is shared durable storage. The Codex Home is a rebuildable
Worker-local shard because SQLite WAL needs same-host shared memory. A Job's
`.codex/config.toml` is project configuration. The Worker-local Codex Home owns
auth, Codex sessions, SQLite, caches, and other official runtime state.

PostgreSQL is authoritative for SOUL, MISSION, and DESIGN. The uppercase files
are read-only projections. Startup and document-change events rebuild them;
every Turn/Job preparation performs a hash/content synchronization barrier and
fails before model invocation if projection fails.

Reply attachments may come only from the current Agent's `user-files` tree.
Job files must first be copied or moved there.

## Session and Job setup

`prepareTurnWorkspace` creates the Agent Home and the direct Session Workspace
under `sessions/`. CodexRunner creates the direct Job Workspace under `jobs/`.
Both receive a `temp` directory.

CodexRunner first produces one `PreparedCodexJobExecution`. `CodexJobSession`
then owns the complete app-server lifecycle: it opens or resumes the declared
thread, applies the bounded recovery ladder, records each Turn, and closes the
session resources. A caller does not reconstruct part of this handoff.

Foreground Turns, Codex Jobs, and Automation Jobs prepare execution materials
through one owner. It resolves WorkerEnv values and materializes the optional
Lark credential, mcporter configuration, and browser runtime. Cleanup runs in
the fixed browser, mcporter, then Lark order and preserves the first failure.

Agent-installed Skill source is
`/agents/<agent-key>/installed-skills/<skill-name>`. A Job projects selected
effective Skills into its real `.ankole/skills` directory and passes that path
to Codex. Database overlays remain semantic control-plane state; only the
composed Job-local `SKILL.md` is materialized.

Built-in Skills and Agent Plugins ship under `/repo/app/library`; internal
images may also provide `/repo/internals/skills`. Plugin packages control
enablement and packaging. Skill discovery, paths, configuration, and execution
remain Skill semantics.

## Runtime behavior

The main Agent has foreground `command`, `read_file`, `replace`, `patch`, and
`reply_attachment` tools plus the allowlisted web, schedule, Skill, MCP,
and BackgroundAgentJob surfaces. Host execution is never exposed; model-facing
commands run through bubblewrap.

Skill-backed MCP stays behind the Skill and mcporter. Each execution receives
only the dependencies declared by its current enabled Skills, through one
invocation-scoped config that the Worker removes when the execution ends.

The command tool defaults to a 180-second foreground budget. Persistent or
asynchronous work uses `background_agent_job`. Jobs have no total wall-clock
cap; callers may steer or stop them. Codex JSON-RPC calls retain their
operation-specific timeouts.

`ANKOLE_MAX_CONCURRENT_TURNS` controls per-Worker active-turn capacity. The
control plane serializes a Session actor and keeps all live work for one Agent
sticky to one Worker. If that Worker is full, new work for the Agent waits
rather than spilling to another Worker.

Browser routes expose only final opaque `ANKOLE_BROWSER_*` values and explicit
read-only socket/material binds. Persistent Codex browser routes are Job-local;
rendered `web_fetch` fallback routes are short-lived.

## Source map

- `src/main.ts`: Worker event loop and turn dispatch.
- `src/worker/`: environment, lifecycle, Agent Home preparation, readiness.
- `src/core/`: turn handlers, Agent Home paths, CodexRunner.
- `src/skills/`: installed Skill observation and pre-turn registry sync.
- `src/fabric/` and `src/lanes/`: RuntimeFabric envelopes and lanes.
- `src/tools/`: model-facing tools.
- `src/prompts/`: system and turn prompts.
- `test/`: Bun unit tests; integration tests require the Worker image.

## Image configuration

Besides `ANKOLE_AGENTS_ROOT`, the base image provides the built-in Skill root,
browser binaries, and the Agent Computer Bun workdir. An internal image or
development mount can set `ANKOLE_INTERNAL_SKILLS_ROOT` when it provides that
optional Skill root. Operator-managed WorkerEnv values are resolved per Agent
and injected below explicit tool inputs; reserved runtime variables cannot be
overridden. A binding-derived Lark tenant token is refreshed in a private
execution file and is not frozen in a long-lived shell environment.

Devkit resolves the immutable GHCR image for the current Git inputs when one is
published. If the Worker inputs changed, it builds a content-addressed local
image. For an explicit manual build, use a disposable name:

```shell
docker build \
  --build-arg "BASE_IMAGE=$(tr -d '\n' < app/agent_computer/base-image.lock)" \
  -f app/agent_computer/Dockerfile -t ankole-agent-computer:manual .
```
