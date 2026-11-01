# RuntimeFabric

RuntimeFabric connects the Elixir control plane to Agent Computer workers over a
live transport without storing messages of its own; PostgreSQL owns every fact
that must survive a restart.

Traffic over a Worker connection falls into two categories:

- **Execution messages** open workspaces, run environment tools, and drive Codex
  Jobs.
- **RPC messages** invoke functions in the peer runtime to read or mutate Ankole
  state.

Both categories share the same authenticated WebSocket connection. Raw file
bytes never cross this socket: instead, the control plane sends a worker-file
RPC to the Worker, and the Worker streams the bytes over HTTP using a one-time
relay URL (see [Worker Files](#worker-files)).

## Which Process Stores What

The Elixir control plane persists all authoritative domain state in PostgreSQL:

- Principals, external identities, site credentials, and AuthZ grants
- Pod Spaces, Pages, collaboration history, and Base definitions (with physical
  Base tables stored on the tenant's assigned Base shard)
- Signals, attempt budgets, and Session epochs
- Tool receipts (retained until the Response tape records the completed round)
- AIGateway conversations and messages
- Agent documents and enabled capabilities
- Mirrored provider messages and outbound provider delivery intents
- Background Agent Job state

Each Agent owns one Worker provisioned, started, and stopped by the control
plane (see [AgentWorkers](AgentWorkers.md)). The Worker executes Agent code
against a persistent Agent Home mounted at `/workspace` (which survives Worker
instance replacement) plus a rebuildable local cache at `/var/cache/ankole`,
while published files live in the control-plane drive (see [Files](Files.md)).
Workers never enforce PostgreSQL invariants or commit business rows directly:
they call control-plane RPCs to read or mutate Ankole data, and the control
plane calls worker-file RPCs to copy bytes between a drive and that Worker's
local disk.

## One Phoenix Channel per Worker

RuntimeFabric maintains one WebSocket per Worker, terminated by a Phoenix
Channel on the control plane:

- `AnkoleWeb.RuntimeFabricSocket` listens at `/runtime-fabric/worker`.
- Each Worker joins topic `worker`, where socket authentication binds the Agent
  and tenant.
- That Channel process addresses the live Worker connection, and PostgreSQL
  stores its `connection_id` as the Worker's `transport_route`.

Every Worker connection carries three distinct identifiers:

| Identity | Owner | Changes when |
| --- | --- | --- |
| `worker_id` | the Agent UID of the Worker | never |
| `incarnation_id` | worker process | the worker process restarts |
| `connection_id` | control plane | the WebSocket reconnects |

The generation credential proves ownership of `worker_id` (see
[Authenticate a Worker](#authenticate-a-worker)); provisioning a new Worker
generation boots a fresh instance over the same persistent `/workspace` while
keeping `worker_id` unchanged.

Actor and RPC frames serialize as binary Protobuf envelopes sent directly in
WebSocket binary frames, with no JSON or Base64 wrapper. Two envelope fields
belong strictly to the transport layer:

- `stream` selects the logical lane (`STREAM_CONTROL`, `STREAM_DURABLE`, or
  `STREAM_TELEMETRY`); it must match both the Phoenix channel event name and the
  permitted body types for that lane.
- `transport_seq` numbers messages monotonically per `(connection, stream)`
  starting at `1` and advancing by `1` for each accepted frame. When the control
  plane rejects a frame (`flow_control`, `wrong_stream`, `bad_sequence`, or
  `invalid_envelope`), `transport_seq` does not advance, so the Worker resends
  with the same sequence number; a `bad_sequence` rejection includes `expected`
  naming the sequence number that the control plane expects next.

### Worker-to-control-plane traffic

Workers push envelopes on three Phoenix channel events—each named after its
stream and carrying a single envelope:

| Event | Bodies | Reply |
| --- | --- | --- |
| `control` | `worker_heartbeat`, `control_shutdown` | after the admission handler returns |
| `durable` | `workspace_ready`, `tool_status`, `tool_progress`, `tool_result`, `turn_accepted`, `worker_progress`, RPC requests, RPC responses, RPC errors | environment messages after Driver handoff; Job messages after the persisted attempt check; RPC requests after task start, and RPC responses after their handler returns |
| `telemetry` | `observability.spans.export` requests | after the request enters the bounded telemetry window |

Environment tool messages forward straight into the Driver mailbox without a
second query for open inputs inside the Channel: the Driver verifies its `Fence`
before writing durable state, so any message arriving after input closure is
harmlessly rejected. Codex Job acceptance and progress frames verify the
persisted attempt before handoff. Note that a transport `ok` confirms only this
process handoff, not a subsequent Driver database commit.

The Channel answers every push with `ok` or `error`, attaching cumulative
acknowledgement and remaining flow-control credit even on rejections:

```text
stream          control | durable | telemetry
acked_seq       highest sequence with no incomplete message below it
message_credit  messages the control plane can still accept on this stream
byte_credit     bytes the control plane can still accept on this stream
reason          only on error
```

Phoenix's per-push reply reference pairs each `ok` or `error` with the push that
sent it, and only that direct reply settles the push's outcome. Because a later
cumulative `acked_seq` can advance past a rejected sequence number, the Worker
uses `acked_seq` solely to update stream accounting and window credit rather
than treating it as success for an earlier push. Reply callbacks from an older
socket never settle pushes on a new socket, while `message_id` and RPC
`request_id` serve as end-to-end business and idempotency keys.

### Control-plane-to-worker traffic and routing

Control-plane pushes to a Worker use two channel events sharing a single
per-connection `transport_seq` on `STREAM_DURABLE`:

| Event | Bodies |
| --- | --- |
| `command` | `workspace_open`, `workspace_close`, `tool_call`, `tool_cancel`, `turn_start`, `mailbox_updated`, `turn_control`, RPC requests |
| `reply` | RPC responses and errors |

As the Worker admits pushes into its inbound queue, it sends cumulative `ack`
events back to the Channel:

```text
acked_seq       highest sequence the worker accepted, cumulative
message_credit  commands the worker can still take
byte_credit     bytes the worker can still take
```

Each `ack` resolves every awaiting caller whose `transport_seq` is at or below
`acked_seq`. In-flight unacknowledged commands on a connection are capped by
both the control-plane limit and the Worker's most recent credit; exceeding
either cap returns `{:error, :backpressure}`.

`Ankole.AgentWorkers.WorkerRoute` is the sole module that sends frames to a
Worker, backed by `Ankole.AgentWorkers.WorkerTracker` (`Phoenix.Tracker`):

- Each Worker has its own tracker topic `worker/<worker_id>` (authentication
  loads the Worker row across tenants and hands its tenant to the Channel),
  sharded across `pool_size` tracker shards via `phash2(topic, pool_size)`; no
  scheduling code ever lists a full topic.
- Each entry is keyed by `connection_id`, carries `incarnation_id` in metadata,
  and supplies the Channel PID and Erlang node, while heartbeat, load, and
  capacity live on the PostgreSQL `agent_workers` row.

Callers read the target route from `agent_workers` at send time—conversation
inputs never persist a Worker route, so a reconnected Worker is addressed on its
live connection—and `WorkerRoute` executes five steps:

1. Looks up `(topic, route)` via `Phoenix.Tracker.get_by_key/3`.
2. Compares the tracker entry's `connection_id` and `incarnation_id` against the
   PostgreSQL route fence, returning `{:error, :stale_route}` on any mismatch.
3. Calls the Channel process directly (crossing Distributed Erlang when hosted
   on another control-plane Pod; Worker commands never use PubSub broadcast).
4. Waits for the Worker's cumulative `ack`.
5. Treats a missing tracker entry, stale entry, or timed-out `ack` as failing
   only this send attempt.

`send_mandatory/2` returns `{:ok, :sent_or_queued}` once the Worker acknowledges
the frame, or one of five error tuples: `{:error, :unknown_route}` (no Channel
owns the route, or the Channel died mid-call without retrying),
`{:error, :stale_route}` (route fence mismatch), `{:error, :backpressure}`
(unacknowledged window full), `{:error, :timeout}` (`ack` deadline elapsed), or
`{:error, :socket_closed}` (socket closed first). RPC requests and replies
follow the identical rule. Only `:unknown_route` and `:socket_closed` prove that
the connection is gone and mark the Worker `stale`; meanwhile, the Session
Driver retains its pending tool call to probe on the next usable route, and the
Job owner retains its active attempt for adoption. Because `Phoenix.Tracker` is
eventually consistent, it can briefly point to a closed connection, which fails
at most one send—PostgreSQL row locks, `incarnation_id`, the route fence, and
`ack` timeouts guarantee correctness.

## Bounded Windows

Both endpoints enforce per-stream message and byte windows:

| Stream | Control plane accepts in flight | Worker keeps in flight |
| --- | --- | --- |
| `control` | 32 messages, 4 MiB | 8 messages, 1 MiB |
| `durable` | 256 messages, 64 MiB | 64 messages, 16 MiB |
| `telemetry` | 64 messages, 16 MiB | 16 messages, 4 MiB |

If an incoming push would overflow the control-plane window, the Channel replies
with `flow_control` alongside updated credits so the Worker paces sends within
its last advertised grant: the Worker backs off and resends `control` or
`durable` frames under the same `transport_seq`, whereas if its local
`telemetry` window fills up, it drops the span export, logs the drop, and leaves
`control` and `durable` unblocked. Dropping telemetry never affects turn
correctness, and RuntimeFabric provides no durable telemetry spool.

Outbound `command` lanes allow up to `64` unacknowledged commands per
connection, and a single WebSocket binary frame caps at `16 MiB`. If a Channel
process mailbox exceeds `10,000` messages, the Channel closes the socket so the
Worker reconnects and recovers from the PostgreSQL AIGateway Response tape,
receipts, and Job state. Before assigning a `transport_seq` or writing to the
socket, the Worker reserves `1,025` bytes for the Phoenix binary frame header
and rejects oversized envelopes locally with `frame_too_large` so callers can
chunk the request or use the WorkerFiles HTTP relay.

## Reconnect and Restart

When a socket drops, the Worker's Phoenix client reconnects with capped
exponential backoff and rejoins `worker`. Because the join payload carries the
Worker's ready capacity fields, every join acts as a full admission, and the
Worker opens its outbound send windows only after `join/3` succeeds.

Reconnecting from the same live Worker process keeps `incarnation_id` while
assigning a new `connection_id`: `join/3` updates `agent_workers` to the new
route and closes the superseded socket without disturbing turn fences. When the
superseded Channel process exits afterward, it leaves the Worker `ready` because
`agent_workers` already points to the new `connection_id`. Before failing
in-flight RPC calls from the closed socket, the Worker first dispatches any
replies already buffered in its receive queue; unsent requests still waiting in
memory can ride the next join up to their original deadline, while requests
already written to the closed socket without a reply fail with `socket_closed`
(allowing callers to retry safe reads within the remaining deadline, while never
auto-retrying writes whose outcome is unknown—domain handlers enforce their own
idempotent completion and abort rules).

The Channel advances its cumulative acknowledgement only across a contiguous
prefix of completed sequence numbers. Each Worker push keeps its own business
outcome: a later cumulative acknowledgement cannot turn an earlier rejection
into success. The Worker accepts callbacks only for the current connection and
settles each pending push once, so an old callback cannot complete a new push
that reuses the sequence number after joining.

Restarting the Worker process mints a fresh `incarnation_id`, and the control
plane keeps no replay spool across process restarts:

- Unacknowledged state from the dead connection is discarded, and late frames
  from the old route fail the route fence.
- Interrupted turns recover through the standard failure and rebuild path, while
  PostgreSQL unique constraints and idempotency keys absorb duplicate durable
  commits (for example, when a transaction committed just before the socket
  dropped its `ok` reply, domain handlers remain idempotent rather than relying
  on Channel replay).

On the Worker side, the Bun transport adapter manages the Phoenix socket and
channel lifecycle, stream classification and credit windows, cumulative `ack`
replies for `command` pushes, Protobuf envelope decoding and post-decode
protocol-version checks, and graceful drain before shutdown—leaving Session
scheduling and run termination strictly to the control plane.

## Routing State

Each Agent's `agent_workers` row persists its Worker generation, credential, and
live connection state (route, `incarnation_id`, capacity, and load) in logged
PostgreSQL storage—since losing a generation credential would strand its running
Worker—without maintaining a separate RuntimeFabric delivery or activation
table.

On the control plane, `Sessions.Driver` registers one `:global` name per `(agent,
session)`, backed by the signal queue and Response tape in PostgreSQL and
serialized by `sessions.epoch`: control-plane tool transactions take a shared
Session lock while admission, round commits, and terminal commits take an
exclusive lock, preventing a superseded Driver from committing once a new
admission increments the epoch.

Workers never see `sessions.epoch`: for environment work, the Worker echoes
`RunRef` (keying tool results by `(response_id, call_id)` so results survive
Driver handoff), and for Codex Jobs, the Worker echoes `JobTurnRef` verified
against the persisted attempt by the Job owner, while `WorkerRouteAuth` confirms
that the socket belongs to the target Agent. `AgentWorkers` manages Worker
placement and slot capacity rather than Session execution state.

## Authenticate a Worker

Every Worker generation receives a fresh 32-byte random credential encoded as
`base64url`; `agent_workers` stores its SHA-256 digest for admission alongside
an encrypted copy for retrying instance creation within the same generation.

Starting a Worker container requires these environment variables:

```text
WORKER_ID=<agent_uid>
ANKOLE_WORKER_TENANT_ID=<tenant_id>
ANKOLE_WORKER_STORAGE_NAME=<tenant-qualified storage name>
ANKOLE_RUNTIME_FABRIC_ENDPOINT=ws://control-plane:4000/runtime-fabric/worker
ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=<credential of this generation>
ANKOLE_WORKER_STORAGE=<mounted | nfs | adapter>
```

`ANKOLE_WORKER_STORAGE` tells the image entrypoint how to mount or restore
`/workspace` before starting the Worker—using a platform volume (`mounted`),
mounting `ANKOLE_WORKER_NFS_SOURCE` (`nfs`), or restoring the latest snapshot
via `ANKOLE_WORKER_ADAPTER_URL` (`adapter`). Because Agent Home is fixed at
`/workspace`, no environment variable configures its path (see
[AgentWorkers](AgentWorkers.md#worker-process)).

During WebSocket upgrade, the Worker passes its credential as the Phoenix auth
token in `Sec-WebSocket-Protocol` (never in the URL), validates the endpoint,
copies the key into process memory, and scrubs it from the environment inherited
by child processes. The credential's globally unique SHA-256 digest locates an
`agent_workers` row and its tenant. `RuntimeFabricSocket.connect/3` then checks
`worker_id` against that row's Agent UID and admits the socket only when it is
`starting`, `stale`, or `ready`—rejecting `absent`, `paused`, `draining`, or
`deleting` rows as well as credentials from superseded generations—and binds the
verified tenant, generation and `worker_id` (the Agent UID) on the socket so message
bodies never carry an Agent ID.

On channel join, the Worker sends `incarnation_id`, `max_slots`, and
`available_slots`. Under the `agent_workers` row lock, `WorkerAdmission`
re-verifies the generation, admission state (`stale_worker_generation` on an
outdated generation), and stored protocol version, then writes the route,
`incarnation_id`, capacity, and heartbeat timestamp—marking the Worker `ready`
immediately with no second ready message.

Subsequent lifecycle transitions stay ordered per Channel without a global
lifecycle dispatcher (while RPC and Actor handlers spawn supervised tasks):

- **Heartbeats** report current capacity and load, renewing `agent_workers` only
  when the row is `ready` or `draining` on the matching route and
  `incarnation_id`.
- **Graceful shutdown (`control_shutdown`)** notifies the control plane that the
  Worker process is exiting, transitioning `agent_workers` to `draining` so it
  stops accepting new workspaces or Codex Jobs while finishing in-flight work
  and receiving RPC replies.
- **Process replacement** brings a new `incarnation_id`: the control plane drops
  delayed frames from the prior route/incarnation and broadcasts the Worker
  change, Drivers probe in-flight environment calls on the new process
  (rerunning declared retry-safe calls and recording unknown unsafe calls as
  interrupted), and the Job owner recovers orphaned Codex attempts.
- **Staleness** triggers after 60 seconds without a valid heartbeat or when the
  active Channel exits: the control plane closes silent sockets, and because a
  heartbeat alone cannot promote a `stale` row back to `ready`, a live Worker
  must reconnect and pass `join/3` again.

This handshake authenticates trusted first-party Workers (with ingress handling
`wss://` TLS termination in front of the control plane and database turn fences
still guarding every write); Ankole does not admit untrusted third-party
workers.

## Encode and Check Actor and RPC Messages

`app/kernel/proto/ankole/runtime_fabric/v1/envelope.proto` defines the wire
envelope and protocol version under package `ankole.runtime_fabric.v1`. On the
control plane, `Ankole.RuntimeFabric` implements the Protox codec and version
checks; on the Worker, `protobuf-es` bindings are generated via
`bun run gen:proto` (the Rust kernel does not touch RuntimeFabric envelopes).
Every outbound envelope stamps the current protocol version enum, and receivers
reject any other version.

While the transport fills in `message_id`, `transport_seq`, `stream`, and `body`
and the authenticated socket supplies Agent identity, domain handlers verify
`RunRef`, `JobTurnRef`, RPC scope, and tool call IDs against PostgreSQL fences
and unique constraints:

- `worker_progress` carries `JobTurnRef` as an attempt keepalive.
- RPC calls correlate via `request_id`, with a dedicated Protobuf message per
  method whose broker verifies execution authority before reading business
  fields; remaining `*_json` byte fields carry UTF-8 JSON (empty bytes mean
  absent).
- Cross-language golden fixtures under `app/kernel/proto/golden` verify
  byte-for-byte Elixir and TypeScript codec agreement across typed and JSON RPC
  payloads, while domain suites test business authorization.
- Frozen Codex model-binding headers use unpadded `base64url` UTF-8 JSON pinned
  by `app/kernel/proto/ankole/runtime_fabric/v1/codex_model_binding_vectors.json`
  (covering nested Provider options, image fallback, hosted Brain operations,
  Unicode, and routing selector fields).

## Execute Environment Tools and Codex Jobs

The control plane drives the main Agent loop and Workflow task loops directly,
requesting a Worker only when a turn invokes an environment tool, whereas Codex
Jobs execute on the Worker's local Codex `app-server`. Worker slot accounting
counts open workspaces plus active Codex attempts (multiple concurrent tool
calls inside one workspace share its single slot), reported on `join/3`, on
periodic heartbeats, and immediately whenever slot usage changes.

### Open a Workspace

`workspace_open` sends `RunRef` (`session_id` and `signal_id`), the
PostgreSQL-assigned numeric workspace ID, resolved Agent context, Binding,
trusted runtime environment, `FetchRuntimeConfig`, and inactivity timeout. The
workspace ID maps to `/workspace/sessions/<workspace-id>`—stable across turns
for one `(agent, session)`. Upon receipt, the Worker materializes `SOUL`,
`MISSION`, `DESIGN`, `ConfidentialityPolicy`, and enabled Skills (using the
exact real Skill paths pre-resolved on the control plane by `WorkerBootstrap`;
reading a Skill alone never requires a Worker) and replies with
`workspace_ready` (or an error if setup fails; duplicate `workspace_open` frames
for the same run adopt the open workspace).

If a recovered tool receipt completes a pending tool batch before an in-flight
`workspace_open` finishes, the Driver cancels that batch's workspace acquisition
tasks and timers together and resets acquisition state to `{:idle, :requested}`
so a subsequent batch can still open the workspace and turn finalization closes
that exact Signal's workspace. Already-ready workspaces and terminal acquisition
failures stay cached for the remainder of the run, and turns that never invoke
an environment tool send zero Worker frames.

### Run and Recover a Tool Call

Control-plane tools commit their domain writes and tool receipts atomically:

1. `Tool.prepare_in_tx/3` acquires domain Principal, capacity, parent, and child
   locks—optionally inserting a not-yet-visible child work identity without
   emitting a Signal—and returns the participating Session keys plus a commit
   callback.
2. `Receipts` locks all source and target Sessions in sorted order, acquires the
   shared workspace fence, verifies `sessions.epoch`, and invokes the commit
   callback so domain mutations, dispatch Signals, and the receipt commit
   together (rolling back both preparation and commit if `sessions.epoch` is
   stale, and running post-commit hooks only after commit).
3. When recovering an interrupted round, the Driver replays committed receipts
   onto the Response tape (or resumes committed waits from their original start
   timestamps) without re-validating against current tool schemas, executing
   only calls that lack a receipt and purging the round's receipts once the full
   round records to the tape.

For environment tools, `tool_call` carries the run reference, `response_id`,
`call_id`, `namespace`, tool name, arguments, and mode (`execute` or `probe`).
The Worker deduplicates calls in memory by `(response_id, call_id)`: duplicate
`execute` frames attach to the in-flight execution or return its cached
`tool_result` without re-running the tool, while `probe` replies `unknown` via
`tool_status` if unrecognized, waits if still running, or returns the cached
`tool_result` (`content_json` text parts, raw `images` bytes converted by the
control plane for the model provider, structured details, and error flags, with
live updates streamed via `tool_progress`). Because these call entries live only
in Worker process memory, if the Worker process restarts, the Driver re-executes
only tools declared retry-safe and records an interrupted error for unknown
unsafe calls.

`tool_cancel` aborts a specific call, and `workspace_close` blocks new calls,
drains running calls and outbound result pushes, and frees the workspace slot.
During Driver takeover or planned control-plane shutdown, the outgoing Driver
omits `workspace_close` so the replacement Driver can adopt work still running
on the Worker.

### Start or Adopt a Codex Attempt

`turn_start` applies exclusively to Codex Jobs, carrying one Signal,
`JobTurnRef` (`signal_id`, `job_id`, and `attempt`, while the socket supplies
the Agent and `job_id` identifies the Session and project directory), the model
snapshot, request context, typed `HostedTool` definitions, trusted runtime
environment, and `FetchRuntimeConfig`:

- **`start` mode**: Also carries `AgentConversationContext` (resolved on the
  control plane outside the claim transaction, while the claim freezes the Job
  runtime projection that selects eligible Skills from that context) and launches
  the claimed attempt.
- **`adopt` mode**: Omits `AgentConversationContext` and reattaches to the
  existing local attempt without re-running preparation or starting a second
  Codex turn; if no matching local attempt exists, the Worker aborts the attempt
  so the Job owner can apply its retry policy.

Upon registering the attempt, the Worker sends `turn_accepted`—which confirms
presence without consuming input—and waits to start Codex execution until the
control plane confirms that acceptance. If the confirmation drops across a
disconnect, the same local attempt waits for rejoin and re-sends acceptance
from a single background task while keeping the receive loop responsive to stop,
drain, and generation updates (duplicate `turn_start` commands never spawn a
second execution).

Follow-up inputs arrive in queue order via `mailbox_updated`. The Worker tracks
which Signal IDs Codex actually consumed and returns them in the terminal
`background_agent_job.status.update` RPC so the Job terminal transaction closes
only the trigger Signal and applied follow-ups, leaving later arrivals open for
the next attempt. `turn_control` interrupts an active attempt or withdraws a
Skill, while failed Worker attempts call `session_turn.abort`. Because both
completion and abort key off the Job's own attempt identity (with idempotent
terminal writes at the Job owner), a Driver handoff cannot reject a
still-running Codex result.

### Trusted Runtime Environment

For each execution, the control plane derives `ANKOLE_RUNTIME_*` variables from
the active Signal—distinct from operator-configured WorkerEnv variables. When an
active Human initiates the Signal, the control plane populates the requester
Principal UID, `access_version`, and derived Lark profile (`ankole-u-<base64url
HMAC-SHA256>`, keyed with the control-plane-only secret
`runtime_fabric.worker_auth_key` over `uid` for `access_version == 1`, or
`uid <> <<0>> <> access_version` for higher versions; rotating that key changes
every profile and requires users to re-authorize Lark). Scheduled and
system-originated Signals omit Human requester variables.

Worker authentication keys never enter shell or Codex environments, and the
Worker blocks per-command overrides in the `ANKOLE_RUNTIME_` namespace. Because
user shell commands can still mutate their own process environment afterward,
downstream consumers must validate any environment value that they read.

### Refresh the Lark Bot Credential

When a turn or Job needs a Lark tenant access token, the Lark adapter fetches
one from the control-plane token manager—requiring at least ten minutes of safe
remaining validity—and returns it solely over the trusted `worker_env.resolve`
RPC. That request includes the active Signal Binding name so the control plane
selects the matching Lark app (an Agent with a single Lark Binding resolves it
implicitly, whereas an Agent with multiple Lark Bindings receives no Lark
credential variables when no Binding matches).

Agent Computer strips the raw token before constructing any shell or Codex
thread environment. Instead, for each open workspace, Background Agent Job
attempt, or Automation Job attempt that receives a Lark bot token, Agent
Computer writes a private file inside Agent Home via atomic rename, refreshes it
every minute through `worker_env.resolve`, and stops refresh and deletes the
file during cleanup. If the Binding switches to a different Lark app or domain
mid-execution, Agent Computer deletes the token file and requires a fresh
execution rather than mixing the old app identity with a new token.

Child environments receive only `ANKOLE_RUNTIME_LARK_TENANT_ACCESS_TOKEN_FILE`.
On every invocation, the Worker's `lark-cli` wrapper reads that file, rejects it
if unrefreshed for more than five minutes—failing locally with
`authentication/credential_unavailable` rather than sending a stale token—and
passes the token only to the short-lived official CLI subprocess. Throughout,
the control plane remains the sole credential owner: the file is a disposable
runtime projection, not a new secret store or authorization subject.

## Call Functions in Another Process

Peer RPC calls travel in `rpc_request`, `rpc_response`, and `rpc_error`
envelopes correlated by `request_id`.

`app/kernel/proto/ankole/runtime_fabric/v1/rpc.proto` defines the Protobuf
messages, while the Bun `rpcOperations` table is the single source of truth for
method names, authorization scopes, turn effects (read, write, or complete),
request/response message pairs, and Worker handlers. Running
`gen-rpc-contract.ts` projects those definitions into the committed
`rpc_methods.json` parity artifact (not a third runtime registry). Elixir
generates its authorization metadata and message modules from `rpc_methods.json`,
keeping the method-to-broker dispatch in a runtime function so codec compilation
stays decoupled from domain brokers while compile-time checks and integration
tests verify 100% method coverage, exported broker functions, and strict
response-struct types (accepting a bare Elixir map only when the declared
response type is `JSONPassthroughResponse`).

Outer RPC frames carry execution authority outside the business payload (and
payloads never duplicate Agent IDs or `request_id`):

- **`turn`-scoped methods** carry one `RunRef` or `JobTurnRef`.
- **`turn_or_automation`-scoped methods** carry one `RunRef`, `JobTurnRef`, or
  `AutomationAttemptRef` (`{automation_job_id, automation_job_run_id,
  attempt_id}`).
- **`worker_agent`-scoped methods** carry no execution ref, taking the Agent UID
  directly from the authenticated socket's `worker_id`.

The control plane authorizes the outer frame before decoding the business
payload: Job lifecycle methods require `JobTurnRef` (allowing idempotent
terminal retries for the same attempt even after input closure), while ordinary
run methods require an open input.

Registered RPC families cover:

- Codex attempt abort and terminal Background Agent Job status/trajectory
  (Codex thread files stay in persistent Agent Home; see
  [Background Agent Job](BackgroundAgentJob.md#persistent-thread-files))
- AIGateway API key resolution and WorkerEnv resolution
- Agent drive files: `files.list`, `files.get`, and `files.commit` (see
  [Files](Files.md))
- Pod content and Base operations: `pod.read` and `pod.write` under turn or
  Automation attempt authority (see [Pod Content Model](PodContentModel.md))
- Automation job management, execution, and event emission
- Webhook endpoint creation, listing, and cancellation
- Worker observability span export and best-effort Codex diagnostic log
  maintenance
- Skill overlay resolution (`skills.overlay.resolve`), returning the rendered
  block of Skill lessons for a Skill set

Main-Agent control-plane tools call domain modules directly in Elixir without
hopping through a Worker RPC for schedules, channel policy, Workflows, or Job
management, and AIGateway owns conversation history and compaction directly
rather than exposing them over RuntimeFabric RPC.

Every `rpc_error` includes an explicit `retryable` boolean and diagnostic
`details_json`:

- Domain validation and authorization errors default to `retryable = false`
  (unexpected Ash errors return a generic message, and authorization denials
  return access denied).
- If a control-plane handler crashes or returns an invalid struct, `rpc_error`
  attaches a `failure_id` matching the control-plane log (which records the
  exception class and stack locations without leaking exception text or function
  arguments).
- Only read methods and the idempotent Job Turn checkpoint upsert mark handler
  crashes retryable; writes, completions, and other worker-agent mutations stay
  non-retryable because the control plane cannot prove they had no side effects.
  Agent Computer preserves `code`, `retryable`, `details_json`, and `failure_id`
  into Actor and Background Agent Job recovery.

Worker-initiated RPCs use a 300-second deadline, whereas control-plane-initiated
Automation Job execution RPCs use a 10-minute deadline plus a short transport
margin. In Job retry accounting, the Worker maps transport push timeouts to
`runtime_fabric_timeout` and RPC deadlines to `runtime_rpc_timeout`; only those
two codes and `socket_closed` count as infrastructure interruptions (ordinary
`timeout` values or retryable domain errors do not).

## Worker Files

To transfer file bytes between a control-plane drive and a Worker's `/workspace`
without sending bytes over the WebSocket, the control plane invokes two
Worker-hosted RPCs declared in `rpc.proto` (carrying no turn fence because the
control plane itself is the caller):

- **`worker_files.pull`**: Instructs the Worker to `GET` bytes from a one-time
  relay URL and write one file at `home_relative_path`.
- **`worker_files.push`**: Instructs the Worker to `PUT` one file—or, when
  `bundle_paths` is set, a multi-file binary bundle rooted at
  `home_relative_path` (encoding each file in requested order as a 4-byte
  big-endian UTF-8 path length, the relative path, an 8-byte big-endian byte
  length, and raw file bytes)—to a one-time relay URL. For a single file,
  a positive `prefix_bytes` requests at most that many bytes from offset zero;
  zero requests the whole file. `max_bytes` bounds the bytes transferred in
  either mode, and the response reports the transferred byte count.

Higher-level drive RPCs ([Files](Files.md)) build on these primitives:
`files.get` reads a private path or an authorized Drive node onto the calling Worker's disk, and
`files.commit` pushes files from that same Worker's disk. Every request
specifies `home_relative_path` relative to `/workspace` without repeating the
Agent UID (for example, `sessions/10000/drive/inbox/0123456789abcdef/file.png`);
the Worker rejects paths that escape `/workspace` and returns the transferred
byte count (`size`).

`Ankole.WorkerFiles` defaults to `100 MiB` per file or bundle. Drive and Pod
file uploads supply the configured object backend's bound; downloads supply the
stored object's byte size. Document XML and other callers retain the default.
Oversized pulls fail on the control plane before sending the RPC,
oversized pushes fail on the Worker before uploading (and the HTTP relay also
rejects bodies above `max_bytes` with HTTP `413`), and out-of-order or
mismatched bundle paths fail validation on the control plane. Cross-runtime
recovery branches on `rpc_error.code` (treating the error message as diagnostic
text only):

- `file_not_found`: source path does not exist.
- `not_regular_file`: source path is not a regular file.
- `file_changed`: the file mutated during upload, or a bundled file's size
  changed while streaming the bundle (the control plane discards the uploaded
  bytes).
- `file_too_large`: source exceeds `max_bytes`.
- `relay_failed`: the HTTP relay returned a non-2xx status or failed at the
  network layer.
- `operation_failed`: any other local error.

## Transfer Files Safely

Each HTTP relay transfer streams chunks between the caller and the Worker.
Drive uploads feed the native object writer directly; PostgreSQL, WebDAV and D1
object backends buffer whole objects natively and enforce their smaller bounds
(see [Files](Files.md#byte-writes-reads-and-collection)):

1. The control-plane Pod handling the drive RPC opens a supervised, short-lived
   in-memory relay session identified by a random `transfer_id` and 32-byte
   random `token`.
2. That Pod sends `worker_files.pull` or `worker_files.push` pointing to its own
   direct Pod origin:
   ```text
   <internal origin>/internal/runtime-fabric/file-relay/<transfer_id>?token=<token>
   ```
3. The Worker issues a single `GET` (pull) or `PUT` (push) to that URL inside
   the cluster network (uncompressed, bounded-chunk HTTP).
4. The relay streams bounded chunks between the control plane's local file and
   the HTTP socket without buffering the full payload.
5. Once the Worker replies to the RPC with the final `size`, the control plane
   completes the enclosing drive RPC.

Because the relay session lives only in the issuing Pod's memory,
`<internal origin>` must address that specific Pod rather than a load-balanced
Service—configured via `ANKOLE_RUNTIME_FABRIC_INTERNAL_ORIGIN`, or derived as
`http://<POD_IP>:<PORT>` from the Kubernetes Downward API when unset—and the
Pod verifies `token` against its in-memory copy for one request and one HTTP
method (redacting the bearer URL from logs on both runtimes and filtering
`token` in Phoenix). The Phoenix endpoint routes this exact relay path ahead of
browser Host checks, body parsers, and session plugs, while leaving normal Host
policy in place for browser pages and APIs. If the relay Pod, Worker, or drive
RPC fails—or if the idle timeout fires—both sides discard state with no partial
resume, and the caller retries from scratch.

On the Worker filesystem, path checks block `..` traversal and symlinks escaping
`/workspace`. Pulls stream into `/tmp/ankole-file-transfer/<transfer-id>/` first
and move into place via atomic rename; pushes open a single file descriptor,
snapshot file identity and byte length before uploading, and return
`file_changed` if the file differs afterward. Once the RPC returns, the Worker
retains zero transfer metadata—the file lives on `/workspace` and PostgreSQL
records how Ankole references it.

## Move Attachments without an Agent Turn

Saving or delivering message attachments needs neither an Actor turn nor a
running Worker—for example, a messaging adapter can persist an inbound
attachment even when the message does not wake an Agent:

- **Inbound attachments**: the adapter observes a pending provider identity,
  streams bytes into a tenant object, then persists the completed object and
  Message attachment relation. The conversation root can hold a node referring
  to the same object. Retry identity is a provider/Message identity, not a hash.
- **Outbound attachments**: `reply_attachment` accepts a Drive `node_id`. The
  control plane checks the executing Agent's node view permission and captures
  the current object. Terminal commit creates Delivery attachment relations;
  pending, failed and unknown outcomes retain those references. Provider
  confirmation transfers the hold to Message attachment rows in the same
  transaction. Later rename, overwrite or deletion of the node does not change
  the sent bytes. File paths do not confer authority or restrict destinations.

Completed hosted image generation uses the same ownership: conversation files
belong to its root, and images without a conversation belong to the Agent's
private root. Model context names a frozen attachment by conversation ID,
Message ID and position, using `ankole-pod chat attachment get`. Pod-managed resources use the Pod
file RPC, while shared Drive files use `files.get` with `node_id`.

## Keep Agent Skills in Sync

Agent Plugins and Skills merge filesystem packages with PostgreSQL enablement
state:

- **Filesystem and drive sync**: Built-in packages ship in the container image,
  while Agent-installed Skills live under `skills/` in the Agent's drive. The
  control plane reads all manifests from `Ankole.Files` to sync the catalog
  (leaving the catalog untouched if a read fails and preserving operator
  enablement overrides across manifest updates). Ahead of each turn or
  Automation Job attempt, the Worker syncs its `/workspace` `installed-skills`
  cache from `skills/`—aborting setup if a download fails (see [Files](Files.md))—without
  mutating the control-plane catalog.
- **Skill lesson overlays**: Workers batch-fetch per-Agent Skill lessons via
  `skills.overlay.resolve`, which synchronizes the Agent registry once, reads
  Skill and lesson rows as sets, and returns exactly one rendered lesson block
  per unique requested Skill name (Dreaming and the Console own all lesson
  writes; see `docs/design-docs/SkillLessons.md`, and `skill_view` merges
  `SKILL.md` with PostgreSQL lessons on the control plane). If any requested
  name is missing, disabled, invalid, or duplicated, the control plane rejects
  the whole request; likewise, if a response is partial, duplicated, or
  unexpected, the Worker aborts setup rather than materializing an inconsistent
  snapshot.
- **Plugin catalog**: RuntimeFabric includes only Agent Plugins enabled for the
  target Agent, and each Codex Job resolves that catalog and its
  Background-eligible member Skills fresh on every prepare (see
  [Plugins](Plugins.md)).

## Deploy Matching Control-Plane and Worker Images

`.github/workflows/runtime-images.yml` builds and publishes immutable
multi-platform control-plane and Worker images from the exact same 40-character
Git SHA, verifying release revision, protocol version, and architecture labels
and emitting a digest-pinned image-pair artifact.

Deployments roll out the control plane configured with
`ANKOLE_AGENT_COMPUTER_IMAGE` pinned to the matching Worker image digest.
`AgentWorkers` immediately replaces any Worker whose RuntimeFabric protocol
version differs from the control plane, and replaces Workers whose image digest
or provider template changed once they go idle (see
[AgentWorkers](AgentWorkers.md)).

In Kubernetes, each control-plane Pod runs as a named Erlang node clustered via
`DNSCluster` over a headless Service with a shared release cookie and a fixed
distribution port (so `NetworkPolicy` restricts Erlang distribution strictly to
control-plane Pods—Distributed Erlang provides process routing only, never
single-writer durability). Workers never touch Erlang distribution ports: they
connect to the `ClusterIP` Service for WebSocket channels and directly to the
issuing Pod IP for HTTP file relays. On graceful Pod termination, the Pod leaves
the Service endpoints before closing its Channels so reconnecting Workers land
on surviving Pods, where Drivers rebuild from PostgreSQL and adopt in-flight
Worker tool calls and Codex attempts.

Finally, the Elixir release boots ERTS with a `65,536` port cap so high
container `ulimit -n` settings do not pre-allocate a massive Erlang port table
at startup; operators can raise this cap via `ERL_FLAGS` (for example,
`+Q 1048576`).

## What RuntimeFabric Does Not Do

RuntimeFabric is intentionally *not*:

- A durable message queue or replay spool
- A general-purpose message broker
- A multi-socket-per-lane connection pool
- A control-plane NFS mount or S3-compatible object store
- An in-band WebSocket file-chunking protocol
- A conversation-history RPC service
- A second database where Workers commit domain records directly
