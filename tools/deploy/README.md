# Deploy Ankole

[简体中文](README.zh-Hans.md)

This directory contains the supported self-hosted deployment configurations for
the open-source Ankole release.

| Target | Files | Database |
| --- | --- | --- |
| Kubernetes | [Helm chart](helm/ankole-agent/README.md) | Bundled PostgreSQL or an external PostgreSQL service |
| One Linux host | [Docker Compose](docker-compose/README.md) | Bundled PostgreSQL |

Both targets deploy the same production architecture:

- The Phoenix/OTP control plane owns durable state and serves the operator
  Console.
- PostgreSQL 18 stores durable state and provides the `pg_search` and `vector`
  extensions.
- The control plane's file service stores each Agent's drive on a local volume
  or in S3-compatible object storage.
- For each Agent that needs an execution environment, the control plane creates
  a dedicated Agent Computer Worker container whose persistent Agent Home lives
  separately from its rebuildable cache.
- RuntimeFabric connects the control plane and Workers over a private network.

By default, these manifests pin the `2.0.0-alpha.24` pre-release control-plane
image—which embeds its matching Worker image reference—alongside a pinned
PostgreSQL image digest. Always pair deployment manifests with images from the
same release: `main-latest` tracks full releases (including release candidates)
and `canary` tracks alpha and beta builds, so either moving tag can lag behind
the manifests on `main`.

Each Worker container acts as one Agent's dedicated computer and sole isolation
boundary: Agents never share a Worker, and Workers require no extra Linux kernel
privileges. Because the control plane provisions Worker containers dynamically,
it needs container-lifecycle permissions—access to the Docker socket under
Docker Compose, or a namespace-scoped `Role` on Kubernetes.

Choose the Helm chart when deploying onto a Kubernetes cluster, or Docker
Compose when running on a single production host with local named volumes.

Workers can also run remotely on Cloudflare Containers via the
[Cloudflare adapter](cloudflare/agent-workers/README.md). Docker Compose seeds a
local Docker Worker provider by default, while the Helm chart can seed a
Cloudflare provider directly; after first boot, you can add more Worker
providers in the Console and choose a provider whenever you create an Agent.
When configuring a Cloudflare provider, point its endpoints at public URLs that
Cloudflare can reach.
