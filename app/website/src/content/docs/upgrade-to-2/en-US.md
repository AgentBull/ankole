---
title: Upgrade from 1.0 to 2.0
description: Move a 1.x site to 2.0, migrate the database, Workers, Agent Homes and drives, and verify recovery.
section: Guides
order: 313
---

This guide is for self-hosted sites that move from 1.0 or a later 1.x version to 2.0. Schedule a maintenance window. Stop all old-version writers before you run the new migrations. An image change cannot undo database migrations.

Rehearse this procedure with backups in an isolated environment before upgrading production, especially for earlier 1.x versions, custom deployments, or modified schemas.

## What changes

| Old 1.x layout | 2.0 layout | Operator action |
| --- | --- | --- |
| Pooled Workers and shared `/agents` | One Worker and private `/workspace` per Agent | Move or adopt Home and assign a WorkerProvider |
| Installed Skills and Automation scripts in Home | `skills/` and `automation/` in the control-plane drive | Run the one-time file import |
| Transient Codex state in Workers | Threads in `/workspace/.codex`; rebuildable cache in `/var/cache/ankole/codex` | Keep Home and provide a separate cache disk |
| In-process script sandboxes and 2 images | External stateless `ankole-function-runtime` (3 co-versioned images: `control-plane`, `worker`, `function-runtime`) | Add `ANKOLE_FUNCTION_RUNTIME_TOKEN` and upgrade all three matching images |
| Data and configuration without tenant ownership | Original data in the `default` tenant; Pod / Base storage on **PostgreSQL 18+** (with optional `BASE_DB_URLS` shards) | Upgrade to PostgreSQL 18+ and run schema and encrypted-configuration migrations with the original key |
| `LocalPassword` sign-in and single admin group | 100% passwordless Authn (`SiteCredential` `email_otp` + enterprise SSO) and per-tenant `pod_admin` alongside `siteadmin` | Pass credential preflight, configure SMTP (`authn.email.mail` or `mix ankole.authn.mail.put`) or SSO, and verify Pod admins |
| Console at `/console` | Site administration Console at `/site-admin-console` (or `ANKOLE_SITE_ADMIN_CONSOLE_PATH`) | Update bookmarks and ingress rules |

If a 1.x site already has private Workers or drives, apply only the steps it still needs. Do not replace existing Home or drive storage with empty storage.

## Prepare the upgrade

1. Record the current and target versions, image digests, Compose project or Helm release name, installation identifier, volume/PVC names, and provider configuration. All **three** images (`control-plane`, `worker`, and `function-runtime`) must use the same source revision. Official control-plane images supply the matching Worker image reference.
2. Keep the original `ANKOLE_SECRET_BASE`, database credentials, and deployment configuration. Add independent hexadecimal values for `RELEASE_COOKIE` and `ANKOLE_FUNCTION_RUNTIME_TOKEN` if they are not set yet. Do not generate a new `ANKOLE_SECRET_BASE` during the upgrade: it decrypts existing credentials and configuration.
3. Resolve all hard-stop Ecto migration preflight checks in the old release before stopping it:
   - **Reserved group collisions (`siteadmin` and `pod_admin`):** check for a custom group named `siteadmin` in the privileged tenant or a custom group named `pod_admin` in any tenant (especially a `computed` group), and rename it before upgrading. Both names are reserved in 2.0; a collision aborts migration. After migration, if a tenant has no unambiguous active administrator, repair it with `mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified --tenant SLUG` (omit `--tenant` to recover `siteadmin` in the privileged tenant).
   - **Passwordless credential preflight (`Ankole.CredentialUpgrade.preflight!/1`):** runs read-only before destructive credential conversion and stops the run if any non-offboarded Human (active or suspended) has a blank or missing login email, if two retained Principals in the same tenant share the same normalized login email, or if one Principal has multiple login emails. Fix reported conflicts in 1.x before retrying. Browser password proofs are revoked during conversion (offline OIDC sessions that match a unique browser proof keep their evidence; others require re-authorization). Sites that used `LocalPassword` **must** configure SMTP (`authn.email.mail` in Console, `mix ankole.authn.mail.put FILE.json`, or `Ankole.Release.put_authn_mail/1`) or a permitted enterprise SSO source so migrated `email_otp` users can sign in.
   - **Console grant CEL `resource` check:** legacy Console grants rewritten to `site_console:*` or `tenant_console:*` must not reference the `resource` variable in their CEL `condition`. Inspect custom Console grants and remove `resource` references before upgrading.
4. Stop new requests and scheduled work. Disable Agents and let active work finish. Stop all old Workers normally, including paused instances, then stop every old control-plane replica. Do not delete Agents to stop Workers.
5. Verify that the database server runs **PostgreSQL 18+** (`server_version_num >= 180000` with `pg_search` in `shared_preload_libraries`, plus `pg_search` and `vector`). Back up PostgreSQL (including any dedicated `BASE_DB_URLS` shard databases), existing file storage, all Agent Homes, and deployment secrets together, and keep the backup until login, tenant membership, and OIDC checks pass. Run the 2.0 migrations against a restored database copy first to measure maintenance-window duration. Compose Home copying needs additional free space at least equal to the used space in the old volume. See [Backup and restore](../backup-and-restore/).

The upgrade also reseals tenant identity-provider configuration, splits old shared Slack/Teams configuration, and resolves platform application identities. The migration environment needs the original key, valid platform credentials, and access to those platforms. Repair the configuration named in a failure log, then retry. Do not copy ciphertext into a new scope.

## Upgrade Docker Compose

Use the target version's [Compose deployment files](https://github.com/AgentBull/ankole/tree/main/tools/deploy/docker-compose), including `compose.yaml`, `worker-providers.yaml`, and `migrate-agent-homes.sh`. Keep the original `.env` and project name. Pin `ANKOLE_CONTROL_PLANE_IMAGE` and `ANKOLE_FUNCTION_RUNTIME_IMAGE` to the target release's matching images or digests (the control-plane image supplies the matching Worker image). Set `ANKOLE_DOCKER_GID` and keep the original `ANKOLE_WORKER_INSTALLATION`.

The examples use official `fs` configuration. For S3, prepare the override in [Drive storage configuration](../drive-storage/). Use the same `-f` options for every Compose command, including file imports.

Add `RELEASE_COOKIE` and `ANKOLE_FUNCTION_RUNTIME_TOKEN` to `.env` if either variable is missing:

```sh
grep -q '^RELEASE_COOKIE=' .env || printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)" >> .env
grep -q '^ANKOLE_FUNCTION_RUNTIME_TOKEN=' .env || printf 'ANKOLE_FUNCTION_RUNTIME_TOKEN=%s\n' "$(openssl rand -hex 32)" >> .env
```

The initial provider seed must set `legacy_agents: true`. Its `provider_id` must equal the Home migration service's `WORKER_PROVIDER`; the official files use `docker`. The seed imports only when the provider table is empty. Later YAML edits do not update stored providers.

2.0 requires **PostgreSQL 18+** (`pg_search` 0.25.11 and `vector`). Complete the major-version upgrade to PostgreSQL 18+ first if the existing database runs an older major version, then update `pg_search`:

```sh
docker compose pull
docker compose stop
docker compose up -d postgresql
docker compose exec postgresql psql -U ankole -d ankole -v ON_ERROR_STOP=1 \
  -c "ALTER EXTENSION pg_search UPDATE TO '0.25.11'"
docker compose up -d --force-recreate
docker compose ps -a migrate migrate-agent-homes
docker compose logs migrate migrate-agent-homes
```

`migrate` runs schema and configuration data migrations. `migrate-agent-homes` stops containers that mount the old shared volume, copies the Homes of existing Agents to private volumes, and sets ownership to uid 1000. The control plane starts only after both services exit successfully. Completion markers prevent retries from overwriting completed copies. If the old volume does not exist, the Home migration completes without copying.

Keep Agents disabled. If the old version had no drive, make the old volume readable by the import process, then import its files. These commands use the default project name; replace `ankole_agents_data` with the original volume for a custom project:

```sh
docker compose run --rm --no-deps --user root --entrypoint chmod \
  -v ankole_agents_data:/agents control-plane -R a+rX /agents
docker compose run --rm --no-deps -v ankole_agents_data:/agents:ro control-plane \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

The import copies installed Skills, Automation scripts, and unsent legacy Outbox attachments. It does not overwrite existing drive paths. Other user files and Session and Job workspaces stay in Home. Save the report. Repair `Skipped` files and Jobs without `main.ts`, then repeat the import. Keep the old volume until file checks and a restore rehearsal pass.

## Upgrade Kubernetes / Helm

1. Scale the old control-plane and pooled Worker Deployments to zero. Wait for all old Pods to disappear. Do not force-delete Pods or use `--grace-period=0`.
2. Ensure external or bundled PostgreSQL runs **PostgreSQL 18+**. If `secrets.existingSecret` (`ankole-bootstrap`) is configured, patch it so it includes both `RELEASE_COOKIE` and `ANKOLE_FUNCTION_RUNTIME_TOKEN` alongside `ANKOLE_SECRET_BASE` and `DATABASE_URL` before running `helm upgrade`:

```sh
kubectl -n ankole patch secret ankole-bootstrap --type merge -p "$(printf '{"stringData":{"RELEASE_COOKIE":"%s","ANKOLE_FUNCTION_RUNTIME_TOKEN":"%s"}}' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)")"
```

   (Run that patch only for keys not already present in `ankole-bootstrap`.)
3. Keep the old shared Agent Home PVC. Set `worker.agents.persistence.existingClaim` to it. Keep the original `worker.installation` and release name. If the old database uses the volume root, keep its original `postgresql.pgdata` (`/var/lib/pgsql/18/data`); a new directory can appear to be an empty database.
4. Prepare Home ownership and permissions before you start the new control plane. The command below requires storage on which Pod root can run `chown`. Replace `OLD_AGENTS_PVC` with the actual claim name.

```sh
kubectl -n ankole run ankole-agent-home-prepare --rm -i --restart=Never \
  --image=busybox:1.37 --overrides='{"apiVersion":"v1","spec":{
    "containers":[{"name":"prepare","image":"busybox:1.37",
      "securityContext":{"runAsUser":0},
      "command":["sh","-ec","chown -R 1000:1000 /agents; chmod 2777 /agents; chmod -R a+rX /agents"],
      "volumeMounts":[{"name":"agents","mountPath":"/agents"}]}],
    "volumes":[{"name":"agents","persistentVolumeClaim":{"claimName":"OLD_AGENTS_PVC"}}]}}'
```

Default root-squash NFS cannot perform this `chown` from a Pod. Prepare the files on the NFS server. Provide a mount that permits Worker root writes and ownership changes, or maps all access to uid/gid 1000. Files accessed through an EFS access point with uid/gid 1000 need no ownership conversion. See [WorkerProviders and cache disks](../worker-providers/).

Set the version-matched `controlPlane.image` and `functionRuntime.image` digests (and `worker.image` only if you override the Worker image explicitly), [drive backend](../drive-storage/), and old PVC in `values-production.yaml`. Then run:

The commands use namespace and release name `ankole` and assume `fullnameOverride: ankole`.

```sh
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole --values values-production.yaml \
  --set files.importAgentHomeClaim=OLD_AGENTS_PVC --wait --timeout 15m
kubectl -n ankole exec deployment/ankole-control-plane -c control-plane -- \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

The Deployment uses `Recreate`; the new Pod's `db-migrate` init container runs migrations first. Keep Agents disabled until import completes. Check the report, remove `files.importAgentHomeClaim`, and upgrade again. Workers still need the old Home PVC: keep it. Adjust commands for custom release, namespace, or Deployment names. See the [Helm deployment guide](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md).

## Verify and recover

- Check the original Agents, identity providers, signal bindings, and Jobs in the `default` tenant in Console. Existing Agents must have a WorkerProvider assignment. The default provider only selects placement for new Agents.
- Enable one Agent and run real file operations and a Job. Check original Home files, Codex thread recovery, imported Skills and Automation scripts, drive uploads and downloads, and attachment delivery. Then restore other Agents and scheduled work.
- If migration fails, keep old control planes stopped. Read Compose `migrate` or Kubernetes `db-migrate` logs. Repair the reported key, credentials, name collision, or storage permissions, then retry the same version's migration.
- The import report lists directories of deleted Agents. It does not create replacement Agents for them. Remove old directories or volumes only after you confirm that their files are no longer needed.
- For rollback, stop all new control planes, `ankole-function-runtime` instances, and Workers. Restore the pre-upgrade PostgreSQL database (and any `BASE_DB_URLS` shard databases), file storage, Homes, configuration, and original key together, then start the corresponding old images. `helm rollback` and image changes cannot undo destructive passwordless or schema migrations, and cannot preserve new writes that you have not exported separately.

For later operations, see [Workers](../worker-management/), [Drive storage configuration](../drive-storage/), and [Disaster recovery](../disaster-recovery/).
