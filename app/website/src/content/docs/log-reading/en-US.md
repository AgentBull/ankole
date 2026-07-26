---
title: Log reading
description: How to read Ankole's structured control-plane and worker logs — the event-name search pattern, the severity levels, and the local pretty-printer.
section: User guide
order: 57
---

Ankole's logs are structured JSON — an event name, a human message, and structured fields, at a severity from `debug` through `error`. This page is the operator's practical guide to reading them: the search pattern, the knobs, and the local pretty-printer. It complements the [Observability](../observability/) page with the hands-on mechanics.

The decisive property, stated up front: the **event name is the join key**. Every log line carries a stable event name like `signals_gateway.webhook.dispatch_failed` or `ai_gateway.response_failed`. Search by event name first, then narrow by the structured fields. Reading logs linearly is slow; reading by event name is fast.

## The log shape

Every log line has:

```json
{
  "severity": "warning",
  "event": "signals_gateway.webhook.dispatch_failed",
  "message": "provider webhook dispatch failed",
  "handler_id": "lark",
  "kind": "message",
  "reason": "..."
}
```

The `event` field is the stable identifier — it does not change between releases for the same operational fact. The `message` is human-readable but may change; search on `event`, read `message`. The remaining fields are structured context — the `handler_id`, the `reason`, the `agent_uid`, the `turn_ref` — and they are what you narrow by after you find the event.

## The two knobs

| Variable | Default | Effect |
|---|---|---|
| `ANKOLE_LOG_LEVEL` | `info` | `debug`/`info`/`warning`/`error` — controls what is emitted. Invalid value rejected at boot. |
| `ANKOLE_LOG_FORMAT` | `json` | `json` for ingestion, `pretty` for local reading (but set `pretty` only in development; production stays `json`). |

Drop to `debug` for a specific reproduction, then raise it back. A deployment left at `debug` is noisy and slow.

## Read locally with the pretty-printer

```bash
bun run kit logs pretty < /path/to/log-stream
```

The pretty-printer reads JSON lines from stdin and formats them for a terminal — severity, event, message, and fields in a readable layout. In production, leave format at `json` and let your log ingester handle formatting.

## The search pattern

When something is wrong, work from the event name:

1. **Identify the event.** If a webhook failed, search for `webhook.dispatch_failed`. If a provider call failed, search for `ai_gateway.response_failed` or `ai_gateway.request_failed`. If a turn errored, search for the turn-error events.
2. **Narrow by fields.** Once you have the event, filter by `agent_uid`, `handler_id`, `reason`, or `turn_ref` to find the specific instance.
3. **Read the context.** The fields around the event tell you which subsystem, which agent, and which boundary produced it. See [Observability](../observability/) for the question-to-surface mapping.

## What is NOT in the logs

- **Secrets.** The logging module never logs decrypted secret values, worker auth keys, or provider credentials. Fields that carry sensitive data are redacted before logging.
- **Full conversation transcripts.** Those are in AIGateway's PostgreSQL, not in logs. Read them through `/ai-gateway/conversations/:id/messages`.
- **Every tool call's arguments.** The logs record that a tool ran and its outcome, not the full arguments payload. For tool-call detail, read the conversation messages.

## What this guide is not

It is not the observability concept page — for the question-to-surface mapping, read [Observability](../observability/). It is not a log-ingester setup guide — your ingester (Loki, Elasticsearch, Datadog, CloudWatch) is your choice. And it is not a troubleshooting runbook — for specific failure patterns, read the [FAQ](../faq/) or [Schedule troubleshooting](../cron-troubleshooting/).

## Next steps

- For the observability surfaces, read [Observability](../observability/).
- For the log knobs as environment variables, read [Environment variables](../environment-variables/).
- For the kit pretty-printer, read the [kit CLI reference](../kit-cli/).
- For troubleshooting patterns, read the [FAQ](../faq/).
