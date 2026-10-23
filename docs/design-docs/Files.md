# Files

Drive references and grants belong to the Agent's tenant. Content-addressed blob
bytes and their storage configuration belong to the site. Tenant deletion removes
its references; the garbage collector deletes only bytes without drive,
Message attachment, or uncompleted Delivery references.
A blob still referenced by another tenant remains.

Each Agent has a drive in the control plane. A tenant also has one Pod drive
for page content. Both use the same file owner, blob store, and collector.
The Agent drive holds received
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
| `drive_files` | `tenant_id`, nullable `agent_uid`, `path`, `sha256`, `mode`, `content_type`, `source`, `conversation_id`, `message_id`, timestamps; unique `(tenant_id, agent_uid, path) NULLS NOT DISTINCT` | One file in an Agent drive or the tenant's Pod drive |

Both models are Ash resources. The root module `Ankole.Files` is their Ash
domain. Blob actions own storage refresh, reference renewal, collection
marking, and final removal. The marking and removal actions use the same
live-reference predicate. DriveFile actions own path upserts and moves under
the natural identity. `drive_files` has no primary key, so AshPostgres
has no destroy action for it: `DriveFile.remove_paths_in_tx/2` removes a
subtree with one `DELETE ... RETURNING` statement that binds the current
tenant. It requires the caller's transaction.

A commit, move, delete, or snapshot listing is a generic action of `DriveFile`
(`commit_paths`, `move_paths`, `delete_paths`, `list_snapshot`), and one batch
of collection is the generic action `collect_marked` of `Blob`. Each generic
action owns its transaction. `Ankole.Files.commit/3`, `move/3`, `delete/2`, and
`list/3` with `snapshot: true` run these actions and give the domain reason of
a failure. Another domain that names files in its own transaction calls
`commit/4`.

- A path identifies a file. A folder is only a path prefix; there are no folder
  rows. A path is relative, uses `/`, has at most 1024 bytes, and has no empty,
  `.`, or `..` segment. A segment has at most 255 bytes. A file cannot also be
  the parent of another file: `a` and `a/b` cannot exist together.
- One content is stored once. Two Agents that receive the same file, or one
  Agent that saves the same bytes at two paths, add only `drive_files` rows.
- `source` is `inbound`, `generated`, `sent`, `agent`, `console`, or `pod`.
- `conversation_id` and `message_id` retain the public origin of a projected
  attachment. The Console listing and Files RPC return them; moves preserve
  them. Files with no Message origin have null values in the Console API.
- `content_type` is the declared type: the provider MIME type, the
  `reply_attachment` type, the generated image type, or the type for the file
  extension. The file service does not inspect bytes.
- `drive_files` rows cascade with the Agent principal. Deleting an Agent
  deletes its drive in the same transaction.
- An Agent reads and writes only its own drive.

The Pod drive uses a null `agent_uid` and stores files under `pages/<page-id>/`.
`Ankole.Pod.Files` checks page access before every read or write. The Agent's
`files.get` RPC can select this drive, but still checks that Agent's page access.
Page files never require granting a Human access to an Agent's whole drive.

A file-page replacement advances its revision with the file reference in one
transaction. Document assets and Database attachments use their full SHA-256 in
their paths. An Applet publication replaces `src/`, `dist/`, and optional
`server/main.js` atomically under the page revision. The backend is inspected
before commit. A publication without a backend removes the previous `server/`
references. The browser host loads only `dist/`; the control plane reads the
backend from the same authorized revision and manifest. Viewers can read source
and backend files through the ordinary page file interface. Digest reads reject
a changed manifest, so the host can restart loading after a publication race.
Page purge and tenant deletion remove `server/` with the other page paths;
unreferenced content follows the collector rules.

Saving a visible Conversation attachment to Pod adds a reference to its original
message digest. It does not copy bytes, and a later move or replacement in the
Agent drive cannot change the attachment. Removing a document image reference
or trashing a page leaves its bytes referenced until page purge removes the Pod
paths. The collector then applies the same live-reference and grace
rules. See [Pod Content Model](PodContentModel.md).

Some prefixes have a fixed meaning:

| Prefix | Writer |
| --- | --- |
| `chats/<channel>/inbox/<digest>/<file name>` | Adapter ingress for a received attachment |
| `chats/<channel>/inbox/<message ID>/<digest>/<file name>` | A native Human Message attachment |
| `chats/<channel>/generated/<digest>/<file name>` | AIGateway image generation in a channel conversation |
| `generated/<digest>/<file name>` | AIGateway image generation without a source channel |
| `skills/<name>/…` | Console upload or `ankole-files put` |
| `automation/<folder>-<suffix>/…` | Automation Job registration |

`<digest>` is the first 16 hexadecimal characters of the content SHA-256. The
same content with the same file name gets the same path within one adapter
channel or native Message. A repeated write is idempotent. A new native Message
has a separate path so it receives the uploaded bytes even if the Agent edited
an earlier input file. Two channels keep separate paths and provenance for the
same bytes.

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

The control plane checks attachment paths at the common Delivery commit boundary.
A file under `chats/<channel>/` can be delivered only to that channel. This
applies to final replies, `send_message`, and generated images, including
schedule delivery targets. A file outside `chats/` can be delivered to any
channel. The check uses the actual destination. It does not track content
lineage: an Agent that copies or moves a file to a shared path can deliver it
elsewhere. The prompt convention and this delivery check are the supported
contract.

## Bytes

The object key of a content is `blobs/<sha256 hex>`. The Rust kernel module
`object_store`, built on OpenDAL, reads and writes objects. It supports `fs`,
`s3` (including Cloudflare R2), `azblob`, `d1`, `cos`, `postgresql`, `oss`,
`tos`, `gcs`, `sftp`, and `webdav`. Every operation runs on the kernel's Tokio
runtime. Large files cross the BEAM boundary through local files. D1,
PostgreSQL, and WebDAV buffer the complete object in the native backend.
`Ankole.ObjectStore` opens the store once per node; only the file service
(`Ankole.Files` and its collection job) calls it.

A write that stops before it completes, for example because the control plane
stopped, leaves data that no object references. The `fs` backend writes
through `<root>/.tmp` and a rename; opening the store removes temporary files
that did not change for one day. The `s3` backend writes a large object as a
multipart upload and aborts the upload when the write fails, but a stopped
process cannot abort it. Give the bucket a lifecycle rule that aborts
incomplete multipart uploads. SFTP writes to a temporary file beside the
object, then renames it. The server must support atomic replacement; OpenSSH
uses `posix-rename`. Failed writes remove the temporary file. A stopped
process can leave `blobs/<digest>.<uuid>.tmp`; remove these files during a
maintenance window with all control-plane writers stopped.

The store is a bootstrap fact:

| Variable | Meaning |
| --- | --- |
| `ANKOLE_FILES_STORE` | One of the supported backends above; required in production |
| `ANKOLE_FILES_FS_ROOT` | `fs`: absolute directory on a persistent volume of the control plane |
| `ANKOLE_FILES_S3_BUCKET`, `ANKOLE_FILES_S3_REGION` | `s3`: bucket and region; R2 uses the region `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | `s3`: optional endpoint of an S3-compatible service |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID`, `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | `s3`: optional static credentials; without them the default AWS credential chain applies, including EKS Pod Identity |
| `ANKOLE_FILES_S3_ROOT` | `s3`: optional key prefix |

Other backends use `ANKOLE_FILES_<SCHEME>_<FIELD>`, with the scheme and field
in uppercase. For example, `azblob` requires `ANKOLE_FILES_AZBLOB_CONTAINER`
and `ANKOLE_FILES_AZBLOB_ENDPOINT`. Empty required values fail at startup;
empty optional values are omitted.

| Backend | Required fields | Optional fields |
| --- | --- | --- |
| `azblob` | `CONTAINER`, `ENDPOINT` | `ROOT`, `ACCOUNT_NAME`, `ACCOUNT_KEY`, `SAS_TOKEN` |
| `d1` | `ACCOUNT_ID`, `DATABASE_ID`, `TOKEN`, `TABLE`, `KEY_FIELD`, `VALUE_FIELD` | `ROOT` |
| `cos` | `BUCKET`, `ENDPOINT` | `ROOT`, `SECRET_ID`, `SECRET_KEY`, `SECURITY_TOKEN` |
| `postgresql` | `CONNECTION_STRING`, `TABLE`, `KEY_FIELD`, `VALUE_FIELD` | `ROOT` |
| `oss` | `BUCKET`, `ENDPOINT` | `ROOT`, `ACCESS_KEY_ID`, `ACCESS_KEY_SECRET`, `SECURITY_TOKEN` |
| `tos` | `BUCKET`, `ENDPOINT`, `REGION` | `ROOT`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `SECURITY_TOKEN` |
| `gcs` | `BUCKET` | `ROOT`, `ENDPOINT`, `CREDENTIAL`, `CREDENTIAL_PATH` |
| `sftp` | `ENDPOINT` | `ROOT`, `USER`, `KEY`, `KNOWN_HOSTS_STRATEGY` |
| `webdav` | `ENDPOINT` | `ROOT`, `USERNAME`, `PASSWORD`, `TOKEN` |

Credentials stay in the control plane. GCS `CREDENTIAL` is a base64-encoded
credential JSON document; `CREDENTIAL_PATH` names the original JSON file.
Without explicit GCS credentials, the upstream Google credential chain
applies. SFTP uses the control-plane image's `ssh` client. `KEY` is a private
key file path, and host checks default to `strict`; provision the control-plane
user's `~/.ssh/known_hosts`. WebDAV accepts Basic credentials or a bearer token.

Provision the database table before using D1 or PostgreSQL. Use a `TEXT`
primary key and a `BLOB` value in D1, or a `TEXT` primary key and a `BYTEA`
value in PostgreSQL. Ankole does not create the table. The table and column
variables select those names. D1 uses the Cloudflare REST API and has a
[2,000,000-byte string, BLOB, and row limit](https://developers.cloudflare.com/d1/platform/limits/).
The backend does not split one object across rows. Use a bucket backend for
large files. Backend configuration does not prove a particular remote service
works; verify reads, writes, replacement, deletion, and large-file transfers.

An `fs` directory must be visible to every control-plane replica, so more than
one replica needs shared remote storage. Development uses
`var/ankole-dev/files`; tests use one directory per test partition.

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
marks old contents with no drive path, Conversation attachment, or uncompleted Delivery attachment
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

`WorkerFiles.with_received_file/3` owns single-file reception to a temporary
local file. It waits for the complete stream and the final Worker RPC result
before it calls the domain function. The stream and function run in the caller's
process, with the caller's tenant context. Relay errors return their declared
reason. Other exceptions propagate. The temporary file is removed on every
exit. Pod and drive callers retain path validation, authorization, digest
checks, and durable writes. Bundle reception uses its separate format.

The turn-local command `ankole-files` gives the model the drive:
`list [<folder>] [--after <path>]`, `get <drive path> [--output <local path>]`,
`put <local path> <drive path>`, and `rm <drive path>`. `get` writes to
`drive/<path>` in the current workspace by default. `put` copies one file or
every regular file under a directory; it skips symlinks. A partial `list`
returns `next_after`; pass it as `--after` to read the next page.

## Attachments

Inbound adapters record a pending observation before they download bytes.
`Conversations.Attachments` owns attachment storage, download result handling,
redelivery reuse, and stable numeric attachment IDs in PostgreSQL. The adapter
stores bytes through `Conversations.Attachments.store_attachment/3`, then
observes a complete or failed result with the same provider identity. A complete
attachment carries `blob_ref`, drive `path`, and size. Redelivery cannot replace
stored bytes with a pending or failed result.

The public Conversation UUID scopes the path under
`chats/<conversation_id>/inbox/<digest>/<filename>`. Provider room and message
IDs do not serve as drive directories. The same stored bytes can serve several
Agents; the attachment owner names them separately in each Agent's drive when
that Agent observes or reads the Message. The model fetches the file with
`ankole-files get`. Image input uses the same file owner.

Outbound `reply_attachment` accepts only `drive_path`, with optional display
name and MIME type. Save a local deliverable with `ankole-files put` first.
The control-plane tool records the drive path and current digest. Delivery
payloads carry `path`, `blob_ref`, `name`, `mime_type`, and `size`; they do not
create a second copy under `sent/`.

The terminal commit checks that the drive still names those bytes and that a
path under `chats/<conversation_id>/` belongs to the destination Conversation.
Changing or deleting the file before that commit rejects the attachment.
Adapters read the confirmed bytes by `blob_ref`. Missing bytes block delivery
with `attachment_file_missing`.

A Delivery commit locks and refreshes referenced content. Collection checks
attachment references across all tenants. An unsent intent retains its bytes
after the last drive path is removed. Confirmed delivery or intent deletion
releases that reference.

Generated image artifacts belong to AIGateway. Sessions.Presentation stores
their bytes in the Agent's drive under
`chats/<conversation_id>/generated/`, or shared `generated/` when there is no
source Conversation. The renderer does not search model prose for file paths.

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
that are absent from the drive and downloads changed files. A local index
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
| `GET /api/v2/agents/:agent_uid/files?path=` | Folders and files of one folder |
| `GET /api/v1/agents/:agent_uid/files/content?path=` | Download one file |
| `POST /api/v1/agents/:agent_uid/files` | Upload one file (multipart: `path`, `file`) |
| `POST /api/v2/agents/:agent_uid/file-moves` | Move or rename a file or folder |
| `DELETE /api/v2/agents/:agent_uid/files?path=` | Delete a file, or a folder and every file in it |

The JSON operations use the Files Ash domain and JSON:API. Multipart uploads
and byte downloads use the two byte-transfer routes above. The Console uses
one configured HTTP client for both paths, including its session, CSRF, and
tenant context. A move rejects an existing target file and leaves both paths
unchanged. The API has no overwrite option.

The AuthZ resource is `agent:<uid>:files` with the actions `read`, `update`,
and `delete`.
