---
title: File management
description: Manage Unified Drive roots in the Console, work with Worker /drive FUSE mounts, and handle attachments and Trash retention.
section: User guide
order: 31
---

**In day-to-day work, people share files directly in chat or collaborate in Pod pages, while Agents read and write `/drive` directly. Open the Console Drive browser when you need to inspect tenant roots while Workers are offline, upload reference datasets, download saved outputs, or reorganize folders across spaces.**

Ankole unifies collaboration pages and runtime files in **Unified Drive**: `Ankole.Pod` owns the `pages` tree, permissions, and Trash lifecycle, while `Ankole.Files` stores tenant-scoped immutable byte blobs in `file_objects` (keeping embedded document, Base, and Applet assets in `pod_files` so they do not clutter Drive listings). Session and Background Agent Job working trees (`/workspace`) live in persistent Agent Home rather than Drive; operators configure the underlying object store via [Control-plane drive storage](../drive-storage/), and 1.x Home imports are covered in [Upgrade from 1.0 to 2.0](../upgrade-to-2/).

## Worker `/drive` mounts and CLI fallback

On FUSE-capable Workers, the root supervisor mounts `/drive` inside each command or Codex process's private mount namespace before dropping to `uid 1000`, exposing the roots permitted by the current execution's access graph:

| Path | Mode | Contents |
|---|---|---|
| `/drive/Public` | Read-write | Shared Pod Space pages, folders, and files (projected as plain directories plus `._adoc.md`, `._abase`, and `._aapp` views where applicable) |
| `/drive/MyDrive` | Read-write | The human owner's Private space when the Agent acts as that member's Personal Assistant |
| `/drive/AgentDrive` | Read-write | The Agent's private runtime root for saved outputs and generated images outside a conversation |
| `/drive/ChatDrive` | Read-write | The active conversation's isolated root for inbound attachments, conversation-generated images, and shared deliverables |
| `/drive/Brain` | Read-only | Brain knowledge pages (`._awiki.md`) filtered by the current room and requester disclosure rules |
| `/drive/Skills` | Read-only | Enabled Skill packages managed in **Meta Ankole → Skills** (see [Skills](../skills/)) |
| `/drive/AGENTS.md`, `/drive/DESIGN.md` | Read-only | Effective composed behavior and design contracts managed in **Meta Ankole → Agents** (see [Agents](../agents/)) |
| `/drive-recovery` | Read-write (local) | Scoped recovery directory where the Worker preserves local draft bytes and diagnostics if a background VFS writeback hits a `412` or `422` conflict |

When a Worker environment cannot mount FUSE during startup probing, Ankole advertises the `ankole-files` CLI (`list`, `get --node-id`, `put`, `mv`, `rm`) over the signed WorkerFiles relay instead. To send a Drive file into chat, `reply_attachment` accepts either a Drive `node_id` or a `/drive/...` path, flushing any pending FUSE writes before capturing the completed object.

## Browse and upload in the Console

1. Open **Drive** in the Console for the selected tenant.
2. Browse **Pod Space**, **Brain**, **Private** roots (for members and Agents), or **Conversation** roots—even when no Worker is running.
3. Open the target folder and select **Upload** to upload individual files or directory trees. Uploading to an existing file name replaces that node's current `object_id`.

Organize reference material under clear, stable paths such as `customer-research/2026-q3-interviews.pdf`. Uploading stores the file in Drive without waking an Agent: mention the path or page in chat when you want an Agent to process it, or submit documents through **Learn source** when you want Brain to extract durable knowledge.

## Attachments, Trash, and retention

Open the action menu beside any non-root item to move, rename, or delete it (roots themselves cannot be moved, renamed, or trashed).

- **Unified Drive Trash:** Deleting a file or folder moves its subtree into Trash immediately and hides it from Drive and Pod listings. Trashed items remain recoverable by callers with `manage` permission until `drive.trash_retention_days` elapses (default `30` days; setting `0` retains trashed items indefinitely until the setting changes). Keep important data covered by your regular [backup](../backup-and-restore/) before permanent purge.
- **Frozen chat attachments:** When a message is sent, Ankole records an immutable `object_id` reference in `message_attachments` (and `ankole-pod chat attachment get` reads that frozen object). Overwriting, renaming, moving, or trashing the Drive file later leaves already-sent conversation attachments intact.

## What persists across Worker restarts

Unified Drive objects live in PostgreSQL and your configured object store, while `/workspace` repositories and scratch files live in persistent Agent Home; both survive Worker restarts and image updates. Files written only under `/workspace` stay in Agent Home until the Agent copies them into `/drive` (or uploads them with `ankole-files put`). See [Worker management](../worker-management/) for provider storage characteristics.

## Common problems

- **The Agent cannot find an uploaded file:** Share the exact `/drive/...` path (or page link) in chat, and verify that the executing Agent holds `view` access on that root or folder. On Workers without FUSE, the Agent fetches Drive nodes with `ankole-files list` and `ankole-files get --node-id`.
- **A generated artifact is missing from Drive:** Ask the Agent to copy the file from `/workspace` into `/drive/ChatDrive`, `/drive/AgentDrive`, or `/drive/Public`, or check whether its Background Agent Job is still running.
- **Concurrent edit conflict during FUSE writeback:** If another writer updates or moves a node before a Worker's cached write commits (`412` or `422`), inspect `/drive-recovery` in that execution scope to recover the preserved draft bytes.
- **An upload fails with a size limit error:** Streaming backends (`fs`, `s3`, `gcs`, `azblob`, `oss`, `cos`, `tos`, `sftp`) follow the backend limit narrowed by `drive.vfs_max_upload_bytes` (when non-zero); `postgresql` and `webdav` cap whole-object uploads at 100 MiB, `d1` caps single objects at 2,000,000 bytes, and structured Markdown page projections cap at 100 MiB.
