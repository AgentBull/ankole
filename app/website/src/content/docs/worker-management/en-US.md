---
title: Workers
description: Check each Agent's Worker in the Console, see how the control plane manages it, and resolve common failures.
section: User guide
order: 52
---

Each Agent has its own Worker and persistent Home at `/workspace`. Operators create a Worker provider in the Console with a type, YAML configuration, and separate credentials. Select the provider when creating an Agent; the selection cannot change. Use separate providers for different instance sizes.

## Worker pools

One Worker provider defines one Worker pool: a platform type, YAML configuration, and separately encrypted credentials. Pools belong to the site. Agents in different tenants can select the same pool, while each Agent keeps its own Worker, persistent Home, cache, and Worker credential.

1. Open **Console → Settings → Worker providers** and select **New Worker provider**.
2. Choose the type and use its YAML example. Set the instance image, size, storage, and connection endpoints that this pool needs.
3. Enter platform credentials in the separate credential fields, save, and run the availability check.
4. Set one pool as the default, or select a pool explicitly when creating an Agent. Without either selection, Agent creation fails.

The site has at most one default pool. Changing the default affects later Agent creation; existing Agents keep their selected provider. Create separate pools for different sizes or locations, including multiple pools of the same type. A provider ID, type, storage location, and an Agent's provider binding cannot change after creation. A pool cannot be deleted while an Agent Worker row refers to it.

Pool configuration manages instances through the selected platform. It does not assign one Agent's computer to another Agent. See [Agents](../agents/) for Agent creation and [Agent Computer Worker](../agent-computer-worker/) for execution and recovery.

## One Agent, one Worker

Agent creation saves the provider binding and a Worker row; it does not start an instance. The control plane starts the Worker when an environment tool, Codex Job, or Automation Job needs it. Main conversation and Workflow model calls run in the control plane and can continue without a Worker.

Sessions and Jobs of the same Agent share that Agent's computer, with separate workspaces in Home. An open environment workspace and a running Codex turn each consume one Worker slot. `ANKOLE_MAX_CONCURRENT_SLOTS` sets that Worker's capacity. More pools or Agents do not increase the slots of an existing Agent's Worker or its separate Background Agent Job limit.

## View Workers

Open **Console → Workers**. The row shows the Agent, provider, state, load, heartbeat, and latest platform error.

| State | Meaning |
| --- | --- |
| `absent` | No instance; the control plane creates one when needed |
| `starting` | A generation is saved; creation or admission is pending |
| `ready` | Connected and able to run turns |
| `stale` | The previous connection is gone |
| `paused` | The platform retains the process and memory |
| `draining` | Waiting for release or replacement |
| `deleting` | Waiting for instances and storage to be removed |

A timeout during creation keeps the same generation for retry. An uncertain result can leave an Agent waiting; the control plane does not create a possible second writer. Read **Reason** before changing configuration.

## Providers and storage

| Type | Persistent Home | Idle operation |
| --- | --- | --- |
| Docker | Local volume per Agent | Delete container |
| Kubernetes | PVC per Agent or directory in a shared PVC | Delete Pod |
| Cloudflare | R2 directory backup | Back up and delete container |
| Vercel | Drive per Agent | Delete sandbox |
| Lambda MicroVMs | Agent directory on EFS | Suspend memory |
| Function Compute | AgenticSpace or OSS prefix per Agent | Pause memory |

Vercel requires Pro or Enterprise for the 24-hour session limit. For Lambda, reserve memory quota for storage deletion helpers as well as running and suspended Workers. Check the target deployment with the commands in the repository's CONTRIBUTING guide. Function Compute follows the official protocols; its storage, template capture, and memory pause still need checks on an enabled Aliyun account. ACS is not registered because its default memory retention is not confirmed.

Home survives instance deletion and image changes. Codex thread files are in `/workspace/.codex`; SQLite is a cache at `/var/cache/ankole/codex`. A rebuild removes only the cache. A Docker local volume cannot survive loss of its host. Cloudflare can lose writes since the last backup after a forced platform stop. Back up persistent Home and the [Agent drive](../file-management/).

## Release, replacement, and deletion

- Set `idleReleaseAfter` in provider YAML. Docker and Kubernetes default to `never`; Cloudflare, Vercel, Lambda, and Function Compute default to `15m`.
- A memory-capable provider pauses an idle Worker. Other types delete the instance and keep persistent storage and any cache volume.
- Image or instance-setting changes replace Workers when idle. A protocol change replaces them immediately. Old paused instances are replaced before they resume.
- `agent_computer.worker.ready_timeout` defaults to 600 seconds. It rebuilds an instance already observed on the platform; it does not settle an uncertain create.
- Agent deletion waits for instances to disappear, deletes Home and cache, then removes the Worker row. Agent UIDs are generated by the server and are never reused.

## Diagnose a waiting Worker

Check provider credentials, storage, capacity, and the configured `endpoints`. For Docker, `ANKOLE_DOCKER_GID` must match the container's Docker socket group. For Kubernetes, check the control-plane Role, Pod events, and PVC binding. For Cloudflare, check the adapter image map and token. For Lambda, check image build state, build-role permissions, the VPC connector, and EFS reachability.

Use provider labels to identify the correct instance. Read its logs before stopping it. A normal Kubernetes deletion must finish; never use zero grace to work around a missing node. With Docker, stop before removal:

```bash
docker stop CONTAINER_NAME
docker rm CONTAINER_NAME
```

The control plane creates a replacement when needed. Home and cache volumes remain. A stop interrupts running turns, which follow their retry policies. If the Worker is ready but work waits, compare load with its turn slots. `ANKOLE_MAX_CONCURRENT_SLOTS` is an instance environment setting in provider YAML; changing it replaces the idle instance. See [Performance tuning](../performance-tuning/).
