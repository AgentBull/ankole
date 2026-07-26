---
title: Updating
description: How to upgrade an Ankole installation — pin images to digests, back up PostgreSQL and Agent Home, then roll Compose or Helm forward. Database migrations do not roll back.
section: Getting started
order: 6
---

An Ankole upgrade is an image roll and a database migration, in that order, with a backup in front of it. This page is the upgrade procedure for both supported deployment targets, and the one rule that makes an upgrade recoverable: **back up PostgreSQL and Agent Home first, because a database migration cannot be reversed by rolling the image back.**

The decisive property, stated up front: the control-plane and worker tags move together, and only after the publish workflow has verified the RuntimeFabric image pair. For a controlled production rollout, pin both images to digests from the same verified pair. A rollback to an old image does not undo the migration; if the old application also needs the old schema, you restore the database backup.

## Before you upgrade: back up

Do this every time, on every deployment target. A skipped backup turns a failed upgrade into data loss.

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc \
  > "ankole-$(date +%Y%m%d).dump"
```

Back up the `ankole_agents_data` volume (Agent Home) with a volume snapshot or a filesystem-level backup, taken while Ankole is stopped. PostgreSQL data lives in `ankole_postgresql_data`. Test the database and Agent Home restore together on a separate host before you rely on them — an untested backup is not a backup.

## Pin images for a controlled rollout

The default images are the moving `main-latest` tags:

```text
ghcr.io/agentbull/ankole-agent-control-plane:main-latest
ghcr.io/agentbull/ankole-agent-computer-worker:main-latest
ghcr.io/agentbull/ankole-postgres-for-ankole:main-latest
```

`main-latest` follows the most recent successful publish. For a controlled production upgrade, do not ride the moving tag. Pin both Ankole images to digests from the same verified pair — control plane and worker move together, or neither should move.

### Compose

In `.env`, set the digest-pinned images:

```bash
ANKOLE_CONTROL_PLANE_IMAGE=ghcr.io/agentbull/ankole-agent-control-plane@sha256:<digest>
ANKOLE_WORKER_IMAGE=ghcr.io/agentbull/ankole-agent-computer-worker@sha256:<digest>
ANKOLE_POSTGRESQL_IMAGE=ghcr.io/agentbull/ankole-postgres-for-ankole@sha256:<digest>
```

### Helm

In `values-production.yaml`, set both digests in one revision:

```yaml
controlPlane:
  image:
    digest: sha256:<control-plane-digest>

worker:
  image:
    digest: sha256:<worker-digest>
```

Changing one without the other breaks the verified-pair guarantee the publish workflow exists to provide.

## Upgrade a Compose deployment

A single-host upgrade has a short service interruption. With the backup taken and the images pinned (or accepted at `main-latest`):

```bash
docker compose pull
docker compose down
docker compose up -d --force-recreate
docker compose ps
```

`down` keeps all named volumes but stops the old application before the migration. The new start runs the migration and bootstrap services again before the new control plane starts. When `docker compose ps` shows the stack healthy, the upgrade is complete.

## Upgrade a Helm deployment

With the backup taken and both digests set in `values-production.yaml`:

```bash
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

The chart's init containers run the migration (creating the required PostgreSQL extensions and applying every pending Ecto migration), then store the deployment worker key. The control plane starts only after both succeed. `--wait` holds the command until the rollout is observed; `--timeout 15m` bounds how long it waits.

## What is and is not reversible

The image roll is reversible; the database migration is not.

- **Image roll back** — recreate the previous images. Compose: pin the old digests in `.env` and `up -d --force-recreate`. Helm: set the old digests in `values-production.yaml` and `helm upgrade` again.
- **Database migration back** — not supported. `helm rollback` does not reverse an Ecto migration, and neither does recreating the old control-plane image. If the old application needs the old schema, restore the PostgreSQL backup you took before the upgrade. This is why the backup is not optional.

Agent Home (`ankole_agents_data`) is mutable runtime state, not migrated — a rollback does not require restoring it, but back it up anyway, since a worker bug in a new image can write into it.

## Verify after the upgrade

A few minutes after the stack is healthy:

- open the Console and confirm an agent can run a real turn (a model call resolves, a signal binding replies);
- check `/background-agent-jobs` for jobs stuck in an unexpected state after the restart;
- read the control-plane logs for any migration warnings the init container emitted.

If a turn fails with a provider or selector error after an upgrade, the migration is rarely the cause — work outward from the model, as the [FAQ](../faq/) describes. A migration-shaped failure is usually a visible error in the init container logs at startup time, not a silent runtime problem.

## Next steps

- For the original deployment steps, read the [installation guide](../installation/).
- For what each image contains, read the [architecture overview](../architecture/).
- For the platform requirements an upgrade targets, read [Platform support](../platform-support/).
