---
title: File management
description: Upload reference material, download Agent artifacts, and manage an Agent's drive in the Console.
section: User guide
order: 31
---

**In day-to-day work, you rarely need the Console file browser described on this page. Send files directly to an Agent in chat, or share files across your team through Pod `file` pages and Pod document/Base/Chat attachments. Open the Console file browser only when you need to recover an undelivered artifact, inspect saved outputs, or organize an Agent's private drive folders manually.**

Each Agent has its own private control-plane drive for chat attachments, generated images, published files, installed Skills, and Automation scripts. Shared workspace files—Pod `file` pages and Pod attachments—live in the Pod workspace under Pod page permissions rather than inside an individual Agent's drive. From the Console, you can upload, download, move, and delete files on an Agent's drive even while its Worker is stopped (note that Session and Job workspaces live in persistent Agent Home rather than drive folders).

Operators configure the underlying local directory, S3, or R2 backend via [Control-plane drive storage](../drive-storage/); to migrate files from legacy Home layouts, see [Upgrade from 1.0 to 2.0](../upgrade-to-2/).

## Find an Agent's files

1. Open **Agents** in the Console and select the Agent.
2. Under **Drive**, select **Browse files**.

| Folder | Contents |
|---|---|
| `inbox/` | Attachments that people sent to the Agent |
| `generated/` | Images that the Agent generated |
| `sent/` | Files that the Agent attached to replies |
| `skills/` | The Agent's installed Skills, one folder per Skill |
| `automation/` | Automation Job scripts |
| Other folders | Files saved explicitly by the Agent or an operator |

## Upload reference material

1. Open the target folder (or type a folder path during upload).
2. Select **Upload** and choose your file—uploading to an existing path overwrites that file.
3. In chat, give the Agent the exact drive path and tell it what to do with the file.

Ankole creates intermediate folders automatically on upload. Organize files under descriptive paths such as `customer-research/2026-q3-interviews.pdf` rather than dumping everything at the drive root or using vague filenames like `final-v2-new.pdf`.

Uploading places a file on the drive without starting an Agent turn: message the Agent in chat when you want it to read the file, or submit the file through **Learn source** to extract durable Brain knowledge from it.

## Download Agent artifacts

An Agent's drive holds files that the Agent explicitly published to its drive as well as files that it attached to chat replies (under `sent/`). If an Agent wrote a file only inside its temporary or conversation workspace, ask the Agent in chat to publish it to the drive first.

Whenever an attachment arrives normally in chat, download it directly from the conversation; use the Console file browser when you need to recover an undelivered artifact, inspect saved outputs, or curate files for long-term retention.

## Move and delete

Open the action menu beside any file or folder to move, rename, or delete it (moving or renaming leaves file contents untouched).

Deletion is immediate and permanent—there is no trash bin, and deleting a folder removes every file inside it. Before deleting anything, confirm that no active Agent work depends on those files and either download important outputs or verify that your [backup](../backup-and-restore/) covers them.

Files under `skills/` back the Agent's installed Skills directly, so editing or deleting files there alters the Skill on the very next turn; enable or disable Skills safely through the [Agent Library](../skills/) instead.

## What remains after a restart

Both the control-plane drive and persistent Agent Home survive Worker replacements. Files written only inside a Session or Job workspace stay in Agent Home until the Agent publishes them to the drive; see [Workers](../worker-management/) for provider storage limits.

The Agent's core persona and policy documents—`MISSION`, `SOUL`, `DESIGN`, and `CONFIDENTIALITY POLICY` (`ConfidentialityPolicy.md`)—are edited on the Agent page and projected into the Worker automatically rather than stored as drive files; see [Agents](../agents/).

## Common problems

- **The Agent cannot find an uploaded file:** include the exact drive path in your chat message so the Agent can fetch it with `ankole-files get`.
- **A generated artifact is missing:** ask the Agent to save the file to its drive, or check whether the Background Job is still running.
- **An upload fails with a size error:** individual uploads are capped at 100 MiB.
- **An attachment shows as unavailable:** downloading the file from the external chat channel or uploading it to the store failed; ask the sender to resend it.
