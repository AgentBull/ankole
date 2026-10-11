# Agent Workers on Cloudflare Containers

[简体中文](README.zh-Hans.md)

The Cloudflare WorkerProvider calls this adapter. Each Agent has one
`AgentWorker` Durable Object and one R2 prefix, `agents/<agent_uid>/`.
The Durable Object owns its container and records the latest completed
`DirectoryBackup`. The registry filters Agents by provider.

## Requirements

- A Cloudflare account with Workers Paid and Containers access.
- An R2 bucket bound as `BACKUPS` in `wrangler.json`.
- The release's `linux/amd64` Worker image. It contains `sandbox-shim` from
  the same `@cloudflare/sandbox` version as the adapter (currently 1.0.0).
- Public Worker Channel, file relay, and AIGateway endpoints. Configure these
  in the provider YAML below. Each endpoint requires credentials.

Run `bun install` at the repository root. Run the following commands in this
directory. They publish cloud resources; local tests do not run them.

## Deploy

1. Log in with `bunx wrangler login`. Create the R2 bucket and set its name in
   `wrangler.json`. Keep the bucket and Durable Object bindings during upgrades:
   they contain Agent data and backup references.

2. Find the image reference that the control plane creates Workers with (its
   `ANKOLE_AGENT_COMPUTER_IMAGE`). The steps below call it `<worker-image>`.
   The Helm chart renders it from `worker.image`: `<repository>@<digest>` when
   `worker.image.digest` is set, else `<repository>:<tag>`, for example
   `ghcr.io/agentbull/ankole-agent-computer-worker@sha256:<worker-digest>`.
   With Compose, it is the Worker image that the control-plane image names.
   Push that image and record the digest that the push prints:

   ```bash
   docker pull --platform linux/amd64 <worker-image>
   docker tag <worker-image> ankole-worker:<revision>
   bunx wrangler containers push ankole-worker:<revision>
   ```

3. Deploy the adapter. Each argument maps a name to a pinned image. The name
   must be `<worker-image>` exactly, and Wrangler accepts at most 128
   characters. The control plane uses this one reference for all its
   providers: in an installation with Kubernetes and Cloudflare Workers,
   Kubernetes pulls it, and the adapter starts the image mapped to it.

   ```bash
   bun run deploy <worker-image>=registry.cloudflare.com/<account-id>/ankole-worker@sha256:<digest>
   ```

   The script writes `wrangler.deploy.json` and passes it to Wrangler. If no
   name matches, the control plane creates no Cloudflare Worker, and the last
   error of the Worker names `cloudflare_image_not_deployed`.

4. Run `bunx wrangler secret put ANKOLE_ADAPTER_TOKEN`.
   Store the same token in the provider's separate
   `adapterToken` credential field. Do not put it in provider YAML.

5. Create a Cloudflare provider in the Console with this configuration, then
   select it when creating Agents. The [Helm chart](../../helm/ankole-agent/README.md#workers-on-cloudflare)
   can supply it as an initial seed instead.

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

`instance` accepts a platform size name or `{cpus, memoryMiB, diskMB}`. The
instance disk must hold the image and restored Agent Home. Instance settings
replace an idle Worker; credentials and the stop grace do not. The adapter URL
cannot change after provider creation. The relay URL must reach the issuing
control-plane node; a shared public relay URL requires one replica.

## Storage and replacement

The instance disk is temporary. A container restart in the same generation,
for example after the container runs out of memory, can give a new disk. After
a restore, the entrypoint writes a marker on the instance disk, outside
`/workspace`. When the disk has no marker, the entrypoint asks the adapter to
restore `/workspace` before it starts the Worker. The adapter restores the
latest backup of the current generation, or the PostgreSQL-committed backup
reference when the generation has no backup yet. Then it removes the other
objects in that Agent's R2 prefix. A failed restore, or a stop signal before
the Worker starts, starts no Worker and requests no backup.

On SIGTERM the supervisor drains the Worker and stops its remaining writers.
On SIGUSR1 it stops them immediately. It then requests a directory backup, but
only from a disk with the marker: a backup of an unrestored Home would replace
the saved one. The adapter records the result before the entrypoint exits. The
control plane must read that record before it marks the instance absent and
creates a replacement. SQLite cache files at `/var/cache/ankole` are not backed
up.

The adapter records each finished or rejected generation. It rejects delayed
create requests for that generation, so they cannot restore an old backup.
Agent deletion removes backups, credentials, runtime state, and the registry
entry. The generation records remain in Durable Object storage without an
expiry, because a delayed request has no expiry. Their size grows with the
number of finished or rejected generations.

Set `stopGraceSeconds` long enough for drain and backup. OOM, SIGKILL, a failed
backup, or a forced platform stop can lose changes since the last completed
backup. A control-plane outage beyond the adapter's six-hour keep-alive limit
can also cause such a stop. These platform and backup paths need real-account
validation before rollout.

## Upgrade

Push the new image and map it under the new Worker image reference of the
control plane, for example the new `worker.image` of the Helm values. Keep the
names that running Workers still use. Then upgrade the control plane. Image
replacement restores Agent Home from R2; it does not depend on a registry
snapshot.

When upgrading `@cloudflare/sandbox`, first disable this provider's Agents and
wait for their instances to finish backup and disappear. Then deploy the new
SDK and matching `sandbox-shim` image, update the target image, and enable the
Agents. Deploying an SDK while an old shim is running can break backup and
restore.

For removal, first delete the Agents through Ankole and wait for instance and
storage cleanup. Then remove the adapter, container application, and image tags
through Wrangler. Retain backups required by the operator before removing R2
objects. Do not delete a shared adapter while another provider uses it.

## Local checks

```bash
bun run test
bun run type-check
```

Unit tests replace the Container and DirectoryBackup/R2 boundary. They do not
prove cloud backup, restore, or platform shutdown behavior. Use
`bunx wrangler tail ankole-agent-workers` for deployed adapter logs.
