---
title: Read logs
description: Get Ankole logs from Docker Compose, Kubernetes, or Cloudflare, then use event names and context fields to locate a failure.
section: User guide
order: 57
---

When the Console only shows a failed request or an Agent does not reply, logs can show whether the failure is in the control plane, Worker, chat channel, or LLM Provider.

Ankole writes structured JSON logs by default. Each record has a severity, event name, message, and related context. Find the event first. Then use the Agent UID, Provider ID, or failure reason to narrow the records.

## Get logs

Docker Compose:

```bash
docker compose logs --since 30m control-plane
docker ps -a --filter label=ankole.installation=ankole
docker logs --since 30m CONTAINER_NAME
```

The control plane creates one Worker container for each Agent. The second command lists them; the label `ankole.agent-uid` names the Agent of each container.

Kubernetes:

```bash
kubectl -n ankole logs deployment/ankole-control-plane --since=30m
kubectl -n ankole get pods -l ankole.io/installation=ankole
kubectl -n ankole logs POD_NAME -c worker --since=30m
```

Resource names can change with the release name. If the command cannot find an object, first run `kubectl -n ankole get deployments`. The value of the Worker Pod label `ankole.io/installation` is the release name unless `worker.installation` sets another value, and the Pod annotation `ankole.io/agent-uid` names the Agent of the Pod.

Cloudflare, in `tools/deploy/cloudflare/agent-workers`:

```bash
bunx wrangler tail ankole-agent-workers
```

The adapter writes one JSON line for each start, stop, and snapshot of a Worker.

If an Agent's Worker does not start, **Console → Workers** shows its state and the latest reason from its backend. See [Workers](../worker-management/).

Before you reproduce a problem, record the approximate time, Agent, chat channel, and user action. You can then inspect a small time window instead of reading from process startup.

## Read one record

```json
{
  "severity": "warning",
  "event": "signals_gateway.webhook.dispatch_failed",
  "message": "provider webhook dispatch failed",
  "handler_id": "lark",
  "reason": "..."
}
```

- `severity` shows how serious the record is.
- `event` is the best field for search and aggregation.
- `message` gives a readable explanation.
- Other fields identify the Agent, channel, Job, or request.

Warnings and information near an error often show the full sequence. Do not copy only the last line. Keep related records before and after the failure.

## A useful search order

1. Limit the logs to the time of the problem.
2. Search for `error`, `warning`, or the error code from the Console.
3. After you find the related event, filter by Agent UID (also the ID of the Agent's Worker), Provider ID, or chat adapter.
4. Compare the records with the state under **Console → Conversations** or **Background Agent Jobs**.

Logs do not contain decrypted model credentials, channel secrets, or Worker credentials. Before you share logs for support, still check for user messages, URLs, and other business data.

## Temporarily increase log detail

`ANKOLE_LOG_LEVEL` controls detail and uses `info` by default. To reproduce a difficult problem, you can temporarily set it to `debug` and restart the related service.

Restore the previous value after the reproduction to avoid a large continuing log volume.

See the [deployment environment reference](../environment-variables/) for all variables.

See the [FAQ](../faq/) for checks organized by symptom.
