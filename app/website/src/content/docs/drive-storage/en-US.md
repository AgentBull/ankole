---
title: Control-plane drive storage
description: Configure local files, cloud buckets, database tables, SFTP, or WebDAV for OpenDAL-based Agent drives, including migration and backup.
section: Guides
order: 318
---

The control plane manages each Agent's drive, which remains available when its Worker is stopped. PostgreSQL stores paths, permissions, and content references. An OpenDAL backend stores file bytes. Ankole supports `fs`, `s3`, `azblob`, `d1`, `cos`, `postgresql`, `oss`, `tos`, `gcs`, `sftp`, and `webdav`.

This is site bootstrap configuration. All tenants use the same object store. WorkerProvider Home, cache, and Cloudflare R2 backups have separate configuration. See [WorkerProviders and cache disks](../worker-providers/) and [File management](../file-management/).

## Select a backend

| Deployment | `ANKOLE_FILES_STORE` | Configuration |
| --- | --- | --- |
| Single host or one control-plane replica | `fs` | Persistent volume or local folder |
| AWS S3 | `s3` | Bucket, region, and AWS credential chain |
| Cloudflare R2 | `s3` | S3 API endpoint, region `auto`, and R2 credentials |
| Other S3-compatible services | `s3` | Service endpoint, signing region, credentials, and compatibility checks |

Multiple control-plane replicas need shared remote storage, with the same backend location and root on each replica. Official Helm rejects `files.store: fs` with more than one replica. An S3 drive does not remove replica limits imposed by individual WorkerProviders.

The current deployment guide still requires `controlPlane.replicaCount: 1` until singleton processes such as schedule firing, chat connections, and scheduler recovery are verified on multiple nodes. Shared remote storage is required for multiple replicas. It does not prove that the whole deployment supports multiple replicas. See [Control-plane replicas](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md#control-plane-replicas).

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

Without static credentials, the default AWS credential chain applies, including configured EKS Pod Identity. Give credentials or workload identity only to the control plane. Workers access their drive through RuntimeFabric and do not need bucket keys. Configuration is read at startup; restart the control plane after changes. Other OpenDAL options are not Ankole environment variables.

## Additional OpenDAL backends

Use `ANKOLE_FILES_<SCHEME>_<FIELD>`, with both names in uppercase. For example, Azure Blob requires `ANKOLE_FILES_STORE=azblob`, `ANKOLE_FILES_AZBLOB_CONTAINER`, and `ANKOLE_FILES_AZBLOB_ENDPOINT`. The following table lists all fields exposed by Ankole. Missing or empty required values fail at startup.

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

Credentials belong in control-plane secrets. GCS `CREDENTIAL` contains base64-encoded credential JSON; `CREDENTIAL_PATH` points to the original JSON file. Without explicit credentials, the upstream Google credential chain applies. SFTP uses the control-plane image's `ssh` client; `KEY` is a private key file path. Host checks default to `strict`, so provision the control-plane user's `~/.ssh/known_hosts`. WebDAV supports Basic credentials or a bearer `TOKEN`.

D1 and PostgreSQL require an existing table. Use a `TEXT` primary key and `BLOB` value for D1, or a `TEXT` primary key and `BYTEA` value for PostgreSQL. Set `TABLE`, `KEY_FIELD`, and `VALUE_FIELD` to those names. Ankole does not create this table. D1, PostgreSQL, and WebDAV buffer complete objects in the native backend. D1's [string, BLOB, and row limit is 2,000,000 bytes](https://developers.cloudflare.com/d1/platform/limits/); Ankole does not split objects across rows. Use a bucket backend for large files.

SFTP uploads to a temporary file beside the object and renames it after close. The server must support atomic replacement, such as OpenSSH `posix-rename`. A stopped control plane can leave `blobs/<digest>.<uuid>.tmp`; remove these during maintenance with all writers stopped.

In Helm, set `files.store` to the backend name. Put the listed non-secret variables in `controlPlane.extraEnv` and credential variables in `secrets.existingSecret`. The chart loads that Secret into the control-plane and migration environments. Files from the same Secret are mounted at `/etc/ankole/bootstrap` in the control-plane container. Provision SSH key permissions and `known_hosts` for uid 10001. In Compose, use the override pattern below and pass the selected backend's variables to both services. Verify read, write, replacement, delete, and large-file transfers against the selected service before deployment.

## Local folders and persistent volumes

```dotenv
ANKOLE_FILES_STORE=fs
ANKOLE_FILES_FS_ROOT=/var/lib/ankole/files
```

The path is inside the control-plane process's filesystem. Mount persistent storage in a container, or container deletion will lose the files. The control-plane image runs as uid/gid 10001 and needs permission to create, write, rename, and delete files. The `fs` backend also creates `.tmp` under the root.

Official Compose mounts `files_data` at `/var/lib/ankole/files`. For a host folder, create it and grant uid/gid 10001 write access, then replace the mount in a Compose override:

```yaml
services:
  control-plane:
    volumes:
      - ./ankole-files:/var/lib/ankole/files
```

For an existing site, copy the original file store first. Mounting an empty folder does not migrate the old volume's contents.

Helm local storage:

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

The chart creates or adopts a files PVC and mounts it at `/var/lib/ankole/files`. Chart-created files PVCs remain after uninstall. An existing PVC still needs suitable permissions and backups. This PVC stores drives; Agent Home uses separate storage.

## AWS S3

Create a private bucket. Give the control-plane identity permission to read, write, and delete objects and use multipart uploads within the selected prefix. If the bucket uses KMS encryption, provide the required KMS permissions too.

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=ap-southeast-1
ANKOLE_FILES_S3_ROOT=/ankole/production/
```

AWS workload identity can omit the Ankole static-credential variables. For static credentials, provide both `ANKOLE_FILES_S3_ACCESS_KEY_ID` and `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` in deployment secrets.

Helm example:

```yaml
files:
  store: s3
  s3:
    bucket: ankole-files
    region: ap-southeast-1
    root: /ankole/production/
```

Use `secrets.existingSecret` for a bootstrap Secret that contains both credential variables. That Secret must also contain the database credentials, original `ANKOLE_SECRET_BASE`, and `RELEASE_COOKIE` required by the deployment. The chart also accepts `secrets.filesS3AccessKeyID` and `secrets.filesS3SecretAccessKey`. Do not commit real keys in values files.

## Cloudflare R2 and other S3-compatible services

R2 uses the `s3` backend:

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=auto
ANKOLE_FILES_S3_ENDPOINT=https://ACCOUNT_ID.r2.cloudflarestorage.com
ANKOLE_FILES_S3_ROOT=/ankole/production/
ANKOLE_FILES_S3_ACCESS_KEY_ID=YOUR_R2_ACCESS_KEY_ID
ANKOLE_FILES_S3_SECRET_ACCESS_KEY=YOUR_R2_SECRET_ACCESS_KEY
```

Use R2 S3 API credentials and the account's S3 API endpoint, not a public bucket domain or Worker URL. See [R2 S3 API compatibility](https://developers.cloudflare.com/r2/api/s3/api/) for region `auto` and supported operations. Helm uses `files.s3.endpoint`, `files.s3.region`, and `files.s3.root`.

Services such as MinIO also use `s3`. Set their actual endpoint and signing region. An S3 compatibility claim alone is not a verification: check reads, writes, deletes, multipart uploads, and large-file transfers before deployment. Ankole exposes the backends and bootstrap fields listed here; S3 virtual-host addressing and custom signing options remain unavailable. See the [OpenDAL S3 backend](https://opendal.apache.org/docs/rust/opendal/services/struct.S3.html) for upstream options.

## Use S3 with Compose

Official Compose sets `fs` directly in YAML. Adding `ANKOLE_FILES_STORE=s3` to `.env` alone does not override it. Use an override file such as `compose.files-s3.yaml` to give migration and control-plane services the same configuration. This example uses static credentials:

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

Set the corresponding values in `.env` or the deployment environment. For a new site, start with this command. For an existing site, migrate objects as described next before you start it:

```sh
docker compose -f compose.yaml -f compose.files-s3.yaml up -d
```

Use both `-f` options for later `run`, `exec`, upgrades, and one-time Home imports, so all operations use the same store. For the AWS credential chain, remove the two static-credential requirements from the override and provide the container's actual workload identity.

## Change backend, bucket, or prefix

A configuration change does not move files. PostgreSQL keeps content references. Object keys are `blobs/<full SHA-256>` under the selected directory or S3 prefix. They are not ordinary folders named after logical Agent drive paths.

1. Stop requests and scheduled work. Disable Agents and wait for active work to finish. Stop Workers and all control planes so file commits and collection stop.
2. Back up the database, original object store, Homes, and secrets together.
3. Copy the complete `blobs/` tree to the target root or prefix without changing object keys. Exclude `.tmp` when copying from `fs`. Do not rename objects to logical drive paths.
4. Change every control-plane replica to the same target. Start the site and verify known file downloads and contents, new uploads, Worker file operations, and attachment delivery.
5. Restore work after verification. Keep the original store for rollback. A rollback that keeps new writes also needs their matching objects and database references.

Do not share one object prefix between independent sites: one site's unreferenced-content cleanup can delete objects the other still needs. Replicas of the same site must share the configuration.

## Backup and cleanup

A database backup contains references; a bucket or folder backup contains bytes. Restore them together. The control plane collects content without drive paths or unfinished attachment references. Do not add expiry rules that delete objects still referenced by the site.

S3 writes use multipart uploads. A process interruption can leave incomplete uploads. Configure a bucket lifecycle rule to abort incomplete multipart uploads, with an interval suitable for the workload. On open, `fs` cleans temporary files unchanged for more than one day. This is not a backup.

With no Worker running, upload and download a known file in Console to verify control-plane storage. Then enable one Worker and check file access and attachment delivery. For `AccessDenied`, check identity and bucket permissions. For `fs` write failures, check mounts, uid 10001 access, and capacity. For missing old files, check bucket, region, prefix, and copied objects first. See [Backup and restore](../backup-and-restore/) and [Upgrade to 2.0](../upgrade-to-2/) for legacy file imports.
