---
title: WorkerProviders and cache disks
description: Compare Docker, Kubernetes, Cloudflare, Vercel, Lambda, and Function Compute limits, and configure Home and SQLite cache storage.
section: Guides
order: 317
---

A WorkerProvider defines where an Agent's computer runs and how it mounts persistent Home and cache storage. Every Agent is permanently bound to a single WorkerProvider and receives its own isolated Worker, while WorkerProviders themselves belong to the site. Enter platform secrets in the Console's dedicated encrypted credential fields rather than inside provider YAML; see [Workers](../worker-management/) for day-to-day pool management.

Vercel support comes from the `vercel-worker-provider` Control Plane Plugin, and Alibaba Function Compute support comes from `china-market-ai-providers` (which also registers regional model providers). Enable the corresponding Plugin in the Site Admin Console and restart the control plane before creating its WorkerProvider; Ankole blocks disabling either Plugin while any Agent—including paused Agents or Agents pending deletion—remains assigned to one of its provider kinds.

## Three storage roles

| Storage | Contents | Persistence requirement |
| --- | --- | --- |
| Agent Home: `/workspace` | Session and Job workspaces, user-installed packages, Codex threads in `/workspace/.codex` | Must survive instance deletion and image upgrades; include in backups |
| Worker cache: `/var/cache/ankole` | SQLite databases, WAL files, and local process locks under `codex/` | Rebuildable; strictly private to each Agent |
| Control-plane drive | Chat attachments, published deliverables, installed Skills, Automation scripts | Back up PostgreSQL metadata and OpenDAL object storage together |

Never share the control-plane drive's S3 bucket as a Worker Home mount or SQLite cache disk; Cloudflare R2 Home snapshots and Function Compute OSS Home prefixes likewise require their own dedicated storage configuration. See [Drive storage configuration](../drive-storage/).

## Provider comparison

| `kind` | Home | Cache | Idle action | Instance lifetime |
| --- | --- | --- | --- | --- |
| `docker` | Private named local volume | Private named local volume | Delete container | No fixed adapter cap |
| `kubernetes` | Dedicated PVC or per-Agent directory on a shared PVC | Dedicated PVC or `emptyDir` | Delete Pod | No fixed adapter cap |
| `cloudflare` | Restored from R2 on boot; snapshotted before graceful exit | Ephemeral instance disk | Snapshot to R2 and delete container | Governed by Cloudflare Containers |
| `vercel` | Dedicated Drive per Agent | Ephemeral instance disk | Delete sandbox | Configurable (`24h` default) |
| `lambda` | Per-Agent directory on EFS | Ephemeral instance disk | Suspend with memory | `8h` total (including suspended time) |
| `function_compute` | AgenticSpace or per-Agent OSS prefix | Ephemeral instance disk | Pause with memory | `24h` per active/resumed window |

The table above reflects the contracts enforced by Ankole's provider adapters; always verify your cloud account's own quotas, pricing plan, and regional availability as well.

All six providers default to `idleReleaseAfter: 15m` (or `never` to disable idle release), which governs when Ankole releases idle Workers without extending hard platform lifetime limits. Once created, a provider's region/location, storage identifiers, `kind`, and existing Agent bindings are immutable. Edits to instance size, `env`, or `endpoints` replace Workers once they go idle. Ankole imports seed YAML only when the provider table is empty—manage all subsequent updates in the Console.

## Provider requirements

### Docker

- Runs against a local Docker Engine using the `local` volume driver—well suited to local development and single-host deployments. Replacing a container preserves its volumes, whereas losing the host machine destroys Home, so replicate backups off-host.
- The control plane requires access to the Docker socket (equivalent to `root` on the host), and `ANKOLE_DOCKER_GID` in Docker Compose must match that socket's group ID.
- Attach Workers to a Docker `network` that can reach both the control plane and required external APIs; Ankole rejects custom Linux capability or `security-opt` overrides in provider YAML.
- Home and cache mount separate local volumes—never substitute a network filesystem mount for the local SQLite cache volume.

### Kubernetes

- Configure Home with either `storage.claimTemplate` (per-Agent PVC) or `storage.sharedClaim` (shared PVC). Multi-node shared Home requires `ReadWriteMany`, whereas per-Agent block PVCs can use `ReadWriteOnce` (or `ReadWriteOncePod` when supported by your CSI driver). Back the cache with a separate block PVC or node `emptyDir`.
- Trusted Worker entrypoints start as `root` before dropping model commands to `uid 1000`, so Worker Pods and helper Pods that clean up storage require at least the `baseline` Pod Security standard and cannot run under `restricted`.
- Home storage must either allow container `root` to write and `chown` files to `uid 1000`, or map all client access to `uid 1000`—default root-squash NFS without `uid 1000` mapping will fail.
- Grant the control plane namespace RBAC for Pods, Secrets, PVCs, and cleanup helper Pods. Remote `kubeconfig` pools must specify all three `endpoints` explicitly, cannot use in-cluster `ownerConfigMap`, and cannot switch between in-cluster auth and remote `kubeconfig` after creation.
- Pre-pull the Worker image onto new cluster nodes, as Ankole's image-preparation step does not pre-pull images on Kubernetes, and always wait for graceful Pod termination rather than force-deleting Pods on unreachable nodes.

### Cloudflare

- Deploy the [Cloudflare adapter](https://github.com/AgentBull/ankole/tree/main/tools/deploy/cloudflare/agent-workers) first, configuring Worker image mappings, an R2 bucket, and a dedicated `adapterToken`.
- Size the container disk so it fits the container image, restored `/workspace`, SQLite cache, and temporary files simultaneously—R2 bucket capacity does not expand container local disk. Ankole accepts `lite`, `standard-1` through `standard-4`, and custom sizes permitted by [Cloudflare Container limits](https://developers.cloudflare.com/containers/platform/limits/).
- On graceful idle release, the Worker snapshots `/workspace` to R2 before exiting (`stopGraceSeconds` defaults to `300` seconds, and a failed R2 upload aborts the release); however, an abrupt platform eviction can lose writes made since the prior snapshot.
- Because the public file relay terminates on a single node, run exactly one control-plane replica even when your drive uses S3.

### Vercel

- Provisions a private Vercel Drive per Agent in the same region; `teamId`, `projectId`, `region`, and `driveSizeGiB` cannot change after creation.
- Push a `linux/amd64` Worker image to your project's VCR registry and pin its digest. `cpus` accepts `1` or any even integer from `2` through `32`, requesting `2048 MiB` of RAM per vCPU.
- `sessionTimeoutSeconds` defaults to `86400` (`24` hours); lower it to `2700` on accounts capped at 45 minutes (including trial accounts) so it never exceeds your plan ceiling—see [Vercel session limits](https://vercel.com/kb/guide/vercel-sandbox-duration-and-persistence). Deleting a sandbox preserves the Agent's Drive while clearing the ephemeral instance cache.

### AWS Lambda MicroVMs

- Launches `arm64` Worker images on Lambda MicroVMs, requiring an image-build S3 bucket and IAM role, a VPC connector, and reachable EFS mount targets.
- Official Worker images support only `memoryMiB: 4096` or `8192`—update any lower saved value in the Console before launching or deleting Workers. `env` accepts at most `47` entries, and `stopGraceSeconds` caps at `59` seconds.
- Your regional MicroVM memory quota counts active Workers, suspended Workers, and storage-cleanup helper instances together: suspending a Worker does not free quota, and after deleting an instance you must wait for AWS to confirm termination before counting that capacity as free. See [MicroVM quotas and lifecycle](https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html).
- EFS backs `/workspace` while SQLite stays on local MicroVM disk, and the eight-hour instance lifetime includes suspended time. Ankole does not garbage-collect old S3 build artifacts or ECR images automatically; fix broken IAM roles, images, or VPC routing before retrying a failed launch.

### Alibaba Function Compute

- Builds a second-generation sandbox template from an `amd64` Worker image in ACR Enterprise using a Team, Sandbox API key, POP AccessKey, and RAM role (the shared template itself contains no Agent identity or Worker credential).
- Choose either `storage.agenticFs` or `storage.oss`: AgenticFS requires a VPC, filesystem, region/zone, capacity quota, and file-count quota with a ready access point before mounting; see [AgenticFS Volume requirements](https://help.aliyun.com/zh/functioncompute/create-an-agenticfs-volume).
- Ensure the Worker image bundles `ossfs2` `2.0.10+` and leaves `/workspace` empty prior to mounting—the official Worker image satisfies both and initializes subdirectories after mounting.
- OSS mounts only `<root>/<agent_uid>` without full POSIX locking, so keep the SQLite cache off OSS mounts (note that a failing `chown` on OSS does not by itself mean the mount is read-only).
- Provider `env` entries can add new variables without overriding variables baked into the image. Pausing retains memory, resuming grants a fresh 24-hour window, and old sandbox templates are not pruned automatically.
- On resume, the control plane runs the Worker image's `ossfs2` reconnection helper while preserving the mount and open file descriptors so reads never hang on TCP connections dropped during pause; if the helper fails, Ankole deletes the instance and rebuilds it from Home on the next reconciliation pass. Always deploy matching control-plane and Worker image versions.

Cloud Worker providers and remote Kubernetes clusters require externally reachable URLs for `runtimeFabricUrl`, `relayOrigin`, and `aiGatewayUrl`—never pass internal Docker Compose service names or cluster-private DNS names that Workers outside that network cannot resolve.

Whenever a provider sets an explicit `endpoints.relayOrigin`—including Vercel, Lambda, Function Compute, and remote Kubernetes—run a single control-plane replica so file-relay transfers always reach the owning node; the official Helm chart rejects multi-replica deployments when `relayOrigin` is configured.

## Cache disk requirements

Codex's SQLite databases and process locks under `/var/cache/ankole` require genuine local POSIX filesystem semantics: reliable file locking, shared memory (`mmap`), atomic renames, and `uid 1000` read/write permissions. Back `/var/cache/ankole` with a local SSD volume, an attached block volume formatted as a local filesystem, or Kubernetes node `emptyDir`—never place the Codex SQLite cache on NFS, EFS, SMB, or S3/R2/OSS FUSE mounts, because [SQLite WAL](https://www.sqlite.org/wal.html) is unsafe over network filesystems.

Give every Agent its own private cache directory or PVC and monitor disk usage, inode consumption, and node ephemeral storage. The official Helm chart defaults cache PVCs to `20 GiB`; adjust that size to match your Agents' log volume and concurrency.

To configure a persistent block cache PVC in native Kubernetes provider YAML (substituting your cluster's `StorageClass`):

```yaml
cache:
  claimTemplate:
    storageClassName: ebs-gp3
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 20Gi
```

Or, to use an ephemeral `emptyDir` cache bounded in size:

```yaml
cache:
  sizeLimit: 5Gi
```

Do not mix provider YAML keys with Helm chart values (`worker.cache.type: pvc`, `worker.cache.size`, and `worker.cache.storageClass`, or `worker.cache.type: emptyDir`).

Docker cache volumes and Kubernetes cache PVCs persist across graceful idle releases, image upgrades, and ordinary instance-setting updates; running an explicit Worker rebuild wipes the cache, while modifying cache settings replaces the cache volume. By contrast, Kubernetes `emptyDir` caches and cloud-provider local disks are discarded whenever the instance stops, while `/workspace` persists. Never delete SQLite database, WAL, or lock files manually while the Codex app-server is running.

Note that Worker startup probes check basic directory permissions and read/write access, which cannot detect broken advisory locking on a network filesystem—so if you encounter SQLite lock errors, full disks, or unbound cache PVCs, inspect **Console → Workers → Reason**, platform events, and volume mount types first. See [Performance tuning](../performance-tuning/) and [Backup and restore](../backup-and-restore/).
