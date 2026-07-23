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
- one or more Agent Computer workers run agent turns;
- `/agents` stores Agent Home files;
- RuntimeFabric connects the control plane and workers on a private network.

The defaults pull `main-latest` images from the GitHub Container Registry. The
RuntimeFabric workflow publishes the control-plane and worker tags only after it
verifies the pair. These tags are mutable. For a controlled production rollout,
pin both Ankole images to digests from the same verified pair.

The Agent Computer needs `SYS_ADMIN` and an unconfined seccomp profile for
strong bubblewrap isolation. These permissions make a worker a trusted
first-party compute service. Do not run unrelated containers in the worker
security boundary.

Use the Helm target when Kubernetes and `ReadWriteMany` storage are available.
Use the Compose target for one production host with local named volumes.
