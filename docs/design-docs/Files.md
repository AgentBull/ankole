# Files

Drive references and grants belong to the Agent's tenant. Content-addressed blob
bytes and their storage configuration belong to the site. Tenant deletion removes
its references; the garbage collector deletes only bytes without drive or
uncompleted Outbox references.
A blob still referenced by another tenant remains.

Each Agent has a drive in the control plane. The drive holds received
attachments, generated images, reply attachments, installed Skills, Automation
scripts, and files that the Agent publishes. It is available without a running
Worker. The drive is the formal store for sensitive user files and deliverables.
The Agent also has persistent Home at `/workspace`, which holds temporary
Session and Job working directories and Codex thread files. Home persistence
supports resume; it does not make a workspace a delivery store. See
[Agent Workers](AgentWorkers.md#files-and-isolation).

`Ankole.Files` owns the drive. PostgreSQL stores which path names which
content. An object store keeps the bytes.

## What PostgreSQL Stores

| Table | Columns | Meaning |
| --- | --- | --- |
| `files` | `sha256` (primary key), `size`, `deleting`, `created_at`, `last_referenced_at` | One distinct byte content |
| `agent_files` | `agent_uid`, `path`, `sha256`, `mode`, `content_type`, `source`, `signal_channel_id`, `source_entry_id`, timestamps; primary key `(agent_uid, path)` | One file in one Agent's drive |

- A path identifies a file. A folder is only a path prefix; there are no folder
  rows. A path is relative, uses `/`, has at most 1024 bytes, and has no empty,
  `.`, or `..` segment. A segment has at most 255 bytes. A file cannot also be
  the parent of another file: `a` and `a/b` cannot exist together.
- One content is stored once. Two Agents that receive the same file, or one
  Agent that saves the same bytes at two paths, add only `agent_files` rows.
- `source` is `inbound`, `generated`, `sent`, `agent`, or `console`.
- `signal_channel_id` and `source_entry_id` retain the origin of a projected
  attachment. The Console listing and Files RPC return them; moves preserve
  them. Files with no provider origin have null values in the Console API.
- `content_type` is the declared type: the provider MIME type, the
  `reply_attachment` type, the generated image type, or the type for the file
  extension. The file service does not inspect bytes.
- `agent_files` rows cascade with the Agent principal. Deleting an Agent
  deletes its drive in the same transaction.
- An Agent reads and writes only its own drive.

Some prefixes have a fixed meaning:

| Prefix | Writer |
| --- | --- |
| `chats/<channel>/inbox/<digest>/<file name>` | Adapter ingress for a received attachment |
| `chats/<channel>/generated/<digest>/<file name>` | AIGateway image generation in a channel conversation |
| `generated/<digest>/<file name>` | AIGateway image generation without a source channel |
| `skills/<name>/…` | Console upload or `ankole-files put` |
| `automation/<folder>-<suffix>/…` | Automation Job registration |

`<digest>` is the first 16 hexadecimal characters of the content SHA-256. The
same content with the same file name gets the same path within one channel,
and a repeated write is idempotent. Two channels keep separate paths and
provenance for the same bytes.

## Conversation Files and Delivery

Each channel has one drive directory, `chats/<channel>/`. The channel ID is
stable across Session resets. Colons and URI-unreserved characters stay as
written; other bytes use percent encoding, so a channel ID cannot add a path
segment. A channel ID equal to `.` or `..` encodes each dot.
Received attachments, generated images, and deliverables belong under
this directory. Paths outside `chats/` hold shared files, Skills, and scripts.

The Worker is the Agent's personal computer. The Agent can read and write its
whole Home and drive. There is no filesystem or drive read isolation between
conversations. The main system prompt names the current workspace and channel
drive directory. It tells the Agent to use the workspace for temporary work,
save files that must be kept or delivered in its channel drive directory, and
leave other conversations' workspaces and drive directories alone. A DM prompt
also identifies the conversation as private. A Background Job receives its
source conversation's drive directory on start and resume.

The control plane checks attachment paths at the common Outbox commit boundary.
A file under `chats/<channel>/` can be delivered only to that channel. This
applies to final replies, `send_message`, and generated images, including
schedule delivery targets. A file outside `chats/` can be delivered to any
channel. The check uses the actual destination. It does not track content
lineage: an Agent that copies or moves a file to a shared path can deliver it
elsewhere. The prompt convention and this delivery check are the supported
contract.

## Bytes

The object key of a content is `blobs/<sha256 hex>`. The Rust kernel module
`object_store`, built on OpenDAL, reads and writes objects. It has two
backends: a local directory (`fs`) and S3 or an S3-compatible service such as
Cloudflare R2 (`s3`). Every operation runs on the kernel's Tokio runtime, and
large files move through local files, never through one large binary.
`Ankole.ObjectStore` opens the store once per node; only the file service
(`Ankole.Files` and its collection job) calls it.

A write that stops before it completes, for example because the control plane
stopped, leaves data that no object references. The `fs` backend writes
through `<root>/.tmp` and a rename; opening the store removes temporary files
that did not change for one day. The `s3` backend writes a large object as a
multipart upload and aborts the upload when the write fails, but a stopped
process cannot abort it. Give the bucket a lifecycle rule that aborts
incomplete multipart uploads.

The store is a bootstrap fact:

| Variable | Meaning |
| --- | --- |
| `ANKOLE_FILES_STORE` | `fs` or `s3`; required in production |
| `ANKOLE_FILES_FS_ROOT` | `fs`: absolute directory on a persistent volume of the control plane |
| `ANKOLE_FILES_S3_BUCKET`, `ANKOLE_FILES_S3_REGION` | `s3`: bucket and region; R2 uses the region `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | `s3`: optional endpoint of an S3-compatible service |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID`, `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | `s3`: optional static credentials; without them the default AWS credential chain applies, including EKS Pod Identity |
| `ANKOLE_FILES_S3_ROOT` | `s3`: optional key prefix |

An `fs` directory must be visible to every control-plane replica, so more than
one replica needs `s3`. Development uses `var/ankole-dev/files`; tests use one
directory per test partition.

## Writes

A write has two steps:

1. `store/1` makes the bytes durable. It upserts the `files` row, which clears
   `deleting` and refreshes `last_referenced_at`, and then writes the object.
2. `commit/4` names stored contents at paths and removes paths in one
   transaction. It refreshes each content with a row-locking update that skips
   rows marked `deleting`, so a content that collection has started to remove
   cannot get a new name. A missing or marked content fails the whole commit
   with `{:blob_missing, sha256}`.

Commits, moves, and deletes take the same per-Agent transaction lock before
they read or change paths. A commit or move checks the complete resulting
tree and rejects file/parent conflicts atomically. Deleting `a` and adding
`a/b` in one commit is valid, as is the reverse change.

The Oban cron job `Ankole.Files.Jobs.CollectUnreferenced` runs every hour. It
marks old contents with no drive path or uncompleted Outbox attachment
reference, and removes the marked rows in batches of 100: first the row, only if
it is still unreferenced, then the object. A marked row that has a reference
again loses its mark. The one-day interval protects a content between its
`store` and its `commit`.

## Worker Access

The Worker never holds storage credentials. Three RuntimeFabric RPCs with
`worker_agent` scope give it the drive of the Agent on the connection:

| Method | Result |
| --- | --- |
| `files.list` | Files under a prefix in path order, with paging. A path that names a file lists that file. |
| `files.get` | Writes one drive file to a path in the Agent Home of the calling Worker |
| `files.commit` | Names files from the Agent Home of the calling Worker at drive paths and removes drive paths |

Bytes never travel in the RPC payload. The control plane moves them over the
[WorkerFiles relay](RuntimeFabric.md#worker-files) of the Worker that called
the RPC. A transfer carries at most 100 MiB. A commit skips the transfer when
the Agent's drive already names the declared digest, and transfers a content
that several upserts declare once. Files under the same top-level folder of
the Agent Home travel together in bundles of at most 100 MiB, packed by the
size that each upsert declares; a file alone in its group travels by itself.

The turn-local command `ankole-files` gives the model the drive:
`list [<folder>] [--after <path>]`, `get <drive path> [--output <local path>]`,
`put <local path> <drive path>`, and `rm <drive path>`. `get` writes to
`drive/<path>` in the current workspace by default. `put` copies one file or
every regular file under a directory; it skips symlinks. A partial `list`
returns `next_after`; pass it as `--after` to read the next page.

## Attachments

Inbound: the adapter downloads the provider bytes once and calls
`Ingress.store_attachment/3`. The attachment JSON then carries `blob_ref` (the
SHA-256), an intermediate `inbox/` path, and `size`. An attachment with `blob_ref`
and `path` needs no other download, whichever Agent received it first. The
gateway prefixes the path with `chats/<channel>/` when it knows the source
channel. It names the content in the Agent's drive when it mirrors the entry, and
again before it delivers an ActorEvent, so every attachment that the model
sees can be fetched. The model sees the drive path and fetches the file with
`ankole-files get`. Native image input fetches the image into the workspace
the same way.

Outbound: `reply_attachment` accepts only `drive_path`, with optional display
name and MIME type. Save a local deliverable with `ankole-files put` first.
The control plane owns the declaration and execution; this tool needs no
Worker. It records the original drive path and its content digest. It does
not copy the file to `sent/`. The outbox payload carries `path`,
`blob_ref`, `name`, `mime_type`, and `size`. The turn commit checks that the
drive still names that content at that path and checks the destination channel.
Changing or deleting the drive file before that commit rejects the attachment.
Adapters read the bytes by
`blob_ref`; a missing content blocks the delivery with
`attachment_file_missing`. An Outbox commit locks and refreshes its referenced
contents in the same transaction. Collection checks attachment references in
every tenant. A row that has not succeeded retains its bytes even after the
last drive path is deleted. Successful delivery or deletion of the intent
releases that reference.

Generated images: when a turn completes, the gateway stores each generated
image artifact and names it under `chats/<channel>/generated/`, or under shared
`generated/` when the conversation has no source channel.

An inbound attachment from before the drive has no `blob_ref`. The model sees
its name marked as not available.

## Upgrade From Shared Inbox Paths

The migration moves inbound `inbox/` drive rows with a recorded
`signal_channel_id` into that channel's directory. It changes paths only;
content, provenance, and timestamps stay unchanged. It stops on a path conflict
or a path that exceeds the drive limits, so operators must resolve the conflict
before retrying the migration.

Rows without a source channel stay at their existing paths, and the migration
reports their count. Operators must place sensitive files from these rows in
the correct channel directories before the delivery check can protect them.
Before this migration, the same bytes and filename could replace one shared
drive row's source channel. Only the recorded channel can be recovered from
that row. Other historical uses cannot be inferred from it.

Old ActorEvent payloads can still contain `inbox/` paths. Input rendering and
attachment linking resolve these references under the event's channel directory
without changing the stored event. Existing `sent/` rows and committed Outbox
references remain valid shared paths; new deliveries no longer create them.

## Skills and Automation Scripts

An installed Skill is the file tree under `skills/<name>/`. The control plane
reads the manifests from the drive to synchronize the Skill catalog, under
the same per-Agent lock as path changes. It changes the catalog only after
the complete read succeeds, and a manifest update preserves the operator's
`enabled_override`. Worker cache contents do not define the catalog.

The control plane reads Skill instructions from the drive when requested;
updated scripts and MCP files take effect when the Worker prepares the next Turn.

Before each turn or Automation Job run, the Worker brings its local
`installed-skills/` directory in step with the drive. It removes indexed files
that the drive no longer has and downloads changed files. A local index
records size, mtime, and digest, so an unchanged file is not hashed again.
Each list page carries a digest of the complete path, content, and mode
manifest, read under the drive transaction lock. The Worker requires the
same revision on every page. Downloads must match the listed digest, size,
and mode, and the local bytes must match the digest. A change fails
preparation before execution; the next preparation can read the new version.
Permission changes apply even when the file contents did not change.
The Worker updates this shared cache one preparation at a time, including
the drive listing and the index write. A failed preparation does not block
the next one.
Files that never came from the drive stay. A download failure stops preparation;
an Automation Job treats it as an infrastructure failure.

An Automation Job script is the folder at its `drive_prefix`. Registration
copies the script directory to a new folder under `automation/` and requires
`main.ts` in it. If the control plane explicitly rejects registration, the
Worker removes that folder. If the result is unknown, it keeps the folder and
tells the caller to list jobs before trying again. Each run copies the folder
and its installed Skills to a fresh directory in the Agent Home, runs
`main.ts` there, and removes the directory. Later cache updates do not change
this run's Skill files. See
[Automation Jobs](AutomationJobs.md).

## Console

The Agent files page is the drive browser: list a folder, download, upload,
move or rename, and delete. Every operation calls `Ankole.Files` directly and
works while the Agent has no running Worker. A listing shows at most 1000
folders and 1000 files of one folder; when a folder has more, the response
says `truncated` and the page says that the list is partial. The page can
upload a chosen folder: each file keeps its path inside that folder, so a
Skill folder goes to `skills/<name>/` in one upload. A move changes the path of
every file under a folder in one transaction, whatever the folder's size.

| Route | Operation |
| --- | --- |
| `GET /api/v1/agents/:agent_uid/files?path=` | Folders and files of one folder |
| `GET /api/v1/agents/:agent_uid/files/content?path=` | Download one file |
| `POST /api/v1/agents/:agent_uid/files` | Upload one file (multipart: `path`, `file`) |
| `POST /api/v1/agents/:agent_uid/file-moves` | Move or rename a file or folder |
| `DELETE /api/v1/agents/:agent_uid/files?path=` | Delete a file, or a folder and every file in it |

Moves reject an existing target file with `already_exists`; the API has no
overwrite option.

The AuthZ resource is `agent:<uid>:files` with the actions `read`, `update`,
and `delete`.

## Upgrade From Agent Home Files

An existing instance has Agent files under `/agents/<uid>`. The one-time
import copies them into the drives:

- `installed-skills/<name>/` to `skills/<name>/` for each folder with a
  `SKILL.md`;
- the directory of each Automation Job created before the drive to its
  `drive_prefix`;
- files named by unsent legacy Outbox attachments from `user-files/` to
  content-addressed `sent/` paths. It updates the attachment with `blob_ref`
  and `path`, retaining provider metadata, attempt counts, and recovery state.

Other user files, Session workspaces, and Job workspaces stay in Home.
Legacy attachments wait for this conversion before a new provider send.
The import schedules the converted intent through the existing Outbox owner;
uncertain or manually stopped deliveries keep their existing recovery policy.
A missing file is reported and its original payload remains available for a
later import with the correct Home. Symlinks cannot redirect the import
outside that Home.

A release runs `bin/ankole eval 'Ankole.Release.import_agent_home("/agents")'`
in a container that mounts the Agent volume at `/agents`. Development runs
`mix ankole.files.import_agent_home var/ankole-dev/agents`. The import never
replaces a drive file, so a second run copies only what the first run did not.
It reports skipped symlinks, Skills or scripts over the Worker transfer limit,
Automation Jobs without `main.ts`, and every directory or file that it cannot
read, so an unreadable Agent Home never looks empty. An Automation Job keeps
`legacy_directory_path`
until every file of its script arrived. The report also names each directory
with an Agent UID name but no Agent: the old release did not remove the Home
of a deleted Agent, and the import does not read it.

Workers before the drive ran as root and created each Agent Home readable only
by root, while the import runs as the control-plane user. The deployment
guides therefore make the old volume readable (`chmod -R a+rX`) before the
import.

Remove `AgentHomeImport`, the import release command, and
`files.importAgentHomeClaim` when upgrades from pooled Worker releases are
no longer supported, all old Skills are present in the drives, and no
Automation Job has `legacy_directory_path`, and no unsent Outbox attachment
uses a legacy Home path. Remove the related legacy
provider assignment and pooled-release e2e at the same release.
