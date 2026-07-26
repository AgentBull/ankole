---
title: Backup and restore
description: The two things you must back up — PostgreSQL and Agent Home — how to back them up, how to restore them, and why an untested backup is not a backup.
section: Guides
order: 315
---

An Ankole installation holds two things you cannot reconstruct: the PostgreSQL database (all durable control-plane state — Principals, agents, sessions, Brain knowledge, jobs, audit) and the Agent Home volume (per-agent workspaces, persona documents, installed skills, session and job files). Everything else is a rebuildable image or a re-derivable projection. This page is how to back up those two, how to restore them, and the one rule that makes a backup real.

The decisive property, stated up front: a database migration cannot be reversed by rolling the image back. A backup you have not restored is a hope, not a backup. The whole point of this page is the restore step — test it, on a separate host, before you rely on it.

## What to back up, and what not to

| Back up | Why | How |
|---|---|---|
| **PostgreSQL** (`ankole_postgresql_data` on Compose; your external server on Helm) | all durable semantic truth | `pg_dump -Fc` archive |
| **Agent Home** (`ankole_agents_data` on Compose; the RWX claim on Helm) | per-agent workspace, persona docs, installed skills, session/job files | volume snapshot or filesystem-level backup, taken while Ankole is stopped |

Do **not** back up the container images — they are rebuildable from the registry. Do not back up the Caddy data or the ephemeral worker state; neither holds anything you cannot recreate. And do not back up only one of the two — PostgreSQL references files in Agent Home, and Agent Home without the database rows that point at it is an orphan.

## Back up PostgreSQL

Take a custom-format archive (it is what the restore steps expect):

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc \
  > "ankole-$(date +%Y%m%d).dump"
```

On Helm with the bundled PostgreSQL, `kubectl exec` into the PostgreSQL pod and run the same `pg_dump`. With an external PostgreSQL, run `pg_dump` wherever you run it for that server — the command shape is the same.

Take this backup before every upgrade, before any destructive operation (`kit app-db rebuild`, `docker compose down -v`), and on whatever cadence your data-loss tolerance demands. A daily archive is a reasonable default for a small installation.

## Back up Agent Home

Agent Home is a filesystem, not a database — back it up while Ankole is **stopped**, so no worker is writing to it during the backup:

```bash
# Compose: snapshot the named volume, or copy it while the stack is down
docker compose down
# take your volume snapshot or filesystem-level backup of ankole_agents_data
docker compose up -d
```

On Helm, the Agent Home is the RWX claim; use whatever snapshot mechanism your StorageClass provides. A filesystem-level copy (rsync, restic, a cloud volume snapshot) all work, as long as it is consistent — taken at one point in time, not racing a writer.

The reason to stop the stack (or at least quiesce the workers) is that a worker writing a file mid-backup produces a torn copy. PostgreSQL's `pg_dump` gives you a transactionally-consistent archive; Agent Home has no such guarantee, so you provide it with timing.

## Restore PostgreSQL

Restore to a separate host first, every time. A restore you have not tested is the most expensive thing you can own in an incident.

```bash
# on a test host with a fresh Ankole database
docker compose exec -T postgresql \
  pg_restore -U ankole -d ankole --clean --if-exists \
  < "ankole-YYYYMMDD.dump"
```

Then run the migrations (`bun run control-plane:setup` locally, or let the Helm init container do it) to bring the schema to the image's level, since a backup taken before a migration restores to the pre-migration schema. Confirm the data — Principals, agents, a known Brain entry — is what you expect before declaring the restore good.

## Restore Agent Home

Restore the volume to the same path (`/agents`, mounted from `ankole_agents_data` on Compose or the RWX claim on Helm) from your snapshot. The directory structure is per-agent-key, so a correct restore recreates `/agents/<agent-key>/...` exactly. Pair it with the database restore — the database rows reference files under Agent Home, and a mismatched pair produces a deployment that looks alive but points at missing or stale files.

## Test the pair together

The README's instruction is the rule: "test database and Agent Home restore together on a separate host." The two are a pair; restoring one without the other proves nothing. A monthly cadence on a throwaway host — restore last night's PostgreSQL and Agent Home, start the stack, run one real turn — is the difference between a backup and a hope.

If the restore works on the test host, your production backup is real. If it does not, you have found out on the test host, not during an incident.

## When backups are not optional

A few operations make a backup mandatory, not advisable:

- **Every upgrade** — a migration cannot be reversed; the backup is your only rollback path for the schema. See [Updating](../updating/).
- **`kit app-db rebuild --yes`** — drops the local `ankole_dev` database. Only run it when the data is genuinely disposable, and back it up first if any of it matters.
- **`docker compose down -v`** — deletes the named volumes, including PostgreSQL and Agent Home. This is a delete, not a restart.
- **Any incident where the harm might reach durable state** — see [Incident response](../incident-response/).

## What this guide is not

It is not a backup product recommendation — use whatever volume-snapshot, restic, or cloud-snapshot tooling you already run. It is not a substitute for testing the restore; the restore step is the whole point. And it is not a way to back up only the parts you care about — PostgreSQL and Agent Home are the pair, and partial backups restore to a broken deployment.

## Next steps

- For the upgrade procedure that needs this backup, read [Updating](../updating/).
- For the incident flow that assumes this backup, read [Incident response](../incident-response/).
- For the deployment layout that names these volumes, read the [installation guide](../installation/).
