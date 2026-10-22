---
title: WorkerProviders and cache disks
description: Compare Docker, Kubernetes, Cloudflare, Vercel, Lambda, and Function Compute limits, and configure Home and SQLite cache storage.
section: Guides
order: 317
---

A WorkerProvider selects where an Agent's computer runs and how it stores Home and cache. Each Agent has one fixed provider and its own Worker. Providers belong to the site. Console stores credentials encrypted in separate fields; do not put credentials in configuration YAML. See [Workers](../worker-management/) for creation and daily operations.

Vercel requires the `vercel-worker-provider` Control Plane Plugin. Alibaba Function Compute requires `china-market-ai-providers`, which also supplies model adapters. Enable the required Plugin and restart the control plane before use. Ankole rejects Plugin disable while any Agent still uses its Worker providers, including paused Agents and pending deletion.

## Three storage roles

| Storage | Contents | Persistence requirement |
| --- | --- | --- |
| Agent Home: `/workspace` | Workspaces, installed software, threads in `/workspace/.codex` | Must survive instance deletion and image replacement; back it up |
| Worker cache: `/var/cache/ankole` | SQLite, WAL, and local process locks under `codex/` | Rebuildable; private to each Agent |
| Control-plane drive | Attachments, published files, Skills, Automation scripts | PostgreSQL references and OpenDAL bytes must be backed up together |

A drive S3 bucket cannot replace Worker Home or the SQLite cache disk. Cloudflare R2 Home backups and Function Compute OSS Home storage also have separate configuration. See [Drive storage configuration](../drive-storage/).

## Provider comparison

| `kind` | Home | Cache | Idle action | Instance lifetime |
| --- | --- | --- | --- | --- |
| `docker` | Private local named volume | Private local named volume | Delete container | No fixed adapter limit |
| `kubernetes` | Private PVC or Agent directory in a shared PVC | Private PVC or `emptyDir` | Delete Pod | No fixed adapter limit |
| `cloudflare` | Restore from R2 at startup; back up before normal exit | Instance disk | Back up and delete container | Platform-controlled |
| `vercel` | Private Drive per Agent | Instance disk | Delete sandbox | Configured; 24 hours by default |
| `lambda` | Agent directory on EFS | Instance disk | Suspend with memory | 8 hours, including suspension |
| `function_compute` | AgenticSpace or Agent prefix in OSS | Instance disk | Pause with memory | 24 hours |

These are limits selected by the Ankole adapters, not a complete platform specification. Check account quotas, plans, and region availability.

All six providers default to `idleReleaseAfter: 15m`; you can set `never`. This controls idle release and cannot extend the platform lifetime. Location, storage keys, provider type, and existing Agent assignments cannot change. Size, environment, or endpoint changes replace idle Workers. Seed YAML imports only when the provider table is empty; use Console for later changes.

## Provider requirements

### Docker

- Uses a local Docker Engine and the `local` volume driver. Suitable for development and single-host deployments. Replacement keeps volumes; host loss loses Home. Store backups on another machine.
- The control plane needs Docker socket access. Compose `ANKOLE_DOCKER_GID` must match the socket group. This access is equivalent to host root access.
- The selected `network` must reach the control plane and external services. Configuration does not accept capability or security-option overrides.
- Home and cache use separate volumes. Do not replace the local cache volume with a network filesystem mount.

### Kubernetes

- Select either `storage.claimTemplate` or `storage.sharedClaim`. Shared Home across nodes needs `ReadWriteMany`. Private block storage can use `ReadWriteOnce`, or `ReadWriteOncePod` with CSI support. Use a separate block PVC or `emptyDir` for cache.
- Trusted Worker processes start as root; model commands run as uid 1000. Worker and storage cleanup helper Pods need baseline Pod Security permission. They do not satisfy the restricted policy.
- Home must permit root writes and ownership changes to uid 1000, or map all access to uid 1000. Root-squash NFS without that mapping does not meet this requirement.
- The control plane needs RBAC for Pods, Secrets, PVCs, and cleanup helpers. Remote kubeconfig requires all three `endpoints` explicitly and cannot use local `ownerConfigMap`. You cannot switch between in-cluster credentials and remote kubeconfig after creation.
- Pre-pull the Worker image on new nodes. Image preparation does not pull images for Kubernetes. Wait for normal Pod deletion; do not bypass an unreachable node with forced deletion or zero grace.

### Cloudflare

- Deploy the [Cloudflare adapter](https://github.com/AgentBull/ankole/tree/main/tools/deploy/cloudflare/agent-workers) first. Configure Worker image mappings, R2, and a separate `adapterToken`.
- The instance disk must fit the image, restored Home, cache, and temporary files. R2 capacity does not enlarge the instance disk. Ankole accepts `lite`, `standard-1` through `standard-4`, and custom sizes. They must also satisfy [Cloudflare limits](https://developers.cloudflare.com/containers/platform/limits/).
- Normal release backs up Home first. A forced platform stop can lose writes since the last backup. A failed backup is not a completed release. `stopGraceSeconds` defaults to 300 seconds for drain and backup.
- The current public file relay requires one control-plane replica. An S3 drive does not remove that relay limit.

### Vercel

- Home uses a private Drive in the same region. `teamId`, `projectId`, `region`, and `driveSizeGiB` cannot change after creation.
- Prepare a `linux/amd64` image in the project's VCR repository and use the target digest. `cpus` accepts 1 or an even number from 2 to 32. The adapter requests 2048 MiB per vCPU.
- `sessionTimeoutSeconds` defaults to 86400 (24 hours). Set 2700 for an account with a 45-minute limit, including a trial account that reports this limit. The value must not exceed the account limit. See [Vercel session limits](https://vercel.com/kb/guide/vercel-sandbox-duration-and-persistence). Sandbox deletion keeps Drive and loses instance cache.

### AWS Lambda MicroVMs

- This type uses Lambda MicroVMs. It needs an `arm64` Worker image, an image-build S3 bucket and IAM role, a VPC network connector, and reachable EFS.
- Official Worker images accept only `memoryMiB: 4096` or `8192`. Correct lower saved values in Console before runtime or cleanup can proceed. `env` has at most 47 entries; `stopGraceSeconds` has a maximum of 59 seconds.
- Memory quota covers running Workers, suspended Workers, and storage deletion helpers. Suspension does not release this capacity. After deletion, wait for AWS to confirm termination before treating capacity as free. See [MicroVM quotas and lifecycle](https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html).
- EFS stores Home; SQLite stays on instance disk. The eight-hour limit includes suspension. Old build objects and images are not collected automatically. Repair failed build roles, images, or networking before retrying.

### Alibaba Function Compute

- Builds a second-generation template from an `amd64` image in ACR Enterprise. It needs a Team, Sandbox API key, POP AccessKey, and authorized RAM role. Template capture has no Agent identity or credential.
- Select either `storage.agenticFs` or `storage.oss`. AgenticFS needs a VPC, filesystem, region/zone, capacity quota, and file-count quota. Its access point must be ready before mounting. See [AgenticFS Volume requirements](https://help.aliyun.com/zh/functioncompute/create-an-agenticfs-volume).
- The image must include OSSFS2 2.0.10 or later and keep `/workspace` empty before mounting. The official Worker image meets these requirements; its entry creates runtime directories after the mount.
- OSS mounts only this Agent's `<root>/<agent_uid>` and does not provide full POSIX semantics. Keep SQLite cache off OSS mounts. A failed `chown` alone does not prove that the mount is unwritable.
- Provider `env` can add variables but cannot override variables recorded by the image. Pause requests retain memory; resume requests use a new 24-hour timeout. Old templates are not collected automatically.
- Resume reconnects OSSFS2 through the image helper while keeping the mount and open files. This prevents reads from waiting on TCP connections that became unusable during memory pause. If the helper fails, the provider deletes the instance and the next reconciliation rebuilds it from Home. Use a Worker image with this helper and its matching control-plane version.

External providers and remote Kubernetes need instance-reachable `runtimeFabricUrl`, `relayOrigin`, and `aiGatewayUrl`. Do not use Compose service names or cluster-only addresses that the instance cannot reach.

A provider with explicit `endpoints.relayOrigin` requires one control-plane replica: file transfers must reach the node that owns the relay. Official Helm rejects multiple replicas for this configuration. This also applies to Vercel, Lambda, Function Compute, and remote Kubernetes.

## Cache disk requirements

SQLite and process locks need local filesystem semantics: reliable locks, shared memory, atomic file operations, and uid 1000 read/write access. Use local SSD, a block device mounted as a filesystem, or node `emptyDir`. Do not use NFS, EFS, SMB, or S3/R2/OSS FUSE mounts for Codex SQLite cache. [SQLite WAL](https://www.sqlite.org/wal.html) does not support network filesystems.

Each Agent needs a private cache directory or PVC. Monitor space, inodes, and node ephemeral storage. There is no universal minimum capacity guarantee. The official Helm cache PVC defaults to 20 GiB; size it for actual logs, concurrency, and work.

Persistent cache in native Kubernetes provider YAML; replace the StorageClass as needed:

```yaml
cache:
  claimTemplate:
    storageClassName: ebs-gp3
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 20Gi
```

For temporary cache, use:

```yaml
cache:
  sizeLimit: 5Gi
```

These are provider YAML fields. Helm values use `worker.cache.type: pvc`, `worker.cache.size`, and `worker.cache.storageClass`, or `worker.cache.type: emptyDir`. Keep the two formats separate.

Docker cache volumes and Kubernetes cache PVCs survive normal release, image changes, and ordinary instance-setting replacement. An explicit rebuild clears cache; cache-setting changes replace it. `emptyDir` and external-provider instance disks disappear with their instances. Home survives these operations. Do not delete SQLite, WAL, or lock files while the app-server runs.

Startup checks verify directory access and basic reads/writes. They do not prove reliable SQLite locking on network storage. For lock errors, full disks, or unbound cache PVCs, check Console **Workers → Reason**, platform events, and mount type first. See [Performance tuning](../performance-tuning/) and [Backup and restore](../backup-and-restore/).
