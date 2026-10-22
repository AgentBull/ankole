---
title: Backup and restore
description: Back up PostgreSQL, the file store, persistent Agent Homes, and the deployment secrets. Test them together.
section: Guides
order: 315
---

Back up three data stores together: PostgreSQL, the control-plane file store, and every Agent's persistent Home. Keep the deployment secrets in your secret manager. A Worker instance and its cache can be replaced; its Home must be restored.

## Backup contents

| Data | Contents | Backup source |
|---|---|---|
| PostgreSQL | Principals, Sessions, Jobs, provider configuration, encrypted credentials, generation and storage references | `pg_dump -Fc` |
| File store | Attachments, published files, installed Skills, Automation scripts | Compose `files_data`, the file-store PVC, or the S3 bucket |
| Agent Home | Workspaces, local packages, Codex threads in `/workspace/.codex` | Each provider's persistent volumes, shared directories, Drives, EFS, or Cloudflare R2 backups |
| Deployment secrets | `ANKOLE_SECRET_BASE` and other startup credentials | A separate secret manager |

`/var/cache/ankole` and container images are rebuildable. Home is not a cache. Docker Home volumes depend on the host, so copy their backups to another host. For Cloudflare, the database backup must include the `storage_ref` for the corresponding R2 backup. A forced stop can lose writes after the last completed backup.

## Take a consistent backup

1. Stop new requests and scheduled work. Disable the Agents and wait for their active work to finish. Keep the control plane running during Worker shutdown.
2. Use each platform's normal stop or delete operation to end its Worker instances, including paused instances. Do not force-remove containers, set Kubernetes grace to zero, or delete Agents. Wait for the control plane to observe absence and save the current storage references. For Cloudflare, confirm the directory backup completed. An unresolved create must settle before this backup procedure can continue.
3. Stop the control plane. Stopping it alone does not stop separately managed Workers. Confirm that no Worker can still write the Homes.
4. Keep PostgreSQL running and take its archive. Back up the file store and all persistent Homes while writers remain stopped. Preserve volume names, provider configuration, Agent UIDs, ownership, and file modes.
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

Restore the matching file store, persistent Homes, provider locations, and original `ANKOLE_SECRET_BASE` before starting the control plane. This key decrypts provider credentials and the credential needed to retry an unsettled generation. Generating a new key is not a complete recovery procedure.

Restore to the same storage layout and preserve uid 1000 ownership. An Agent cannot switch provider, and provider location and persistent-storage keys are immutable. A move to another storage layout requires a separate migration plan.

A recovery rehearsal must isolate its restored platform resources from production. Two control planes must never manage the same Agent storage independently. Do not clear generations to bypass an uncertain platform result.

Verify that a known workspace file and a drive file can be read, that a Background Job can resume from its Home, and that a real Turn completes. Repeat this restore test after changes to the storage layout or backup procedure. See [Disaster recovery](../disaster-recovery/) and [Workers](../worker-management/).
