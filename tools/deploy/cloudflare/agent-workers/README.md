# Agent Workers on Cloudflare Containers

[简体中文](README.zh-Hans.md)

This adapter backs Ankole's Cloudflare `WorkerProvider`. Each Agent maps to one
`AgentWorker` Durable Object and one R2 prefix (`agents/<agent_uid>/`): the
Durable Object manages that Agent's container instance and records the latest
completed `DirectoryBackup`, while the adapter registry filters Agents by
provider.

## Requirements

- A Cloudflare account with Workers Paid and Containers enabled.
- An R2 bucket bound as `BACKUPS` in `wrangler.json`.
- The `linux/amd64` Worker image for your Ankole release, which bundles
  `sandbox-shim` from the exact `@cloudflare/sandbox` version used by this
  adapter (`1.0.0`).
- Publicly reachable Worker Channel, file relay, and AIGateway endpoints
  configured in the provider YAML below, each protected by credentials.

Run `bun install` at the repository root first, then run the deployment commands
from this directory. Because these commands publish live cloud resources, local
test suites do not execute them.

## Deploy

1. Sign in with `bunx wrangler login`, create your R2 bucket, and set its bucket
   name in `wrangler.json`. Preserve both the R2 bucket and the Durable Object
   bindings across upgrades, because they hold Agent Home backups and backup
   metadata.

2. Identify the Worker image reference that the control plane uses when creating
   Workers (`ANKOLE_AGENT_COMPUTER_IMAGE`, written `<worker-image>` below). In
   the Helm chart, this value comes from `worker.image`—formatted as
   `<repository>@<digest>` when `worker.image.digest` is set, or
   `<repository>:<tag>` otherwise (for example,
   `ghcr.io/agentbull/ankole-agent-computer-worker@sha256:<worker-digest>`). In
   Docker Compose, it is the Worker image embedded in the control-plane image.
   Pull, retag, and push that image to Cloudflare's container registry, noting
   the digest printed by the push:

   ```bash
   docker pull --platform linux/amd64 <worker-image>
   docker tag <worker-image> ankole-worker:<revision>
   bunx wrangler containers push ankole-worker:<revision>
   ```

3. Deploy the adapter, passing `<worker-image>=<cloudflare-image-digest>` for
   each supported image. The left-hand key must match `<worker-image>` character
   for character and stay within Wrangler's 128-character limit. Because the
   control plane passes the same `<worker-image>` reference to every provider, a
   hybrid deployment with both Kubernetes and Cloudflare Workers pulls
   `<worker-image>` directly on Kubernetes while launching the mapped Cloudflare
   digest through this adapter:

   ```bash
   bun run deploy <worker-image>=registry.cloudflare.com/<account-id>/ankole-worker@sha256:<digest>
   ```

   This script generates `wrangler.deploy.json` and invokes Wrangler. If a
   request arrives for an unmapped `<worker-image>`, no Cloudflare container is
   created and the Worker reports `cloudflare_image_not_deployed` as its last
   error.

4. Configure the shared adapter secret with
   `bunx wrangler secret put ANKOLE_ADAPTER_TOKEN`, and enter the identical
   value in the provider's encrypted `adapterToken` credential field in Ankole
   (never in the plaintext provider YAML).

5. Create a Cloudflare Worker provider in the Console with the configuration
   below—or seed it on first boot through the
   [Helm chart](../../helm/ankole-agent/README.md#workers-on-cloudflare)—and
   select that provider when creating Agents:

   ```yaml
   adapterUrl: https://ankole-agent-workers.example.workers.dev
   instance: standard-3
   env: {}
   endpoints:
     runtimeFabricUrl: wss://ankole.example.com/runtime-fabric/worker
     relayOrigin: https://ankole.example.com
     aiGatewayUrl: https://ankole.example.com/api/v1/ai-gateway
   stopGraceSeconds: 300
   idleReleaseAfter: 15m
   ```

`instance` accepts either a Cloudflare preset name or an explicit
`{cpus, memoryMiB, diskMB}` map; ensure the disk is large enough to hold both
the container image and the restored Agent Home. Changing `instance` settings
causes the control plane to replace idle Workers, whereas rotating credentials
or adjusting `stopGraceSeconds` does not. Once a provider is created,
`adapterUrl` is immutable. Because file-relay requests must land on the
control-plane node that issued the transfer URL, using a shared public
`relayOrigin` requires running a single control-plane replica.

## Storage and replacement

Container instance disks on Cloudflare are ephemeral: even if a container
restarts within the same generation (for instance after an out-of-memory kill),
the new container can wake up with an empty disk. Whenever the Worker entrypoint
restores `/workspace`, it writes a restore marker onto the instance disk outside
`/workspace`. On startup, if that marker is missing, the entrypoint asks the
adapter to restore `/workspace` before launching the Worker. The adapter
restores the latest backup recorded for the current generation—or falls back to
the backup reference committed in PostgreSQL when the current generation has not
backed up yet—and then prunes older backup objects under that Agent's R2 prefix.
If the restore fails, or if a stop signal arrives before the Worker launches,
the entrypoint exits without starting the Worker or triggering a backup.

On `SIGTERM`, the supervisor drains active work and terminates any remaining
writer processes; on `SIGUSR1`, it terminates writers immediately. Afterward, it
requests a directory backup only if the restore marker is present on disk, so an
unrestored empty `/workspace` can never overwrite a valid backup in R2. The
adapter commits the backup result before the container entrypoint exits, and the
control plane reads that result before marking the instance absent and starting
a replacement generation. Rebuildable SQLite cache files under
`/var/cache/ankole` are excluded from backups.

The adapter also records every completed or rejected generation in Durable
Object storage and rejects late creation requests carrying those generation IDs,
preventing a delayed request from restoring a superseded backup. Deleting an
Agent removes its R2 backups, credentials, runtime state, and registry entry;
however, because delayed network requests have no upper bound on arrival time,
finished-generation tombstones stay in Durable Object storage indefinitely and
grow proportionally to the number of retired generations.

Size `stopGraceSeconds` generously enough for both draining and R2 upload to
complete. If a container hits OOM, receives `SIGKILL`, fails its backup upload,
or is forcibly terminated by the platform—including when a control-plane outage
exceeds the adapter's six-hour keep-alive limit—any file changes made since the
last completed backup can be lost.

## Upgrade

To roll out a new Worker image, push the image to Cloudflare first and redeploy
the adapter with an added mapping for the new `<worker-image>` reference (such
as the updated `worker.image` in Helm values) while keeping existing mappings
for Workers that are still running. Then upgrade the control plane. Replacing a
Worker image restores Agent Home from R2 rather than relying on a container
registry snapshot.

Before upgrading `@cloudflare/sandbox`, disable all Agents on this provider and
wait until their containers finish backing up and terminate. Then deploy the
updated adapter SDK together with a Worker image containing the matching
`sandbox-shim`, update the target image reference, and re-enable the Agents.
Deploying a newer SDK while containers still run an older shim can break backup
and restore calls.

To decommission this deployment, delete its Agents in Ankole first and wait for
instance termination and R2 cleanup to finish; then remove the adapter Worker,
container application, and image tags with Wrangler, archiving any operator
backups you wish to keep before deleting R2 objects. Do not delete an adapter
that is still shared by another Ankole provider.

## Local checks

```bash
bun run test
bun run type-check
```

To stream live logs from the deployed adapter, run
`bunx wrangler tail ankole-agent-workers`.
