---
title: LLM observability
description: Export optional cross-runtime Agent Turn traces with AIGateway LLM semantics to an OTLP/HTTP receiver.
section: User guide
order: 44
---

Ankole can export OpenTelemetry traces through OpenTelemetry Protocol (OTLP) over HTTP/protobuf. Export is off by default. `observability.traces.provider` selects the vendor attributes added to Turn roots and AIGateway LLM spans. It is not an AIGateway model Provider, does not implement transport, and does not filter other OpenTelemetry spans. All providers share the process-wide OpenTelemetry SDK and OTLP exporter:

- `langfuse` adds Langfuse v4 agent and generation attributes.
- `langsmith` adds LangSmith run-type and content compatibility attributes.
- `opentelemetry` sends only generic OpenTelemetry, `gen_ai.*`, and Ankole attributes. Use it for VictoriaTraces, Honeycomb, Grafana Cloud, and a Collector.

An enabled trace contains model input and output. It can also contain tool arguments and results. Ankole removes configured credentials, request headers, generic caller metadata, encrypted reasoning and tool fields, and internal `__ankole_*` fields. It replaces inline `data:` media with its byte count and omits an input or output payload larger than 1 MiB. The receiver must still be a trusted system with suitable access and retention controls.

Each dispatched Agent Turn is one trace. Its `turn <event-type>` root is an agent observation in Langfuse and contains the sanitized triggering event and final reply. Main Agent tools and AIGateway responses are children of that root. A Background Job also contains `codex.turn` and Codex tool spans. A direct AIGateway call without Turn context keeps its own `ai_gateway.response` root. Agent Computer sends its protobuf OTLP batches through the authenticated Runtime Fabric RPC lane, so receiver credentials stay in the control plane.

## Configure Langfuse

This procedure follows the [Langfuse native OpenTelemetry guide](https://langfuse.com/integrations/native/opentelemetry) and its [Langfuse v4 migration checklist](https://langfuse.com/integrations/native/opentelemetry/migration-to-v4).

### Before you begin

- Create a Langfuse project and copy its project public key (`pk-lf-...`) and secret key (`sk-lf-...`) from **Settings → API Keys**.
- Select the endpoint for the project region:

| Deployment | `observability.traces.otlp_endpoint` |
|---|---|
| Langfuse Cloud EU | `https://cloud.langfuse.com/api/public/otel` |
| Langfuse Cloud US | `https://us.cloud.langfuse.com/api/public/otel` |
| Langfuse Cloud Japan | `https://jp.cloud.langfuse.com/api/public/otel` |
| Langfuse Cloud HIPAA | `https://hipaa.cloud.langfuse.com/api/public/otel` |
| Self-hosted Langfuse 3.22.0 or later | `https://<langfuse-host>/api/public/otel` |

Enter the base endpoint without `/v1/traces`. Ankole appends `/v1/traces` and sends `application/x-protobuf`. Langfuse does not accept OTLP/gRPC on this endpoint.

### Build the Authorization value

Basic authentication uses the project public key as the username and the project secret key as the password. Generate one Base64 value without a trailing newline:

```bash
printf '%s' 'pk-lf-...:sk-lf-...' | base64 | tr -d '\n'
```

Prefix the result with `Basic ` when setting the header. Do not store the separate Langfuse keys in AppConfigure.

### Set AppConfigure

Open **Console → System configuration → LLM observability** and complete the visual form in this order:

1. Select **Langfuse** as the Trace Provider.
2. Enter the selected base endpoint.
3. Add these authentication header rows, replacing `<base64-value>`:

   | Header name | Header value |
   |---|---|
   | `Authorization` | `Basic <base64-value>` |
   | `x-langfuse-ingestion-version` | `4` |

4. Turn on **Trace export** and save.
5. Restart the control plane. These four values are read once during control-plane startup.
6. Send one normal Agent message or run one Background Job, then open the Langfuse project. The trace appears as one `turn <event-type>` agent root. A Main Agent trace contains `tool <name>` and `ai_gateway.response` children, with `chat <model>` generations below each response. A Background Job also contains `codex.turn` and Codex tool spans. A direct AIGateway request still appears as an `ai_gateway.response` root. A provider-native compaction call appears as its own `compact <model>` generation.

The `x-langfuse-ingestion-version: 4` header selects Langfuse's real-time v4 ingestion path. Without it, directly ingested data can be delayed. The headers value is encrypted in PostgreSQL and masked in Console after it is saved.

Langfuse groups new traces by their trigger without another Console setting. Ankole sets `user.id` with these rules:

- A direct message from a trusted human uses `principal:<principal_uid>`.
- A group Turn, or an event Turn with a source channel, uses `channel:<signal_channel_id>`.
- A Turn without a source channel uses `principal:<principal_uid>` when it has a trusted human trigger.
- A Turn without a trusted human or a source channel omits `user.id`.

A direct AIGateway request that is not part of a Turn uses `principal:<authenticated_subject_uid>`. The Agent stays separate in `ankole.principal.uid`, `ankole.principal.type`, and filterable trace metadata. The conversation — a Main Agent conversation or a Background Job Codex session — stays the Langfuse session.

These identity rules do not add a fifth AppConfigure value. The four values above still control only export and the OTLP receiver. Only spans from the updated control plane and Agent Computer use the new mapping after those processes restart. Existing Langfuse data does not change. Set the optional `ANKOLE_ENV` and `ANKOLE_VERSION` process environment variables on the control plane to label every trace with a Langfuse environment (lowercase letters, digits, `-` and `_`, at most 40 characters) and release.

To disable export, set `observability.traces.enabled` to `false` and restart the control plane. Export failures never change a Turn or AIGateway model result, but traces are best effort and Ankole does not retain a delivery outbox for them.

## Configure LangSmith

This setup follows the current [LangSmith OpenTelemetry guide](https://docs.langchain.com/langsmith/trace-with-opentelemetry) and the [LangSmith OpenTelemetry announcement](https://www.langchain.com/blog/opentelemetry-langsmith). Ankole emits the mapped `langsmith.span.kind`, `gen_ai.prompt`, `gen_ai.completion`, model, and token attributes.

1. Open **Console → System configuration → LLM observability** and select **LangSmith** as the Trace Provider.
2. Select the base endpoint for the LangSmith region. Do not append `/v1/traces`:

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

   `Langsmith-Project` is optional; LangSmith uses the `default` Project when it is absent. When an AIGateway Response belongs to a conversation, the `langsmith` provider copies that conversation ID to LangSmith's documented `langsmith.trace.session_id` and also keeps `session.id` and `gen_ai.conversation.id`.

4. Turn on **Trace export**, save, restart the control plane, and run one AIGateway request.

## Configure other OTLP/HTTP receivers

Use `observability.traces.provider=opentelemetry` for the receivers in this table. Do not include `/v1/traces` in the endpoint.
In the visual form, add each entry shown in the headers column as one authentication header row.

| Receiver | `observability.traces.otlp_endpoint` | `observability.traces.otlp_headers` |
|---|---|---|
| OpenTelemetry Collector | `http://<collector-host>:4318` | `{}` unless the receiver requires authentication |
| VictoriaTraces single-node | `http://<victoria-traces>:10428/insert/opentelemetry` | `{}` on a trusted network without an authentication proxy |
| VictoriaTraces cluster | `http://<vtinsert>:10481/insert/opentelemetry` | `{}` on a trusted network without an authentication proxy |
| Honeycomb US | `https://api.honeycomb.io` | `{"x-honeycomb-team":"<api-key>"}` |
| Honeycomb EU | `https://api.eu1.honeycomb.io` | `{"x-honeycomb-team":"<api-key>"}` |
| Grafana Cloud | Copy the base `OTEL_EXPORTER_OTLP_ENDPOINT` from the stack's OpenTelemetry connection tile | `{"Authorization":"Basic <base64(instance-id:access-policy-token)>"}` |

Ankole appends `/v1/traces` to these base endpoints, so the final VictoriaTraces path is `/insert/opentelemetry/v1/traces`. VictoriaTraces does not provide tenant authorization. Use vmauth or another authentication proxy outside a trusted network and put its required headers in AppConfigure. See the [VictoriaTraces OTLP guide](https://docs.victoriametrics.com/victoriatraces/data-ingestion/opentelemetry/).

Honeycomb Classic also requires `x-honeycomb-dataset`. For Grafana Cloud, use a token with `traces:write`; the endpoint is installation-specific and typically ends in `/otlp`. See the official [Honeycomb OTLP configuration](https://docs.honeycomb.io/send-data/opentelemetry) and [Grafana Cloud OTLP configuration](https://grafana.com/docs/grafana-cloud/send-data/otlp/send-data-otlp/) before copying current account values.

The `opentelemetry` provider does not emit `langfuse.*` or `langsmith.*` attributes. A `langfuse` or `langsmith` selection enriches only Turn roots and AIGateway LLM spans. Worker tool spans and other control-plane spans stay vendor-neutral and go to the same configured receiver. LangSmith accepts spans from a standard OpenTelemetry client, so selecting `langsmith` does not require Ankole to drop unrelated spans.

## Troubleshoot export

- If no trace appears, confirm that the control plane was restarted after all four values were saved.
- If a vendor receives data but does not identify the LLM fields, confirm that `observability.traces.provider` matches that vendor.
- If the receiver reports a missing route, confirm that the AppConfigure endpoint is a base OTLP endpoint and does not already end in `/v1/traces`.
- If Langfuse returns `401`, rebuild `Authorization` from the public and secret project keys and remove any newline from the Base64 output.
- If Langfuse receives a trace but it does not appear promptly, confirm that the headers contain `x-langfuse-ingestion-version` with the string value `4`.
- If the control-plane log reports `observability.traces.disabled`, correct the endpoint or headers, then restart the control plane.

Do not use `OTEL_TRACES_EXPORTER` or `OTEL_EXPORTER_OTLP_*` to configure Ankole. Ankole removes these variables before OpenTelemetry starts and before it applies the AppConfigure endpoint and headers. AppConfigure is the only owner of this exporter.
