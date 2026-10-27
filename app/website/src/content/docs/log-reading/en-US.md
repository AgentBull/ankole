---
title: Read logs
description: Get Ankole logs from Docker Compose, Kubernetes, or Cloudflare, then use event names and context fields to locate a failure.
section: User guide
order: 57
---

When the Console shows a failed request or an Agent stops replying, logs reveal whether the failure occurred in the control plane, the Worker, the chat channel, or the LLM Provider.

Ankole emits structured JSON logs by default, where every record carries a severity, an event name, a human-readable message, and structured context fields. Locate the relevant event first, and then filter by Agent UID, Provider ID, or failure reason to isolate the request.

## Get logs

Docker Compose:

```bash
docker compose logs --since 30m control-plane
docker ps -a --filter label=ankole.installation=ankole
docker logs --since 30m CONTAINER_NAME
```

Because the control plane creates a dedicated Worker container for each Agent, run the second command to list Worker containers; the `ankole.agent-uid` label identifies which Agent owns each container.

Kubernetes:

```bash
kubectl -n ankole logs deployment/ankole-control-plane --since=30m
kubectl -n ankole get pods -l ankole.io/installation=ankole
kubectl -n ankole logs POD_NAME -c worker --since=30m
```

Kubernetes resource names vary with your Helm release name, so run `kubectl -n ankole get deployments` first if the deployment name differs. On Worker Pods, the `ankole.io/installation` label defaults to the release name (unless overridden by `worker.installation`), and the `ankole.io/agent-uid` annotation identifies the owning Agent.

Cloudflare, from `tools/deploy/cloudflare/agent-workers`:

```bash
bunx wrangler tail ankole-agent-workers
```

The Cloudflare adapter logs one JSON line for each Worker start, stop, and R2 snapshot.

If an Agent's Worker fails to start, open **Console → Workers** to inspect its current state and the latest error reported by the Worker provider. See [Workers](../worker-management/).

Before reproducing an issue, note the approximate timestamp, Agent, chat channel, and user action so you can inspect a narrow time window instead of scanning logs from process startup.

## Read one record

```json
{
  "severity": "warning",
  "event": "signals.webhook.dispatch_failed",
  "message": "provider webhook dispatch failed",
  "handler_id": "lark",
  "reason": "..."
}
```

- `severity` indicates the log level.
- `event` provides a stable identifier for searching and aggregating records.
- `message` summarizes what happened in plain text.
- Additional fields identify the specific Agent, channel, Job, or request.

Because surrounding `info` and `warning` entries often explain what led up to an error, capture the full sequence of related records before and after the failure rather than copying only the final error line.

## A useful search order

1. Narrow the log stream to the time window around the incident.
2. Search for `error`, `warning`, or any error code shown in the Console.
3. Once you find the relevant `event`, filter by the Agent UID (which also serves as the Worker ID), Provider ID, or chat adapter.
4. Cross-check those log entries against the conversation or job state under **Console → Conversations** or **Background Agent Jobs**.

Ankole never logs decrypted model credentials, channel secrets, or Worker credentials. Even so, review log excerpts for user messages, internal URLs, and other sensitive business context before sharing them outside your team.

## Temporarily increase log detail

`ANKOLE_LOG_LEVEL` controls log verbosity and defaults to `info`. When diagnosing a subtle issue, you can temporarily set `ANKOLE_LOG_LEVEL=debug` and restart the affected service, then restore `info` afterward to avoid excessive log volume.

See the [deployment environment reference](../environment-variables/) for all logging and bootstrap variables, and the [FAQ](../faq/) for symptom-based troubleshooting checks.
