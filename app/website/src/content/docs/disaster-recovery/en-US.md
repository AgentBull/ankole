---
title: Disaster recovery
description: Recovering an Ankole deployment from loss across PostgreSQL, Base shard databases, the file store, Agent Homes, Function Runtime, and deployment secrets.
section: Guides
order: 320
---

Recover the control-plane PostgreSQL database, dedicated Pod Base shard databases (`BASE_DB_URLS`) when configured, the file store, persistent Agent Homes, `ankole-function-runtime`, and the original deployment secrets as one coordinated deployment. The [backup guide](../backup-and-restore/) defines the data to preserve and the consistent backup procedure.

## Before recovery

Prove that the old control plane and its Workers cannot write to the restored Homes or databases. Loss of contact is not proof that a Worker stopped; include paused instances and create requests whose results are unknown. Keep unresolved generations and their credentials in PostgreSQL so recovery reconciles the same generation until the platform returns a definite result.

Restore a rehearsal into isolated platform resources. A copied database that still points at live production provider locations can manage production instances. Ankole does not provide automatic migration between providers or storage layouts.

## Recovery procedure

1. Prepare the replacement infrastructure with the control plane stopped. Preserve the provider location, `BASE_DB_URLS` shard IDs (`ankole_sharding`), and persistent-storage layout. Provision the stateless `ankole-function-runtime` service from the same release before starting the control plane, and restore Docker Home volumes before the control plane can create empty ones.
2. Restore the control-plane PostgreSQL database, every dedicated Base shard database in `BASE_DB_URLS` (when configured), the matching file store, and every persistent Home. Use the commands and ordering in [Backup and restore](../backup-and-restore/). When restoring dedicated Base shards with Point-in-Time Recovery (PITR), set every Base shard database recovery timestamp `>=` the control-plane database recovery timestamp so a shard never lacks a physical Base table recorded in the control plane, and preserve matching PostgreSQL locale/collation settings and `public._ankole_shard` shard IDs. Keep Agent UIDs, volume names, file ownership, and permissions.
3. Restore the original `ANKOLE_SECRET_BASE` from the secret manager. It decrypts provider secrets and the saved credential for an unsettled generation. If that key is lost, stop and prepare a separate credential-recovery plan; entering new provider credentials alone does not recover generation credentials.
4. Configure the remaining startup secrets and endpoints — including `DATABASE_URL`, `BASE_DB_URLS` (when dedicated shards are used), `ANKOLE_FUNCTION_RUNTIME_URL`, and the shared `ANKOLE_FUNCTION_RUNTIME_TOKEN` — then start `ankole-function-runtime` and the control plane. Let normal reconciliation inspect the actual platform state. Do not clear generation or instance references to make the status look healthy; an uncertain platform result stays in `starting` or `deleting` with its cause in `last_error`.
5. Enable the recovered Agents. Read a known Home file, a drive or Pod file, and a Pod Base table, resume a Background Job, and run a real Turn. Confirm that the old deployment remains stopped before moving traffic.

## Recovery limits

PostgreSQL and Base shard databases restore durable control-plane and Pod Base state. Home restores workspaces and Codex thread files; the SQLite cache is rebuildable, and `ankole-function-runtime` holds no durable state. Files written after the backup fall outside its recovery point. Live process memory and in-flight model or function requests are not included in backups.

Docker local volumes do not survive loss of their host without an external backup. Cloudflare requires both the R2 backup and its database reference; a forced stop can lose changes written after that backup. See the provider limits in [Workers](../worker-management/).

For a planned host move, stop writers first and take a final consistent backup across PostgreSQL, Base shards, the file store, and Agent Homes. For a rehearsal, run the same procedure on isolated resources, verify the user flow, and record the actual recovery point and elapsed time. A rehearsal that omits Base shards, Home storage, or `ANKOLE_SECRET_BASE` does not verify full recovery.
