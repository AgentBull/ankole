---
title: Workers
description: Check each Agent's Worker in the Console, see how the control plane manages it, and resolve common failures.
section: User guide
order: 52
---

Every Agent owns a dedicated Worker and persistent Home directory mounted at `/workspace`. Operators configure Worker providers in the Console—combining a platform type, YAML settings, and separately encrypted credentials—and bind each Agent to its provider at creation time (an immutable choice). Create separate Worker providers whenever you need distinct machine sizes or regions.

## Worker pools

Each Worker provider defines one site-scoped Worker pool with a platform kind, YAML configuration, and encrypted platform credentials. Agents across different tenants can share the same Worker pool while retaining strictly isolated Workers, persistent Homes, caches, and Worker credentials:

1. Open **Console → Settings → Worker providers** and click **New Worker provider**.
2. Select the platform type and start from its YAML template, configuring the Worker image, compute size, storage mounts, and control-plane endpoints for the pool.
3. Enter the platform credentials in the dedicated secret fields, save the provider, and run its availability check.
4. Mark one pool as the site default, or pick a pool explicitly whenever you create an Agent—if neither is set, Ankole rejects Agent creation.

At most one pool can be marked as the site default, and changing that default affects only newly created Agents while existing Agents keep their assigned provider. Create multiple pools—even of the same platform kind—when you want separate instance sizes or regions. Once saved, a provider's ID, platform type, and storage location, as well as each Agent's provider assignment, are immutable, and Ankole prevents deleting a pool while any Agent Worker row still references it.

A Worker pool tells the control plane how to provision compute on your chosen platform; it never shares one Agent's Worker with another Agent. See [Agents](../agents/) for creating Agents and [Agent Computer Worker](../agent-computer-worker/) for runtime execution and crash recovery.

## One Agent, one Worker

Creating an Agent persists its provider binding and Worker record without booting a container or VM immediately. Instead, the control plane starts the Worker on demand as soon as an environment tool, Codex Job, or Automation Job needs a computer, while pure conversational and Workflow model calls run directly in the control plane without touching a Worker.

Concurrent Sessions and Jobs belonging to the same Agent share that Agent's Worker while isolating their files under separate workspace subdirectories in `/workspace`. Each open environment workspace or active Codex turn occupies one slot up to `ANKOLE_MAX_CONCURRENT_SLOTS`—adding more Worker pools or creating additional Agents does not expand an existing Agent's Worker slots or its per-Agent Background Agent Job cap.

## View Workers

Open **Console → Workers** to inspect each Agent's assigned provider, lifecycle state, active slot load, last heartbeat, and most recent platform error:

| State | Meaning |
| --- | --- |
| `absent` | No live instance exists; the control plane will launch one on demand |
| `starting` | A new generation is recorded and awaiting platform creation or channel admission |
| `ready` | Connected over RuntimeFabric and ready to accept work |
| `stale` | Connected earlier, but the RuntimeFabric socket dropped |
| `paused` | Process and memory state are suspended by the platform |
| `draining` | Waiting for active work to finish before idle release or replacement |
| `deleting` | Tearing down compute instances and underlying storage |

If a platform launch times out, the control plane keeps the same Worker generation for retry; if a launch leaves an uncertain state, the Agent waits rather than risking a split-brain second Worker. Always read the **Reason** column before modifying provider YAML.

## Providers and storage

See [WorkerProviders and cache disks](../worker-providers/) for detailed platform limits, IAM/RBAC rules, networking, and SQLite cache disks. If you are migrating a 1.x site, see [Upgrade from 1.0 to 2.0](../upgrade-to-2/).

| Type | Persistent Home | Idle operation |
| --- | --- | --- |
| Docker | Named local volume per Agent | Delete container |
| Kubernetes | Dedicated PVC per Agent, or subdirectory on a shared PVC | Delete Pod |
| Cloudflare | R2 directory snapshot | Snapshot to R2 and delete container |
| Vercel | Dedicated Drive per Agent | Delete sandbox |
| Lambda MicroVMs | Per-Agent directory on EFS | Suspend with memory |
| Function Compute | AgenticSpace or per-Agent OSS prefix | Pause with memory |

On Vercel, keep `sessionTimeoutSeconds` within your plan's ceiling (`86400` seconds by default, or `2700` seconds on accounts capped at 45 minutes). On AWS Lambda MicroVMs, budget memory quota across active Workers, suspended Workers, and storage-deletion helper instances alike. On Alibaba Function Compute, resuming a paused Worker invokes the OSS reconnection helper bundled in the Worker image, so always upgrade the Worker image and control plane in lockstep.

Persistent Home (`/workspace`, including Codex threads under `/workspace/.codex`) survives instance deletion and image upgrades, whereas the SQLite cache under `/var/cache/ankole/codex` is rebuildable and cleared on explicit Worker rebuilds. Keep off-host backups of both persistent Home and the [Agent drive](../file-management/): Docker local volumes cannot survive losing the Docker host, and Cloudflare Workers can lose writes made since the prior R2 snapshot if evicted abruptly by the platform.

## Release, replacement, and deletion

- Configure `idleReleaseAfter` in provider YAML (defaults to `15m` across all six providers; set `never` to disable idle release).
- Memory-preserving providers (`lambda` and `function_compute`) suspend or pause idle Workers in place, whereas other providers delete the compute instance while keeping persistent Home and any dedicated cache volume.
- Updating the Worker image or instance settings replaces Workers once they go idle; bumping the RuntimeFabric protocol version replaces Workers immediately and replaces stale paused instances instead of resuming them.
- `agent_workers.ready_timeout_seconds` (`600` seconds by default) triggers a rebuild when an already-observed platform instance fails to connect in time, without overriding an uncertain initial create.
- Deleting an Agent waits for all Worker instances to terminate, wipes both Home and cache storage, and finally removes the Worker row; Ankole generates fresh server-side Agent UIDs and never reuses deleted UIDs.

## Diagnose a waiting Worker

Start by verifying provider credentials, storage availability, platform quotas, and configured `endpoints`. On Docker, confirm that `ANKOLE_DOCKER_GID` matches the host Docker socket's group ID. On Kubernetes, check the control plane's namespace Role, Pod events, and PVC binding status. On Cloudflare, check the adapter's image map and `adapterToken`. On AWS Lambda, inspect image-build status, build IAM role permissions, VPC connector health, and EFS mount targets.

Use platform labels to locate the exact container or Pod and inspect its logs before stopping it. On Kubernetes, always let normal Pod deletion complete—never pass `--grace-period=0` or force-delete a Pod on an unreachable node. On Docker, stop the container cleanly before removing it:

```bash
docker stop CONTAINER_NAME
docker rm CONTAINER_NAME
```

The control plane launches a fresh Worker container automatically the next time the Agent needs one, leaving Home and cache volumes intact; any turns interrupted by the stop follow their declared retry policies. If a Worker shows `ready` while tasks still queue up, compare its current load against `ANKOLE_MAX_CONCURRENT_SLOTS` (configured under instance `env` in provider YAML, which takes effect once the idle Worker is replaced); see [Performance tuning](../performance-tuning/).
