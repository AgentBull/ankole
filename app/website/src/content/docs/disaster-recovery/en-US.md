---
title: Disaster recovery
description: The full shape of recovering an Ankole deployment instance from loss — what is recoverable, what is not, the cross-host migration, and the rehearsal that makes a recovery real.
section: Guides
order: 320
---

Recover PostgreSQL, the file store, persistent Agent Homes, and the original deployment secrets as one deployment. The [backup guide](../backup-and-restore/) defines the data to preserve and the consistent backup procedure.

## Before recovery

Prove that the old control plane and its Workers cannot write the restored Homes. Loss of contact is not proof that a Worker stopped. This includes paused instances and create requests whose results are unknown. Keep unresolved generations and their credentials in PostgreSQL; recovery uses the same generation until the platform gives a definite result.

Restore a rehearsal into isolated platform resources. A copied database with live production provider locations can manage production instances. Ankole does not provide automatic migration between providers or storage layouts.

## Recovery procedure

1. Prepare the replacement infrastructure with the control plane stopped. Preserve the provider location and persistent-storage layout. Restore Docker Home volumes before the control plane can create empty ones.
2. Restore PostgreSQL, the matching file store, and every persistent Home. Use the commands and ordering in [Backup and restore](../backup-and-restore/). Keep Agent UIDs, volume names, file ownership, and permissions.
3. Restore the original `ANKOLE_SECRET_BASE` from the secret manager. It decrypts provider secrets and the saved credential for an unsettled generation. If that key is lost, stop and prepare a separate credential-recovery plan; entering new provider credentials alone does not recover generation credentials.
4. Configure the other startup secrets and endpoints, then start the control plane. Let its normal reconciliation inspect the actual platform state. Do not clear generation or instance references to make the status look healthy. An uncertain platform result stays in `starting` or `deleting`, with its cause in `last_error`.
5. Enable the recovered Agents. Read a known Home file and a drive file, resume a Background Job, and run a real Turn. Confirm that the old deployment remains stopped before moving traffic.

## Recovery limits

PostgreSQL restores durable work state. Home restores workspaces and Codex thread files; the SQLite cache can be rebuilt. Files written after the backup are outside its recovery point. Live process memory and an in-flight model request are not included in a Home backup.

Docker local volumes do not survive loss of their host without an external backup. Cloudflare needs both the R2 backup and its database reference; a forced stop can lose changes since that backup. See the provider limits in [Workers](../worker-management/).

For a planned host move, first stop writers and take a final consistent backup. For a rehearsal, repeat the same procedure on isolated resources and verify the user flow. Record the actual recovery point and the time required. A restore rehearsal that omits Home or the encryption key does not prove full recovery.
