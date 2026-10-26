---
title: Backup and restore
description: Back up PostgreSQL, the file store, persistent Agent Homes, and the deployment secrets. Test them together.
section: Guides
order: 315
---

Back up PostgreSQL (the control-plane database and any physical Base shard databases in `BASE_DB_URLS`), the object store (control-plane file store), and every Agent's persistent Home together. Keep the deployment configuration and secrets in your secret manager. A Worker instance, `ankole-function-runtime`, and `/var/cache/ankole` can be replaced; persistent Homes and databases must be restored.

## Backup contents

| Data | Contents | Backup source |
|---|---|---|
| Control-plane PostgreSQL | Principals, Sessions, Jobs, Pod metadata and documents, provider configuration, encrypted credentials, generation and storage references | `pg_dump -Fc` or PITR |
| Physical Base shards (`BASE_DB_URLS`) | Tenant physical Base table rows (in single-database deployments with `BASE_DB_URLS` unset, Base tables live in the control-plane database and one atomic `pg_dump` captures both) | `pg_dump -Fc` or PITR on every shard database |
| Object store (file store) | Pod `file` pages, Pod and conversation attachments, compiled Applet bundles, published files, installed Skills, Automation scripts | Compose `files_data`, the file-store PVC, or the S3 bucket |
| Agent Home | Workspaces, local packages, Codex threads in `/workspace/.codex` | Each provider's persistent volumes, shared directories, Drives, EFS, or Cloudflare R2 backups |
| Deployment configuration and secrets | `ANKOLE_SECRET_BASE`, `ANKOLE_FUNCTION_RUNTIME_TOKEN`, `BASE_DB_URLS`, and other startup credentials | A separate secret manager |

`/var/cache/ankole` and container images are rebuildable. Home is not a cache. Docker Home volumes depend on the host, so copy their backups to another host. For Cloudflare, the database backup must include the `storage_ref` for the corresponding R2 backup. A forced stop can lose writes after the last completed backup.

## Take a consistent backup

1. Stop new requests and scheduled work. Disable the Agents and wait for their active work to finish. Keep the control plane running during Worker shutdown.
2. Use each platform's normal stop or delete operation to end its Worker instances, including paused instances. Do not force-remove containers, set Kubernetes grace to zero, or delete Agents. Wait for the control plane to observe absence and save the current storage references. For Cloudflare, confirm the directory backup completed. An unresolved create must settle before this backup procedure can continue.
3. Stop the control plane. Stopping it alone does not stop separately managed Workers. Confirm that no Worker can still write the Homes.
4. Keep PostgreSQL running and take its archive. In a single-database deployment (`BASE_DB_URLS` unset), one `pg_dump` backs up the control plane and Base tables atomically. In a multi-shard deployment (`BASE_DB_URLS` set), back up the control-plane database and every physical Base shard database. Back up the object store and all persistent Homes while writers remain stopped. Preserve volume names, shard IDs, provider configuration, Agent UIDs, ownership, and file modes.
5. Start the control plane, enable the Agents, and verify a known Home file and a drive file.

For Compose, take the database archive with:

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc > ankole-backup.dump
```

Use the storage system's backup mechanism for each volume or bucket. Take backups before upgrades and destructive maintenance. A database migration cannot be undone by changing the image.

## Restore and verify

Keep all control planes and Workers stopped while restoring. On the target database:

```bash
docker compose exec -T postgresql \
  pg_restore -U ankole -d ankole --clean --if-exists < ankole-backup.dump
```

Restore every physical Base shard database in `BASE_DB_URLS` as well. When using point-in-time recovery (PITR) across a multi-shard deployment, each Base shard recovery timestamp must be greater than or equal to (`>=`) the control-plane database recovery timestamp so no control-plane metadata points to missing shard schema or rows.

Restore the matching object store, persistent Homes, provider locations, `BASE_DB_URLS`, `ANKOLE_FUNCTION_RUNTIME_TOKEN`, and original `ANKOLE_SECRET_BASE` before starting the control plane. `ANKOLE_SECRET_BASE` decrypts provider credentials and the credential needed to retry an unsettled generation. Generating a new key is not a complete recovery procedure.

Restore to the same storage layout and preserve uid 1000 ownership. An Agent cannot switch provider, and provider location and persistent-storage keys are immutable. A move to another storage layout requires a separate migration plan.

A recovery rehearsal must isolate its restored platform resources from production. Two control planes must never manage the same Agent storage independently. Do not clear generations to bypass an uncertain platform result.

Verify that a known workspace file and a drive file can be read, that a Background Job can resume from its Home, and that a real Turn completes. Repeat this restore test after changes to the storage layout or backup procedure. See [Disaster recovery](../disaster-recovery/) and [Workers](../worker-management/).
