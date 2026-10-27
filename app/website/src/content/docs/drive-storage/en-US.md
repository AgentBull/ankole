---
title: Control-plane drive and object storage
description: Configure local files, cloud buckets, database tables, SFTP, or WebDAV for Ankole.ObjectStore (Agent drives, Pod file pages, attachments, and compiled Applet bundles), including migration and backup.
section: Guides
order: 318
---

`ANKOLE_FILES_STORE` configures `Ankole.ObjectStore`, the control-plane object store backing Agent drives (which stay accessible even when a Worker is stopped), Pod `file` pages, attachments across Pod documents, Bases, Chats, and conversations, and compiled Applet bundles. PostgreSQL stores logical paths, permissions, and content references, while an OpenDAL backend stores the content-addressed blob bytes (`fs`, `s3`, `azblob`, `d1`, `cos`, `postgresql`, `oss`, `tos`, `gcs`, `sftp`, or `webdav`).

Object storage is configured once at site bootstrap and shared across all tenants on the site. WorkerProvider Homes, cache disks, and Cloudflare R2 Worker snapshots use separate settings; see [WorkerProviders and cache disks](../worker-providers/) and [File management](../file-management/).

## Select a backend

| Deployment | `ANKOLE_FILES_STORE` | Configuration |
| --- | --- | --- |
| Single host or one control-plane replica | `fs` | Persistent volume or local folder |
| AWS S3 | `s3` | Bucket, region, and AWS credential chain |
| Cloudflare R2 | `s3` | S3 API endpoint, region `auto`, and R2 credentials |
| Other S3-compatible services | `s3` | Service endpoint, signing region, credentials, and compatibility checks |

Running multiple control-plane replicas requires shared remote storage pointed at the exact same backend location and root on every replica—the official Helm chart rejects `files.store: fs` whenever replica count exceeds one. Even with S3 storage, however, individual WorkerProviders may impose their own replica constraints, and `controlPlane.replicaCount` must stay at `1` today because singleton processes (schedule firing, chat connections, and scheduler hydration) run on a single node. Shared remote storage is therefore a prerequisite for multi-replica topologies rather than sufficient on its own; see [Control-plane replicas](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md#control-plane-replicas).

## Environment variables

| Variable | Backend | Requirement |
| --- | --- | --- |
| `ANKOLE_FILES_STORE` | All | Required in production; choose a supported backend |
| `ANKOLE_FILES_FS_ROOT` | `fs` | Writable absolute path inside the control plane |
| `ANKOLE_FILES_S3_BUCKET` | `s3` | Name of an existing bucket |
| `ANKOLE_FILES_S3_REGION` | `s3` | Required; bucket region for AWS, `auto` for R2 |
| `ANKOLE_FILES_S3_ENDPOINT` | `s3` | S3-compatible endpoint; usually omit for AWS S3 |
| `ANKOLE_FILES_S3_ROOT` | `s3` | Optional object-key prefix, such as `/ankole/production/` |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID` | `s3` | Optional static credential; set with the next variable |
| `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | `s3` | Optional static credential; set with the previous variable |

When you omit static S3 credentials, Ankole falls back to the default AWS credential chain, including EKS Pod Identity when configured. Grant bucket credentials or workload identity only to the control plane—Workers access their drive over RuntimeFabric and never need direct bucket keys. Because Ankole reads these variables once at startup (and ignores unexposed OpenDAL environment options), restart the control plane after any storage change.

## Additional OpenDAL backends

Configure additional backends with uppercase `ANKOLE_FILES_<SCHEME>_<FIELD>` variables—for example, Azure Blob requires `ANKOLE_FILES_STORE=azblob`, `ANKOLE_FILES_AZBLOB_CONTAINER`, and `ANKOLE_FILES_AZBLOB_ENDPOINT`. The table below lists every field that Ankole exposes; if any required variable is missing or empty, Ankole fails to start.

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

Store all backend credentials in control-plane secrets:

- **GCS, WebDAV, and SFTP authentication**: For `gcs`, pass base64-encoded credential JSON in `CREDENTIAL`, point `CREDENTIAL_PATH` to a mounted JSON file, or omit both to use the upstream Google credential chain. `webdav` accepts either Basic credentials (`USERNAME` / `PASSWORD`) or a bearer `TOKEN`. `sftp` invokes the `ssh` client inside the control-plane image (`KEY` is a private-key file path) and defaults `KNOWN_HOSTS_STRATEGY` to `strict`, so provision `~/.ssh/known_hosts` for the control-plane user.
- **Database and buffered backends (`d1`, `postgresql`, `webdav`)**: For `d1` and `postgresql`, create the target table ahead of time—Ankole does not create it—using a `TEXT` primary key and `BLOB` value on D1, or a `TEXT` primary key and `BYTEA` value on PostgreSQL, and set `TABLE`, `KEY_FIELD`, and `VALUE_FIELD` accordingly. Because `d1`, `postgresql`, and `webdav` buffer complete objects in memory in the native backend—and Cloudflare D1 enforces a [2,000,000-byte string, BLOB, and row limit](https://developers.cloudflare.com/d1/platform/limits/) without Ankole splitting objects across rows—use a bucket backend whenever you store large files.
- **SFTP atomic writes**: `sftp` uploads to a sibling temporary file and renames it on close, so the SFTP server must support atomic replacement (such as OpenSSH `posix-rename`). If the control plane stops mid-upload, stale `blobs/<digest>.<uuid>.tmp` files may remain; remove them during a maintenance window with all writers stopped.

In Helm, set `files.store` to the backend name, place non-secret variables in `controlPlane.extraEnv`, and store credentials in `secrets.existingSecret`—the chart injects that Secret into both the control-plane and migration environments and mounts Secret files under `/etc/ankole/bootstrap` in the control-plane container (provision SSH key permissions and `known_hosts` for uid `10001`). In Docker Compose, follow the override pattern below so both `migrate` and `control-plane` receive the backend variables. Before going live, verify reads, writes, atomic replacements, deletes, and large-file transfers against your target service.

## Local folders and persistent volumes

```dotenv
ANKOLE_FILES_STORE=fs
ANKOLE_FILES_FS_ROOT=/var/lib/ankole/files
```

`ANKOLE_FILES_FS_ROOT` resolves inside the control-plane process's filesystem. When running in a container, mount persistent storage at that path so deleting or recreating the container does not wipe your files. Because the control-plane image runs as uid/gid `10001` and the `fs` backend writes temporary files into `.tmp` under the root, grant uid/gid `10001` permission to create, write, rename, and delete files there.

Official Compose mounts the `files_data` named volume at `/var/lib/ankole/files`. To bind-mount a host directory instead, create the folder, grant write access to uid/gid `10001`, and override the volume mount:

```yaml
services:
  control-plane:
    volumes:
      - ./ankole-files:/var/lib/ankole/files
```

When switching an existing site to a host folder, copy the contents of the original file store first—mounting an empty folder does not migrate existing blobs.

In Helm, configure local persistent storage as follows:

```yaml
controlPlane:
  replicaCount: 1
files:
  store: fs
  persistence:
    size: 100Gi
    storageClass: YOUR_STORAGE_CLASS
    # existingClaim: YOUR_EXISTING_FILES_PVC
```

The chart creates (or adopts) a files PVC, mounts it at `/var/lib/ankole/files`, and retains chart-created PVCs on uninstall. If you supply an existing PVC, verify its ownership permissions and backup coverage. Note that this PVC backs `Ankole.ObjectStore` only; Agent Homes use separate storage.

## AWS S3

Create a private S3 bucket and grant the control-plane identity permission to read, write, and delete objects—including multipart uploads—under your chosen prefix (plus KMS permissions if the bucket uses KMS encryption):

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=ap-southeast-1
ANKOLE_FILES_S3_ROOT=/ankole/production/
```

When using AWS workload identity, omit the static-credential variables; otherwise, set both `ANKOLE_FILES_S3_ACCESS_KEY_ID` and `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` in your deployment secrets.

Helm example:

```yaml
files:
  store: s3
  s3:
    bucket: ankole-files
    region: ap-southeast-1
    root: /ankole/production/
```

Provide S3 credentials via `secrets.existingSecret` (alongside `DATABASE_URL`, `POSTGRES_PASSWORD` when bundled PostgreSQL is enabled, the original `ANKOLE_SECRET_BASE`, `ANKOLE_FUNCTION_RUNTIME_TOKEN`, and `RELEASE_COOKIE`), or pass them through `secrets.filesS3AccessKeyID` and `secrets.filesS3SecretAccessKey` without committing real keys to values files.

## Cloudflare R2 and other S3-compatible services

Cloudflare R2 uses the `s3` backend with region `auto`:

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=auto
ANKOLE_FILES_S3_ENDPOINT=https://ACCOUNT_ID.r2.cloudflarestorage.com
ANKOLE_FILES_S3_ROOT=/ankole/production/
ANKOLE_FILES_S3_ACCESS_KEY_ID=YOUR_R2_ACCESS_KEY_ID
ANKOLE_FILES_S3_SECRET_ACCESS_KEY=YOUR_R2_SECRET_ACCESS_KEY
```

Point `ANKOLE_FILES_S3_ENDPOINT` at your account's R2 S3 API endpoint—not a public bucket domain or Cloudflare Worker URL—and authenticate with R2 S3 API credentials; see [R2 S3 API compatibility](https://developers.cloudflare.com/r2/api/s3/api/) for supported operations. In Helm, set `files.s3.endpoint`, `files.s3.region`, and `files.s3.root`.

Other S3-compatible stores such as MinIO also use `ANKOLE_FILES_STORE=s3` with their service endpoint and signing region. Because "S3-compatible" implementations vary, always verify reads, writes, deletes, multipart uploads, and large-file transfers before production rollout. Ankole supports only the bootstrap fields documented on this page—virtual-hosted bucket addressing and custom signing flags are not exposed (see the [OpenDAL S3 backend](https://opendal.apache.org/docs/rust/opendal/services/struct.S3.html) for upstream behavior).

## Use S3 with Compose

Because the base `compose.yaml` hardcodes `ANKOLE_FILES_STORE: fs`, setting `ANKOLE_FILES_STORE=s3` in `.env` alone will not override it. Instead, layer a Compose override file such as `compose.files-s3.yaml` so both `migrate` and `control-plane` share the exact same S3 settings (shown below with static credentials):

```yaml
x-files-environment: &files-environment
  ANKOLE_FILES_STORE: s3
  ANKOLE_FILES_S3_BUCKET: ${ANKOLE_FILES_S3_BUCKET:?Set the files bucket}
  ANKOLE_FILES_S3_REGION: ${ANKOLE_FILES_S3_REGION:?Set the files region}
  ANKOLE_FILES_S3_ENDPOINT: ${ANKOLE_FILES_S3_ENDPOINT:-}
  ANKOLE_FILES_S3_ROOT: ${ANKOLE_FILES_S3_ROOT:-/ankole/}
  ANKOLE_FILES_S3_ACCESS_KEY_ID: ${ANKOLE_FILES_S3_ACCESS_KEY_ID:?Set the access key}
  ANKOLE_FILES_S3_SECRET_ACCESS_KEY: ${ANKOLE_FILES_S3_SECRET_ACCESS_KEY:?Set the secret key}
services:
  migrate:
    environment: *files-environment
  control-plane:
    environment: *files-environment
```

Populate the matching variables in `.env` or your deployment environment. On a brand-new site, start the stack directly; on an existing site, migrate existing objects first (see the next section) before starting:

```sh
docker compose -f compose.yaml -f compose.files-s3.yaml up -d
```

Pass both `-f` flags on every subsequent `run`, `exec`, upgrade, or one-time Home import so every command targets the same object store. If you rely on the AWS credential chain instead of static keys, remove the two static-credential lines from the override and attach the workload identity to the containers.

## Change backend, bucket, or prefix

Updating storage environment variables does not move existing data: PostgreSQL continues to point at content-addressed keys under `blobs/<full SHA-256>` (never folders named after logical Agent drive paths) inside your configured root or prefix. To migrate safely:

1. Quiesce requests and scheduled work: disable Agents, wait for active runs to finish, and stop all Workers and control-plane replicas so file commits and garbage collection halt completely.
2. Back up PostgreSQL, the current object store, Agent Homes, and deployment secrets together.
3. Copy the entire `blobs/` tree to the new root or prefix with object keys unchanged—excluding `.tmp` if copying from `fs`, and never renaming blobs to logical drive paths.
4. Point every control-plane replica at the new store, start the site, and verify existing file downloads, new uploads, Worker file access, and chat attachment delivery.
5. Re-enable normal work while retaining the old store until rollback is out of scope (rolling back without losing post-cutover writes requires restoring any new blobs and database rows together).

Never share a single bucket prefix across independent Ankole sites—garbage collection on one site will delete blobs that the other site still references. Only replicas belonging to the same site may share an object store root.

## Backup and cleanup

Because PostgreSQL holds metadata references while the bucket or folder holds raw blob bytes, always back up and restore them as a pair. Control-plane garbage collection automatically removes blobs once zero references remain across Agent drives, Pod `file` pages, Pod document/Base/Chat and conversation attachments, and compiled Applet bundles—so never configure bucket lifecycle expiration rules that delete live `blobs/*` objects.

Because S3 uploads use multipart transfers that can leave orphaned parts if a process terminates mid-write, add a bucket lifecycle rule that aborts incomplete multipart uploads after an interval suited to your workload. On `fs`, Ankole sweeps `.tmp` files older than 24 hours when opening the store (a housekeeping pass, not a substitute for backups).

To verify storage health before enabling Workers, upload and download a test file in Console; then enable a Worker and confirm drive file access and attachment delivery. If troubleshooting errors, check IAM/bucket permissions first on `AccessDenied`, check volume mounts, uid `10001` ownership, and free disk space on `fs` write errors, and verify bucket, region, prefix, and copied `blobs/` keys if older files fail to load. See [Backup and restore](../backup-and-restore/) and [Upgrade to 2.0](../upgrade-to-2/) for legacy file imports.
