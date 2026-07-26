---
title: Workers
description: Check Agent Computer Worker state, capacity, and heartbeat in the Console, and resolve common failures.
section: User guide
order: 52
---

An Agent Computer Worker is the computer where Agents do their work. The control plane manages and assigns work. A Worker runs Agents, tools, and file operations. One deployment instance can connect to one or more Workers.

## View Workers

Open **Console → Workers**. Each row shows:

- **State:** whether the Worker can accept new work;
- **Slots:** the largest number of Agent turns that it can run at the same time;
- **Active turns:** turns that are running now;
- **Last heartbeat:** the last time that the control plane received Worker state;
- **Version:** the Ankole version on the Worker.

The control plane can assign work while at least one Worker is ready. A Worker with no recent heartbeat usually has a stopped container, a network problem, or an authentication failure between the Worker and control plane.

Select **Browse files** to inspect Agent files on that Worker. See [File management](../file-management/) for the procedure.

## If no Worker is ready

Check these items in order:

1. The Worker container or Pod is running.
2. Worker logs do not show a control-plane address, authentication, or connection error.
3. The control plane and Worker use the same `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`.
4. The Worker can reach the control plane Runtime Fabric address.
5. The control plane and Worker use compatible Ankole versions.

For Docker Compose:

```bash
docker compose ps agent-computer-worker
docker compose logs agent-computer-worker
```

For Kubernetes:

```bash
kubectl -n ankole get pods
kubectl -n ankole logs deployment/ankole-agent-computer-worker
```

The exact resource name depends on the release name. If the command cannot find the object, use `kubectl -n ankole get deployments` to find it.

## If Workers are ready but work stays queued

Compare **Active turns** with **Slots**. If every Worker uses all of its slots, new work waits for capacity.

A short wait is normal. For a persistent queue, first confirm that the LLM Provider is not slow. Then decide whether to add Workers, increase per-Worker capacity, or reduce concurrent work. See [Performance tuning](../performance-tuning/).

## Restart a Worker

Restart a Worker only when it does not respond and its logs show that it cannot recover.

Docker Compose:

```bash
docker compose restart agent-computer-worker
```

Kubernetes:

```bash
kubectl -n ankole rollout restart deployment/ankole-agent-computer-worker
```

A restart interrupts turns that run on that Worker. The control plane handles them according to their retry policy. After the restart, check the result under **Console → Conversations** or **Background Agent Jobs**.
