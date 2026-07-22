# Logger

Ankole writes one JSON object for each application event. Docker and Kubernetes
collect these lines from standard output and standard error.

The format uses Google Cloud Logging severity names, but it does not call the
Google Cloud Logging API.

The Bun Worker uses an adapter around Pino. The Elixir control plane uses
`Ankole.Logging` and an Erlang Logger formatter.

Application code does not call a remote logging service. Logs also do not
replace metrics, traces, telemetry, or database records.

## Fields in Each Entry

Each application entry has these fields:

| Field | Owner | Meaning |
| --- | --- | --- |
| `severity` | Logger | Severity name |
| `message` | Caller | Stable human summary |
| `time` | Logger | ISO 8601 timestamp |
| `event` | Caller | Stable machine event name |
| `labels` | Logger and caller | Low-cardinality dimensions |

An entry can also have these top-level fields:

| Field | Meaning |
| --- | --- |
| `http_request` | One real Phoenix request |
| `operation` | One operation that has multiple log entries |
| `insert_id` | An explicit deduplication ID |
| `trace` | A trace ID or trace resource name |
| `span_id` | A span ID |
| `trace_sampled` | A trace sampling flag |

Put other structured data in the JSON payload. Common examples include worker
IDs, ActorEvent IDs, routes, request IDs, and durations.

The logger does not emit numeric Pino levels or Erlang Logger levels. It also does not emit `severity_text` or `severity_number`.

## Use Labels Only for Small Sets of Values

Each entry has these labels:

| Label | Control plane | Worker |
| --- | --- | --- |
| `service` | `ankole-control-plane` | `ankole-worker` |
| `component` | `control-plane` by default | `agent-computer` by default |
| `runtime` | `beam` | `bun` |

`ANKOLE_ENV` can set the environment label. The Worker also accepts `NODE_ENV` when `ANKOLE_ENV` is absent.

`ANKOLE_VERSION` can set the version label.

Do not put unique or rapidly changing IDs in labels. Put them in normal payload
fields.

## Choose a Severity

Ankole supports these severities:

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

Application code does not emit `DEFAULT`.

`ANKOLE_LOG_LEVEL` accepts the severity names and lowercase aliases. `warn` maps to `WARNING`, and `fatal` maps to `CRITICAL`.

The Worker uses `INFO` when the configured value is unknown. The Elixir runtime raises during bootstrap for an unknown value.

## Group Related Entries

Use `operation` when several entries describe one operation. Reuse the real
domain ID when one exists.

Examples include:

- `actor_event_id` for an Actor turn
- `rpc_request_id` for a RuntimeFabric RPC
- `transfer_id` for a file transfer

Do not create an operation ID for one entry. Use a normal payload field instead.

## Log HTTP Requests Once

Only `AnkoleWeb.RequestLogger` writes `http_request`. It listens for `[:phoenix, :endpoint, :stop]` and emits `http.request.completed`.

The request logger uses these severities:

| Condition | Severity |
| --- | --- |
| Status is 500 or more | `ERROR` |
| Status is 401, 403, or 429 | `WARNING` |
| Duration is at least 2,000 ms | `WARNING` |
| All other statuses | `INFO` |

RuntimeFabric, ActorRuntime, Worker turns, file transfers, and provider delivery do not use `http_request`.

## Write Logs in the Bun Worker

Worker code imports `app/agent_computer/src/worker/logging.ts`.

```ts
workerLogger.notice('worker.ready_sent', 'worker ready sent', {
  worker_id: workerID
})

const turnLogger = workerLogger.child({
  component: 'turn',
  fields: { actor_event_id: actorEventID }
})
```

The Worker logging API provides:

- `debug(event, message, fields?)`
- `info(event, message, fields?)`
- `notice(event, message, fields?)`
- `warning(event, message, fields?)`
- `error(event, message, fields?)`
- `critical(event, message, fields?)`
- `alert(event, message, fields?)`
- `emergency(event, message, fields?)`
- `child({ component?, labels?, fields? })`

Pino uses `message` as its message key and `error` as its error key. It writes ISO timestamps and omits Pino base fields.

The Worker drops these payload names:

- `severity`, `level`, `severity_text`, and `severity_number`
- `message` and `time`
- names that start with `logging.googleapis.com/`

The API replaces a supplied `event` with the method argument. It merges supplied
`labels` with the logger labels.

The Worker serializes JavaScript `Error` values with type, message, stack, and supported structured details.

## Write Logs in the Elixir Control Plane

Control-plane and first-party Plugin code calls `Ankole.Logging`.

```elixir
Logging.notice("worker.ready_sent", "worker ready sent", %{
  worker_id: worker_id
})
```

The Elixir API provides the same eight severity methods as the Worker. Each
method accepts an event, message, and fields map.

`Ankole.Logging.JSONFormatter` writes the JSON line. It promotes the special top-level fields and removes reserved payload copies.

The formatter also removes old Google special names and the legacy `httpRequest` name.

Do not call the standard Logger directly in control-plane or first-party Plugin
application code.

A generic library can use the standard Logger when it cannot depend on Ankole modules. The configured formatter still writes JSON for that record.

## Read Logs During Development

Production runtimes write JSON. The Worker does not include `pino-pretty`.

The root development command pipes Devkit logs through `bun kit logs pretty`. This command changes display only.

## Name Events and Messages

Use a stable dotted lowercase event name. Start the name with the owning subsystem.

Examples include:

- `worker.ready_sent`
- `worker.turn_failed`
- `runtime_fabric.router_decode_failed`
- `signals_gateway.outbox.mirror_failed_after_provider_send`
- `http.request.completed`

Do not put IDs, status text, or user data in an event name. Put these values in payload fields.

Keep each message short and stable. Do not require an operator to parse IDs from the message.

## Record Errors

Use `error` for exception values. Use a stable structured reason for domain failures.

When no structured reason exists, use an inspected `reason` value. Do not convert a stable domain reason to free text.

## Test the Logging Contract

Run these commands from the repository root:

```sh
bun test app/agent_computer/test/logging.test.ts tools/devkit/src/commands/logs.test.ts

cd app/control_plane
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test test/ankole/logging/json_formatter_test.exs
```

The Bun test verifies severity mapping, labels, reserved fields, errors, and JSON output.

The Elixir test verifies the formatter, request logger, special fields, labels, and reserved-field protection.

## Rules

- Each application log record is one JSON object.
- `severity` is the only level field in output.
- `event` is a stable machine name.
- Labels contain only low-cardinality dimensions.
- Only Phoenix request completion uses `http_request`.
- Database rows, not logs, record workflow state.
