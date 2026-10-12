---
title: File management
description: Upload reference material, download Agent artifacts, and manage an Agent's drive in the Console.
section: User guide
order: 31
---

**You typically do not need the file browser described on this page. Send files directly to the Agent in chat to create, read, modify, organize, or transfer files. Use the Console file browser only to recover undelivered artifacts, inspect saved outputs, or organize folders manually.**

Each Agent has a control-plane drive for attachments, images, published files, installed Skills, and Automation scripts. The Console can upload, download, move, and delete these files even while no Worker runs. Session and Job workspaces live in persistent Home and are not drive folders.

Operators can configure local folders, S3, or R2 with [Control-plane drive storage](../drive-storage/). For files in legacy Home, see [Upgrade from 1.0 to 2.0](../upgrade-to-2/).

## Find an Agent's files

1. Open **Agents** in the Console and open the Agent.
2. Under **Drive**, select **Browse files**.

| Folder | Contents |
|---|---|
| `inbox/` | Attachments that people sent the Agent |
| `generated/` | Images that the Agent generated |
| `sent/` | Files that the Agent attached to replies |
| `skills/` | The Agent's installed Skills, one folder per Skill |
| `automation/` | Automation Job scripts |
| Other folders | Files that the Agent or a person saved |

## Upload reference material

1. Open the target folder, or enter a folder during upload.
2. Select **Upload** and add the file. A file that already exists at the same path is replaced.
3. In chat, tell the Agent the drive path and the task.

Folders in the path are created on upload. Use stable names such as `customer-research/2026-q3-interviews.pdf`. Do not put every file at the root, and avoid names such as `final-v2-new.pdf` that do not identify the content.

Uploading makes the file available to the Agent. It does not start work. Tell the Agent to use it in chat. To turn the material into durable knowledge, submit it through **Learn source**.

## Download Agent artifacts

The drive holds the files that the Agent saved and the files that it attached to replies (under `sent/`). A file that the Agent only wrote into its conversation workspace is not in the drive; ask the Agent to save it.

If the attachment arrived in chat, download it there. Use the Console to recover an artifact that was not delivered, inspect saved outputs, or organize results that must be retained.

## Move and delete

Use the action menu for a file or folder to move, rename, or delete it. A move does not change the file contents.

Deletion is permanent and has no trash. Deleting a folder deletes every file in it. Confirm that no active Agent work uses the files.

Download important material first, or confirm that it is included in a [backup](../backup-and-restore/).

Files under `skills/` are the installed Skills. A change there changes the Skill for the next turn. Manage Skill enablement in the [Agent Library](../skills/).

## What remains after a restart

The drive and persistent Home survive Worker instance replacement. Files that an Agent only writes to its workspace stay in Home; publish them to the drive to make them available in the Console. See [Workers](../worker-management/) for storage limits.

The Agent's `MISSION`, `SOUL`, and `DESIGN` documents are managed in the Agent editor. They are projected to the Worker and are not drive files. See [Agents](../agents/) for those documents.

## Common problems

- **The Agent cannot find an uploaded file:** include the exact drive path in your message. The Agent fetches it with `ankole-files get`.
- **A generated artifact is missing:** ask the Agent to save it to its drive, or confirm that the Job finished.
- **An upload fails with a size error:** one file can have at most 100 MiB.
- **An attachment shows as not available:** it arrived before the drive existed or its download failed. Ask the sender to send it again.
