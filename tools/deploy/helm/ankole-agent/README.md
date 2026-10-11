# Ankole Helm chart

[简体中文](README.zh-Hans.md)

This chart installs the open-source Ankole control plane. The control plane
creates one Agent Computer Worker Pod for each Agent that needs one, through
the Kubernetes API. The chart can also install the Ankole PostgreSQL 18 image.
That image includes `pg_search` and `vector`.

A site is one complete deployment. It may contain several tenants, each with
its own people, Agents, Brain and integrations. Site operators manage shared
providers and infrastructure. The administrator Console defaults to
`/site-admin-console`; `/console` returns 404 after this upgrade. Set
`controlPlane.siteAdminConsolePath` in Helm values to choose another absolute path.
Keep that path in operator configuration. Normal users sign in through their
OIDC application rather than the site administration Console.

## Requirements

- Kubernetes 1.27 or later.
- Helm 3 or later.
- A Linux `amd64` or `arm64` node pool.
- A `ReadWriteMany` StorageClass for the default shared Agent Home claim, or
  an exclusive `worker.storage.claimTemplate` for each Agent.
- A StorageClass with `ReadWriteOnce` volumes for the Worker cache disks, when
  `worker.cache.type` is `pvc` (the default).
- An HTTPS Ingress for the setup and Console browser flows.
- Enough CPU, memory, and storage for the selected model workload. Each Agent
  that runs has its own Worker Pod with the `worker.resources` of the values.

Worker Pods need no extra kernel privileges: the container is the isolation
boundary of each Agent. The chart gives the control plane a namespace Role that
creates and deletes Pods, Secrets, and PVCs, and gives the Worker Pods their own
ServiceAccount without permissions.

## Install with bundled PostgreSQL

Create the namespace and bootstrap Secret first. An explicit Secret prevents a
failed first install from changing the database password while a retained
PostgreSQL volume still has the old password.

```sh
kubectl create namespace ankole

POSTGRES_PASSWORD="$(openssl rand -hex 24)"
ANKOLE_SECRET_BASE="$(openssl rand -hex 32)"
RELEASE_COOKIE="$(openssl rand -hex 32)"

kubectl -n ankole create secret generic ankole-bootstrap \
  --from-literal="POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
  --from-literal="ANKOLE_SECRET_BASE=${ANKOLE_SECRET_BASE}" \
  --from-literal="RELEASE_COOKIE=${RELEASE_COOKIE}" \
  --from-literal="DATABASE_URL=ecto://ankole:${POSTGRES_PASSWORD}@ankole-postgresql:5432/ankole"

unset POSTGRES_PASSWORD ANKOLE_SECRET_BASE RELEASE_COOKIE
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
      storageClass: nfs
  cache:
    type: pvc
    storageClass: standard
    size: 20Gi

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
applies every pending Ecto migration. The control plane starts only after it
succeeds.

## Install with external PostgreSQL

The external server must run PostgreSQL 18 or later. It must preload
`pg_search`, and it must make both `pg_search` and `vector` available to the
application database owner. The extension and loaded library must meet the
[Brain version contract](../../../../docs/design-docs/BrainV3.md#retrieval-index-recovery).
For an older installation, stop the control plane and follow the
[database image upgrade procedure](../../../devkit/postgres-for-ankole/README.md)
before you deploy the new Pods. This also applies to bundled PostgreSQL.

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
RELEASE_COOKIE="$(openssl rand -hex 32)"

kubectl -n ankole create secret generic ankole-bootstrap \
  --from-literal="ANKOLE_SECRET_BASE=${ANKOLE_SECRET_BASE}" \
  --from-literal="RELEASE_COOKIE=${RELEASE_COOKIE}" \
  --from-literal="DATABASE_URL=ecto://ankole:REPLACE_ME@postgres.example.com:5432/ankole"

unset ANKOLE_SECRET_BASE RELEASE_COOKIE
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
```

The installation has no Worker Pod yet. The control plane creates the Worker of
an Agent when the Agent is created.

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
ghcr.io/agentbull/ankole-postgres-for-ankole:main-latest
```

`main-latest` follows the most recent successful GitHub publish. Before a
controlled production upgrade, resolve and record the control-plane digest:

```yaml
controlPlane:
  image:
    digest: sha256:CONTROL_PLANE_DIGEST
```

The control-plane image supplies its matching immutable Worker image.
Leave `worker.image` empty to use that image. Set `worker.image.repository`
and its tag or digest only for an explicit Worker image override. An override
must come from the same source revision as the control plane.

After an upgrade, the control plane replaces each Worker that has another image
when its Agent is idle; a running Job keeps its old Worker until it ends. A
Worker of another RuntimeFabric protocol version is replaced at once.
Instance replacement preserves Agent Home and Codex Home.

When upgrading from pooled Workers, first scale the old control-plane and
Worker Deployments to zero. Wait until their Pods have disappeared. Do not use
`--grace-period=0` or force-delete Pods. Prepare the old shared claim as described
below **before** starting the new control plane. The seed assigns the old
Agents to that claim in the same transaction that imports the provider.

Back up PostgreSQL, Agent Home storage, and the file store before each upgrade. Then run:

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

The default provider uses the retained shared Agent Home claim, usually
`<release>-ankole-agent-agents`. Each Worker mounts only its Agent's directory at
`/workspace`; `/agents/<agent_uid>` is a symbolic link to it. Keep the old claim
name in `worker.agents.persistence.existingClaim` if the release name changes.

The old Workers ran as root, and each old Agent Home has mode 0700. New Worker
commands, Codex, MCP servers, browsers, and Automation scripts run as uid 1000.
The credential-holding Worker still runs as root. The one-time drive import
reads the old files as uid 10001.
After all old writers have stopped, prepare the old claim for its storage:

- **Root in a Pod is root on the files**, for example on block and local
  volumes and on NFS exported with `no_root_squash`: run the preparation Pod
  below with the old claim name in `<claim>`.
- **NFS with root squash**, the NFS default: the server maps root in a Pod to
  its anonymous user. That user owns the old Homes but cannot give them to
  uid 1000, so `chown` in the preparation Pod fails with
  `Operation not permitted`. Run the three commands of the Pod as root on the
  NFS server, with the directory of the claim on the server in place of
  `/agents`. The new Worker needs root writes and `chown`, so use
  `no_root_squash` for runtime access or map all access with
  `all_squash,anonuid=1000,anongid=1000`.
- **EFS through an access point with POSIX user 1000 and group 1000**: every
  access, also each write of the old Workers, used uid 1000, so the files
  already belong to uid 1000. No preparation is necessary.

```sh
kubectl -n ankole run ankole-agent-home-prepare --rm -i --restart=Never \
  --image=busybox:1.37 --overrides='{"apiVersion":"v1","spec":{
    "containers":[{"name":"prepare","image":"busybox:1.37",
      "securityContext":{"runAsUser":0},
      "command":["sh","-ec","chown -R 1000:1000 /agents; chmod 2777 /agents; chmod -R a+rX /agents"],
      "volumeMounts":[{"name":"agents","mountPath":"/agents"}]}],
    "volumes":[{"name":"agents","persistentVolumeClaim":{"claimName":"<claim>"}}]}}'
```

Wait for the command to succeed. It gives the old Homes to uid 1000. It sets
the root directory to group 1000 and mode 2777, so uid 1000 can write the
directories that kubelet creates for new Agents. It also makes the old files
readable for the import.

Then upgrade with `--set files.importAgentHomeClaim=<claim>`, which mounts the
claim read-only at `/agents` in the control plane, and run the import:

```sh
kubectl -n ankole exec deployment/ankole-control-plane -c control-plane -- \
  /app/bin/ankole eval 'Ankole.Release.import_agent_home("/agents")'
```

Then upgrade again without the value. The import copies each Agent's
installed Skills, Automation Job scripts, and unsent legacy attachment bytes.
It never replaces a drive file and reports every skipped or unreadable file.
User files, session files, and
Job workspaces remain in Agent Home. Files named by unsent attachments also
enter the drive. Resolve each missing attachment in the report before removing
the old volume; legacy sends wait for conversion.

The old release did not remove the Home of an Agent that you deleted. The
import report names each orphan directory ("No Agent has the UID of …").
New Agents receive generated UIDs. Remove a reported orphan directory when
its files are no longer required. After the preparation above, the files belong to
uid 1000, so run the preparation Pod with `"runAsUser":1000` and the command
`["rm","-rf","/agents/<uid>"]`.

The chart uses `Recreate` for every control-plane replica count. An upgrade has a
short service interruption, but an old control plane does not run against a
schema that the new release is changing. Worker Pods keep running during the
upgrade and connect to the new control plane. Retain Recreate until all supported
direct-upgrade origins already contain tenant ownership and mixed-version
schema, writes and durable jobs have passed an upgrade rehearsal. The two Release
data steps remain until those origins also include identity scope and per-Agent
Slack/Teams keys and no legacy rows remain after rehearsal.

## Storage and backup

Before a consistent backup, disable Agents and wait for their work to finish.
End the Worker instances through normal platform deletion and wait for the
control plane to record absence and current storage references. Then stop the
control plane and back up PostgreSQL, the file store, and all Homes together.
Stopping the control plane alone does not stop Workers. Preserve the original
`ANKOLE_SECRET_BASE` with the backup secrets; it decrypts unsettled-generation
credentials as well as provider secrets.

Agent Home and Codex Home are durable data. The default provider uses the
shared claim; `worker.storage.claimTemplate` gives each Agent a separate PVC.
These PVCs have no Worker owner reference. The chart-managed shared PVC has
`helm.sh/resource-policy: keep`. Deleting a Pod, changing its image, or uninstalling
the chart preserves Agent Home. Back up this storage with PostgreSQL and the
file store.

The installation label, `worker.installation` or the release name when that
value is empty, is part of the names and labels of the Worker Pods, Secrets,
and PVCs. Do not change it after the first install. With a new label, the
control plane creates new, empty PVCs for exclusive Homes, and it does not see
the running Workers, so it can start a second Worker that writes the same
Home. To install the chart under another release name, set
`worker.installation` to the old label.

The separate cache at `/var/cache/ankole` holds Codex SQLite files. A cache PVC
survives instance deletion and image replacement. Rebuilding a Worker or changing
its instance settings deletes the cache. `worker.cache.type=emptyDir` instead
loses the cache when the Pod is deleted. Cache loss does not remove Agent Home.

The owner ConfigMap `<fullname>-agent-workers` owns Worker Pods, contract
Secrets, and cache PVCs. `helm uninstall`, or an upgrade with
`worker.localPods=false`, deletes these objects. Agent deletion removes its
instance first, then its persistent storage and cache.

The bundled PostgreSQL StatefulSet retains its PVC after deletion or scale
down. Back up the database independently:

```sh
kubectl -n ankole exec statefulset/ankole-postgresql -- \
  pg_dump -U ankole -d ankole -Fc > "ankole-$(date +%Y%m%d).dump"
```

The database is in the directory that `postgresql.pgdata` names, by default
`pgdata` on the PostgreSQL volume: a block volume such as EBS has `lost+found`
at its root, and `initdb` needs an empty directory. An earlier chart kept the
database at the volume root. When you upgrade such an installation, set
`postgresql.pgdata=/var/lib/pgsql/18/data`, so PostgreSQL opens the existing
database.

The control plane keeps Agent drives in the file store that `files.store`
selects. With `fs`, the chart creates a `ReadWriteOnce` PVC, mounts it at
`/var/lib/ankole/files`, and keeps it on `helm uninstall`; the Pod's `fsGroup`
makes it writable. With `s3`, the drives are in the bucket; give the bucket a
lifecycle rule that aborts incomplete multipart uploads, because a control
plane that stops during a large upload leaves its parts there. PostgreSQL names
every drive file, so back up and restore the database and the file store
together.

Also use the storage provider snapshot mechanism for the PostgreSQL and file
store volumes, or the bucket's backup mechanism. Test restore procedures on a
separate installation.

## Operations

```sh
# Workload status
kubectl -n ankole get deployments,statefulsets,pods,pvc,ingress

# Control-plane logs
kubectl -n ankole logs deployment/ankole-control-plane -c control-plane -f

# Worker Pods, one for each Agent that needs one
kubectl -n ankole get pods -l ankole.io/installation=ankole

# Logs of one Worker; the annotation ankole.io/agent-uid names its Agent
kubectl -n ankole logs POD_NAME -c worker -f

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
| `worker.image.digest` | empty | Digest for an explicit Worker image override |
| `worker.cache.type` | `pvc` | Worker cache disk: `pvc` (kept after instance deletion) or `emptyDir` |
| `worker.cache.size`, `worker.cache.storageClass` | `20Gi`, empty | Size and StorageClass of the cache disk |
| `worker.resources` | empty | Resources of each Worker Pod |
| `worker.runtimeClassName` | empty | RuntimeClass of the Worker Pods, for example `gvisor` |
| `worker.installation` | release name | Label in the names of the Worker objects of this release; do not change it after the first install |
| `worker.localPods` | `true` | Create the objects that Worker Pods in the release namespace need; `false` deletes them |
| `worker.providers` | empty | Complete initial provider seed list; replaces the generated default |
| `worker.providerConfig` | empty | Full raw YAML for the default Kubernetes provider |
| `worker.storage` | empty | Empty selects the shared claim; `claimTemplate` selects an exclusive PVC |
| `worker.agents.persistence` | RWX, `100Gi` | Retained shared Agent Home claim |
| `worker.idleReleaseAfter` | `15m` | Idle release policy of the generated provider |
| `files.store` | `fs` | Drive file store: `fs` (one control-plane replica) or `s3` |
| `files.persistence.size` | `100Gi` | Size of the `fs` file store PVC |
| `files.s3.bucket`, `files.s3.region` | empty | Bucket and region for `s3` |
| `files.s3.endpoint` | empty | Endpoint of an S3-compatible store such as Cloudflare R2 |
| `files.importAgentHomeClaim` | empty | Mount this Agent Home claim read-only in the control plane for the one-time import |
| `postgresql.enabled` | `true` | Install bundled PostgreSQL |
| `postgresql.persistence.enabled` | `true` | Persist bundled PostgreSQL |
| `postgresql.pgdata` | `/var/lib/pgsql/18/data/pgdata` | Database directory; `/var/lib/pgsql/18/data` for an installation that an earlier chart created |
| `ingress.enabled` | `false` | Create an Ingress |

When `secrets.existingSecret` is set, it must contain these keys:

- `ANKOLE_SECRET_BASE`
- `DATABASE_URL`
- `RELEASE_COOKIE`, the distributed Erlang cookie of the control-plane nodes
- `POSTGRES_PASSWORD` when bundled PostgreSQL is enabled

It can also contain `ANKOLE_FILES_S3_ACCESS_KEY_ID` and
`ANKOLE_FILES_S3_SECRET_ACCESS_KEY` for an `s3` file store with static
credentials. Without them the control plane uses the default AWS credential
chain, for example EKS Pod Identity. Provider seeds can read arbitrary credential keys from this Secret at
`/etc/ankole/bootstrap/<key>`. The control plane mounts it read-only.

When no existing Secret is set, the chart can generate missing secret values
and preserve them during normal upgrades. Explicit secret management is safer
for production recovery.

## Worker file relay

Drive transfers move bytes between the file store and a Worker through the
control-plane Pod that serves the Worker's drive request. The chart injects
`POD_IP` through the Downward API, and the control plane derives the relay
origin `http://<POD_IP>:<PORT>` from it. Workers must be able to reach every
control-plane Pod IP on the HTTP port; a NetworkPolicy that only permits the
Service address blocks file transfers. Set `ANKOLE_RUNTIME_FABRIC_INTERNAL_ORIGIN`
in `controlPlane.extraEnv` only when Workers reach the control plane through a
different per-Pod address.

## Control-plane replicas

Every control-plane Pod is one named Erlang node, `ankole@<POD_IP>`. The chart
renders a headless Service for node discovery, sets `DNS_CLUSTER_QUERY` to it,
stores a generated `RELEASE_COOKIE` in the bootstrap Secret, and fixes the
distribution port at `controlPlane.distributionPort`. With one replica these
settings are inert. This release uses Recreate even with several replicas:
all old control-plane Pods stop before a new Pod runs database migrations.
Workers reconnect after the new control plane starts. Plan a maintenance window;
mixed old and new tenant schemas are not supported.

The release uses the normal ERTS limit of 65,536 ports. A high container file
limit therefore does not reserve a large port table. To set another limit,
use `controlPlane.extraEnv.ERL_FLAGS`, for example `+Q 1048576`.

`networkPolicy.enabled` restricts EPMD and the distribution port to
control-plane Pods. HTTP stays open to every peer because the ingress controller
serves the Console and Workers reach each Pod IP for the file relay. It also
limits the Worker Pods: they accept no connection and reach only the control
plane, DNS, and public addresses, not `networkPolicy.workerDeniedCIDRs` (the
private ranges and the node metadata address). Also set the instance metadata
hop limit of the nodes to 1.

`files.store=fs` allows one replica, and the chart refuses to render more; use
`files.store=s3` for more than one.

Keep `controlPlane.replicaCount` at 1 until the control-plane singleton
processes (schedule firing, chat adapter connections, scheduler hydration) are
verified safe on more than one node. The migration init container runs in
every new Pod under the existing database migration lock.

## Worker Pods

The control plane creates and deletes Worker Pods. `kubectl drain --force`
permits eviction of these Pods because they have no controller. Keep a positive
termination grace period and wait for Pod deletion to finish. The Console
Workers page shows the state and the latest platform reason.

Worker and storage helper Pods start trusted processes as root, with only
`SETUID`, `SETGID`, `CHOWN`, `FOWNER`, `DAC_OVERRIDE`, and `KILL`. They keep
`allowPrivilegeEscalation: false`. The namespace must permit the baseline Pod
Security Standard; these Pods do not satisfy the restricted standard.
Shared NFS must permit root writes and ownership changes, or map all file access
to uid 1000 through an access point. Root squash without this mapping does not
support the Worker filesystem contract.

The provider's `idleReleaseAfter` controls idle release. Kubernetes deletes the
instance and keeps storage and cache. `agent_computer.worker.ready_timeout`
(default 10 minutes) limits how long a Worker may remain unready.

## Provider seed

The Secret `<fullname>-worker-providers` contains `providers.yaml`. The control
plane imports it only on its first start, while `worker_providers` is empty.
After that, add and edit providers in the Console; a later change of the seed
values does not change stored providers. The generated provider uses
`worker.resources`, scheduling settings, `extraEnv`, and probes. Use
`worker.providerConfig` to supply its complete YAML without merging. Use
`worker.providers` for a complete list of providers with different types or
specifications. Each `config` string is preserved, including comments.

The generated shared-claim provider has `legacy_agents: true`. An exclusive
layout does not assign legacy Agents automatically. Select their provider in
the Console after transferring their files to the chosen storage. If a raw
configuration names another owner ConfigMap, ServiceAccount, claim, namespace,
or cluster, provision those resources and permissions separately.

The seed does not control the objects that the chart creates; `worker.localPods`
does. With `true`, the default, the chart creates the objects that Worker Pods
in the release namespace need: the owner ConfigMap, the Worker ServiceAccount,
the control-plane Role and RoleBinding, the Worker NetworkPolicy, and, while
`worker.storage` and `worker.agents.persistence.existingClaim` are empty, the
shared Agent Home claim. Set `false` only when no provider runs Workers in this
namespace, and list the initial providers in `worker.providers`. `false`
deletes these objects. Kubernetes then deletes every Worker Pod, contract
Secret, and cache PVC that the owner ConfigMap owns, and a stored Kubernetes
provider of this namespace loses its Role and ServiceAccount. The shared claim
and its data stay.

## Workers on Cloudflare

Deploy the adapter and its R2 storage first. See the
[adapter README](../../cloudflare/agent-workers/README.md). In the adapter
deployment, map the Worker image reference supplied by the control-plane image
to the Cloudflare image. An explicit `worker.image` override changes that
reference for all Worker providers.

On an installation that already runs, create the Cloudflare provider in the
Console. For a new installation that runs only Cloudflare Workers, put the
provider in the seed and turn off local Worker Pods:

```yaml
worker:
  localPods: false
  providers:
    - provider_id: cloudflare
      kind: cloudflare
      display_name: Cloudflare
      is_default: true
      config: |
        adapterUrl: https://ankole-agent-workers.example.workers.dev
        instance: standard-3
        idleReleaseAfter: 15m
        endpoints:
          runtimeFabricUrl: wss://ankole.example.com/runtime-fabric/worker
          relayOrigin: https://ankole.example.com
          aiGatewayUrl: https://ankole.example.com/api/v1/ai-gateway
      credentials:
        adapterToken:
          file: /etc/ankole/bootstrap/worker-adapter-token
```

Set `secrets.existingSecret` to a Secret that includes `worker-adapter-token`
and the required bootstrap keys. Keep the token outside `config`. All three endpoints
must be reachable from Cloudflare; the Worker Channel requires WebSocket support.
A provider with `relayOrigin` requires one control-plane replica.

## Troubleshooting

- A Worker Pod that stays `Pending` usually has a cache PVC that the
  StorageClass cannot bind, or no node with enough resources. The Console
  Workers page and `kubectl describe pod` show the reason.
- A blocked `db-migrate` init container usually means that `DATABASE_URL` is
  wrong, PostgreSQL is not ready, or the required extensions are unavailable.
- A running Worker that never becomes ready usually cannot open a WebSocket to
  the control-plane Service HTTP port. After `agent_computer.worker.ready_timeout`
  the control plane replaces its instance. Agent Home remains on persistent storage.
- A control plane that cannot create Workers logs a missing Kubernetes
  permission. Check the Role and RoleBinding of the control-plane
  ServiceAccount.
- A setup page that reloads after activation usually has no trusted HTTPS
  connection. Check the Ingress certificate and forwarded host.
