---
title: Agent Computer Worker
description: Environment tools, Codex, persistent Home, and recovery across control-plane replacement.
section: Developer guide
order: 108
---

Each Agent has its own isolated computer, called an Agent Computer Worker. When you create an Agent, Ankole records its Worker provider binding, initializes the Worker row in an absent state, and queues an initial Worker start in the background. After that first start completes and the idle Worker is released, environment tools and Codex Jobs start it on demand. Pure Q&A turns and control-plane tools run without waiting for a Worker.

## Execution and ownership

Inside the Worker, the Bun runtime executes shell commands, file and browser tools, Skills, MCP calls, and Codex Jobs. Durable orchestration stays in the Elixir control plane: `Ankole.Sessions` drives the main Agent loop, commits consumed inputs and tool results, and owns final replies, while AIGateway manages the stored Response chain and hosted tools.

When booting a Worker, the control plane injects `WORKER_ID`, the RuntimeFabric endpoint, generation credentials, and storage settings. Each Worker serves only its assigned Agent, strips control-plane credentials from child process environments, and never opens a database connection. The `root` supervisor (`ankole-worker-supervisor` paired with a root-only `ankole-rclone` daemon) holds `/dev/fuse` and `SYS_ADMIN` solely to assemble each execution's private mount and PID namespace, then drops child command and Codex processes to `uid` `1000` / `gid` `1000` with empty Linux capabilities (`NoNewPrivs` and no `sudo`).

## Worker providers and the live connection

An Agent's assigned `WorkerProvider` (`WorkerProviders`) determines its underlying platform, instance sizing, and storage backend. Even when multiple Agents share the same `WorkerProvider`, the platform provisions a separate computer for each Agent. When a Worker sits idle, the control plane can pause or remove the compute instance while preserving the Agent's persistent Home directory. See [Worker providers](../worker-management/) for configuration and lifecycle rules.

Once running, the Worker opens a single authenticated WebSocket connection to `/runtime-fabric/worker/websocket` and joins its Phoenix Channel. Over this channel, the control plane and Worker exchange environment calls, execution results, Codex control commands, and progress updates in RuntimeFabric protobuf envelopes, while transferring file bytes out-of-band through one-time HTTP relay URLs. The control plane verifies generation and incarnation numbers to reject messages from a replaced Worker, and stores all durable recovery facts in PostgreSQL.

## Operation identity and recovery

For interactive environment work, the Driver tags operations with a `RunRef` identifying the Agent, Session, and triggering input, and keys each call by its Response ID and call ID. Because running commands survive a control-plane disconnect, a replacement Driver can probe the existing workspace and adopt an in-flight call or collect its finished result. If the Worker process itself crashes, the Driver retries only idempotent safe calls and returns `interrupted` for any other unknown calls.

Codex Jobs instead identify work with a `JobTurnRef` carrying the Job ID and attempt number, while Codex runs its own model loop inside the Worker. If the control-plane Job owner restarts, it sends an `adopt` request to stay attached to the running turn, thread, and workspace; when the turn finishes, the Job owner fences terminal writes and consumes applied input IDs in a single transaction.

For capacity accounting, each open environment workspace and each running Codex turn occupies one Worker slot, whereas main-loop and Workflow model calls execute in the control plane without consuming Worker slots.

## The filesystem contract

Each Agent's persistent Home directory is mounted at `/workspace` (with `/agents/<agent_uid>` symlinked to `/workspace`), while FUSE-capable Workers mount Unified Drive at `/drive` inside each execution's private mount namespace:

```text
/workspace/
├── .codex/
├── AGENTS.md
├── DESIGN.md
├── .ankole/turn-skills/<job-signal-id>/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── AGENTS.md
    └── temp/

/drive/
├── Public/        (read-write)
├── MyDrive/       (read-write, Personal Assistant owner space)
├── AgentDrive/    (read-write)
├── ChatDrive/     (read-write, scoped to active conversation)
├── Brain/         (read-only, disclosure-filtered)
├── Skills/        (read-only)
├── AGENTS.md      (read-only)
└── DESIGN.md      (read-only)
```

At `/drive`, `Ankole.Files.Vfs` exposes read-write `/drive/Public`, `/drive/MyDrive` (when acting as a Personal Assistant), `/drive/AgentDrive`, and conversation-isolated `/drive/ChatDrive`, alongside read-only `/drive/Brain`, `/drive/Skills`, `/drive/AGENTS.md`, and `/drive/DESIGN.md` from [Agent Library](../agent-library/). If a background VFS writeback hits a terminal `412` or `422` conflict, the Worker preserves local draft bytes in that scope's `/drive-recovery` directory; on Workers where startup probing cannot mount FUSE, Agents transfer Drive files via `ankole-files` instead (see [File management](../file-management/)). `~/AGENTS.md`, `~/DESIGN.md`, and `$CODEX_HOME/AGENTS.md` likewise mirror the effective contracts each turn, and Background Agent Jobs materialize their admitted Skill selection under `.ankole/turn-skills/<signal-id>/` (which can shrink on capability revocation, never expand). `sessions/` holds conversation workspaces with stable PostgreSQL numeric IDs starting at `10000`, and `jobs/` holds Background Agent Job projects and instruction files.

Agent Home survives instance deletion and container image updates—rebuilding a Worker clears only `/var/cache/ankole`. Storage durability follows the backing provider: local Docker volumes depend on the host disk, whereas forcing a Cloudflare Worker stop can lose writes made since the last R2 backup. See [Workers](../worker-management/) for provider storage limits.

Raw Codex thread files live in `/workspace/.codex`, while `AgentCodexRuntime` scopes active Codex runtime entries, `CODEX_HOME`, and rebuildable SQLite caches under `/var/cache/ankole/codex` by execution view (including conversation identity so `ChatDrive` and disclosure mounts stay isolated). Across Worker replacements, Codex resumes threads from `/workspace/.codex` and rebuilds its cache automatically, while Background Jobs load Skills on demand through `skill_view`.

## Progress and capacity

The Session Driver owns main-loop streaming and tool presentation, while the Worker sends environment results and Codex progress updates over RuntimeFabric. Streaming progress is best-effort; recovery always relies on the completion facts and stored results persisted in PostgreSQL.

Periodic Worker heartbeats report active workspaces, running Codex turns, and remaining free slots. When a Worker is idle, the control plane releases it according to `idleReleaseAfter` in the provider YAML (setting `never` retains idle Workers indefinitely). Reconnecting over the WebSocket preserves the Worker's process incarnation and all in-flight work.

See [Sessions](../sessions/) for writer and operation fences, [AIGateway](../ai-gateway/) for Responses, [Agent Library](../agent-library/) for Skills, and [Workers](../worker-management/) for provider states.
