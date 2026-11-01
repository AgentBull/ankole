# Files

`Ankole.Files` owns the tenant Drive: one durable node tree, its access rules,
trash lifecycle and immutable file objects. Pod owns document, Base and Applet
semantics attached to those nodes. PostgreSQL is the authority; Worker caches
and local paths can be rebuilt. Workers never receive object-store credentials.

## Ownership and storage

| Table | Purpose |
| --- | --- |
| `drive_nodes` | Real folder, file, doc, base and applet nodes; topology, name, ACL anchors, trash state and the file's current `object_id` |
| `file_objects` | Tenant-owned immutable bytes: UUID, storage key, SHA-256, size and completion time |
| `message_attachments` | Frozen Message references by `(tenant_id, message_id, position)` |
| `delivery_attachments` | Pending Delivery references by intent identity and position |
| `pod_files` | Pod-managed resources by `(tenant_id, node_id, path)`; a nullable node identifies tenant metadata such as custom emoji |
| `pages` | Optional Pod properties keyed by the same node ID |

Every object reference is a tenant-scoped composite foreign key with `RESTRICT`
on object deletion. A Message attachment's optional node pointer may be cleared
when its node is removed, while its object reference still retains the bytes.
Pod resource rows cascade when their owning node is permanently deleted.
`pod_page_nodes` is a read-only SQL view joining nodes and Pod properties; it is
not a second topology or a materialized copy.

Object keys are `tenants/<tenant-id>/objects/<uuidv7>`. A new write always gets a
new key and row, even for identical bytes. SHA-256 is calculated during upload
for integrity and Pod resource idempotency; it is not an object identity or a
deduplication index. Multiple nodes or attachments can explicitly reference one
existing object without copying it. Objects are never shared across tenants.

There is no file version table or recovery API. Overwriting a file changes its
node's `object_id`; the last successful commit wins. Already-sent attachments
retain their original object reference. Document history remains Pod's
`PageSnapshot` feature. An empty file has no object until its first write.

Drive publishes committed node changes on `drive-node:<id>` after the top-level
transaction succeeds. Pod's page channel consumes that event for both runtime
and browser writes. File readers compare `object_id` when reconciling missed
events. Pod file replacement accepts the manifest's `base_object_id` (null for
an empty file) and rejects a stale value with `manifest_changed`; runtime writes
use last-commit-wins semantics. Pod document and Applet revisions describe their
own content, independently of file objects.

## Tree and access

Every tenant has a public root. Members and Agents have private roots initialized
with their owner's `manage` role; Guests have none. Membership demotion preserves
a private root but revokes its owner's
access according to the offboarding rules. Each conversation has a folder root;
current participants receive view and contribute bits from the authorization
snapshot, with no persistent grants generated from membership.

Names are unique among live siblings. `Ankole.Files.Path` rejects empty, `.` and
`..` segments, slashes, ASCII/C1 control characters, Unicode bidirectional
override, embedding, isolate, and mark characters (`U+202A..U+202E`,
`U+2066..U+2069`, `U+200E`, `U+200F`, `U+061C`), and segments over 255 bytes
across Drive node creation, rename, upload, and staged chat attachment writes.
For untrusted external IM attachment filenames and historical entries,
`Ankole.Files.sanitize_display_path/1` strips bidirectional and control
characters before prompt formatting, `Content-Disposition` headers, and UI
display, while browser views wrap rendered names in `<bdi>` isolation. Private
runtime paths are
relative and at most 1024 bytes. Roots cannot be moved, renamed or trashed. Files
are leaves. A node has one parent and one ACL owner; moves recompute affected ACL
anchors and prevent cycles. Ordinary browser/RPC name collisions receive a
suffix. Pod display titles can remain empty or duplicated; their Drive names are
normalized. Renaming a doc, base or applet through Drive updates its Pod title
through the narrow content-owner callback.

The five permission bits retain role masks 1, 19, 23 and 31:

| Bit | Action | Meaning |
| --- | --- | --- |
| 1 | `node_view` | Read content and visible descendants |
| 2 | `node_contribute` | Add children to a folder/conversation, or write Base records and attachments |
| 4 | `node_edit` | Edit existing content or structure, rename, move and trash |
| 8 | `node_manage` | Manage access |
| 16 | `node_comment` | Comment |

Creating directly under the public or private root requires edit. Creating a
subpage of a doc/base/applet also requires edit because it changes document
structure. Initial content for an empty file requires contribute on its parent;
subsequent writes require edit on the file. File contribution grants no other
operation. An editor's temporary-file rename over an existing file therefore
requires edit on the destination.

Resource authorization evaluates one executing Principal. Human instruction
validity remains guarded by `turn_authority`, `WorkAccess`, and Automation
`AttemptAccess`; Human authentication conditions are not intersected with an
Agent's resource grants. See [AuthZ](AuthZ.md) for administrative and delegated
access, and [Pod Content Model](PodContentModel.md) for document operations.

Topology changes acquire the tenant tree lock, resolve affected private roots
while holding that lock, acquire those root locks in sorted order, and then
acquire instruction/runtime and row locks. Node-ID content uploads transfer
bytes outside the transaction; their short commit transaction takes a shared
tree lock before resolving its root. This allows concurrent content writes
while preventing an ancestor from moving to another space between root
selection and commit. Private path writes already know their immutable private
root and serialize with its snapshot lock. They revalidate existence after
acquiring that lock: a concurrent move or delete returns `path_changed` instead
of silently creating a replacement under a higher-ranked lock. Skill catalog
snapshots share the private-root lock.

Trash hides a subtree immediately. Purge retains a marked root until the
content-owner callback has removed Base physical tables and Pod data, then
removes grants and nodes. Interrupted cleanup is retryable. Permanent Principal
and tenant deletion use the same content-owner boundary.

## Byte writes, reads and collection

1. `Files.store/1` creates an incomplete object row before byte transfer.
2. An OpenDAL writer consumes the source once, hashing and counting while it
   writes. The native queue is bounded, uses 8 MiB parts, and acknowledges each
   chunk before requesting the next. Owner exit or failure aborts the writer.
3. The transaction that attaches the object locks its row, verifies the upload
   receipt, sets `completed_at`, and inserts the reference together. Failed
   attachment leaves an incomplete object for collection.

The hourly collector considers objects older than 24 hours and checks all four
reference owners centrally. In one PostgreSQL transaction it deletes the
unreferenced row and inserts a site-scoped `DeleteObject` Oban job containing
the storage key. Composite foreign keys resolve reference/collection races.
The job retries byte deletion independently; keys are never reused. Tenant
cleanup enqueues the same deletion jobs before deleting its object rows.

`Files.read_object_range/3` clips the requested length to the completed object's
stored size and returns empty bytes at or beyond EOF. It delegates nonempty
ranges to `ObjectStore.read_range/3`, which reads the offset and length directly through
OpenDAL. HTTP file endpoints fetch metadata once and send 1 MiB chunks without
a full control-plane download. They support single closed/open/suffix byte
ranges, 206, 416, ETag, If-None-Match and If-Range, including empty files.
Multi-range or malformed Range headers are ignored and return the full response.
Applet index HTML is read in full only because the host injects its shell.

OpenDAL supports `fs`, `s3` (including R2), `azblob`, `d1`, `cos`, `postgresql`,
`oss`, `tos`, `gcs`, `sftp`, and `webdav`. Native buffering depends on the backend:

| Backend | Write bound | Basis |
| --- | --- | --- |
| D1 | 2,000,000 bytes | Its single BLOB/row bound; no object sharding |
| PostgreSQL, WebDAV | 100 MiB | Whole-object native buffering; preserve a bounded memory cost |
| Other backends | No Ankole 100 MiB ceiling | Streaming writer; provider limits still apply |

The protocol's numeric byte bound fits JavaScript's exact integer range. It
is not a claim that every backend accepts a file of that size. Files RPC, Pod
file transfer and HTTP multipart paths use the backend bound for uploads and
the stored object's size for downloads. Other Worker file operations retain
their default 100 MiB policy, including document XML transfer.

On macOS arm64, isolated native file uploads of 100 MiB peaked at about 482 MiB
RSS for PostgreSQL and 247 MiB for WebDAV; at 256 MiB they reached about 1.24 GiB
and 788 MiB respectively. These are local single-process measurements against
local PostgreSQL and WsgiDAV, not production capacity or concurrency promises.
D1 rejects oversized writes before remote I/O. Local fs and S3-compatible
streaming tests cover incremental digest, abort, and range reads; a sparse 5 GiB
fs object verifies a tail range without allocating the whole object.

For S3-compatible storage, configure lifecycle cleanup of abandoned multipart
uploads. Process termination may also leave backend temporary files; use the
backend's documented cleanup procedure. The 24-hour database collector cannot
abort a provider-side multipart upload whose process died before completion.

## Configuration

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

## Worker access

A personal assistant uses its own private root for runtime files, Skills,
Library documents and execution outputs. Pod's Private navigation resolves the
assistant's same-tenant owner instead, allowing business tools to work with the
owner's documents. These roots have separate owners and lifecycles. Creation
grants the Human owner management access to the assistant's runtime root.

The runtime uses `ankole-files` against the same Drive tree while the FUSE
release gate is unresolved:

- `ankole-files list [<folder>] [--after <path>]` lists private files with stable
  `node_id`, current `object_id`, and a manifest revision for cache preparation.
- `ankole-files get <private-path> [--output <local-path>]` reads private files;
  `ankole-files get <node-id> --node` reads another shared file after node access
  checks.
- `ankole-files put <local-path> <private-path>` uploads every write; it never
  skips transfer by looking up a hash.
- `ankole-files rm <private-path>` trashes the matching file or subtree.

Files RPC transfers bytes through a signed, one-time WorkerFiles relay. Every
upload verifies declared size and an optional caller digest before committing;
there is no hash shortcut, transfer bundle, or second staging upload. A Worker
has only its execution credentials and relay URL. The RuntimeFabric protocol requires
a coordinated control-plane/Worker upgrade.

The final design's FUSE release requires actual mounts on all six supported
Worker providers. Current Kubernetes isolation lacks the required mount access,
so FUSE is postponed as required by gate C1. No `/drive` mount or inode cache is
advertised as shipped, and the security baseline is unchanged. See
[Agent Workers](AgentWorkers.md) for provider evidence and the remaining gate.

## Attachments and Pod resources

Conversation attachments freeze the object in `message_attachments`, addressed
by Message ID and position. Display name, MIME type and legacy JSON fields do
not keep an object alive. Two equally named attachments remain distinct.
Downloads authorize current conversation membership, or current `node_view`
on the host node of an `anchor_page` conversation, then read the frozen object, even if the original node was overwritten, renamed or deleted. The
runtime command is `ankole-pod chat attachment get <conversation-id>
<message-id> <position> --to <local-path>`. Saving an attachment creates a node
referencing the same object.

`reply_attachment` accepts `node_id`; `send_message` accepts attachment node
IDs. The control plane authorizes node view and captures the current completed
object. Pending, failed and unknown Delivery intents retain relational object
references. Confirmed delivery transfers that hold to the public Message in the
same transaction; expired references are cleared while presentation metadata is
retained. A file's path is not an authority or a delivery confinement rule.

Inbound attachments and generated images with a conversation belong to its
root. Generated images without a conversation belong to the Agent private root.
Giving the same object to multiple nodes is explicit reference sharing, not
hash deduplication. Presentation never searches model prose for attachments.

Screenshots embedded in documents, Base cell attachments and Applet source
remain Pod-managed `pod_files`; they do not clutter Drive listings. Pod checks
node view for `dist/` and `assets/`, and node edit for source and server files.
Applet publication binds all object references and its manifest atomically.
Custom emoji have no node owner and survive individual page purge. These
resources are accessible through `ankole-pod`, including `applet pull`.

## Skills and Automation

Installed Skills remain under `skills/<name>/` in the Agent private tree.
Drive snapshots synchronize their authoritative catalog and preserve operator
enablement. Workers cache a manifest of path, object ID and mode, verify received
hashes and sizes, and fail preparation if a multi-page manifest changes.

Automation registration writes its source to a fresh `automation/<name>/`
private directory. Every run materializes that directory and selected Skills
into an isolated execution directory in Agent Home. Human employment and
`access_version` validate the instruction; Drive access uses the Agent executor.
See [Automation Jobs](AutomationJobs.md).

## Site Console

The Console Drive browser lists all roots of the selected tenant, including
Human and Agent private roots and conversation roots, without an online Worker.
It supports breadcrumbs, cursor pagination, folder creation, upload of files
and directory trees, download, move, rename and trash. Roots are immutable.

| Route | Operation |
| --- | --- |
| `GET /api/v2/drive/:tenant_id/nodes` | List roots or children by `parent_id`, optionally `after` and `limit` |
| `POST /api/v2/drive/:tenant_id/nodes` | Create a folder or empty file |
| `PATCH /api/v2/drive/:tenant_id/nodes/:id` | Move or rename |
| `DELETE /api/v2/drive/:tenant_id/nodes/:id` | Trash a subtree |
| `POST /api/v2/drive/:tenant_id/uploads` | Multipart `parent_id`, `name`, `file` |
| `GET /api/v2/drive/:tenant_id/nodes/:id/content` | Download current file bytes |

These actions check `site_console:drive` in the privileged tenant using read,
update or delete. Creating and uploading use update, preserving existing
administrative action semantics and CEL conditions. Site administration does
not grant an Agent runtime access. `tenant_console` retains its existing scope.
See [the upgrade guide](../upgrades/unified-drive.md) before applying the one-time
migration; old writers must be stopped before topology and object ownership move.
