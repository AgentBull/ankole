---
title: Installation
description: Deploy Ankole with Docker Compose on one host, or with the public Helm chart on Kubernetes.
section: Operations
order: 3
---

A production Ankole installation has a control plane, one or more Agent Computer workers, PostgreSQL, and persistent Agent Home storage. Two deployment packages are supported:

- **Docker Compose** for a single Linux host. It brings PostgreSQL, migrations, worker-key bootstrap, one Worker, and Caddy HTTPS.
- **Helm** for Kubernetes. It supports bundled or external PostgreSQL and requires shared `ReadWriteMany` storage for Agent Home.

Both packages pull the latest verified images from GitHub Container Registry:

```text
ghcr.io/agentbull/ankole-agent-control-plane:main-latest
ghcr.io/agentbull/ankole-agent-computer-worker:main-latest
ghcr.io/agentbull/ankole-postgres-for-ankole:main-latest
```

The control-plane and Worker tags move together, and only after the publish workflow has verified the RuntimeFabric image pair. For a controlled rollout, pin both Ankole images to digests from the same pair.

## Docker Compose on one host

Use a Linux `amd64` or `arm64` host with Docker Engine, the Docker Compose plugin, persistent local storage, and ports `80` and `443` free.

Clone the repository and prepare the deployment environment:

```bash
git clone https://github.com/AgentBull/ankole.git
cd ankole/tools/deploy/docker-compose
cp .env.example .env
chmod 600 .env
```

Generate three independent hexadecimal values:

```bash
openssl rand -hex 24
openssl rand -hex 32
openssl rand -hex 24
```

Put them in `.env` as `POSTGRES_PASSWORD`, `ANKOLE_SECRET_BASE`, and `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`. Set `ANKOLE_HOST` to a DNS name that points at the host, and set `ACME_EMAIL`. Do not put provider API keys in this file — configure them in the Ankole Console.

Start the installation:

```bash
docker compose pull
docker compose up -d
docker compose ps
```

Compose waits for PostgreSQL, applies all pending migrations, stores the Worker authentication key, then starts the control plane, Worker, and Caddy.

Read the first setup activation code:

```bash
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"
```

Open `https://<ANKOLE_HOST>/setup`. When the host has public DNS, Caddy obtains and renews the public certificate automatically. For a local-only `ankole.localhost` deployment, trust Caddy's local CA as described in the [complete Compose guide](https://github.com/AgentBull/ankole/blob/main/tools/deploy/docker-compose/README.md). The production setup flow requires trusted HTTPS.

### Operate and upgrade Compose

Back up the database before an upgrade:

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc \
  > "ankole-$(date +%Y%m%d).dump"
```

Then upgrade with a short service interruption:

```bash
docker compose pull
docker compose down
docker compose up -d --force-recreate
docker compose ps
```

`docker compose down` keeps named volumes. `docker compose down -v` deletes PostgreSQL, Agent Home, and Caddy data — do not use `-v` unless you intend to delete data permanently and have a tested backup.

## Helm on Kubernetes

The public chart lives at [`tools/deploy/helm/ankole-agent`](https://github.com/AgentBull/ankole/tree/main/tools/deploy/helm/ankole-agent). It requires Kubernetes 1.27 or later, Helm 3 or later, Linux `amd64` or `arm64` nodes, an HTTPS Ingress, and an RWX StorageClass or an existing RWX claim for Agent Home.

The chart installs bundled PostgreSQL by default:

```yaml
postgresql:
  enabled: true
```

To use an external database instead, set:

```yaml
postgresql:
  enabled: false

secrets:
  existingSecret: ankole-bootstrap
```

That external Secret must provide `ANKOLE_SECRET_BASE`, `DATABASE_URL`, and `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`. When bundled PostgreSQL is enabled, it must also provide `POSTGRES_PASSWORD`. The [complete Helm guide](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md) has the exact Secret commands and a production values file.

With the values file and Secret ready, install:

```bash
helm upgrade --install ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --create-namespace \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

The chart runs the database migration and worker-key bootstrap as init containers. The control plane starts only after both succeed.

### PostgreSQL requirements

Bundled PostgreSQL already carries the required packages. An external server must run PostgreSQL 18 or later, preload `pg_search`, and make `pg_search` and `vector` available to the application database owner:

```sql
SHOW server_version_num;
SHOW shared_preload_libraries;

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_search', 'vector')
ORDER BY name;
```

`server_version_num` must be at least `180000`, and `shared_preload_libraries` must contain `pg_search`. Back up PostgreSQL and Agent Home before every upgrade — a Helm rollback does not reverse a database migration.

## First product setup

For Helm, read the activation code from the control-plane log:

```bash
kubectl -n ankole logs deployment/ankole-control-plane \
  -c control-plane | grep "SETUP ACTIVATION CODE"
```

Open the HTTPS `/setup` page, enter the code, pick the Control Plane Plugins, and configure the administrator identity provider. Then use the Console to configure providers, model profiles, Agents, Signal bindings, Agent Library capabilities, and WorkerEnv secrets.

The identity step shows the login callback URL of this installation. It is the request origin that the control plane receives plus the Provider ID, in the form `https://<domain>/sessions/oidc/<provider-id>/callback`. Register that URL in the identity provider developer console before you sign in, because a provider accepts only a registered callback URL. The browser must reach the URL, so it must be the TLS-terminating ingress address and not an internal cluster address. Credentials that the provider rejects stop at this step with the provider's own message, and do not send you to a provider error page.

Agent Computer needs `SYS_ADMIN`, an unconfined seccomp profile, and an unmasked `/proc` for strong bubblewrap isolation. The Compose and Helm packages already carry these settings. Treat Worker nodes as a trusted, first-party compute boundary.
