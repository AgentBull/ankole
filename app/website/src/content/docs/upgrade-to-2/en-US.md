---
title: Upgrade from 1.0 to 2.0
description: Move a 1.x site to 2.0, migrate the database, Workers, Agent Homes and drives, and verify recovery.
section: Guides
order: 313
---

This guide walks self-hosted deployments through upgrading from Ankole 1.0 (or a later 1.x release) to 2.0. Schedule a maintenance window and stop all 1.x writers before running the 2.0 migrations—reverting container images cannot undo completed database migrations.

Always rehearse the upgrade against a restored backup in an isolated staging environment before touching production, especially if you are upgrading from an early 1.x build, running custom infrastructure, or carrying local schema changes.

## What changes

| Old 1.x layout | 2.0 layout | Operator action |
| --- | --- | --- |
| Pooled Workers and shared `/agents` | One Worker and private `/workspace` per Agent | Copy or adopt Agent Homes and assign a WorkerProvider |
| Installed Skills and Automation scripts in Home | `skills/` and `automation/` in the control-plane drive | Run the one-time Agent Home file import |
| Transient Codex state in Workers | Threads in `/workspace/.codex`; rebuildable cache in `/var/cache/ankole/codex` | Preserve Home and attach a separate cache disk |
| In-process script sandboxes and 2 images | External stateless `ankole-function-runtime` (3 co-versioned images: `control-plane`, `worker`, `function-runtime`) | Set `ANKOLE_FUNCTION_RUNTIME_TOKEN` and deploy all three matching images |
| Data and configuration without tenant ownership | Original data placed in the `default` tenant; Pod / Base storage on **PostgreSQL 18+** (with optional `BASE_DB_URLS` shards) | Upgrade to PostgreSQL 18+ and run schema and encrypted-config migrations with the original key |
| `LocalPassword` sign-in and single admin group | 100% passwordless Authn (`SiteCredential` `email_otp` + enterprise SSO) and per-tenant `pod_admin` alongside `siteadmin` | Pass credential preflight, configure SMTP (`authn.email.mail` or `mix ankole.authn.mail.put`) or SSO, and verify Pod admins |
| Console at `/console` | Site Admin Console at `/site-admin-console` (or `ANKOLE_SITE_ADMIN_CONSOLE_PATH`) | Update bookmarks and reverse-proxy ingress rules |

If a late 1.x deployment already runs per-Agent Workers or drives, perform only the remaining steps—never overwrite existing Home or drive volumes with empty storage.

## Prepare the upgrade

1. Record your current and target versions, image digests, Docker Compose project or Helm release name, installation ID, volume or PVC names, and Worker provider settings. All **three** images (`control-plane`, `worker`, and `function-runtime`) must come from the exact same source revision; official `control-plane` images already reference the matching `worker` image digest.
2. Preserve your existing `ANKOLE_SECRET_BASE`, database credentials, and deployment configuration, and generate independent random hex secrets for `RELEASE_COOKIE` and `ANKOLE_FUNCTION_RUNTIME_TOKEN` if they are not set yet. Never rotate `ANKOLE_SECRET_BASE` during the upgrade, because the migration needs the original key to decrypt and reseal stored credentials.
3. Clear all hard-stop preflight checks on the 1.x deployment before shutting it down:
   - **Reserved group name collisions (`siteadmin` and `pod_admin`):** Check for any custom group named `siteadmin` in the privileged tenant or `pod_admin` in any tenant (especially `computed` groups) and rename it before upgrading. Both names are reserved in 2.0, and a collision aborts the migration. If a tenant ends up with no unambiguous active administrator after migration, promote one with `mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified --tenant SLUG` (omit `--tenant` to recover `siteadmin` in the privileged tenant).
   - **Passwordless credential preflight (`Ankole.CredentialUpgrade.preflight!/1`):** Ankole runs this read-only check before converting credentials and aborts if any non-offboarded Human (active or suspended) lacks a login email, if two retained Principals in the same tenant share a normalized login email, or if one Principal owns multiple login emails. Resolve any reported conflicts in 1.x before retrying. During conversion, Ankole revokes browser password proofs (offline OIDC sessions tied to a unique browser proof retain their evidence; others prompt for re-authorization). Deployments that used `LocalPassword` **must** configure either SMTP (`authn.email.mail` in the Console, `mix ankole.authn.mail.put FILE.json`, or `Ankole.Release.put_authn_mail/1`) or an allowed enterprise SSO provider so migrated `email_otp` users can sign in.
   - **Console grant CEL `resource` variable check:** Legacy Console grants migrated to `site_console:*` or `tenant_console:*` cannot reference `resource` in their CEL `condition`. Audit custom Console grants and remove any `resource` references beforehand.
4. Quiesce new traffic and scheduled jobs: disable Agents, let running work complete, stop all 1.x Workers cleanly (including paused instances), and then stop every 1.x control-plane replica. Never delete Agents as a shortcut for stopping Workers.
5. Confirm that PostgreSQL runs **PostgreSQL 18+** (`server_version_num >= 180000` with `pg_search` in `shared_preload_libraries`, plus the `pg_search` and `vector` extensions). Take a coordinated backup of PostgreSQL (including any `BASE_DB_URLS` shard databases), object/file storage, all Agent Homes, and deployment secrets, and retain that backup until sign-in, tenant membership, and OIDC flows are verified. Rehearse the 2.0 migrations on a restored database copy first to time your maintenance window. For Docker Compose Home migration, verify that the host has free disk space at least equal to the used bytes in the old shared volume. See [Backup and restore](../backup-and-restore/).

During migration, Ankole also reseals tenant Identity Provider secrets, splits legacy shared Slack and Teams configurations, and resolves upstream application IDs—so ensure the migration container has the original `ANKOLE_SECRET_BASE`, valid platform credentials, and outbound network access to those chat platforms. If a step fails, repair the configuration named in the log and re-run; never copy raw ciphertext across scopes by hand.

## Upgrade Docker Compose

Fetch the target release's [Compose deployment files](https://github.com/AgentBull/ankole/tree/main/tools/deploy/docker-compose)—including `compose.yaml`, `worker-providers.yaml`, and `migrate-agent-homes.sh`—while keeping your existing `.env` and Compose project name. Pin `ANKOLE_CONTROL_PLANE_IMAGE` and `ANKOLE_FUNCTION_RUNTIME_IMAGE` to matching 2.0 release tags or digests (the control-plane image supplies the matching Worker image), set `ANKOLE_DOCKER_GID`, and preserve `ANKOLE_WORKER_INSTALLATION`.

The commands below assume the default `fs` drive backend; if you use S3, include the override file from [Drive storage configuration](../drive-storage/) and pass the exact same `-f` flags to every `docker compose` command, including the one-time file import.

Append `RELEASE_COOKIE` and `ANKOLE_FUNCTION_RUNTIME_TOKEN` to `.env` if either variable is missing:

```sh
grep -q '^RELEASE_COOKIE=' .env || printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)" >> .env
grep -q '^ANKOLE_FUNCTION_RUNTIME_TOKEN=' .env || printf 'ANKOLE_FUNCTION_RUNTIME_TOKEN=%s\n' "$(openssl rand -hex 32)" >> .env
```

In `worker-providers.yaml`, ensure the initial provider seed sets `legacy_agents: true` and uses the same `provider_id` as the Home migration service's `WORKER_PROVIDER` (`docker` in the official files). Ankole imports this seed YAML only when the provider table is empty; make any subsequent provider changes in the Console.

Because 2.0 requires **PostgreSQL 18+** (`pg_search` `0.25.11` and `vector`), complete a PostgreSQL major-version upgrade first if your server runs an older major version, and then update `pg_search` and run the Compose stack:

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

Here, `migrate` runs schema and encrypted-configuration migrations, while `migrate-agent-homes` stops any containers still mounting the old shared volume, copies each existing Agent's Home into its own private volume, and sets ownership to `uid 1000`. The control plane waits until both one-shot services exit `0`. Completion markers ensure retries never overwrite finished copies, and if no legacy volume exists, `migrate-agent-homes` exits cleanly without copying.

Leave Agents disabled while you import legacy files into the control-plane drive (replace `ankole_agents_data` below if you use a custom Compose project name):

```sh
docker compose run --rm --no-deps --user root --entrypoint chmod \
  -v ankole_agents_data:/agents control-plane -R a+rX /agents
docker compose run --rm --no-deps -v ankole_agents_data:/agents:ro control-plane \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

`import_agent_home/1` imports installed Skills, Automation scripts, and unsent legacy Outbox attachments without overwriting existing drive paths, leaving general user files and Session/Job workspaces in Home. Save the printed import report, fix any `Skipped` files or Automation Jobs missing `main.ts`, and re-run the import until clean. Retain the old shared volume until file verification and a restore rehearsal succeed.

## Upgrade Kubernetes / Helm

1. Scale both the 1.x control-plane Deployment and pooled Worker Deployment to `0` replicas and wait for every old Pod to terminate cleanly—never force-delete Pods or pass `--grace-period=0`.
2. Confirm that your external or bundled database runs **PostgreSQL 18+**. If you use `secrets.existingSecret` (`ankole-bootstrap`), patch it so `RELEASE_COOKIE` and `ANKOLE_FUNCTION_RUNTIME_TOKEN` exist alongside `ANKOLE_SECRET_BASE` and `DATABASE_URL` before running `helm upgrade`:

```sh
kubectl -n ankole patch secret ankole-bootstrap --type merge -p "$(printf '{"stringData":{"RELEASE_COOKIE":"%s","ANKOLE_FUNCTION_RUNTIME_TOKEN":"%s"}}' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)")"
```

   (Patch only keys that are not already present in `ankole-bootstrap`.)
3. Retain your existing shared Agent Home PVC by pointing `worker.agents.persistence.existingClaim` at it, and keep the original `worker.installation` and Helm release name. If your bundled PostgreSQL stores data directly at the volume root, keep its existing `postgresql.pgdata` path (`/var/lib/pgsql/18/data`) so PostgreSQL does not initialize an empty directory.
4. Normalize ownership and permissions on the Agent Home PVC before booting the 2.0 control plane (requires storage where container `root` can run `chown`; replace `OLD_AGENTS_PVC` with your PVC name):

```sh
kubectl -n ankole run ankole-agent-home-prepare --rm -i --restart=Never \
  --image=busybox:1.37 --overrides='{"apiVersion":"v1","spec":{
    "containers":[{"name":"prepare","image":"busybox:1.37",
      "securityContext":{"runAsUser":0},
      "command":["sh","-ec","chown -R 1000:1000 /agents; chmod 2777 /agents; chmod -R a+rX /agents"],
      "volumeMounts":[{"name":"agents","mountPath":"/agents"}]}],
    "volumes":[{"name":"agents","persistentVolumeClaim":{"claimName":"OLD_AGENTS_PVC"}}]}}'
```

On NFS exports with default root-squash enabled, a Pod cannot run `chown`; run the ownership change on the NFS server instead, and export the share so Worker `root` can write and `chown` to `uid/gid 1000` (or map all client access to `uid/gid 1000`). Volumes mounted via an AWS EFS access point already enforcing `uid/gid 1000` need no conversion. See [WorkerProviders and cache disks](../worker-providers/).

Configure matching 2.0 digests for `controlPlane.image` and `functionRuntime.image` (plus `worker.image` only if you override the Worker image explicitly), your [drive backend](../drive-storage/), and the existing Home PVC in `values-production.yaml`. Assuming namespace and release name `ankole` with `fullnameOverride: ankole`, run:

```sh
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole --values values-production.yaml \
  --set files.importAgentHomeClaim=OLD_AGENTS_PVC --wait --timeout 15m
kubectl -n ankole exec deployment/ankole-control-plane -c control-plane -- \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

Because the control-plane Deployment uses the `Recreate` strategy, the new Pod's `db-migrate` init container completes all Ecto migrations before the control plane starts. Keep Agents disabled until `import_agent_home/1` finishes, review the printed report, remove `files.importAgentHomeClaim`, and run `helm upgrade` once more—keeping the shared Home PVC itself, which Worker Pods continue to mount. Adjust resource names if your release, namespace, or Deployment names differ; see the [Helm deployment guide](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md).

## Verify and recover

- Inspect migrated Agents, Identity Providers, signal routing rules, and Background Agent Jobs under the `default` tenant in the Console. Verify that every existing Agent has an assigned WorkerProvider, since the site default provider applies only to newly created Agents.
- Enable a single canary Agent first and exercise file tools and a Background Agent Job—checking legacy Home files, Codex thread resumption, imported Skills and Automation scripts, drive uploads/downloads, and chat attachment delivery—before re-enabling your remaining Agents and schedules.
- If a migration step fails, leave 1.x replicas stopped, inspect the Compose `migrate` or Kubernetes `db-migrate` logs, fix the reported secret, credential, group-name collision, or storage permission issue, and re-run the 2.0 migration.
- `import_agent_home/1` logs leftover Home directories belonging to previously deleted Agents without recreating those Agents; delete legacy directories or volumes only after confirming none of their files are needed.
- If you must roll back to 1.x, stop all 2.0 control planes, `ankole-function-runtime` instances, and Workers, restore your coordinated pre-upgrade backup (PostgreSQL, any `BASE_DB_URLS` shard databases, object/file storage, Agent Homes, configuration, and original `ANKOLE_SECRET_BASE`), and start the 1.x images. Running `helm rollback` or reverting image tags alone cannot undo destructive passwordless or schema migrations, nor preserve post-upgrade writes that were not exported separately.

For day-two operations after upgrading, see [Workers](../worker-management/), [Drive storage configuration](../drive-storage/), and [Disaster recovery](../disaster-recovery/).
