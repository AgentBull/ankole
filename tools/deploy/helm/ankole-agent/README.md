# Ankole Helm chart

[简体中文](README.zh-Hans.md)

This chart installs the open-source Ankole control plane, which uses the
Kubernetes API to create one Agent Computer Worker Pod for each Agent that needs
one. Optionally, the chart can also install the Ankole PostgreSQL 18 image,
which bundles `pg_search` and `vector`.

A site is one complete deployment and may host several tenants, each with its
own people, Agents, Brain, and integrations, while site operators manage shared
providers and infrastructure. The Console for site administration defaults to
`/site-admin-console`; set `controlPlane.siteAdminConsolePath` in Helm values to
choose a different absolute path, and keep that path recorded in your operator
configuration. Regular users sign in through their tenant host or OIDC
application rather than the Console for site administration.

## Requirements

- Kubernetes 1.27 or later.
- Helm 3 or later.
- A Linux `amd64` or `arm64` node pool.
- A `ReadWriteMany` StorageClass for the default shared Agent Home claim, or
  an exclusive `worker.storage.claimTemplate` for each Agent.
- A StorageClass that provisions `ReadWriteOnce` volumes for Worker cache disks
  when `worker.cache.type` is `pvc` (the default).
- An HTTPS Ingress for browser-based setup and Console flows.
- Sufficient CPU, memory, and storage for your workload. Each running Agent gets
  its own Worker Pod sized according to `worker.resources` in Helm values.

Worker Pods require no extra kernel privileges because the container itself is
each Agent's isolation boundary. The chart grants the control plane a namespace
Role to create and delete Pods, Secrets, and PVCs, while assigning Worker Pods a
dedicated ServiceAccount with no Kubernetes permissions.

## Install with bundled PostgreSQL

The bundled PostgreSQL container runs with `C.utf8`, so empty volumes initialize
with UTF8 encoding while existing volumes keep their database encoding. Check
`SHOW server_encoding` on existing volumes; if a database uses `SQL_ASCII`,
follow the separate
[backup and restore](../../../devkit/postgres-for-ankole/README.md) procedure.

Because the bundled PostgreSQL StatefulSet runs a single replica without
protection against voluntary Pod disruption, use an external PostgreSQL database
for production. If you run the bundled database on Karpenter-managed nodes, add
this Pod annotation:

```yaml
postgresql:
  podAnnotations:
    karpenter.sh/do-not-disrupt: "true"
```

With this annotation set, Karpenter skips consolidation and can defer drift
replacement, though it does not provide database failover. Karpenter can still
evict the Pod during forceful disruption or when a configured NodeClaim
`terminationGracePeriod` expires; see the
[Karpenter disruption rules](https://karpenter.sh/docs/concepts/disruption/).
The chart omits a PodDisruptionBudget because blocking eviction of the single
replica would stall node upgrades. Plan database downtime before removing this
annotation for node maintenance.

Create the namespace and bootstrap Secret first. Managing the Secret explicitly
ensures that if the initial install fails, a retry will not generate a new
database password while a retained PostgreSQL volume still expects the original
password.

```sh
kubectl create namespace ankole

POSTGRES_PASSWORD="$(openssl rand -hex 24)"
ANKOLE_SECRET_BASE="$(openssl rand -hex 32)"
RELEASE_COOKIE="$(openssl rand -hex 32)"
ANKOLE_FUNCTION_RUNTIME_TOKEN="$(openssl rand -hex 32)"

kubectl -n ankole create secret generic ankole-bootstrap \
  --from-literal="POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
  --from-literal="ANKOLE_SECRET_BASE=${ANKOLE_SECRET_BASE}" \
  --from-literal="RELEASE_COOKIE=${RELEASE_COOKIE}" \
  --from-literal="ANKOLE_FUNCTION_RUNTIME_TOKEN=${ANKOLE_FUNCTION_RUNTIME_TOKEN}" \
  --from-literal="DATABASE_URL=ecto://ankole:${POSTGRES_PASSWORD}@ankole-postgresql:5432/ankole"

unset POSTGRES_PASSWORD ANKOLE_SECRET_BASE RELEASE_COOKIE ANKOLE_FUNCTION_RUNTIME_TOKEN
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

Replace the host, Ingress settings, and StorageClass names for your cluster.
Setting `fullnameOverride` to `ankole` keeps the PostgreSQL Service named
`ankole-postgresql` so that it matches `DATABASE_URL` in the Secret.

Install the chart:

```sh
helm upgrade --install ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

During startup, the migration init container creates both required PostgreSQL
extensions and applies all pending Ecto migrations; the control plane starts
only after those migrations succeed.

## Install with external PostgreSQL

Your external server must run PostgreSQL 18 or later, preload `pg_search`, and
make both `pg_search` and `vector` available to the owner of the application
database. Both the installed extension and the loaded library must satisfy the
[Brain version contract](../../../../docs/design-docs/BrainV3.md#retrieval-index-recovery).
When upgrading an older installation—including one that uses bundled
PostgreSQL—stop the control plane and complete the
[upgrade procedure for the database image](../../../devkit/postgres-for-ankole/README.md)
before deploying the new Pods.

Verify the exact server referenced by `DATABASE_URL` before installation:

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

Create the bootstrap Secret:

```sh
ANKOLE_SECRET_BASE="$(openssl rand -hex 32)"
RELEASE_COOKIE="$(openssl rand -hex 32)"
ANKOLE_FUNCTION_RUNTIME_TOKEN="$(openssl rand -hex 32)"

kubectl -n ankole create secret generic ankole-bootstrap \
  --from-literal="ANKOLE_SECRET_BASE=${ANKOLE_SECRET_BASE}" \
  --from-literal="RELEASE_COOKIE=${RELEASE_COOKIE}" \
  --from-literal="ANKOLE_FUNCTION_RUNTIME_TOKEN=${ANKOLE_FUNCTION_RUNTIME_TOKEN}" \
  --from-literal="DATABASE_URL=ecto://ankole:REPLACE_ME@postgres.example.com:5432/ankole"

unset ANKOLE_SECRET_BASE RELEASE_COOKIE ANKOLE_FUNCTION_RUNTIME_TOKEN
```

Set these values in `values-production.yaml`:

```yaml
secrets:
  existingSecret: ankole-bootstrap

postgresql:
  enabled: false
```

Then run the same Helm install command shown in the bundled database section.

## First setup

Wait for all workloads to become ready:

```sh
kubectl -n ankole get pods
kubectl -n ankole rollout status deployment/ankole-control-plane --timeout=10m
```

No Worker Pods exist right after installation; the control plane creates an
Agent's Worker Pod when you create the Agent.

Read the activation code from the control-plane logs:

```sh
kubectl -n ankole logs deployment/ankole-control-plane \
  -c control-plane | grep "SETUP ACTIVATION CODE"
```

Open `https://ankole.example.com/setup`, enter the activation code, select the
Control Plane Plugins, and configure the identity provider for administrators.
Because the production image sets secure cookies, the browser setup flow
requires HTTPS.

Once setup completes, use the Console to configure model providers, model
profiles, Agent Library capabilities, Agents, channel bindings, and WorkerEnv
secrets. Do not store provider API keys in Helm values.

## Image policy and upgrades

Direct upgrades are supported only from v0.70.0 or later; upgrades from earlier
releases are unsupported.

By default, `values.yaml` pins the control plane to `2.0.0-alpha.24` (a
pre-release) and pins PostgreSQL by image digest. Always pair deployment files
and images from the same release, because `main-latest` may point to an older
release with a different startup contract. If you select a different PostgreSQL
tag, clear `postgresql.image.digest` as well, because an image digest takes
precedence over a tag. Before running a controlled production upgrade, resolve
and record the control-plane digest:

```yaml
controlPlane:
  image:
    digest: sha256:CONTROL_PLANE_DIGEST
```

The control-plane image embeds a matching immutable Worker image reference.
Leave `worker.image` empty to use that default reference, and set
`worker.image.repository` along with its tag or digest only when you explicitly
override the Worker image. Any Worker image override must be built from the same
source revision as the control plane.

Similarly, `functionRuntime.image` selects the Function Runtime image from the
same release, and its headless Service exposes Ready replicas to the
control-plane client. Function Pods mount neither database credentials nor a
service account token. The chart's NetworkPolicy permits ingress from the
control plane and egress to the public network, so `functionRuntime.deniedCIDRs`
must include your site's internal ranges as well as public control-plane and
database addresses, and your cluster must enforce NetworkPolicy. For
authentication, the chart either reads `ANKOLE_FUNCTION_RUNTIME_TOKEN` from
`secrets.existingSecret` or generates and preserves an internal function token.

After an upgrade, the control plane replaces Workers running an older image when
their Agents become idle, while any running Job finishes on its existing Worker
first. If a Worker speaks a different RuntimeFabric protocol version, however,
the control plane replaces it immediately. Replacing a Worker instance preserves
both Agent Home and Codex Home.

When upgrading from pooled Workers, first scale the old control-plane and Worker
Deployments to zero and wait until all of their Pods terminate. Do not pass
`--grace-period=0` or force-delete Pods. Prepare the old shared claim as
described below **before** starting the new control plane, because the provider
seed assigns existing Agents to that claim in the same transaction that imports
the provider.

Back up PostgreSQL, Agent Home storage, and the file store before every upgrade,
and then run:

```sh
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

The new control-plane Pod runs database migrations before starting. Because
`helm rollback` does not revert database migrations, restore from your database
backup whenever an application rollback also requires a schema rollback.

The default provider uses the retained shared Agent Home claim, normally named
`<release>-ankole-agent-agents`. Each Worker mounts only its own Agent directory
at `/workspace`, with `/agents/<agent_uid>` as a symbolic link to `/workspace`.
If you change the Helm release name, set
`worker.agents.persistence.existingClaim` to the previous claim name.

In pooled-Worker releases, Workers ran as root and created each Agent Home with
mode `0700`. In the current Worker layout, commands, Codex, MCP servers,
browsers, and Automation scripts run as uid `1000`, the credential-holding
Worker supervisor runs as root, and the one-time drive import reads legacy files
as uid `10001`. Once all old writers have stopped, prepare the existing claim
according to its storage backend:

- **Root inside a Pod maps to root on the filesystem** (for example block
  volumes, local volumes, and NFS exported with `no_root_squash`): run the
  preparation Pod below, replacing `<claim>` with the old claim name.
- **NFS with root squash** (the NFS default): because the NFS server maps root
  inside a Pod to its anonymous user, that anonymous user owns the legacy Homes
  but cannot `chown` them to uid `1000`, causing `chown` inside the preparation
  Pod to fail with `Operation not permitted`. Instead, run the preparation Pod's
  three shell commands directly as root on the NFS server, substituting the
  claim's exported server directory for `/agents`. Because Worker Pods require
  root writes and `chown` at runtime, export the share with `no_root_squash` or
  map all access with `all_squash,anonuid=1000,anongid=1000`.
- **EFS mounted via an access point configured with POSIX user `1000` and group
  `1000`**: every read and write—including writes from older Workers—already ran
  as uid `1000`, so the files already belong to uid `1000` and need no
  preparation.

```sh
kubectl -n ankole run ankole-agent-home-prepare --rm -i --restart=Never \
  --image=busybox:1.37 --overrides='{"apiVersion":"v1","spec":{
    "containers":[{"name":"prepare","image":"busybox:1.37",
      "securityContext":{"runAsUser":0},
      "command":["sh","-ec","chown -R 1000:1000 /agents; chmod 2777 /agents; chmod -R a+rX /agents"],
      "volumeMounts":[{"name":"agents","mountPath":"/agents"}]}],
    "volumes":[{"name":"agents","persistentVolumeClaim":{"claimName":"<claim>"}}]}}'
```

Wait for this Pod to succeed. The command transfers ownership of legacy Homes to
uid `1000`, sets the root `/agents` directory to group `1000` and mode `2777` so
uid `1000` can write into directories that kubelet creates for new Agents, and
grants read access so the drive import can read legacy files.

Next, upgrade with `--set files.importAgentHomeClaim=<claim>` to mount the claim
read-only at `/agents` in the control plane, and run the one-time import:

```sh
kubectl -n ankole exec deployment/ankole-control-plane -c control-plane -- \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

After the import finishes, run `helm upgrade` again without
`files.importAgentHomeClaim`. The import copies each Agent's installed Skills,
Automation Job scripts, and unsent legacy attachment bytes into the drive
without overwriting existing drive files, and it reports any skipped or
unreadable files. User files, session files, and Job workspaces remain in Agent
Home, while files referenced by unsent attachments are copied into the drive.
Resolve every missing attachment listed in the report before removing the old
volume, because pending legacy sends wait for conversion.

Pooled-Worker releases left Agent Home directories behind when you deleted an
Agent, and the import report lists each orphan directory (`"No Agent has the UID
of …"`). Once you confirm that an orphan directory's files are unneeded, delete
it by running the preparation Pod as `"runAsUser":1000` (since the preparation
step above assigned those files to uid `1000`) with command
`["rm","-rf","/agents/<uid>"]`.

The chart uses the `Recreate` deployment strategy regardless of control-plane
replica count. Upgrades therefore incur a brief service interruption so that an
older control plane never runs against a database schema being migrated by the
new release. Worker Pods continue running during the upgrade and reconnect once
the new control plane is ready.

## Storage and backup

Before taking a consistent backup, disable Agents, wait for their active work to
finish, delete their Worker instances through the platform, and wait for the
control plane to record instance absence and current storage references. Once
the Workers are gone, stop the control plane and back up PostgreSQL, the file
store, and all Agent Homes together—stopping the control plane by itself leaves
Workers running. Keep the original `ANKOLE_SECRET_BASE` alongside your backup
secrets because Ankole uses it to decrypt both provider secrets and credentials
from unsettled generations.

Agent Home and Codex Home hold durable data. By default, the provider mounts the
shared claim, whereas setting `worker.storage.claimTemplate` allocates a
dedicated PVC for each Agent. Neither PVC mode sets a Worker owner reference,
and the chart-managed shared PVC carries `helm.sh/resource-policy: keep`, so
deleting a Pod, replacing an image, or uninstalling the chart preserves Agent
Home. Always back up Agent Home together with PostgreSQL and the file store.

The installation label—`worker.installation`, or the Helm release name when
`worker.installation` is empty—is embedded in the names and labels of Worker
Pods, Secrets, and PVCs. Choose 1–20 lowercase letters, digits, or hyphens with
a letter or digit at both ends so the chart does not have to lowercase,
truncate, or strip a trailing hyphen. Do not change this label after your first
install: under a different label, the control plane allocates fresh empty PVCs
for exclusive Homes and ignores running Workers, which can cause a second Worker
to write to the same Home concurrently. If you reinstall the chart under a new
release name, set `worker.installation` to the original label.

A separate cache volume mounted at `/var/cache/ankole` stores Codex SQLite
files. When `worker.cache.type` is `pvc`, the cache survives instance deletion
and image replacement, and is deleted only when you rebuild a Worker or change
its instance settings. When `worker.cache.type` is `emptyDir`, Pod deletion
clears the cache. Losing the cache never deletes Agent Home.

The owner ConfigMap `<fullname>-agent-workers` owns Worker Pods, contract
Secrets, and cache PVCs, so running `helm uninstall` or upgrading with
`worker.localPods=false` deletes those objects. Deleting an Agent removes its
Worker instance first and then deletes its persistent storage and cache.

The bundled PostgreSQL StatefulSet retains its PVC when deleted or scaled down.
Back up the database independently:

```sh
backup_path="ankole-$(date +%Y%m%d).dump"
kubectl -n ankole exec statefulset/ankole-postgresql -- \
  pg_dump -U ankole -d ankole -Fc > "$backup_path.partial" || exit 1
pg_restore -l "$backup_path.partial" > "$backup_path.list" || exit 1
mv "$backup_path.partial" "$backup_path"
```

Check every exit status rather than relying on a nonempty output file: if either
the export or the archive listing fails, the snippet leaves `.partial` in place
and renames the dump only after both commands succeed. Run `pg_restore` on the
host using a client version that supports PostgreSQL 18 archives. Because
`pg_restore -l` only inspects the archive table of contents, still run full
restore drills against a separate database.

If `kubectl exec` truncates the stream, preserve the diagnostic output, set
`KUBECTL_REMOTE_COMMAND_WEBSOCKETS=false`, and re-run both the export and the
archive check. Never keep a truncated file as a backup.

PostgreSQL stores its cluster in `postgresql.pgdata` (defaulting to the `pgdata`
subdirectory on the volume because block volumes such as EBS place `lost+found`
at the volume root and `initdb` requires an empty directory). Earlier versions
of this chart initialized the cluster directly at the volume root; when
upgrading such an installation, set
`postgresql.pgdata=/var/lib/pgsql/18/data` so PostgreSQL opens the existing
cluster.

The control plane stores Agent drives in the backend selected by `files.store`:
`fs`, `s3`, `azblob`, `d1`, `cos`, `postgresql`, `oss`, `tos`, `gcs`, `sftp`,
or `webdav`. For remote backends other than S3, configure the documented
`ANKOLE_FILES_*` settings in `controlPlane.extraEnv` and put credentials in
`secrets.existingSecret`, which both the control plane and the migration
container load into their environment; see the
[drive storage guide](../../../../app/website/src/content/docs/drive-storage/en-US.md).
When `files.store` is `fs`, the chart creates a `ReadWriteOnce` PVC mounted at
`/var/lib/ankole/files`, makes it writable via the Pod's `fsGroup`, and retains
it on `helm uninstall`. When `files.store` is `s3`, add a bucket lifecycle rule
to abort incomplete multipart uploads so interrupted large uploads do not leave
orphaned parts behind. Because PostgreSQL records metadata for every drive file,
always back up and restore PostgreSQL and the file store together.

Supplement logical dumps with volume snapshots from your storage provider (or
bucket backups for object storage), and test full restores on a separate
installation.

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
| `controlPlane.image.tag` | `2.0.0-alpha.24` | Immutable published release |
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
| `files.store` | `fs` | Drive file store: `fs` (one replica), `s3`, `azblob`, `d1`, `cos`, `postgresql`, `oss`, `tos`, `gcs`, `sftp`, or `webdav` |
| `files.persistence.size` | `100Gi` | Size of the `fs` file store PVC |
| `files.s3.bucket`, `files.s3.region` | empty | Bucket and region for `s3` |
| `files.s3.endpoint` | empty | Endpoint of an S3-compatible store such as Cloudflare R2 |
| `files.importAgentHomeClaim` | empty | Mount this Agent Home claim read-only in the control plane for the one-time import |
| `postgresql.enabled` | `true` | Install bundled PostgreSQL |
| `postgresql.persistence.enabled` | `true` | Persist bundled PostgreSQL |
| `postgresql.pgdata` | `/var/lib/pgsql/18/data/pgdata` | Database directory; `/var/lib/pgsql/18/data` for an installation that an earlier chart created |
| `ingress.enabled` | `false` | Create an Ingress |

When `secrets.existingSecret` is set, the Secret must include these keys:

- `ANKOLE_SECRET_BASE`
- `ANKOLE_FUNCTION_RUNTIME_TOKEN`
- `DATABASE_URL`
- `RELEASE_COOKIE` (the distributed Erlang cookie shared by control-plane nodes)
- `POSTGRES_PASSWORD` (required when bundled PostgreSQL is enabled)

For an `s3` file store with static credentials, the Secret can also include
`ANKOLE_FILES_S3_ACCESS_KEY_ID` and `ANKOLE_FILES_S3_SECRET_ACCESS_KEY`; when
those keys are omitted, the control plane falls back to the default AWS
credential chain (such as EKS Pod Identity). Because the control plane mounts
this Secret read-only at `/etc/ankole/bootstrap/<key>`, provider seeds can read
arbitrary credential keys from it as well.

When `secrets.existingSecret` is unset, the chart generates missing secret
values on install and preserves them across normal upgrades, though managing an
explicit Secret is safer for production recovery.

## Worker file relay

When a Worker reads or writes drive files, bytes stream between the file store
and the Worker through whichever control-plane Pod handles the request. The
chart injects `POD_IP` via the Downward API so the control plane can advertise
`http://<POD_IP>:<PORT>` as its relay origin. Consequently, Workers must be able
to reach every control-plane Pod IP directly on the HTTP port; if a
NetworkPolicy permits traffic only to the Service address, file transfers will
fail. Set `ANKOLE_RUNTIME_FABRIC_INTERNAL_ORIGIN` in `controlPlane.extraEnv`
only when Workers reach each control-plane Pod through a different per-Pod
address.

## Control-plane replicas

Each control-plane Pod runs as a named Erlang node (`ankole@<POD_IP>`). The
chart renders a headless Service for node discovery, points `DNS_CLUSTER_QUERY`
at that Service, stores a generated `RELEASE_COOKIE` in the bootstrap Secret,
and pins the distribution port to `controlPlane.distributionPort` (with a single
replica, these clustering settings stay inert). Even with multiple replicas, the
chart uses the `Recreate` deployment strategy so all old control-plane Pods
terminate before a new Pod runs database migrations, and Workers reconnect once
the new control plane starts. Plan a maintenance window for upgrades, because
running old and new tenant schemas concurrently is unsupported.

The release uses the standard ERTS limit of 65,536 ports, so raising the
container open-file limit does not allocate an oversized port table. To change
the port limit, pass `ERL_FLAGS` in `controlPlane.extraEnv` (for example,
`+Q 1048576`).

`networkPolicy.enabled` defaults to `false`. When you enable it, the
control-plane policy allows EPMD and the distribution port from peer
control-plane Pods while keeping the HTTP port open to all peers so the ingress
controller can serve the Console and Workers can reach individual Pod IPs for
the file relay. When `worker.localPods=true`, a second policy selects Worker
Pods matching this installation's labels in the release namespace without adding
any ingress rules. Its egress rules permit control-plane HTTP, TCP/UDP port 53
to **any destination**, and IPv4 destinations outside
`networkPolicy.workerDeniedCIDRs`. Because the port 53 rule also applies inside
`workerDeniedCIDRs`, that list is not an absolute deny list for private
addresses.

Enforcing NetworkPolicy requires a CNI plugin with NetworkPolicy support. Other
policies selecting the same Pods can grant additional access, and traffic to or
from a Pod's own node follows separate Kubernetes routing rules; see the
[NetworkPolicy contract](https://kubernetes.io/docs/concepts/services-networking/network-policies/).
This chart does not manage network policies for external Worker providers or
remote browser networks. Enforce node metadata protection in your node
configuration—on nodes that support a hop limit for instance metadata, set that
hop limit to `1`—and validate the deployed boundary with the steps below.

When `files.store` is `fs`, only a single control-plane replica is supported and
the chart refuses to render higher replica counts; switch to a shared remote
backend before running multiple replicas.

Keep `controlPlane.replicaCount` at `1`, because singleton control-plane
processes (schedule firing, chat adapter connections, and scheduler hydration)
run on a single node. The migration init container runs in every new Pod under
the database migration lock.

### Verify Worker egress in a deployment

Verify egress with a disposable Agent and controlled test endpoints, because
rendering Helm templates alone does not prove that your cluster's CNI plugin
enforces the policy.

1. Record the namespace, Worker Pod and installation labels, CNI plugin,
   rendered NetworkPolicy, and every other NetworkPolicy that selects the Worker
   Pod.
2. Stand up two HTTP endpoints that log incoming requests and return a fresh
   random marker: one on an allowed public IPv4 address, and one on a private
   address inside `workerDeniedCIDRs` using a port other than `53` (do not host
   the private endpoint on a control-plane Pod or on the Worker's own node).
   Verify both markers from a separate permitted client before and after testing,
   and test only against these controlled endpoints rather than cloud metadata
   services or production internal endpoints.
3. Request both URLs from the same Agent using the `command` tool, the local
   browser, and an Automation Job, using a distinct marker path on each request
   to prevent caching:
   - In `command`, run `curl --noproxy '*' --connect-timeout 3 --max-time 5 '<URL>'`.
   - In the Agent's local browser, open both URLs.
   - In the Automation Job's `main.ts`, call `fetch` with
     `AbortSignal.timeout(5000)` and log the response or error in the run output.
   Record the tool or Job run, Worker Pod name, target address, timeout, and
   outcome, and confirm that control-plane connectivity and DNS resolution still
   succeed.
4. Confirm that the public endpoint returns its marker, and correlate each
   blocked private request with both CNI denial logs and the absence of hits in
   the private endpoint's access log. By themselves, a missing listener, DNS
   failure, connection refusal, timeout, browser SSRF block, or remote-browser
   request does not prove cluster NetworkPolicy enforcement. Delete the
   temporary Job and test endpoints when finished.

## Worker Pods

The control plane creates and deletes Worker Pods directly via the Kubernetes
API. Because these Pods have no controller, `kubectl drain --force` is required
to evict them during node drains; keep a positive termination grace period and
wait for Pod deletion to complete. You can inspect each Worker's current state
and latest platform status reason on the Console Workers page.

Worker Pods and storage helper Pods start trusted supervisor processes as root
with `allowPrivilegeEscalation: false` and only the `SETUID`, `SETGID`, `CHOWN`,
`FOWNER`, `DAC_OVERRIDE`, and `KILL` capabilities. Because of this security
context, the namespace must allow the `baseline` Pod Security Standard rather
than `restricted`. Shared NFS exports must either permit root writes and
ownership changes or map all file access to uid `1000` through an access point;
an NFS export with default `root_squash` and no uid `1000` mapping cannot
satisfy the Worker filesystem contract.

Each provider's `idleReleaseAfter` setting governs when Kubernetes deletes idle
Worker Pods while retaining persistent storage and cache volumes. Meanwhile,
`agent_workers.ready_timeout_seconds` (10 minutes by default) bounds how long a
Worker Pod may stay unready before replacement.

## Provider seed

The `<fullname>-worker-providers` Secret renders `providers.yaml`, which the
control plane imports only on initial startup when the `worker_providers` table
is empty. After initial startup, add and edit providers in the Console, because
subsequent Helm changes to seed values do not modify stored provider rows. By
default, the generated provider incorporates `worker.resources`, scheduling
constraints, `extraEnv`, and probes. Set `worker.providerConfig` to supply raw
YAML for the default Kubernetes provider without merging, or set
`worker.providers` to define a complete list of providers across any types or
specifications (preserving each `config` string verbatim, including comments).

The generated shared-claim provider sets `legacy_agents: true`, whereas
exclusive PVC layouts do not claim legacy Agents automatically—transfer their
files to the target storage first, then assign their provider in the Console. If
a custom configuration references a different owner ConfigMap, ServiceAccount,
PVC, namespace, or cluster, provision those Kubernetes objects and RBAC rules
separately.

Whether the chart renders local Kubernetes Worker resources is controlled by
`worker.localPods`, not by the provider seed. When `worker.localPods` is `true`
(the default), the chart creates the owner ConfigMap, Worker ServiceAccount,
control-plane Role and RoleBinding, Worker NetworkPolicy, and—when both
`worker.storage` and `worker.agents.persistence.existingClaim` are empty—the
shared Agent Home PVC. Set `worker.localPods` to `false` only when no provider
runs Workers in the release namespace, and supply your initial providers in
`worker.providers`. Setting `worker.localPods=false` deletes those namespace
objects, causing Kubernetes garbage collection to delete every Worker Pod,
contract Secret, and cache PVC owned by the owner ConfigMap while leaving any
stored Kubernetes provider for this namespace without its Role and
ServiceAccount. The shared Agent Home PVC and its data remain intact.

## Workers on Cloudflare

Deploy the Cloudflare adapter and its R2 bucket first by following the
[adapter README](../../cloudflare/agent-workers/README.md). In that adapter
deployment, map the Worker image reference supplied by the control-plane image
to your Cloudflare container image (setting an explicit `worker.image` override
in Helm changes that image reference across all Worker providers).

On an existing installation, add the Cloudflare provider through the Console.
For a fresh installation that runs Workers exclusively on Cloudflare, declare
the provider in `worker.providers` and disable local Worker Pods:

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

Point `secrets.existingSecret` at a Secret containing `worker-adapter-token`
alongside the required bootstrap keys, and never inline the token inside
`config`. Cloudflare must be able to reach all three endpoints, with WebSocket
support enabled for `runtimeFabricUrl`, and any provider configured with
`relayOrigin` requires a single control-plane replica.

## Troubleshooting

- **Worker Pod stuck in `Pending`**: Usually either the StorageClass cannot bind
  its cache PVC or no node has enough free resources. Check the Console Workers
  page and `kubectl describe pod` for scheduling events.
- **`db-migrate` init container blocked**: Usually `DATABASE_URL` is invalid,
  PostgreSQL is not ready yet, or `pg_search` / `vector` is unavailable on the
  server.
- **Running Worker never becomes Ready**: Usually the Worker cannot establish a
  WebSocket connection to the control-plane Service HTTP port. Once
  `agent_workers.ready_timeout_seconds` elapses, the control plane replaces the
  Worker instance while keeping Agent Home on persistent storage.
- **Control plane fails to create Workers**: Look for missing Kubernetes RBAC
  permissions in the control-plane logs, and verify the Role and RoleBinding
  attached to the control-plane ServiceAccount.
- **Setup page reloads right after activation**: Usually the browser is not
  reaching Ankole over a trusted HTTPS connection. Check the Ingress TLS
  certificate and forwarded `Host` header.
