---
title: Agent Computer Worker
description: Environment tools, Codex, persistent Home, and recovery across control-plane replacement.
section: Developer guide
order: 108
---

Each Agent has its own isolated computer, called an Agent Computer Worker. When you create an Agent, Ankole records its Worker provider binding and initializes the Worker row in an absent state without booting an instance. Pure Q&A turns and control-plane tools run directly in the control plane without a Worker; the control plane starts the Worker on demand the first time a turn invokes an environment tool or starts a Codex Job.

## Execution and ownership

Inside the Worker, the Bun runtime executes shell commands, file and browser tools, Skills, MCP calls, automation scripts, and Codex Jobs. Durable orchestration stays in the Elixir control plane: `Ankole.Sessions` drives the main Agent loop, commits consumed inputs and tool results, and owns final replies, while AIGateway manages the stored Response chain and hosted tools.

When booting a Worker, the control plane injects `WORKER_ID`, the RuntimeFabric endpoint, generation credentials, and storage settings. Each Worker serves only its assigned Agent, strips control-plane credentials from child process environments, and never opens a database connection. The container itself forms the Agent's isolation boundary, where commands run as `uid` `1000` without `sudo`.

## Worker pools and the live connection

An Agent's saved Worker provider determines its pool, underlying platform, instance sizing, and storage backend. Even when multiple Agents share the same pool, the platform provisions a separate computer for each Agent. When a Worker sits idle, the control plane can pause or remove the compute instance while preserving the Agent's persistent Home directory. See [Worker pools](../worker-management/) for configuration and lifecycle rules.

Once running, the Worker opens a single authenticated WebSocket connection to `/runtime-fabric/worker/websocket` and joins its Phoenix Channel. Over this channel, the control plane and Worker exchange environment calls, execution results, Codex control commands, and progress updates in RuntimeFabric protobuf envelopes, while transferring file bytes out-of-band through one-time HTTP relay URLs. The control plane verifies generation and incarnation numbers to reject messages from a replaced Worker, and stores all durable recovery facts in PostgreSQL.

## Operation identity and recovery

For interactive environment work, the Driver tags operations with a `RunRef` identifying the Agent, Session, and triggering input, and keys each call by its Response ID and call ID. Because running commands survive a control-plane disconnect, a replacement Driver can probe the existing workspace and adopt an in-flight call or collect its finished result. If the Worker process itself crashes, the Driver retries only idempotent safe calls and returns `interrupted` for any other unknown calls.

Codex Jobs instead identify work with a `JobTurnRef` carrying the Job ID and attempt number, while Codex runs its own model loop inside the Worker. If the control-plane Job owner restarts, it sends an `adopt` request to stay attached to the running turn, thread, and workspace; when the turn finishes, the Job owner fences terminal writes and consumes applied input IDs in a single transaction.

For capacity accounting, each open environment workspace and each running Codex turn occupies one Worker slot, whereas main-loop and Workflow model calls execute in the control plane without consuming Worker slots.

## The filesystem contract

Each Agent's persistent Home directory is mounted at `/workspace`, with `/agents/<agent_uid>` symlinked to `/workspace`. Before enforcing the Home boundary, the Worker resolves all symbolic links. Its layout is:

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
    ├── .codex/config.toml
    ├── AGENTS.md
    └── temp/
```

Models see these absolute container paths directly: the Worker performs no path translation, and every command's working directory must stay inside Agent Home. At the root of `/workspace`, four documents managed by the [Agent Library](../agent-library/) govern the Agent: `SOUL.md` and `MISSION.md` define behavior and responsibilities, `DESIGN.md` specifies the design system for visual work, and `ConfidentialityPolicy.md` guides audience selection when writing to Brain. Alongside them, `installed-skills/`, `sessions/`, and `jobs/` hold Skills, conversation workspaces, and Background Agent Job workspaces; PostgreSQL assigns each Session a stable numeric `workspace-id` starting at `10000`.

Agent Home survives instance deletion and container image updates—rebuilding a Worker clears only `/var/cache/ankole`. Storage durability follows the backing provider: local Docker volumes depend on the host disk, whereas forcing a Cloudflare Worker stop can lose writes made since the last R2 backup. See [Workers](../worker-management/) for provider storage limits.

Attachments, published files, Skills, and Automation scripts live separately in the control-plane Files drive rather than in `/workspace`. Agents use `ankole-files` to read from or publish to that drive, while keeping Job workspaces and Codex threads in persistent Home. Before starting a turn, the Worker synchronizes `installed-skills/` with the control-plane drive.

Codex Home lives at `/workspace/.codex`. Because raw thread files stay in persistent Home, Codex can resume threads across Worker replacements even after the rebuildable SQLite cache at `/var/cache/ankole/codex` is recreated. Background Jobs load Skills on demand through `skill_view`.

## Progress and capacity

The Session Driver owns main-loop streaming and tool presentation, while the Worker sends environment results and Codex progress updates over RuntimeFabric. Streaming progress is best-effort; recovery always relies on the completion facts and stored results persisted in PostgreSQL.

Periodic Worker heartbeats report active workspaces, running Codex turns, and remaining free slots. When a Worker is idle, the control plane releases it according to `idleReleaseAfter` in the provider YAML (setting `never` retains idle Workers indefinitely). Reconnecting over the WebSocket preserves the Worker's process incarnation and all in-flight work.

See [Sessions](../sessions/) for writer and operation fences, [AIGateway](../ai-gateway/) for Responses, [Agent Library](../agent-library/) for Skills, and [Workers](../worker-management/) for provider states.
