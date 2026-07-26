---
title: Platform support
description: Which deployment targets, operating systems, and development hosts Ankole supports — the Compose host, the Kubernetes cluster, the worker node, and the contributor machine.
section: Getting started
order: 5
---

Ankole is a self-hosted server-side system, not a per-machine install, so "platform support" means two different things: where you **deploy** it (the host or cluster that runs the control plane and workers) and where you **develop** it (the machine a contributor runs `kit dev` on). This page is the support matrix for both, plus the worker node's hard requirements.

The decisive property, stated up front: production runs on Linux. The worker needs Linux kernel features for sandboxing, and the supported deployment packages target Linux hosts or Linux Kubernetes nodes. Development can happen on macOS or Windows/WSL2, but what ships is Linux.

## Deployment targets

These are the supported ways to run Ankole in production.

| Target | Architecture | Method | Notes |
|---|---|---|---|
| **Single Linux host** | `amd64`, `arm64` | Docker Compose | one host, bundled PostgreSQL and Caddy HTTPS; the canonical small deployment |
| **Kubernetes cluster** | `amd64`, `arm64` Linux nodes | Helm chart | bundled or external PostgreSQL; requires RWX storage for Agent Home |

Both methods are documented in the [installation guide](../installation/), and both pull the same verified images from GitHub Container Registry. Pick Compose for one host, Helm for a cluster — there is no third supported deployment shape.

### Single-host requirements (Compose)

A Linux `amd64` or `arm64` host with Docker Engine, the Docker Compose plugin, persistent local storage, and ports `80` and `443` free. The host kernel must accept the worker's security options; if it rejects them, use a supported Linux kernel rather than weakening the worker.

### Kubernetes requirements (Helm)

Kubernetes 1.27 or later, Helm 3 or later, Linux `amd64` or `arm64` nodes, an HTTPS Ingress, and an RWX StorageClass or an existing RWX claim for Agent Home. The chart runs the database migration and worker-key bootstrap as init containers; the control plane starts only after both succeed.

## The worker node's hard requirements

The Agent Computer worker needs three Linux-specific things for strong bubblewrap isolation, and the Compose and Helm packages already carry them:

- `SYS_ADMIN` capability,
- an unconfined seccomp profile,
- an unmasked `/proc`.

These exist because the worker runs agent shells under bubblewrap confinement, which needs those kernel facilities. Treat worker nodes as a trusted, first-party compute boundary — the sandboxing protects the host *from* the worker's shells, not the other way around, and a worker node is not a place to run untrusted code outside that contract. A host that cannot provide these three is not a supported worker target.

## External PostgreSQL

If you bring your own PostgreSQL instead of the bundled one, the external server must:

- run PostgreSQL 18 or later,
- preload `pg_search`,
- make `pg_search` and `vector` available to the application database owner.

`pg_search` is a hard requirement — Ankole uses BM25 full-text search through it — and a Helm rollback does not reverse a database migration, so back up PostgreSQL before every upgrade.

## Development hosts

These are the machines a contributor runs `kit dev` on to work on Ankole itself.

| Host | Status | Notes |
|---|---|---|
| **macOS** | supported | start Docker Desktop before `kit dev` |
| **Linux** | supported | log out and back in if the env-setup script added your user to the `docker` group |
| **Windows / WSL2** | supported | use WSL2; the env installer does not support native Windows shells |
| **Windows native** | not supported | use WSL2 |

GitHub Codespaces works for code and test work, but the baseline signal-binding walkthrough assumes `localhost:4000`, so adapt and verify callbacks when Codespaces hands you a forwarded HTTPS origin. See the [quick start](../quickstart/) for the local-source path.

## Not supported

These are not supported deployment or development shapes:

- **Running the control plane or worker on macOS or Windows in production.** Development on those hosts is fine; production is Linux.
- **A worker node that cannot grant `SYS_ADMIN`, an unconfined seccomp profile, and an unmasked `/proc`.** The worker's sandbox contract depends on them.
- **PostgreSQL older than 18, or PostgreSQL 18+ without `pg_search` preloaded.** The BM25 dependency is not optional.
- **A third deployment method outside Compose and Helm.** The images are published; an ad-hoc deployment assembled from them is not a supported shape, even if it runs.

If you are on an unsupported shape, the path forward is to move to one of the supported deployment targets, not to weaken the worker sandbox or run an older PostgreSQL.

## Next steps

- For the deployment steps, read the [installation guide](../installation/).
- For the local development path, read the [quick start](../quickstart/).
- For the worker's sandbox contract, read the [Agent Computer](../agent-computer/) developer page.
