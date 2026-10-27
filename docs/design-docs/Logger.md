# Logger

Ankole emits one JSON object per application log event to standard output or
standard error, where Docker or Kubernetes collects the stream. Entries use
Google Cloud Logging severity names, though application code never calls the
Google Cloud Logging API or any other remote logging service directly.

In the Bun Worker, logging goes through an adapter around Pino; in the Elixir
control plane, it goes through `Ankole.Logging` and an Erlang Logger formatter.
Logs capture operational and diagnostic events and do not replace metrics,
traces, telemetry, or database records.

## Fields in Each Entry

Every application log entry includes these core fields:

| Field | Owner | Meaning |
| --- | --- | --- |
| `severity` | Logger | Severity name |
| `message` | Caller | Stable human summary |
| `time` | Logger | ISO 8601 timestamp |
| `event` | Caller | Stable machine event name |
| `labels` | Logger and caller | Low-cardinality dimensions |

An entry may also include these optional top-level fields:

| Field | Meaning |
| --- | --- |
| `http_request` | One real Phoenix request |
| `operation` | One operation that spans multiple log entries |
| `insert_id` | An explicit deduplication ID |
| `trace` | A trace ID or trace resource name |
| `span_id` | A span ID |
| `trace_sampled` | A trace sampling flag |

Place additional structured context—such as worker IDs, Signal IDs, routes,
request IDs, and durations—in the JSON payload. Neither logger emits numeric
Pino or Erlang Logger levels, and neither emits `severity_text` or
`severity_number`.

## Use Labels Only for Small Sets of Values

Every entry carries three default labels:

| Label | Control plane | Worker |
| --- | --- | --- |
| `service` | `ankole-control-plane` | `ankole-worker` |
| `component` | `control-plane` by default | `agent-computer` by default |
| `runtime` | `beam` | `bun` |

Operators can set the environment label with `ANKOLE_ENV` and the version label
with `ANKOLE_VERSION`; the control plane forwards both variables to launched
Workers, and the Worker falls back to `NODE_ENV` for `environment` and
`ANKOLE_RELEASE_REVISION` for `version` when either variable is unset. Because
`labels` is reserved for low-cardinality dimensions, never place unique or
rapidly changing IDs in `labels`; put them in ordinary payload fields instead.

## Choose a Severity

Ankole supports eight severity levels:

| Severity | Use |
| --- | --- |
| `DEBUG` | Diagnostic detail and protocol noise |
| `INFO` | Routine progress and successful completion |
| `NOTICE` | Significant normal lifecycle events |
| `WARNING` | Recoverable conditions that can require attention |
| `ERROR` | A failed operation that affects a user or durable workflow |
| `CRITICAL` | A process cannot safely continue the current operation |
| `ALERT` | An operator must act immediately |
| `EMERGENCY` | An essential system is unusable |

Application code never emits `DEFAULT`. Operators configure the threshold via
`ANKOLE_LOG_LEVEL`, which accepts the canonical severity names as well as
lowercase aliases (`warn` maps to `WARNING`, and `fatal` maps to `CRITICAL`).
If `ANKOLE_LOG_LEVEL` has an unrecognized value, the Worker falls back to
`INFO`, whereas the Elixir runtime raises an error during bootstrap.

## Group Related Entries

When several log entries describe the same multi-step operation, correlate them
with the top-level `operation` field, reusing the real domain ID whenever one
exists:

- `signal_id` for a Session turn
- `rpc_request_id` for a RuntimeFabric RPC
- `transfer_id` for a file transfer

Do not mint a synthetic `operation` ID for a single log entry; record the
identifier in a regular payload field instead.

## Log HTTP Requests Once

`AnkoleWeb.RequestLogger` is the sole module that writes `http_request`. It
subscribes to `[:phoenix, :endpoint, :stop]` and emits
`http.request.completed` with a severity determined by the HTTP status code:

| Condition | Severity |
| --- | --- |
| Status is 500 or more | `ERROR` |
| Status is 401, 403, or 429 | `WARNING` |
| All other statuses | `INFO` |

Every request entry records the duration and Cloud HTTP latency fields. A
healthy long-running AI request still logs at `INFO`, because elapsed duration
alone does not indicate an incident. Non-HTTP subsystems—including
RuntimeFabric, Sessions, Worker turns, file transfers, and provider
delivery—never populate `http_request`.

## Write Logs in the Bun Worker

Worker modules import the logger from `app/agent_computer/src/worker/logging.ts`:

```ts
workerLogger.notice('worker.ready_sent', 'worker ready sent', {
  worker_id: workerID
})

const turnLogger = workerLogger.child({
  component: 'turn',
  fields: { signal_id: signalId }
})
```

The Worker logger exposes these methods:

- `debug(event, message, fields?)`
- `info(event, message, fields?)`
- `notice(event, message, fields?)`
- `warning(event, message, fields?)`
- `error(event, message, fields?)`
- `critical(event, message, fields?)`
- `alert(event, message, fields?)`
- `emergency(event, message, fields?)`
- `child({ component?, labels?, fields? })`

Under the hood, Pino writes the summary under `message`, errors under `error`,
and timestamps in ISO 8601 format while omitting default Pino base fields. To
protect the top-level schema, the Worker strips reserved keys from caller
`fields`:

- `severity`, `level`, `severity_text`, and `severity_number`
- `message` and `time`
- any key starting with `logging.googleapis.com/`

If the caller supplies `event` in `fields`, the logger overwrites it with the
method's `event` argument; if the caller supplies `labels`, the logger merges
them with its existing labels. JavaScript `Error` values serialize with their
type, message, stack, and any supported structured details.

## Write Logs in the Elixir Control Plane

Control-plane and first-party Plugin code logs through `Ankole.Logging`:

```elixir
Logging.notice("worker.ready_sent", "worker ready sent", %{
  worker_id: worker_id
})
```

`Ankole.Logging` provides the same eight severity functions as the Worker, each
taking an `event`, `message`, and `fields` map. `Ankole.Logging.JSONFormatter`
renders each record as a single JSON line, promoting recognized top-level
fields and removing duplicate reserved keys from the payload.

Before emitting a line, `Ankole.Logging.JSONFormatter` scrubs Webhook
capability tokens across the entire JSON entry—including framework messages and
nested fields—replacing raw and percent-encoded `wh_` tokens from
`Ankole.Signals.Webhooks` with `[REDACTED]`. Route templates keep `:token`, and
Phoenix parameter filtering hides the `token` parameter in debug logs.

Do not call Elixir's standard `Logger` directly from control-plane or
first-party Plugin code. Generic libraries that cannot depend on Ankole modules
may use the standard `Logger`, and the configured formatter still renders their
entries as JSON.

## Read Logs During Development

Production runtimes always output raw JSON lines, and the Worker does not
bundle `pino-pretty`. During local development, the root development command
pipes Devkit output through `bun kit logs pretty`, which formats entries for
terminal display without changing the underlying log payload.

## Name Events and Messages

Format `event` as a stable, dotted, lowercase name prefixed with the owning
subsystem:

- `worker.ready_sent`
- `worker.turn_failed`
- `runtime_fabric.router_decode_failed`
- `conversations.delivery.mirror_failed_after_provider_send`
- `http.request.completed`

Never embed IDs, dynamic status text, or user data in `event`; pass those
values in payload fields. Keep `message` short and stable so operators never
have to parse identifiers out of prose.

## Record Errors

Pass exception values under `error`, and represent domain failures with a
stable structured reason. `Ankole.Logging.failure_fields/1` extracts an atom
reason or the leading atom of a domain error tuple, while exceptions include
their type and a stacktrace with function arities (argument counts). When an
unexpected failure reaches the Console, Ankole logs it at `ERROR` severity and
returns HTTP 500; for expected request errors, Ankole returns their declared
HTTP status.

## Test the Logging Contract

Run these commands from the repository root:

```sh
bun run agent-computer:test
bun test tools/devkit/src/commands/logs.test.ts

cd app/control_plane
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test test/ankole/logging/json_formatter_test.exs
```

Both the Agent Computer unit suite and the Devkit log-formatting test run on
the host. The Agent Computer suite verifies severity mapping, labels, reserved
field stripping, error serialization, and JSON output, while the Elixir test
verifies `Ankole.Logging.JSONFormatter`, `AnkoleWeb.RequestLogger`, promoted
top-level fields, labels, and reserved-field protection.

## Rules

- Emit each application log record as a single JSON object.
- Write the log level only in `severity`.
- Give every entry a stable machine-readable `event` name.
- Restrict `labels` to low-cardinality dimensions.
- Populate `http_request` only when a Phoenix HTTP request completes.
- Record workflow state in PostgreSQL rows, never in logs.
