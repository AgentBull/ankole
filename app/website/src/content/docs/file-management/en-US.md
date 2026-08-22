---
title: File management
description: Upload reference material, download Agent artifacts, and manage durable Agent files in the Console.
section: User guide
order: 31
---

**Most of the time, you do not need the file browser described on this page. Send a file to the Agent, or ask it in chat to create, read, change, organize, or send files. Use the Console when you must recover an artifact that was not delivered, inspect intermediate files, or organize files manually.**

Agents read source material and save work and artifacts in durable Worker storage. The Console lets you upload references, download reports, images, or data files, and rename or remove material that is no longer needed.

## Find an Agent's files

1. Open **Workers** in the Console.
2. Select a ready Worker and then **Browse files**.
3. Select the Agent.
4. Select the file root:

| Root | Contents | Common actions |
|---|---|---|
| **User files** | References, templates, and input files that a person provided | Upload, download, rename, or remove |
| **Agent sessions** | Work files from Agent conversations | Download artifacts and remove old files when needed |
| **Agent installed skills** | Skill files that the Agent can currently read | Confirm synchronization; normally do not edit them here |

The list opens through one Worker, but all Workers in a production deployment must share durable Agent storage. Docker Compose uses a local persistent volume. Kubernetes uses a shared volume that several nodes can read and write.

If Workers show different files, repair the storage mounts instead of uploading duplicate copies.

## Upload reference material

1. Open **User files**.
2. Open the target directory, or enter a subdirectory during upload.
3. Select **Upload** and add the file.
4. In chat, tell the Agent the file name, directory, and task.

An upload creates missing subdirectories. Use stable names such as `customer-research/2026-q3-interviews.pdf`. Do not put every file at the root, and avoid names such as `final-v2-new.pdf` that do not identify the content.

Uploading makes the file readable. It does not start work. Tell the Agent to use it in chat. To turn the material into durable knowledge, submit it through **Learn source**.

## Download Agent artifacts

After an Agent creates a file in a conversation, find it under **Agent sessions** and download it. For a large directory, first open the relevant conversation path and then search by name or kind.

If the attachment arrived in chat, download it there. Use the Console to recover an artifact that was not delivered, inspect intermediate files, or organize results that must be retained.

## Rename and remove

Use the action menu for a file to rename or remove it. Rename does not change the file contents.

Removal is permanent and has no trash. Removing a directory also removes its children. Confirm that no active Agent work uses the files.

Download important material first, or confirm that it is included in a [backup](../backup-and-restore/).

Do not edit files under **Agent installed skills**. Manage Skill enablement in the [Agent Library](../skills/). Change Skill content at its source and synchronize it again.

## What remains after a restart

User files, Agent session files, and installed Skills live on persistent storage and remain after a Worker restart. Worker temporary directories are outside this view and can disappear after a restart.

The Agent's `MISSION`, `SOUL`, and `DESIGN` documents are managed in the Agent editor. They are projected to the Worker but must not be changed through the file browser. See [Agents](../agents/) for those documents.

## Common problems

- **The list is empty:** confirm the Worker, Agent, and file root, and check that the Worker is ready.
- **The Agent cannot find an uploaded file:** confirm that the file is in that Agent's **User files**, and include the exact relative path in your message.
- **Only some Workers show the file:** confirm that every Worker mounts the same persistent volume.
- **A generated artifact is missing:** confirm that the Job finished and inspect the correct conversation directory.
- **The list is truncated:** open a more specific subdirectory and search again.
