---
title: Agent Computer Worker
description: Environment tools, Codex, persistent Home, and recovery across control-plane replacement.
section: Developer guide
order: 108
---

An Agent Computer Worker is one Agent's computer. Agent creation saves the provider binding and an absent Worker row. The control plane starts it when an environment tool or Codex first needs it. Pure questions and control-plane tools work without it.

## Execution and ownership

The Bun Worker executes commands, file and browser tools, Skills, MCP calls, automation scripts, and Codex Jobs. `Ankole.Sessions` in the control plane runs the main Agent loop, commits input consumption and tool results, and owns final replies. AIGateway owns the stored Response chain and hosted tools.

The control plane supplies `WORKER_ID`, the RuntimeFabric endpoint, generation credentials, and storage settings. The Worker serves its own Agent, removes credentials from child environments, and has no database connection. The container is the Agent's isolation boundary; commands run as uid 1000 without sudo.

## Worker pools and the live connection

The Agent's saved Worker provider selects its pool, platform, instance configuration, and storage. Several Agents can use the same pool; the platform creates a separate computer for each Agent. Idle release can remove or pause the instance while retaining Home. See [Worker pools](../worker-management/) for configuration and lifecycle rules.

The Worker opens one authenticated WebSocket to `/runtime-fabric/worker/websocket` and joins its Phoenix Channel. RuntimeFabric protobuf envelopes carry environment calls, results, Codex control, and progress. Generation and incarnation checks reject a replaced Worker. File bytes use one-time HTTP relay URLs; PostgreSQL owns durable recovery facts.

## Operation identity and recovery

Environment work uses a `RunRef` for the Agent, Session, and triggering input. A call is keyed by Response ID and call ID. A replacement Driver probes the existing workspace and adopts a running call or its result. Disconnecting the control plane leaves commands running. After Worker process loss, only safe calls retry; other unknown calls return `interrupted`.

Codex uses `JobTurnRef` with the Job ID and attempt. An `adopt` request keeps the same running turn, thread, and workspace. The Job owner fences terminal writes and consumes applied input IDs in the same transaction. Codex keeps its own model loop.

An open environment workspace and a running Codex turn each use one Worker slot. Main and Workflow model calls do not use these slots.

## The filesystem contract

Agent Home is persistent storage at `/workspace`. `/agents/<agent_uid>` is a symbolic link to `/workspace`; path checks resolve symbolic links before checking the Home boundary. Its layout is:

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

The model sees the absolute container path. The Worker does not translate paths, and a command's working directory must be inside the Agent Home. `SOUL.md` and `MISSION.md` define Agent behavior and responsibility. `DESIGN.md` is the design system for visual work. `ConfidentialityPolicy.md` guides audience selection for Brain writes. The [Agent Library](../agent-library/) manages all four documents. `installed-skills/`, `sessions/`, and `jobs/` hold Skills, conversation workspaces, and Background Agent Job workspaces. PostgreSQL assigns each Session a stable numeric workspace ID that starts at 10000.

Home survives instance deletion and image changes. A rebuild removes only `/var/cache/ankole`. Docker local volumes depend on their host; a forced Cloudflare stop can lose writes since the last R2 backup. See [Workers](../worker-management/) for provider storage limits.

The control-plane drive separately holds attachments, published files, Skills, and Automation scripts. Use `ankole-files` to read or publish drive files. Job workspaces and Codex threads remain in persistent Home. Before a turn, the Worker brings `installed-skills/` in step with the drive.

Codex Home is `/workspace/.codex`. Thread files survive replacement; Codex can resume them even after the rebuildable SQLite cache at `/var/cache/ankole/codex` is replaced. Background Jobs load Skills through `skill_view`.

## Progress and capacity

The Driver owns main-loop streaming and tool presentation. The Worker reports environment results and Codex progress over RuntimeFabric. Progress is best effort; PostgreSQL completion facts and stored results own recovery.

Heartbeats report active workspaces, Codex turns, and free slots. The control plane manages idle release through provider YAML `idleReleaseAfter`; `never` retains an idle Worker. Reconnection keeps the process incarnation and in-flight work.

See [Sessions](../sessions/) for writer and operation fences, [AIGateway](../ai-gateway/) for Responses, [Agent Library](../agent-library/) for Skills, and [Workers](../worker-management/) for provider states.
