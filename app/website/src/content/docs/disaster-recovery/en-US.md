---
title: Disaster recovery
description: The full shape of recovering an Ankole deployment instance from loss — what is recoverable, what is not, the cross-host migration, and the rehearsal that makes a recovery real.
section: Guides
order: 320
---

Disaster recovery is what you do when a deployment instance is gone — the host died, the cluster was lost, the volume was destroyed — and you need to bring it back somewhere else. It is not an incident (the system is not misbehaving, it is absent), and it is not an upgrade (there is nothing to roll forward). This page is the end-to-end recovery shape, built on the backup discipline and the migration mechanics the other guides cover.

The decisive property, stated up front: recovery is a *restore onto a fresh deployment*, not a repair of the old one. You deploy Ankole from scratch, restore PostgreSQL and Agent Home from backups, and re-enter the bootstrap secrets. What you recover is exactly what you backed up — no more, no less — and a recovery you have not rehearsed is a plan, not a capability.

## What is recoverable, and what is not

| State | Recoverable? | From what |
|---|---|---|
| Principals, agents, sessions, jobs, audit, AuthZ grants | yes | PostgreSQL `pg_dump` archive |
| Per-Agent workspaces, durable documents, installed Skills, conversation and Job files | yes | Agent Home volume snapshot |
| Provider credentials, chat-channel credentials, encrypted environment variables | yes | PostgreSQL and Agent Home store them, so the backup restores them |
| Bootstrap secrets (`ANKOLE_SECRET_BASE`, worker auth key) | **re-enter by hand** | they are not in the backup; generate new ones or reuse the recorded ones |
| In-flight turns, running background jobs, live worker state | **no** | ephemeral; lost with the process |
| Logs that were never shipped to an external ingester | **no** | lived on the lost host |

The bootstrap-secret row is the one that surprises people: the secrets that derive other keys are deployment-time inputs, not PostgreSQL state, so they are not in the `pg_dump`. Keep them in your secrets manager (not in the backup of the instance, but alongside it), or regenerate them and accept that the derived keys change.

## The recovery procedure

### Step 1: deploy Ankole fresh, from scratch

Stand up a new deployment instance on a new host or cluster, following [Quick start](../quickstart/#deployment). Do **not** try to attach the new instance to the old host's volumes or database — the old ones are the thing you are recovering from, and a half-attached instance is worse than a clean one. Use a new database, a new Agent Home volume, and new bootstrap secrets (or the recorded old ones — see Step 4).

### Step 2: restore PostgreSQL

Before starting the control plane for real, restore the database from the archive:

```bash
# on the fresh deployment, with the control plane stopped or in setup mode
docker compose exec -T postgresql \
  pg_restore -U ankole -d ankole --clean --if-exists \
  < "ankole-YYYYMMDD.dump"
```

Then run the migrations (`bun run control-plane:setup` locally, or let the Helm init container do it) to bring the restored schema to the image's level. The restored database has the Principals, agents, sessions, jobs, and AuthZ grants from the moment the backup was taken.

### Step 3: restore Agent Home

Restore the `ankole_agents_data` volume (or the RWX claim on Helm) from the snapshot, to the same `/agents` mount path. The per-agent-key directory structure recreates `/agents/<agent-key>/...` exactly. Pair it with the PostgreSQL restore — the database rows reference files under Agent Home, and a mismatched pair produces a deployment that looks alive but points at missing files.

### Step 4: handle the bootstrap secrets

The bootstrap secrets (`ANKOLE_SECRET_BASE`, `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`, `POSTGRES_PASSWORD`) are not in the backup. Two paths:

- **Reuse the recorded ones** — if you stored them in a secrets manager alongside (not inside) the instance backup, re-enter them. Existing encrypted rows in the restored PostgreSQL decrypt correctly, because the derived keys are the same.
- **Regenerate them** — generate new ones in `.env` (Compose) or the Secret (Helm). The restored PostgreSQL is intact, but provider credentials, chat-channel credentials, and environment variables encrypted with the old `ANKOLE_SECRET_BASE` will not decrypt. Enter these values again in the Console after recovery.

Reusing is simpler and preserves secrets; regenerating is safer if the old secrets may have been compromised in the disaster. Pick the path that matches why you are recovering.

### Step 5: re-enter anything not in the backup

After the restore, walk the configuration surfaces and confirm each is intact:

- **Providers and model profiles** — live in PostgreSQL, restored.
- **Signal routing rules** — stored in PostgreSQL and restored. You might need to enter their Channel Provider credentials again if you regenerated `ANKOLE_SECRET_BASE` in Step 4.
- **Identity providers** — same: rows restored, credentials may need re-entry.
- **Control Plane Plugins enable list** — restored, but takes effect on the next process start.

Send one real turn through a binding to confirm the end-to-end path works on the new deployment.

## Cross-host migration (the planned version)

A planned move to a new host is the same procedure, done deliberately:

1. Stop the old deployment (quiesce workers, stop writes).
2. Take a final PostgreSQL backup and Agent Home snapshot — these are the migration's source of truth.
3. Deploy fresh on the new host, restore the pair, handle bootstrap secrets.
4. Verify on the new host with one real turn.
5. Cut over DNS (or the load balancer) to the new host; the old one can be decommissioned once you are confident.

The difference from disaster recovery is the "stop the old deployment" step — in a disaster, the old deployment stopped itself, and the backup you have is from before that. Take the final backup as close to the cutover as you can, to minimize the gap.

## The rehearsal

A recovery you have not rehearsed is a plan, not a capability. The rehearsal is the single highest-leverage thing in this guide:

- **Monthly, on a throwaway host**, restore last night's PostgreSQL and Agent Home, deploy the images, run one real turn. If the restore works, your recovery is real. If it does not, you have found out on the throwaway host, not during a disaster.
- **Include the bootstrap-secret step.** A rehearsal that skips it has not tested the part that surprises people. Either reuse the recorded secrets, or regenerate and re-enter credentials — do the one you would do for real.
- **Vary the host.** Restoring onto the same host every time tests the backup, not the recovery. Restore onto a different host (different OS, different cloud) periodically, because that is what a disaster hands you.

## How this relates to the other guides

- [Backup and restore](../backup-and-restore/) is the discipline that makes recovery possible — the backups are the source.
- When the system still exists but misbehaves, diagnose the fault first. This page applies when the instance is unavailable or its data is lost.
- A planned upgrade moves the existing instance forward. Disaster recovery rebuilds the instance from backups in a new environment.
- [Security hardening](../security-hardening/) assumes the backups you would restore from are tested — this page is that test.

## What this guide is not

It is not a guarantee that no data is lost — anything not in the backup is gone, and in-flight work is always ephemeral. It is not a substitute for the rehearsal; the rehearsal is the whole point. And it is not a single command — recovery is deploy-fresh-plus-restore-pair-plus-secrets, and each step has its own verification. Skipping a step to save time is how a recovery produces a broken deployment.

## Next steps

- For the backup discipline recovery depends on, read [Backup and restore](../backup-and-restore/).
- For the fresh-deployment steps, read [Quick start](../quickstart/#deployment).
- When the system is still running but misbehaves, use [Log reading](../log-reading/) to find the first fault.
