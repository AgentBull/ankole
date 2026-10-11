# Deploy Ankole

[简体中文](README.zh-Hans.md)

This directory contains the supported self-hosted deployment assets for the
open-source Ankole release.

| Target | Files | Database |
| --- | --- | --- |
| Kubernetes | [Helm chart](helm/ankole-agent/README.md) | Bundled PostgreSQL or an external PostgreSQL service |
| One Linux host | [Docker Compose](docker-compose/README.md) | Bundled PostgreSQL |

Both targets run the same production path:

- the Phoenix/OTP control plane owns durable state and the operator Console;
- PostgreSQL 18 stores durable state and provides `pg_search` and `vector`;
- the file service of the control plane keeps each Agent's drive, on a local
  volume or in S3-compatible storage;
- the control plane creates one Agent Computer Worker container for each Agent
  that needs one; its Agent Home persists separately from its cache;
- RuntimeFabric connects the control plane and the Workers on a private network.

The defaults pull `main-latest` images from the GitHub Container Registry. The
RuntimeFabric workflow publishes the control-plane and worker tags only after it
verifies the pair. These tags are mutable. For a controlled production rollout,
pin the Ankole images to digests from the same verified pair.

A Worker container is the computer of one Agent and its only isolation
boundary: it needs no extra kernel privileges, and Agents share no Worker. The
control plane needs the right to create Worker containers: the Docker socket
with Compose, a namespace Role with Kubernetes.

Use the Helm target when Kubernetes is available. Use the Compose target for
one production host with local named volumes.

Workers can also run on Cloudflare Containers through the
[Cloudflare adapter](cloudflare/agent-workers/README.md). The Helm chart
can include a Cloudflare provider in its seed. Compose supplies a Docker
provider seed by default. Add providers in the Console after initial import;
select a provider when creating each Agent. Cloudflare provider endpoints use
public addresses that Cloudflare can reach.
