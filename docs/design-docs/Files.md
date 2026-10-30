# Files

Drive references and access grants belong to the Agent's tenant, whereas
content-addressed blob bytes and object-store settings belong to the site. When
a tenant is deleted, Ankole removes that tenant's file references, and the
garbage collector deletes blob bytes only when no drive path, Message
attachment, or uncompleted Delivery intent references them across any tenant. A
blob that another tenant still references remains in storage.

Each Agent owns a drive in the control plane, and each tenant also owns one Pod
drive for page content. Both drives share the same file service, blob store, and
garbage collector. An Agent's drive stores received attachments, generated
images, outbound reply attachments, installed Skills, Automation scripts, and
published deliverables, and it remains accessible even when the Agent has no
running Worker. Separately, each Agent has a persistent Home directory at
`/workspace` for temporary Session and Job working directories and Codex thread
files. Home persistence supports execution resume rather than durable file
delivery; see [Agent Workers](AgentWorkers.md#files-and-isolation).

`Ankole.Files` owns the drive: PostgreSQL maps relative paths to content
digests, and an object store holds the raw bytes.

## What PostgreSQL Stores

| Table | Columns | Meaning |
| --- | --- | --- |
| `files` | `sha256` (primary key), `size`, `deleting`, `created_at`, `last_referenced_at` | One distinct byte content |
| `drive_files` | `tenant_id`, nullable `agent_uid`, `path`, `sha256`, `mode`, `content_type`, `source`, `conversation_id`, `message_id`, timestamps; unique `(tenant_id, agent_uid, path) NULLS NOT DISTINCT` | One file in an Agent drive or the tenant's Pod drive |

Both tables back Ash resources in the `Ankole.Files` domain. `Blob` actions
manage storage refreshes, reference renewals, garbage-collection marking, and
final deletion, using the same live-reference predicate for both marking and
removal. `DriveFile` actions handle path upserts and moves under the composite
natural key. Because `drive_files` has no single-column primary key, AshPostgres
defines no `destroy` action on it; instead, `DriveFile.remove_paths_in_tx/1`
deletes a path or subtree with a single tenant-scoped `DELETE ... RETURNING`
statement inside the caller's transaction.

Top-level callers run `Ankole.Files.commit/3`, `move/3`, `delete/2`, `list/3`
(with `snapshot: true`), and garbage-collection batches inside
`Repo.transact_top_level/2`. Callers in another domain that already own a
transaction compose file writes through `commit_in_tx/3`.

Drive paths and metadata follow six invariants:

- Every row names a file; folders exist only as shared `/` path prefixes with no
  dedicated folder rows. Paths are relative, contain at most 1024 bytes, allow
  at most 255 bytes per segment, and forbid empty, `.`, or `..` segments. A file
  path cannot also act as a parent prefix (`a` and `a/b` cannot coexist).
- Identical byte content is stored once in `files`. If two Agents receive the
  same attachment or one Agent writes the same bytes to two paths, Ankole
  inserts only `drive_files` rows.
- `source` is one of `inbound`, `generated`, `sent`, `agent`, `console`, or
  `pod`.
- `conversation_id` and `message_id` record the public origin of a projected
  attachment. Both the Console listing and the Files RPC return these IDs, path
  moves preserve them, and files without a Message origin expose `null` in the
  Console API.
- `content_type` stores the declared MIME type (from the IM provider,
  `reply_attachment`, image generation, or the file extension); the file service
  never sniffs file bytes.
- `drive_files` rows cascade when an Agent Principal is deleted, removing the
  Agent's entire drive in the same transaction. Each Agent can read and write
  only its own Agent drive.

The tenant's Pod drive sets `agent_uid` to `NULL` and stores page files under
`pages/<page-id>/`. `Ankole.Pod.Files` checks page permissions before every read
or write. Although an Agent can target the Pod drive through the `files.get`
RPC, the control plane still enforces that Agent's permissions on the target
page, so sharing a page file never requires exposing an Agent's personal drive
to a Human.

The Pod drive also owns a tenant-wide `metadata/` namespace for files that
belong to the Pod rather than to a Page. `metadata/custom-emoji/<sha256>/<icon
name>` holds the shared picture library that Page icons use, where the name is
an ASCII shortcode such as `:my_icon:`, and a Page stores that relative path in
its `icon` value. Space `page_view` reads the library and
space `page_edit` adds to it through `/api/v2/pod/metadata/custom-emojis` and
`/api/v2/pod/metadata/files/content`. Purging a Page leaves these paths in
place, because they have no Page owner and stay available to the whole Pod.

Replacing a file page advances the page revision and updates the file reference
in one transaction, while document assets and Base attachments embed their full
SHA-256 digest in their paths. Publishing an Applet atomically replaces `src/`,
`dist/`, and the optional `server/main.js` under the new page revision after
inspecting the backend bundle; publishing an Applet without a backend removes
any earlier `server/` references. In the browser, the Applet host loads only
`dist/`, while the control plane loads the backend from the same authorized
revision and manifest. Readers with `page_view` can list and read only
`dist/**` and `assets/**`; listing or reading `src/**`, `server/**`,
`applet.env.json`, `package.json`, `bun.lock`, or `tsconfig.json` requires
`page_edit`. If a concurrent publication changes the manifest during loading,
the server rejects digest reads against the stale manifest so the host can
restart from the new revision. Purging a page or deleting a tenant removes
`server/` together with the other page paths, leaving unreferenced blobs to the
garbage collector.

When a Human saves a visible Conversation attachment to Pod, Ankole adds a Pod
reference to the Message's original content digest rather than copying bytes, so
moving or overwriting the file in an Agent's drive never alters the saved
attachment. Similarly, removing an image from a document or moving a page to the
trash keeps its blobs referenced until page purge deletes the `pages/<page-id>/`
paths, after which normal live-reference and grace-period collection applies;
see [Pod Content Model](PodContentModel.md).

Several Agent-drive prefixes carry reserved meanings:

| Prefix | Writer |
| --- | --- |
| `chats/<channel>/inbox/<digest>/<file name>` | Adapter ingress for a received attachment |
| `chats/<channel>/inbox/<message ID>/<digest>/<file name>` | A native Human Message attachment |
| `chats/<channel>/generated/<digest>/<file name>` | AIGateway image generation in a channel conversation |
| `generated/<digest>/<file name>` | AIGateway image generation without a source channel |
| `sent/<digest>/<file name>` | Outbound reply attachment committed by the Worker (source `sent`) |
| `skills/<name>/…` | Console upload or `ankole-files put` |
| `automation/<folder>-<suffix>/…` | Automation Job registration |

Here `<digest>` is the first 16 lowercase hexadecimal characters of the content
SHA-256. Uploading the same bytes with the same filename inside one adapter
channel or one native Message maps to the exact same path, making retries
idempotent. Each new native Message includes its `<message ID>` in the prefix so
it receives clean uploaded bytes even if the Agent modified an earlier copy, and
separate channels keep independent paths and provenance for identical bytes.

## Conversation Files and Delivery

Each conversation channel owns one drive directory at `chats/<channel>/`, whose
channel ID stays stable across Session resets. Ankole leaves colons and
URI-unreserved characters literal and percent-encodes all other bytes (including
encoding each dot when a channel ID is `.` or `..`), preventing any channel ID
from injecting extra path segments. Received attachments, generated images, and
channel deliverables live under `chats/<channel>/`, while paths outside `chats/`
hold shared files, installed Skills, and Automation scripts.

Because the Worker acts as the Agent's personal computer, the Agent can read and
write across its entire Home directory and drive; Ankole does not enforce
filesystem or drive read isolation between conversations of the same Agent.
Instead, the main system prompt names the active workspace and channel drive
directory, instructing the Agent to keep temporary scratch work in the
workspace, write durable or outbound deliverables into its `chats/<channel>/`
directory, and leave other conversations' directories untouched (additionally
marking DM conversations as private). When a Background Agent Job starts or
resumes, it receives its originating conversation's drive directory in the same
way.

At the shared Delivery commit boundary, the control plane enforces outbound
channel confinement: any attachment under `chats/<channel>/` may be delivered
only to that exact `<channel>`, covering final replies, `send_message`,
generated images, and scheduled delivery targets. Files outside `chats/` may be
delivered to any channel. Because this check inspects the target path rather
than tracking byte lineage, an Agent that copies or moves a file outside
`chats/` can deliver it elsewhere; the system prompt rules together with this
path gate form the supported boundary.

## Bytes

Object storage keys every blob at `blobs/<sha256 hex>`. The Rust kernel's
`object_store` module (built on OpenDAL) executes all reads and writes on the
kernel's Tokio runtime and supports `fs`, `s3` (including Cloudflare R2),
`azblob`, `d1`, `cos`, `postgresql`, `oss`, `tos`, `gcs`, `sftp`, and `webdav`.
Large blobs cross the BEAM-to-Rust boundary through temporary local files, while
the `d1`, `postgresql`, and `webdav` backends buffer complete objects in native
memory. `Ankole.ObjectStore` opens the configured backend once per node, and
only `Ankole.Files` and its garbage-collection job invoke it.

If a control-plane node exits mid-write, an incomplete upload can leave
unreferenced data in the backend:

- **`fs`:** writes stage into `<root>/.tmp` before an atomic rename, and opening
  the store deletes `.tmp` files left untouched for more than one day.
- **`s3`:** large writes use multipart uploads and abort on write error, but a
  terminated process cannot send the abort request; configure a bucket lifecycle
  rule to abort incomplete multipart uploads automatically.
- **`sftp`:** writes stage to a sibling file `blobs/<digest>.<uuid>.tmp` and
  atomically rename it onto the target (requiring server-side atomic replacement
  such as OpenSSH `posix-rename`). Failed writes delete the `.tmp` file, whereas
  process termination can leave `blobs/<digest>.<uuid>.tmp` behind; remove stale
  `.tmp` files during a maintenance window while all control-plane writers are
  stopped.

Object-store selection is a node bootstrap setting configured through
environment variables:

| Variable | Meaning |
| --- | --- |
| `ANKOLE_FILES_STORE` | One of the supported backends above; required in production |
| `ANKOLE_FILES_FS_ROOT` | `fs`: absolute directory on a persistent volume of the control plane |
| `ANKOLE_FILES_S3_BUCKET`, `ANKOLE_FILES_S3_REGION` | `s3`: bucket and region; R2 uses the region `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | `s3`: optional endpoint of an S3-compatible service |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID`, `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | `s3`: optional static credentials; without them the default AWS credential chain applies, including EKS Pod Identity |
| `ANKOLE_FILES_S3_ROOT` | `s3`: optional key prefix |

All other backends follow the naming pattern `ANKOLE_FILES_<SCHEME>_<FIELD>` in
uppercase (for example, `azblob` requires `ANKOLE_FILES_AZBLOB_CONTAINER` and
`ANKOLE_FILES_AZBLOB_ENDPOINT`). If a required variable is empty, node startup
fails; if an optional variable is empty, Ankole omits it.

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

Storage credentials never leave the control plane. For `gcs`, `CREDENTIAL` holds
a base64-encoded service-account JSON document and `CREDENTIAL_PATH` points to a
JSON file on disk; when both are omitted, OpenDAL falls back to Google's default
credential chain. `sftp` invokes the control-plane image's `ssh` binary with
`KEY` as a private-key path and `KNOWN_HOSTS_STRATEGY` defaulting to `strict`,
so operators must populate `~/.ssh/known_hosts` for the control-plane user.
`webdav` accepts either HTTP Basic credentials or a bearer token.

Before selecting `d1` or `postgresql`, provision the backing table manually with
a `TEXT` primary key and a `BLOB` column (in D1) or `BYTEA` column (in
PostgreSQL), matching the configured `TABLE`, `KEY_FIELD`, and `VALUE_FIELD`
variables; Ankole does not run DDL for blob storage. Because D1 communicates
over the Cloudflare REST API, it enforces a
[2,000,000-byte string, BLOB, and row limit](https://developers.cloudflare.com/d1/platform/limits/)
and never shards one blob across multiple rows, so deployments handling larger
files must use a bucket backend. Valid startup configuration does not guarantee
that a remote backend works end to end; operators should verify reads, writes,
replacements, deletions, and large-file transfers against the target store.

When using `fs`, every control-plane replica must mount the same directory, so
multi-replica deployments require shared network or object storage. Local
development defaults to `var/ankole-dev/files`, and automated tests isolate
storage into one directory per test partition.

## Writes

Writing a file to a drive takes two steps:

1. **`store/1`** persists the blob bytes: it upserts the `files` row (clearing
   `deleting` and refreshing `last_referenced_at`) and writes the object to the
   store.
2. **`commit/4`** binds stored digests to drive paths and removes deleted paths
   in one PostgreSQL transaction. For each digest, it runs a row-locking update
   that skips rows marked `deleting`, preventing a blob already claimed by
   garbage collection from gaining a new path reference. If any digest is
   missing or marked `deleting`, `commit/4` rolls back the entire transaction
   with `{:blob_missing, sha256}`.

Commits, moves, and deletes all acquire the same per-Agent transaction lock
before reading or mutating paths, and both `commit` and `move` validate the
complete resulting path tree to reject file-versus-parent prefix collisions
atomically. Consequently, deleting `a` and creating `a/b` (or vice versa) within
a single commit succeeds cleanly.

Every hour, the Oban cron job `Ankole.Files.Jobs.CollectUnreferenced` sweeps old
`files` rows that have no drive path, Conversation attachment, or uncompleted
Delivery attachment reference. It first marks eligible rows `deleting` and then processes marked rows in
batches of 100: it deletes the database row only if that row remains
unreferenced, and then deletes the object from storage. If a new write
calls `store/1` on a marked digest before removal, `store/1` clears `deleting`.
A 24-hour grace period protects newly stored blobs between `store/1` and
`commit/4`.

## Worker Access

Workers never hold object-store credentials. Instead, three RuntimeFabric RPCs
in the `worker_agent` scope expose the drive belonging to the connection's
Agent:

| Method | Result |
| --- | --- |
| `files.list` | Lists files under a prefix in path order with pagination; passing an exact file path returns that single file |
| `files.get` | Streams one drive file to a target path inside the calling Worker's Agent Home |
| `files.commit` | Binds files from the calling Worker's Agent Home to drive paths and removes deleted drive paths |

File bytes never travel inside JSON/Protobuf RPC payloads; instead, the control
plane streams them over the calling Worker's
[WorkerFiles relay](RuntimeFabric.md#worker-files), with a 100 MiB cap per
transfer. During `files.commit`, the control plane skips transferring any digest
already present in that Agent's drive, and it transfers shared bytes only once
even when several upserts in the batch share a digest. Files under the same
top-level folder of Agent Home are packed into relay bundles of up to
100 MiB using each upsert's declared byte size, while a single file in its own
top-level group transfers unbundled.

On the control plane, `WorkerFiles.with_received_file/3` streams a single
incoming file into a temporary local file and waits for both the stream EOF and
the final Worker RPC response before invoking the domain callback. Both stream
reception and the callback execute in the caller's BEAM process under the
caller's tenant context, and `with_received_file/3` deletes the temporary file
on every exit path. Relay failures return their declared error tuples, unexpected
exceptions propagate, and Pod or drive callers still enforce path validation,
authorization, SHA-256 verification, and durable commits. Multi-file bundles use
their own dedicated receiver.

Inside a turn, the `ankole-files` CLI exposes these operations to the model:

- `ankole-files list [<folder>] [--after <path>]` (when truncated, pass the
  returned `next_after` value to `--after` for the next page)
- `ankole-files get <drive path> [--output <local path>]` (defaults to
  `drive/<path>` inside the current workspace)
- `ankole-files put <local path> <drive path>` (uploads a single file or all
  regular files under a directory while skipping symlinks)
- `ankole-files rm <drive path>`

## Attachments

Before downloading an inbound attachment, IM adapters record a pending
observation. `Conversations.Attachments` manages attachment persistence,
download outcomes, redelivery deduplication, and stable numeric attachment IDs
in PostgreSQL. After streaming the bytes through
`Conversations.Attachments.store_attachment/3`, the adapter records a completed
or failed observation under the same provider identity. Completed attachments
record `blob_ref`, drive `path`, and byte `size`, and later webhook redeliveries
cannot overwrite stored bytes with a pending or failed state. The same rule
applies to an ignored group entry that has no Message: its inbound batch entry
keeps the stored bytes of the last observation of that provider message.

Inbound paths are scoped by the public Conversation UUID at
`chats/<conversation_id>/inbox/<digest>/<filename>` rather than raw provider
room or message IDs. When multiple Agents observe or read the same Message,
`Conversations.Attachments` links the shared blob into each Agent's drive
separately, where the model can fetch it via `ankole-files get` (and where
vision input reads from the same file owner).

For outbound files, the `reply_attachment` tool accepts only a `drive_path`
(plus an optional display name and MIME type), so an Agent must upload local
workspace files with `ankole-files put` first. When `reply_attachment` runs, the
control plane records the drive path and its current SHA-256 digest; Delivery
payloads carry `path`, `blob_ref`, `name`, `mime_type`, and `size` directly
without duplicating the file under `sent/`.

At the terminal turn commit, the control plane verifies both that the Agent's
drive still maps `drive_path` to that exact digest and that any path under
`chats/<conversation_id>/` matches the destination Conversation. If the Agent
changed or deleted the file beforehand, the control plane rejects the
attachment. Outbound adapters then fetch confirmed bytes by `blob_ref`; if the
blob is missing from object storage, delivery fails with
`attachment_file_missing`.

Committing a Delivery intent locks and refreshes every referenced `files` row,
and garbage collection checks uncompleted Delivery references across all
tenants. Consequently, an unsent Delivery intent retains its blob bytes even if
the Agent deletes the last drive path, releasing that hold only once the
provider confirms delivery or the intent is deleted.

Generated images belong to AIGateway, and `Sessions.Presentation` writes their
bytes into the Agent's drive under `chats/<conversation_id>/generated/` (or
shared `generated/` when there is no source Conversation). Presentation never
parses model prose to auto-attach file paths.

## Skills and Automation Scripts

An Agent-installed Skill lives in the drive subtree `skills/<name>/`. Under the
same per-Agent lock used for path writes, the control plane reads Skill
manifests from the drive to synchronize the Skill catalog, committing catalog
updates only after all manifest reads succeed and preserving any operator
`enabled_override`. Cached files on a Worker never define the authoritative
catalog.

While the control plane reads `SKILL.md` instructions directly from the drive on
demand, updated Skill helper scripts and MCP configurations take effect when the
Worker prepares the next Turn or Automation run.

Before starting a Turn or Automation Job run, the Worker synchronizes its local
`installed-skills/` cache with the drive one preparation at a time (serializing
both the drive listing and the local index write, though a failed sync never
blocks the next attempt):

1. Every `files.list` page includes a manifest digest computed across all paths,
   content hashes, and file modes under the drive transaction lock, and the
   Worker requires every page in the walk to report the identical manifest
   digest.
2. Using a local index of `(size, mtime, digest)` to avoid re-hashing unchanged
   files, the Worker deletes indexed files removed from the drive, downloads
   added or modified files, updates file permissions even when bytes are
   unchanged, and leaves untracked local files alone.
3. Every downloaded file must match its listed digest, size, and mode on disk.
   If the drive changes mid-walk or a download fails, preparation aborts before
   execution starts (which an Automation Job records as a retryable
   infrastructure failure), allowing the next attempt to read the new revision.

An Automation Job script lives in its registered `drive_prefix` under
`automation/` and must contain `main.ts`. During registration, the Worker copies
the local directory to a fresh `automation/<folder>-<suffix>/` prefix: if the
control plane explicitly rejects registration, the Worker deletes that folder,
whereas if the RPC outcome is indeterminate, the Worker leaves the folder intact
and instructs the caller to list existing jobs before retrying. On each run, the Worker copies the script folder and its installed Skills into a
fresh run directory in Agent Home, executes `main.ts` there, and deletes the run
directory afterward so later cache updates cannot change that run's Skill files;
see [Automation Jobs](AutomationJobs.md).

## Console

The Agent files page in the Console provides a full drive browser (listing
folders, downloading, uploading files or entire folders, moving, renaming, and
deleting) backed directly by `Ankole.Files`, so every operation works even when
the Agent has no running Worker:

- Selecting files or a directory uploads them into the current folder while
  preserving relative paths inside an uploaded directory (for example, uploading
  a Skill directory populates `skills/<name>/` in one step).
- Clicking a filename downloads its bytes.
- **Rename** changes a file or folder's leaf name within the same parent folder,
  whereas **Move** changes its parent folder while keeping the leaf name; both
  update every path under a moved folder in a single transaction regardless of
  subtree size, and if a move fails, the dialog retains the entered destination
  for easy retry.
- Folder listings return up to 1,000 child folders and 1,000 files; if a folder
  contains more entries, the API marks the response `truncated` and the UI notes
  that the listing is partial.

| Route | Operation |
| --- | --- |
| `GET /api/v2/agents/:agent_uid/files?path=` | List folders and files inside one folder |
| `GET /api/v2/agents/:agent_uid/files/content?path=` | Download one file |
| `POST /api/v2/agents/:agent_uid/files` | Upload one file (multipart: `path`, `file`) |
| `POST /api/v2/agents/:agent_uid/file-moves` | Move or rename a file or folder |
| `DELETE /api/v2/agents/:agent_uid/files?path=` | Delete a file, or a folder and every file inside it |

Metadata endpoints run through the `Ankole.Files` Ash domain and JSON:API, while
multipart uploads and raw downloads use the two byte-transfer routes above; the
Console calls both through a single HTTP client sharing session, CSRF, and
tenant headers. If the destination path of a move already exists, the server
rejects the move and leaves both source and destination untouched (there is no
overwrite option).

Console file operations check the AuthZ resource `site_console:agent:<uid>:files`
with actions `read`, `update`, and `delete`.
