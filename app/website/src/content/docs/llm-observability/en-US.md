---
title: LLM observability
description: Export optional cross-runtime Agent Turn traces with AIGateway LLM semantics to an OTLP/HTTP receiver.
section: User guide
order: 44
---

Ankole can export OpenTelemetry traces over HTTP/protobuf using the OpenTelemetry Protocol (OTLP). Trace export is disabled by default. When you enable it, `observability.traces.provider` selects which vendor-specific attributes Ankole attaches to Turn root spans and AIGateway LLM spans—it is not an AIGateway model Provider, does not replace OTLP transport, and does not filter out other OpenTelemetry spans. All three modes share the same process-wide OpenTelemetry SDK and OTLP exporter:

- `langfuse` adds Langfuse v4 agent and generation attributes.
- `langsmith` adds LangSmith run-type and content compatibility attributes.
- `opentelemetry` emits only standard OpenTelemetry, `gen_ai.*`, and Ankole attributes—use this mode for VictoriaTraces, Honeycomb, Grafana Cloud, or an OpenTelemetry Collector.

When trace export is active, spans include model inputs and outputs as well as tool arguments and results. Before exporting, Ankole strips configured credentials, request headers, generic caller metadata, encrypted reasoning and tool fields, and internal `__ankole_*` fields; replaces inline `data:` media with its byte count; and omits any input or output payload larger than 1 MiB. Even with those redactions, only export traces to a trusted receiver with appropriate access and retention controls.

Each dispatched Agent Turn produces one trace whose `turn <event-type>` root span appears as an agent observation in Langfuse, carrying the sanitized triggering event and final reply. Main Agent tool calls and AIGateway responses attach as children of that root, while a Background Job trace also nests `codex.turn` and Codex tool spans. Direct AIGateway calls made outside a Turn use `ai_gateway.response` as their root span. On the Worker side, Agent Computer forwards its protobuf OTLP batches over the authenticated Runtime Fabric RPC lane so that OTLP receiver credentials stay exclusively in the control plane.

## Configure Langfuse

This procedure follows the [Langfuse native OpenTelemetry guide](https://langfuse.com/integrations/native/opentelemetry) and the [Langfuse v4 migration checklist](https://langfuse.com/integrations/native/opentelemetry/migration-to-v4).

### Before you begin

- Create a Langfuse project and copy its project public key (`pk-lf-...`) and secret key (`sk-lf-...`) from **Settings → API Keys**.
- Choose the base endpoint matching your project's region:

| Deployment | `observability.traces.otlp_endpoint` |
|---|---|
| Langfuse Cloud EU | `https://cloud.langfuse.com/api/public/otel` |
| Langfuse Cloud US | `https://us.cloud.langfuse.com/api/public/otel` |
| Langfuse Cloud Japan | `https://jp.cloud.langfuse.com/api/public/otel` |
| Langfuse Cloud HIPAA | `https://hipaa.cloud.langfuse.com/api/public/otel` |
| Self-hosted Langfuse 3.22.0 or later | `https://<langfuse-host>/api/public/otel` |

Enter the base endpoint without `/v1/traces`—Ankole appends `/v1/traces` automatically and sends `application/x-protobuf` payloads. Note that Langfuse does not accept OTLP/gRPC on this endpoint.

### Build the Authorization value

Langfuse HTTP Basic authentication uses the project public key as the username and the project secret key as the password. Encode both keys into a single Base64 string with no trailing newline:

```bash
printf '%s' 'pk-lf-...:sk-lf-...' | base64 | tr -d '\n'
```

Prepend `Basic ` when entering the header value, and do not store the raw Langfuse keys separately in AppConfigure.

### Set AppConfigure

Open **Console → System configuration → LLM observability** and fill out the form in order:

1. Select **Langfuse** as the Trace Provider.
2. Enter the base endpoint for your Langfuse region.
3. Add these authentication header rows, replacing `<base64-value>`:

   | Header name | Header value |
   |---|---|
   | `Authorization` | `Basic <base64-value>` |
   | `x-langfuse-ingestion-version` | `4` |

4. Turn on **Trace export** and save.
5. Restart the control plane, since Ankole reads these four settings once at startup.
6. Send one Agent message or run one Background Job, then check your Langfuse project. Dispatched Turns appear under a `turn <event-type>` agent root with `tool <name>` and `ai_gateway.response` child spans, and `chat <model>` generations beneath each response. Background Jobs also include `codex.turn` and Codex tool spans, direct AIGateway calls outside a Turn appear as `ai_gateway.response` roots, and provider-native compaction calls appear as `compact <model>` generations.

Include `x-langfuse-ingestion-version: 4` so Langfuse routes spans through its real-time v4 ingestion pipeline; without that header, ingested traces can be delayed. Once saved, Ankole encrypts the header map in PostgreSQL and masks its values in the Console.

To help Langfuse group traces by trigger, Ankole populates `user.id` according to the source of the Turn:

- For a direct message from a trusted human, Ankole sets `user.id` to `principal:<principal_uid>`.
- For a group Turn, or an event Turn tied to a source Conversation, Ankole sets `user.id` to `channel:<conversation_uuid>`.
- For a Turn without a source Conversation that was triggered by a trusted human, Ankole sets `user.id` to `principal:<principal_uid>`.
- For a Turn with neither a trusted human trigger nor a source Conversation, Ankole omits `user.id`.

Direct AIGateway requests outside a Turn set `user.id` to `principal:<authenticated_subject_uid>`. Ankole records the executing Agent in `ankole.principal.uid`, `ankole.principal.type`, and filterable trace metadata, and maps the conversation—either a Main Agent conversation or a Background Job Codex session—to the Langfuse session.

The `channel:` prefix is part of Ankole's observability contract and always wraps the public Conversation UUID rather than an external chat-platform channel ID.

You can also set the optional `ANKOLE_ENV` and `ANKOLE_VERSION` environment variables on the control plane to tag every trace with a Langfuse environment (lowercase letters, digits, `-`, and `_`, up to 40 characters) and release version.

To turn off trace export, set `observability.traces.enabled` to `false` and restart the control plane. Export failures never affect Agent Turns or AIGateway responses, though export is best effort and Ankole does not buffer failed trace batches in a durable outbox.

## Configure LangSmith

This setup follows the [LangSmith OpenTelemetry guide](https://docs.langchain.com/langsmith/trace-with-opentelemetry) and the [LangSmith OpenTelemetry announcement](https://www.langchain.com/blog/opentelemetry-langsmith). In `langsmith` mode, Ankole emits the mapped `langsmith.span.kind`, `gen_ai.prompt`, `gen_ai.completion`, model, and token attributes.

1. Open **Console → System configuration → LLM observability** and select **LangSmith** as the Trace Provider.
2. Enter the base endpoint for your LangSmith region without appending `/v1/traces`:

   | Deployment | `observability.traces.otlp_endpoint` |
   |---|---|
   | GCP US | `https://api.smith.langchain.com/otel` |
   | GCP EU | `https://eu.api.smith.langchain.com/otel` |
   | GCP APAC | `https://apac.api.smith.langchain.com/otel` |
   | AWS US | `https://aws.api.smith.langchain.com/otel` |
   | Self-hosted | `https://<langsmith-api-host>/api/v1/otel` |

3. Add these authentication header rows:

   | Header name | Header value |
   |---|---|
   | `x-api-key` | `<langsmith-api-key>` |
   | `Langsmith-Project` | `<project-name>` |

   `Langsmith-Project` is optional; when you omit it, LangSmith routes traces to the `default` project. Whenever an AIGateway Response belongs to a conversation, `langsmith` mode copies that conversation ID into `langsmith.trace.session_id` while preserving `session.id` and `gen_ai.conversation.id`.

4. Turn on **Trace export**, save, restart the control plane, and run an AIGateway request to verify ingestion.

## Configure other OTLP/HTTP receivers

Select `observability.traces.provider=opentelemetry` for any receiver in the table below, omit `/v1/traces` from the base endpoint, and enter each required header as a separate authentication header row in the Console form:

| Receiver | `observability.traces.otlp_endpoint` | `observability.traces.otlp_headers` |
|---|---|---|
| OpenTelemetry Collector | `http://<collector-host>:4318` | `{}` unless the receiver requires authentication |
| VictoriaTraces single-node | `http://<victoria-traces>:10428/insert/opentelemetry` | `{}` on a trusted network without an authentication proxy |
| VictoriaTraces cluster | `http://<vtinsert>:10481/insert/opentelemetry` | `{}` on a trusted network without an authentication proxy |
| Honeycomb US | `https://api.honeycomb.io` | `{"x-honeycomb-team":"<api-key>"}` |
| Honeycomb EU | `https://api.eu1.honeycomb.io` | `{"x-honeycomb-team":"<api-key>"}` |
| Grafana Cloud | Copy the base `OTEL_EXPORTER_OTLP_ENDPOINT` from the stack's OpenTelemetry connection tile | `{"Authorization":"Basic <base64(instance-id:access-policy-token)>"}` |

Because Ankole appends `/v1/traces` automatically, the full ingestion URL sent to VictoriaTraces resolves to `/insert/opentelemetry/v1/traces`. VictoriaTraces does not enforce built-in tenant authentication, so place `vmauth` or another authenticating proxy in front of it outside a trusted network and configure those proxy headers in AppConfigure; see the [VictoriaTraces OTLP guide](https://docs.victoriametrics.com/victoriatraces/data-ingestion/opentelemetry/).

Honeycomb Classic environments also require an `x-honeycomb-dataset` header. For Grafana Cloud, generate an access policy token with `traces:write` scope; your stack's base endpoint typically ends in `/otlp`. Check the [Honeycomb OTLP configuration](https://docs.honeycomb.io/send-data/opentelemetry) and [Grafana Cloud OTLP configuration](https://grafana.com/docs/grafana-cloud/send-data/otlp/send-data-otlp/) docs before copying account-specific values.

In `opentelemetry` mode, Ankole emits no `langfuse.*` or `langsmith.*` attributes. Conversely, selecting `langfuse` or `langsmith` enriches only Turn roots and AIGateway LLM spans—Worker tool spans and other control-plane spans stay vendor-neutral and go to the same configured OTLP endpoint. Because LangSmith accepts standard OpenTelemetry spans, Ankole does not need to drop non-LLM spans when `langsmith` is selected.

## Troubleshoot export

- **No traces appear:** Confirm that you restarted the control plane after saving all four settings.
- **Traces arrive, but LLM fields are missing:** Check that `observability.traces.provider` matches your receiver vendor.
- **The receiver logs a `404` or missing route:** Verify that `observability.traces.otlp_endpoint` is the base OTLP URL and does not already end with `/v1/traces`.
- **Langfuse returns `401`:** Rebuild the `Authorization` header from your project's public and secret keys, making sure the Base64 string contains no trailing newline.
- **Langfuse traces are delayed:** Confirm that the headers include `x-langfuse-ingestion-version` set to `"4"`.
- **Control-plane logs show `observability.traces.disabled`:** Fix the invalid endpoint or header configuration in the Console, then restart the control plane.

Do not set `OTEL_TRACES_EXPORTER` or `OTEL_EXPORTER_OTLP_*` in the process environment. Ankole clears those environment variables before starting OpenTelemetry so that AppConfigure remains the sole owner of exporter configuration.
