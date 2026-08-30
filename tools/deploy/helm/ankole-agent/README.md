# Ankole Helm chart

[简体中文](README.zh-Hans.md)

This chart installs the open-source Ankole control plane and Agent Computer
workers. It can also install the Ankole PostgreSQL 18 image. That image includes
`pg_search` and `vector`.

## Requirements

- Kubernetes 1.27 or later.
- Helm 3 or later.
- A Linux `amd64` or `arm64` node pool.
- A `ReadWriteMany` StorageClass or an existing RWX claim for Agent Home.
- An HTTPS Ingress for the setup and Console browser flows.
- Enough CPU, memory, and storage for the selected model workload.

The worker security context adds `SYS_ADMIN`, uses `procMount: Unmasked`, and
uses an unconfined seccomp profile. Check that the cluster admission policy
permits these settings.

## Install with bundled PostgreSQL

Create the namespace and bootstrap Secret first. An explicit Secret prevents a
failed first install from changing the database password while a retained
PostgreSQL volume still has the old password.

```sh
kubectl create namespace ankole

POSTGRES_PASSWORD="$(openssl rand -hex 24)"
ANKOLE_SECRET_BASE="$(openssl rand -hex 32)"
ANKOLE_WORKER_AUTH_KEY="$(openssl rand -hex 24)"

kubectl -n ankole create secret generic ankole-bootstrap \
  --from-literal="POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
  --from-literal="ANKOLE_SECRET_BASE=${ANKOLE_SECRET_BASE}" \
  --from-literal="ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=${ANKOLE_WORKER_AUTH_KEY}" \
  --from-literal="DATABASE_URL=ecto://ankole:${POSTGRES_PASSWORD}@ankole-postgresql:5432/ankole"

unset POSTGRES_PASSWORD ANKOLE_SECRET_BASE ANKOLE_WORKER_AUTH_KEY
```

Create `values-production.yaml`:

```yaml
fullnameOverride: ankole

secrets:
  existingSecret: ankole-bootstrap

controlPlane:
  publicHost: ankole.example.com

worker:
  agents:
    persistence:
      storageClass: nfs-rwx
      size: 100Gi

postgresql:
  enabled: true
  persistence:
    storageClass: standard
    size: 50Gi

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
  hosts:
    - host: ankole.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: ankole-tls
      hosts:
        - ankole.example.com
```

Replace the host, Ingress settings, and StorageClass names. The
`fullnameOverride` value keeps the PostgreSQL Service name equal to
`ankole-postgresql`, which matches the Secret.

Install the chart:

```sh
helm upgrade --install ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

The migration init container creates both required PostgreSQL extensions and
applies every pending Ecto migration. The next init container stores the
deployment worker key in AppConfigure. The control plane starts only after both
operations succeed.

## Install with external PostgreSQL

The external server must run PostgreSQL 18 or later. It must preload
`pg_search`, and it must make both `pg_search` and `vector` available to the
application database owner.

Check the exact server from `DATABASE_URL` before installation:

```sql
SHOW server_version_num;
SHOW shared_preload_libraries;

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_search', 'vector')
ORDER BY name;
```

`server_version_num` must be at least `180000`, and
`shared_preload_libraries` must contain `pg_search`.

Create a Secret:

```sh
ANKOLE_SECRET_BASE="$(openssl rand -hex 32)"
ANKOLE_WORKER_AUTH_KEY="$(openssl rand -hex 24)"

kubectl -n ankole create secret generic ankole-bootstrap \
  --from-literal="ANKOLE_SECRET_BASE=${ANKOLE_SECRET_BASE}" \
  --from-literal="ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=${ANKOLE_WORKER_AUTH_KEY}" \
  --from-literal="DATABASE_URL=ecto://ankole:REPLACE_ME@postgres.example.com:5432/ankole"

unset ANKOLE_SECRET_BASE ANKOLE_WORKER_AUTH_KEY
```

Set these values in `values-production.yaml`:

```yaml
secrets:
  existingSecret: ankole-bootstrap

postgresql:
  enabled: false
```

Use the same Helm install command as the bundled database path.

## First setup

Wait for all workloads:

```sh
kubectl -n ankole get pods
kubectl -n ankole rollout status deployment/ankole-control-plane --timeout=10m
kubectl -n ankole rollout status deployment/ankole-worker --timeout=10m
```

Read the activation code from the control-plane log:

```sh
kubectl -n ankole logs deployment/ankole-control-plane \
  -c control-plane | grep "SETUP ACTIVATION CODE"
```

Open `https://ankole.example.com/setup`, enter the code, select the Control
Plane Plugins, and configure the administrator identity provider. The
production image uses secure cookies, so the browser setup flow requires HTTPS.

After setup, use the Console to configure providers, model profiles, Agent
Library capabilities, Agents, channel bindings, and WorkerEnv secrets. Do not
put provider API keys in Helm values.

## Image policy and upgrades

Direct upgrades to this release are supported only from v0.70.0 or later.
Upgrades from an older release are not supported.

The default images are:

```text
ghcr.io/agentbull/ankole-agent-control-plane:main-latest
ghcr.io/agentbull/ankole-agent-computer-worker:main-latest
ghcr.io/agentbull/ankole-postgres-for-ankole:main-latest
```

`main-latest` follows the most recent successful GitHub publish. Before a
controlled production upgrade, resolve and record the control-plane and worker
digests. Change both digest values in one values-file revision:

```yaml
controlPlane:
  image:
    digest: sha256:CONTROL_PLANE_DIGEST

worker:
  image:
    digest: sha256:WORKER_DIGEST
```

Do not combine a control-plane digest and worker digest from different source
revisions. RuntimeFabric checks the protocol, but matching source revisions also
keep the full runtime contract aligned.

Back up PostgreSQL and Agent Home before each upgrade. Then run:

```sh
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

The new control-plane Pod runs migrations before it starts. A Helm rollback
does not reverse a database migration. Restore the database backup if an
application rollback also needs a schema rollback.

The chart uses `Recreate` for the single control-plane Pod and for Workers.
An upgrade has a short service interruption, but an old control plane does not
run against a schema that the new release is changing.

## Storage and backup

Agent Home is authoritative worker file state. The chart requires an RWX claim
and mounts it at `/agents`. A chart-created Agent Home PVC has the Helm
`keep` policy, so `helm uninstall` does not delete it.

The bundled PostgreSQL StatefulSet retains its PVC after deletion or scale
down. Back up the database independently:

```sh
kubectl -n ankole exec statefulset/ankole-postgresql -- \
  pg_dump -U ankole -d ankole -Fc > "ankole-$(date +%Y%m%d).dump"
```

Also use the storage provider snapshot mechanism for the PostgreSQL and Agent
Home volumes. Test restore procedures on a separate installation.

## Operations

```sh
# Workload status
kubectl -n ankole get deployments,statefulsets,pods,pvc,ingress

# Control-plane logs
kubectl -n ankole logs deployment/ankole-control-plane -c control-plane -f

# Worker logs
kubectl -n ankole logs deployment/ankole-worker -c worker -f

# Migration logs when a control-plane Pod is blocked
kubectl -n ankole logs POD_NAME -c db-migrate

# PostgreSQL readiness and extensions
kubectl -n ankole exec statefulset/ankole-postgresql -- \
  psql -U ankole -d ankole -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_search', 'vector') ORDER BY extname"
```

## Main values

| Value | Default | Purpose |
| --- | --- | --- |
| `secrets.existingSecret` | empty | Existing bootstrap Secret |
| `controlPlane.image.tag` | `main-latest` | Mutable GitHub image channel |
| `controlPlane.image.digest` | empty | Immutable control-plane image |
| `controlPlane.publicHost` | `ankole.example.com` | Phoenix public host |
| `worker.image.digest` | empty | Immutable worker image |
| `worker.replicaCount` | `1` | Worker process count |
| `worker.agents.persistence.existingClaim` | empty | Existing RWX Agent Home claim |
| `worker.agents.persistence.storageClass` | empty | RWX StorageClass |
| `postgresql.enabled` | `true` | Install bundled PostgreSQL |
| `postgresql.persistence.enabled` | `true` | Persist bundled PostgreSQL |
| `ingress.enabled` | `false` | Create an Ingress |

When `secrets.existingSecret` is set, it must contain these keys:

- `ANKOLE_SECRET_BASE`
- `DATABASE_URL`
- `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`
- `POSTGRES_PASSWORD` when bundled PostgreSQL is enabled

When no existing Secret is set, the chart can generate missing secret values
and preserve them during normal upgrades. Explicit secret management is safer
for production recovery.

## Troubleshooting

- A pending Worker PVC usually means that the selected StorageClass does not
  support `ReadWriteMany`.
- A blocked `db-migrate` init container usually means that `DATABASE_URL` is
  wrong, PostgreSQL is not ready, or the required extensions are unavailable.
- A running worker that never becomes ready usually has a wrong RuntimeFabric
  key or cannot reach the control-plane Service on port `6010`.
- A setup page that reloads after activation usually has no trusted HTTPS
  connection. Check the Ingress certificate and forwarded host.
- An admission rejection for the worker security context means that the
  cluster policy does not permit the isolation settings. Use a dedicated
  trusted worker node pool or an equivalent approved sandbox profile.
