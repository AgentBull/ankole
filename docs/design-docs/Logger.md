# Logger

Ankole logs are application events written as structured JSON. The contract is
inspired by Google Cloud Logging's severity vocabulary and structured-log shape,
but it is not a Google Cloud Logging compatibility layer. The production target
is ordinary Docker and Kubernetes stdout/stderr collection.

The control plane and the Bun worker use the same event contract even though
their implementations are different:

- the Bun agent-computer uses a small facade over Pino;
- the Elixir control plane uses `Ankole.Logging` over the Erlang/Elixir Logger;
- Docker and Kubernetes deployments collect JSON from stdout/stderr;
- application code does not call a remote logging write API directly.

This document describes the log entry contract. It is not a generic observability
strategy and it does not replace domain telemetry, metrics, traces, or durable
runtime rows.

## Goals

The logger has three jobs:

1. Emit one cross-runtime JSON shape that container log collectors can ingest
   without a sidecar-specific schema.
2. Keep log levels human and operator meaningful by using one field,
   `severity`, with the severity names borrowed from Google Cloud Logging.
3. Preserve Ankole runtime truth by logging the actual boundary that produced
   the event. RuntimeFabric and worker core events are not HTTP events; Phoenix
   request completion is the only HTTP request log source.

The logger deliberately does not emit `level`, `severity_text`, or
`severity_number`. Numeric Pino levels and Erlang Logger levels are internal
implementation details only.

## Entry Shape

Every application log entry must have these fields:

| Field | Owner | Meaning |
| --- | --- | --- |
| `severity` | logger facade/formatter | Google severity name, such as `INFO` or `ERROR` |
| `message` | caller | Human-readable stable summary |
| `time` | logger runtime | ISO-8601 timestamp |
| `event` | caller | Stable machine event name, dotted lowercase by convention |
| `labels` | logger facade plus caller | Low-cardinality dimensions for filtering and grouping |

Optional top-level structured fields:

| Field | Use |
| --- | --- |
| `http_request` | Real Phoenix/HTTP request boundary only |
| `operation` | Multi-log operation correlation, such as a turn, RPC, or file transfer |
| `insert_id` | Explicit log de-duplication id when the caller has one |
| `trace` | Trace id or trace resource name when the caller has one |
| `span_id` | Span id associated with the log entry |
| `trace_sampled` | Trace sampling flag |

All other structured fields remain in the JSON payload. Common payload fields
include `worker_id`, `actor_event_id`, `message_id`, `correlation_id`,
`rpc_request_id`, `route`, `transfer_id`, `duration_ms`, `agent_uid`, and
`binding_name`.

Reserved contract fields are not valid payload fields. If application fields try
to provide `level`, `severity_text`, `severity_number`, `severity`, `message`,
`time`, `event`, old Cloud Logging special-field names, or legacy camelCase
HTTP request fields as ordinary payload, the logger drops the payload copy. New
code must use ordinary Ankole field names such as `labels`, `operation`,
`insert_id`, and `http_request`.

## Labels

`labels` is for low-cardinality dimensions only. It must always include:

| Label | Control plane | Worker |
| --- | --- | --- |
| `service` | `ankole-control-plane` | `ankole-worker` |
| `component` | default `control-plane`, overridden for a subsystem | default `agent-computer`, overridden by child loggers |
| `runtime` | `beam` | `bun` |

Optional labels:

- `environment`, from `ANKOLE_ENV`, `NODE_ENV`, or logger config;
- `version`, from `ANKOLE_VERSION`.

Do not put high-cardinality ids in labels. Worker ids, actor event ids, message
ids, request ids, routes, transfer ids, and correlation ids stay in the JSON
payload. This keeps labels useful for filtering without turning them into
unbounded index dimensions.

## Severity

Ankole uses the same severity names as Google Cloud Logging because their
operational meaning is clear and broadly familiar. `DEFAULT` is not emitted by
application code.

| Severity | Use in Ankole |
| --- | --- |
| `DEBUG` | Diagnostic detail for local investigation, protocol noise, ignored unmatched frames, best-effort cleanup failures |
| `INFO` | Routine successful progress, normal completed turns, normal request completion |
| `NOTICE` | Normal but significant lifecycle events, such as worker readiness or setup/bootstrap state changes |
| `WARNING` | Recoverable anomalies that might need attention: slow requests, selected 4xx statuses, skipped heartbeats, route mismatch, invalid external payloads |
| `ERROR` | Failed operation that likely affects a user, actor event, provider call, persisted data, or request |
| `CRITICAL` | Process-level or worker-level failure where the current runtime cannot safely continue the operation |
| `ALERT` | Immediate operator action is required, but the whole installation is not necessarily unusable |
| `EMERGENCY` | One or more essential systems are unusable |

`ANKOLE_LOG_LEVEL` accepts these severity names and common aliases such as
`warn` and `fatal`. `fatal` maps to `CRITICAL`.

## Operation Field

Use `operation` when several log entries describe one logical operation. The
operation id should be a real Ankole id:

- actor turn: `actor_event_id`;
- RuntimeFabric RPC: `rpc_request_id`;
- file transfer: `transfer_id` when that is the operation being followed.

The producer should name the subsystem, for example
`ankole-control-plane/runtime-fabric-rpc` or `ankole-worker/agent-computer`.

Do not invent operation ids for one-off events. The payload field is enough when
there is no multi-entry operation to follow.

## HTTP Request Logs

`http_request` is only emitted for Phoenix endpoint request completion. The
request logger subscribes to `[:phoenix, :endpoint, :stop]` and emits
`http.request.completed`.

Severity rules:

| Condition | Severity |
| --- | --- |
| HTTP status `>= 500` | `ERROR` |
| HTTP status `401`, `403`, or `429` | `WARNING` |
| request duration at or above 2000 ms | `WARNING` |
| ordinary `2xx`, `3xx`, and other `4xx` responses | `INFO` |

RuntimeFabric, actor runtime, worker turns, file transfer, and provider delivery
must not fake `http_request`. If a worker core event was triggered by an HTTP
API earlier in the flow, log the durable/runtime id such as `actor_event_id` or
`message_id`; do not copy the original HTTP request shape into worker logs.

## Runtime APIs

### Bun Worker

Worker code imports the facade from
`app/agent_computer/src/worker/logging.ts`.

```ts
workerLogger.notice('worker.ready_sent', 'worker ready sent', {
  worker_id: workerId
})

const turnLogger = workerLogger.child({
  component: 'turn',
  fields: { actor_event_id: actorEventId }
})

turnLogger.error('worker.turn_failed', 'worker turn failed', { error })
```

Public methods:

- `debug(event, message, fields?)`;
- `info(event, message, fields?)`;
- `notice(event, message, fields?)`;
- `warning(event, message, fields?)`;
- `error(event, message, fields?)`;
- `critical(event, message, fields?)`;
- `alert(event, message, fields?)`;
- `emergency(event, message, fields?)`;
- `child({ component?, labels?, fields? })`.

The facade sets Pino `messageKey: "message"`, `errorKey: "error"`, ISO
timestamps, and `base: null`. Pino level formatter outputs only `severity`.
`pino-pretty` is a development display layer owned by the repository devkit,
not the worker runtime package or the production contract.

### Elixir Control Plane

Control-plane and first-party plugin code calls `Ankole.Logging`.

```elixir
Logging.notice("worker.ready_sent", "worker ready sent", %{
  worker_id: worker_id
})

Logging.warning("runtime_fabric.file_lane.route_mismatch", "worker file lane ignored mismatched route", %{
  transfer_id: transfer_id,
  expected_route: expected_route,
  route: route
})
```

Public methods mirror the Bun facade:

- `debug(event, message, fields \\ %{})`;
- `info(event, message, fields \\ %{})`;
- `notice(event, message, fields \\ %{})`;
- `warning(event, message, fields \\ %{})`;
- `error(event, message, fields \\ %{})`;
- `critical(event, message, fields \\ %{})`;
- `alert(event, message, fields \\ %{})`;
- `emergency(event, message, fields \\ %{})`.

`Ankole.Logging.JSONFormatter` is the only place that converts Erlang
Logger metadata into the JSON contract. Application code should not call
`Logger.info`, `Logger.warning`, or `Logger.error` directly in control-plane or
first-party plugin paths. The facade is the boundary.

Generic library packages that are not allowed to depend on Ankole application
modules may still use standard `Logger`; when they run inside the control-plane
VM, the configured formatter still emits structured JSON for those records.

## Configuration

| Variable | Values | Default |
| --- | --- | --- |
| `ANKOLE_LOG_LEVEL` | severity name or alias | `INFO` |

Kubernetes, Docker deployments, and worker runtime code emit structured JSON
log lines. Pretty logs are only for local development and must not be treated
as the ingestion format. The root `dev` script pipes the devkit process through
`bun kit logs pretty`, which applies the local display formatting outside
the worker runtime boundary.

## Event Naming

Event names are stable machine names. Use dotted lowercase names scoped by the
owning subsystem:

- `worker.ready_sent`;
- `worker.turn_failed`;
- `runtime_fabric.router_decode_failed`;
- `runtime_fabric.file_lane.route_mismatch`;
- `signals_gateway.outbox.mirror_failed_after_provider_send`;
- `http.request.completed`;
- `lark_adapter.inbound.reaction_missing_operator`.

The event name should not include ids, status text, or user data. Put those in
payload fields.

Messages are for humans. Keep them short and stable. Do not make operators
parse ids out of `message`; log ids as fields.

## Error Fields

Use the `error` field for exception-like values.

Bun serializes JavaScript `Error` values as:

```json
{
  "error": {
    "type": "TypeError",
    "message": "failed",
    "stack": "..."
  }
}
```

Elixir exception values are serialized by the formatter as:

```json
{
  "error": {
    "type": "RuntimeError",
    "message": "failed"
  }
}
```

If the error is not an exception object, log `reason: inspect(reason)` or a
domain-specific structured reason. Prefer the domain reason when it is already
stable and JSON-safe.

## Verification

The logging contract is protected by focused tests:

- `app/agent_computer/test/logging.test.ts` checks the Bun worker facade,
  severity mapping, error serialization, labels, and structured output.
- `tools/devkit/src/commands/logs.test.ts` checks the local pretty-display
  options used by `bun kit logs pretty`.
- `app/control_plane/test/ankole/logging/json_formatter_test.exs`
  checks the control-plane formatter, top-level structured fields, labels, `http_request`,
  and reserved-field protection.

Useful scans:

```sh
rg -n "\bLogger\.(debug|info|notice|warning|error|critical|alert|emergency|log)\b|require Logger" \
  app/control_plane/lib plugins/lark_adapter/lib \
  --glob '!app/control_plane/lib/ankole/logging.ex'

rg -n "logWorkerEvent" app/agent_computer/src app/agent_computer/test
```

Expected result: no output.

Useful commands:

```sh
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test test/ankole/logging/json_formatter_test.exs test/ankole/i18n_test.exs

cd ankole
bun test app/agent_computer/test/logging.test.ts tools/devkit/src/commands/logs.test.ts
```

The worker package type-check can fail for unrelated type errors outside the
logger. Do not treat that as proof of a logging contract failure unless the
error points at the logging files or logging tests.

## Influences

- Google Cloud Logging structured logging influenced the choice to keep
  `severity`, `message`, labels, HTTP request information, and operation
  correlation as first-class fields.
- Google Cloud Logging `LogSeverity` influenced the severity vocabulary:
  https://docs.cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry
