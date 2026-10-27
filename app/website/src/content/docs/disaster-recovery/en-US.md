---
title: Disaster recovery
description: Recovering an Ankole deployment from loss across PostgreSQL, Base shard databases, the file store, Agent Homes, Function Runtime, and deployment secrets.
section: Guides
order: 320
---

Recovering an Ankole deployment requires restoring the control-plane PostgreSQL database, dedicated Pod Base shard databases (`BASE_DB_URLS`) when configured, the file store, persistent Agent Homes, `ankole-function-runtime`, and the original deployment secrets together as a single coordinated unit. See [Backup and restore](../backup-and-restore/) for what data to preserve and how to take a consistent backup.

## Before recovery

Before restoring anything, confirm that the old control plane and all of its Workers cannot write to the restored Homes or databases. Losing network contact does not prove that a Worker has stopped—account for paused instances and in-flight create requests whose outcomes remain unknown. Preserve unresolved generations and their credentials in PostgreSQL so Ankole's recovery reconciliation keeps tracking the same generation until the underlying platform returns a definite result.

When running a recovery rehearsal, always restore into isolated platform resources: if you restore a copied database that still points at live production provider locations, the rehearsal control plane will attempt to manage live production instances. Ankole does not migrate instances automatically between providers or storage layouts.

## Recovery procedure

1. Prepare the replacement infrastructure while keeping the control plane stopped, preserving the original provider location, `BASE_DB_URLS` shard IDs (`ankole_sharding`), and layout for persistent storage. Provision the stateless `ankole-function-runtime` service from the same release before starting the control plane, and restore Docker Home volumes first so the control plane cannot create empty volumes in their place.
2. Restore the control-plane PostgreSQL database, every dedicated Base shard database in `BASE_DB_URLS` (when configured), the matching file store, and every persistent Home using the commands and sequence in [Backup and restore](../backup-and-restore/). If you restore dedicated Base shards with Point-in-Time Recovery (PITR), set the recovery timestamp of every Base shard database at or after (`>=`) the recovery timestamp of the control-plane database so no shard lacks a physical Base table recorded in the control plane, and preserve matching PostgreSQL locale/collation settings alongside `public._ankole_shard` shard IDs. Keep all Agent UIDs, volume names, file ownership, and permissions intact.
3. Restore the original `ANKOLE_SECRET_BASE` from your secret manager so Ankole can decrypt provider secrets and saved credentials for unsettled Worker generations. If you lose `ANKOLE_SECRET_BASE`, stop and prepare a separate credential-recovery plan—entering fresh provider credentials alone will not recover saved generation credentials.
4. Configure the remaining startup secrets and endpoints—including `DATABASE_URL`, `BASE_DB_URLS` (when dedicated shards are used), `ANKOLE_FUNCTION_RUNTIME_URL`, and the shared `ANKOLE_FUNCTION_RUNTIME_TOKEN`—then start `ankole-function-runtime` followed by the control plane. Let normal reconciliation inspect actual platform state rather than clearing generation or instance references to make statuses appear healthy; whenever a platform outcome is uncertain, Ankole keeps the Worker in `starting` or `deleting` and records the cause in `last_error`.
5. Re-enable the recovered Agents and verify the end-to-end deployment: read a known Home file, a drive or Pod file, and a Pod Base table, resume a Background Job, and run a real Turn. Confirm once more that the old deployment remains stopped before shifting live traffic.

## Recovery limits

PostgreSQL and Base shard databases restore durable control-plane and Pod Base state, while Agent Homes restore workspaces and Codex thread files (the Worker SQLite cache is rebuildable, and `ankole-function-runtime` holds no durable state). Any files written after the backup fall outside its recovery point, and backups never capture live process memory or in-flight model and function requests.

Storage durability also depends on your Worker provider: Docker local volumes do not survive host loss without an external backup, and Cloudflare Workers require both the R2 backup and its matching database reference (a forced stop can lose writes made after that snapshot). See [Workers](../worker-management/) for provider-specific limits.

For a planned host migration, stop all writers first and capture a final consistent backup across PostgreSQL, Base shards, the file store, and Agent Homes. When running a rehearsal, execute this exact procedure against isolated resources, verify the end-to-end user flow, and record both the achieved recovery point and elapsed recovery time—omitting Base shards, Home storage, or `ANKOLE_SECRET_BASE` leaves full recovery unverified.
