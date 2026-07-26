---
title: Worker files
description: How to upload, download, move, and delete files on a worker's Agent Home filesystem — the Console routes and what each does.
section: User guide
order: 47
---

The worker's Agent Home filesystem is where the agent reads and writes files during a turn. Sometimes an operator needs to manage those files directly — upload a reference document, download a generated artifact, move a misplaced file, clean up old work. This page is the operator surface for those moves, through the Console's worker-file routes.

The decisive property, stated up front: these routes operate on a **specific worker's filesystem**, not on a logical agent. The route is scoped to a `worker_id`, and it moves real files on that worker's Agent Home volume. There is no "agent file store" abstraction above the filesystem — the filesystem is the store.

## The routes

Five Console routes cover the operator's file moves:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/agent-computer-workers/:worker_id/files` | List files in a worker filesystem root |
| `GET` | `/agent-computer-workers/:worker_id/files/content` | Download one file |
| `POST` | `/agent-computer-workers/:worker_id/files` | Upload one file |
| `POST` | `/agent-computer-workers/:worker_id/file-moves` | Rename or move a path |
| `DELETE` | `/agent-computer-workers/:worker_id/files` | Delete one file or directory |

Each route targets a worker by its `worker_id` — the same id visible in `GET /agent-computer-workers`. The file paths are relative to the worker's Agent Home root (`/agents`).

## Upload a file

Upload a reference document or a template the agent needs:

```bash
curl -X POST https://ankole.example.com/api/v1/agent-computer-workers/<worker_id>/files \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -F "path=user-files/reference.md" \
  -F "file=@local-file.md"
```

The uploaded file lands at the specified path relative to Agent Home. Use the `user-files/` directory for operator-provided files — it is the conventional place for files the agent should see but did not create itself.

## Download a file

Retrieve a generated artifact — a report the agent wrote, a chart it produced, a log it saved:

```bash
curl -o output.pdf https://ankole.example.com/api/v1/agent-computer-workers/<worker_id>/files/content \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -G -d "path=jobs/42/output.pdf"
```

The path is relative to Agent Home. The response is the file's raw bytes.

## Move or rename a file

```bash
curl -X POST https://ankole.example.com/api/v1/agent-computer-workers/<worker_id>/file-moves \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "from": "temp/draft.md", "to": "user-files/final.md" }'
```

The move is atomic on the filesystem — the file appears at the destination and disappears from the source. Use it to relocate a file the agent put in the wrong place, or to promote a draft to a permanent location.

## Delete a file

```bash
curl -X DELETE https://ankole.example.com/api/v1/agent-computer-workers/<worker_id>/files \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -G -d "path=temp/old-output.txt"
```

Deletion is permanent — the file is removed from the filesystem, not moved to a trash. Use it for cleanup; do not use it for anything you might want back (restore from backup instead — see [Backup and restore](../backup-and-restore/)).

## What this guide is not

It is not a file-transfer protocol reference — the file transfer lane (RuntimeFabric) is the [Kernel](../kernel/) page's scope. It is not a permissions guide — the worker runs under bubblewrap, and the paths above are what the agent sees inside that sandbox. And it is not a substitute for the [file management](../file-management/) page — that page covers the layout and durability model; this page covers the operator's file moves.

## Next steps

- For the Agent Home layout and durability, read [File management](../file-management/).
- For the Console routes, read the [Console API reference](../console-api/).
- For backup, read [Backup and restore](../backup-and-restore/).
