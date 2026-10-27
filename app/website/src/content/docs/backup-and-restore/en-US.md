---
title: Backup and restore
description: Back up PostgreSQL, the file store, persistent Agent Homes, and the deployment secrets. Test them together.
section: Guides
order: 315
---

Always back up PostgreSQL (both the control-plane database and any physical Base shard databases in `BASE_DB_URLS`), the object store (control-plane file store), and every Agent's persistent Home as a coordinated set, while storing deployment configuration and secrets in your secret manager. Stateless components—Worker instances, `ankole-function-runtime`, and `/var/cache/ankole`—can be replaced from scratch, whereas databases, object storage, and persistent Homes must be restored from backups.

## Backup contents

| Data | Contents | Backup source |
|---|---|---|
| Control-plane PostgreSQL | Principals, Sessions, Jobs, Pod metadata and documents, provider configuration, encrypted credentials, generation and storage references | `pg_dump -Fc` or PITR |
| Physical Base shards (`BASE_DB_URLS`) | Tenant physical Base table rows (in single-database deployments with `BASE_DB_URLS` unset, Base tables live in the control-plane database and one atomic `pg_dump` captures both) | `pg_dump -Fc` or PITR on every shard database |
| Object store (file store) | Pod `file` pages, Pod and conversation attachments, compiled Applet bundles, published files, installed Skills, Automation scripts | Compose `files_data`, the file-store PVC, or the S3 bucket |
| Agent Home | Workspaces, local packages, Codex threads in `/workspace/.codex` | Each provider's persistent volumes, shared directories, Drives, EFS, or Cloudflare R2 backups |
| Deployment configuration and secrets | `ANKOLE_SECRET_BASE`, `ANKOLE_FUNCTION_RUNTIME_TOKEN`, `BASE_DB_URLS`, and other startup credentials | A separate secret manager |

Container images and `/var/cache/ankole` are rebuildable caches, whereas Agent Home holds irreplaceable workspace state. Because local Docker Home volumes depend on a single host disk, replicate their backups off-host. On Cloudflare Workers, make sure the PostgreSQL backup captures the `storage_ref` corresponding to the completed R2 backup—forcing a Cloudflare stop can lose writes made after the last completed backup.

## Take a consistent backup

1. Pause incoming traffic and scheduled triggers, disable all Agents, and wait for active runs to finish while keeping the control plane online during Worker shutdown.
2. Stop or delete all Worker instances—including paused instances—using each platform's graceful lifecycle operation rather than force-removing containers, setting Kubernetes termination grace periods to zero, or deleting Agents. Wait until the control plane observes every Worker as absent and commits updated storage references (and on Cloudflare, verify that directory backups to R2 finished). If any Worker creation is still in flight, wait for it to settle before proceeding.
3. Stop the control plane. Because stopping the control plane alone does not terminate externally hosted Workers, confirm that no Worker remains able to write to any Agent Home.
4. With writers stopped and PostgreSQL still running, capture database, object-store, and Home archives: in single-database deployments (`BASE_DB_URLS` unset), one `pg_dump` captures both the control plane and Base tables atomically; in multi-shard deployments (`BASE_DB_URLS` set), dump the control-plane database and every physical Base shard database. Preserve volume names, shard IDs, provider configuration, Agent UIDs, `uid` `1000` ownership, and file permissions.
5. Start the control plane, re-enable the Agents, and verify access to both a known Home file and a control-plane drive file.

On Docker Compose, dump the control-plane database with:

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc > ankole-backup.dump
```

Back up each volume or bucket using its native snapshot or replication tool, and always capture a fresh backup before upgrades or destructive maintenance—rolling back an application image cannot reverse a committed database migration.

## Restore and verify

Keep all control-plane nodes and Workers stopped throughout the restore. On the target database, run:

```bash
docker compose exec -T postgresql \
  pg_restore -U ankole -d ankole --clean --if-exists < ankole-backup.dump
```

Restore every physical Base shard database in `BASE_DB_URLS` as well. When performing point-in-time recovery (PITR) across a multi-shard deployment, ensure every Base shard recovery timestamp is greater than or equal to (`>=`) the control-plane database recovery timestamp so control-plane metadata never points to missing shard schemas or rows.

Before starting the control plane, restore the matching object store, persistent Homes, provider locations, `BASE_DB_URLS`, `ANKOLE_FUNCTION_RUNTIME_TOKEN`, and the original `ANKOLE_SECRET_BASE`. Ankole requires the original `ANKOLE_SECRET_BASE` both to decrypt stored provider credentials and to decrypt generation credentials when reconciling unsettled Workers; generating a new secret key is not a valid recovery path.

Restore Agent Homes to the exact original storage layout with `uid` `1000` ownership preserved. Because an Agent's Worker provider, provider location, and persistent-storage keys are immutable, moving to a different storage topology requires a dedicated migration plan rather than an in-place restore.

When rehearsing recovery, isolate the rehearsal environment from production platform resources—two control planes must never manage the same Agent storage concurrently, and you must never clear Worker generation counters to bypass an uncertain platform outcome.

Finally, verify that an Agent can read both a known Home workspace file and a control-plane drive file, resume a Background Job from Home, and complete a full live Turn. Re-run this restore drill whenever you change your storage layout or backup pipeline. See [Disaster recovery](../disaster-recovery/) and [Workers](../worker-management/).
