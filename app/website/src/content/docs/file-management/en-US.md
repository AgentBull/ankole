---
title: File management
description: How the Agent Home filesystem works — the layout, what is durable, how files move between the control plane and the worker, and the Console's worker-file surface.
section: User guide
order: 45
---

Agent Home is the shared filesystem an agent's worker reads from and writes to during a turn. It holds persona documents, workspace files, installed skills, session state, and job artifacts. This page is the operator-facing view of that filesystem — its layout, what is durable, how files move between the control plane and the worker, and the Console routes that manage them.

The decisive property, stated up front: Agent Home is a **real filesystem the model sees as paths**, not an abstraction. The model-visible absolute path is the container path — the worker does not translate paths. What is durable is the filesystem itself (on a persistent volume); what is ephemeral is the process that reads and writes it.

## The layout

Agent Home is mounted at `/agents`, laid out per actor key:

```text
/agents/<agent-key>/
├── .codex/                    # Codex configuration
├── SOUL.md                    # persona: tone and behavior
├── MISSION.md                 # persona: scope and responsibility
├── DESIGN.md                  # persona: working agreements
├── user-files/                # operator-provided files
├── installed-skills/          # agent-installed skill bundles
├── sessions/<base64url-session-id>/   # per-session workspace
└── jobs/<job-id>/             # per-job workspace
    ├── .codex/config.toml
    ├── .ankole/skills/
    └── temp/
```

The persona documents (`SOUL.md`, `MISSION.md`, `DESIGN.md`) are the agent's own library documents — authored through the Console, projected into the filesystem. The `sessions/` and `jobs/` directories are per-session and per-job workspaces, isolated by the session or job id. The model sees these paths verbatim — there is no path translation layer.

## What is durable, what is ephemeral

| Path | Durable? | Why |
|---|---|---|
| `/agents/<key>/SOUL.md`, `MISSION.md`, `DESIGN.md` | yes | projected from PostgreSQL; survive worker restart |
| `/agents/<key>/user-files/` | yes | on the persistent volume |
| `/agents/<key>/installed-skills/` | yes | on the persistent volume; synced by the Agent Library |
| `/agents/<key>/sessions/<id>/` | yes | on the persistent volume; per-session context |
| `/agents/<key>/jobs/<id>/` | yes | on the persistent volume; per-job workspace |
| Worker-local temp (`/tmp`) | no | ephemeral; gone when the worker restarts |

Agent Home is backed by the `ankole_agents_data` volume (Compose) or the RWX claim (Helm). A worker that restarts reads the same files; a volume that is lost takes the files with it. See [Backup and restore](../backup-and-restore/) for how to protect Agent Home.

## How files move between the control plane and the worker

The worker reads Agent Home directly — it does not fetch files from the control plane over RPC for normal operation. Two paths exist for moving files explicitly:

- **The file transfer lane** — a dedicated RuntimeFabric lane for uploading, downloading, moving, and deleting files on a worker. This is what the Console's `/agent-computer-workers/:worker_id/files` routes use. It has its own codec and path-security checks, separate from the RPC lane.
- **Worker-file Console routes** — the operator surface for managing files on a specific worker:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/agent-computer-workers/:worker_id/files` | List files |
| `GET` | `/agent-computer-workers/:worker_id/files/content` | Download file content |
| `POST` | `/agent-computer-workers/:worker_id/files` | Upload a file |
| `POST` | `/agent-computer-workers/:worker_id/file-moves` | Move a file |
| `DELETE` | `/agent-computer-workers/:worker_id/files` | Delete files |

These routes are scoped to a worker id, not to an agent — they operate on whatever the worker's Agent Home contains.

## Persona documents

The three persona documents — `SOUL.md`, `MISSION.md`, `DESIGN.md` — are the operator-authored files the agent reads on every turn (see [Agents](../agents/)). They are stored in the `agent_library_container_entries` table in PostgreSQL (as agent-owned, content-addressed rows) and projected into the filesystem at `/agents/<key>/`. The operator authors them through `PUT /agents/:agent_uid/library-documents/:document_kind`; the agent reads them as files.

This means the persona documents are **durable truth (PostgreSQL) projected as files (Agent Home)**. Editing the document through the Console updates the PostgreSQL row; the next turn reads the updated projection. See [Prompt assembly](../prompt-assembly/) for how they reach the system prompt.

## Installed skills

The `installed-skills/` directory holds skill bundles the agent has installed — distinct from the builtin skills shipped in the app image (`app/library/skills/`). The Agent Library syncs this directory against what it observes in worker-visible storage, so a skill that disappears from storage is reflected in the registry. See [Agent Library](../agent-library/) for the sync model and [Skills](../skills/) for the user-facing view.

## What this guide is not

It is not a filesystem permissions guide — the worker runs under bubblewrap confinement, and the paths above are what the agent sees inside that sandbox. It is not a file-transfer protocol reference — the file transfer lane is the [Kernel](../kernel/) page's scope. And it is not a substitute for the Console API reference; the exact request shapes for the worker-file routes are there.

## Next steps

- For the persona documents, read [Agents](../agents/).
- For the Agent Library that syncs skills, read [Agent Library](../agent-library/).
- For the backup that protects Agent Home, read [Backup and restore](../backup-and-restore/).
- For the Console routes, read the [Console API reference](../console-api/).
