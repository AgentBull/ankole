# RuntimeFabric

RuntimeFabric connects the Elixir control plane to Agent Computer workers.
It carries live messages but does not store them. PostgreSQL stores any data
that Ankole needs after a restart.

The connection carries two groups of messages:

- Execution messages open workspaces, run environment tools, and control Codex Jobs.
- RPC messages ask another process to read or change Ankole data.

Both groups use the same worker connection and authentication. File bytes do
not travel on this connection. A worker-file operation is a control-plane RPC
to the worker, and the worker moves the bytes over HTTP with a one-time relay
URL (see "Worker Files").

## Which Process Stores What

The control plane stores:

- Signals, attempt budgets, and Session epochs
- Tool receipts until the Response tape records their results
- AIGateway conversations and messages
- Agent documents and enabled capabilities
- copies of provider messages and provider intent rows
- Background Agent Job state

Each Agent has one Worker, which the control plane creates, starts, and stops
(see [AgentWorkers](AgentWorkers.md)). A Worker runs the Agent's code on its
own persistent Home at `/workspace`. That storage survives instance deletion;
the separate cache at `/var/cache/ankole` can be rebuilt. The control-plane
drive stores published files (see [Files](Files.md)). Workers do not define
PostgreSQL rules or commit business records.

Workers use RPC when they need to read or change stored Ankole data. The control
plane uses the worker-file RPC methods to move bytes between a drive and the
disk of the Worker that needs them.

## One Phoenix Channel per Worker

RuntimeFabric uses one WebSocket connection per worker, carried by a Phoenix
Channel on the control plane.

- The control plane serves `AnkoleWeb.RuntimeFabricSocket` at
  `/runtime-fabric/worker`.
- Each Worker joins the topic `worker`. Authentication supplies the Agent
  and tenant.
- The channel process is the address of the worker connection. Its
  `connection_id` is the `transport_route` that PostgreSQL stores.

Every connection has three identities:

| Identity | Owner | Changes when |
| --- | --- | --- |
| `worker_id` | the Agent UID of the Worker | never |
| `incarnation_id` | worker process | the worker process restarts |
| `connection_id` | control plane | the WebSocket reconnects |

The credential of the current generation proves the `worker_id` (see
"Authenticate a Worker"). A new generation is a new instance on the same persistent
Agent Home; it keeps the `worker_id`.

Actor and RPC messages use Protobuf. The WebSocket carries the envelope bytes
as binary frames. There is no JSON or Base64 wrapper.

Two envelope fields belong to this transport:

- `stream` names the logical stream (`STREAM_CONTROL`, `STREAM_DURABLE`,
  `STREAM_TELEMETRY`). It must equal the channel event that carries the
  envelope, and the body type must belong to that stream.
- `transport_seq` is the sequence number inside one stream on one
  connection. It starts at 1 and increases by one for each accepted message.
  A rejected message (`flow_control`, `wrong_stream`, `bad_sequence`,
  `invalid_envelope`) does not advance the sequence; the worker repeats it
  with the same number. A `bad_sequence` reply carries `expected`, the
  number the control plane waits for.

Worker-to-control-plane traffic uses three channel events. The event name is
the stream; the payload is one envelope:

| Event | Bodies | Reply |
| --- | --- | --- |
| `control` | `worker_heartbeat`, `control_shutdown` | after the admission handler returns |
| `durable` | `workspace_ready`, `tool_status`, `tool_progress`, `tool_result`, `turn_accepted`, `worker_progress`, RPC requests, RPC responses, RPC errors | environment messages after Driver handoff; Job messages after the persisted attempt check; RPC requests after task start, and RPC responses after their handler returns |
| `telemetry` | `observability.spans.export` requests | after the request enters the bounded telemetry window |

Environment messages enter the Driver mailbox without a second open-input
query in the Channel. The Driver checks `Fence` when it writes durable facts.
A message that arrives after input closure cannot change those facts. Job
acceptance and progress still check the persisted attempt before handoff.
Transport acknowledgement confirms this handoff; it does not confirm a later
Driver commit.

The channel answers each event with `ok` or `error`. Every reply, including
a rejection, carries the stream's cumulative acknowledgement and its
remaining credit:

```text
stream          control | durable | telemetry
acked_seq       highest sequence with no incomplete message below it
message_credit  messages the control plane can still accept on this stream
byte_credit     bytes the control plane can still accept on this stream
reason          only on error
```

The Phoenix reply reference correlates each `ok` or `error` with its push.
Only that reply confirms the push result. A later cumulative `acked_seq` can
include a rejected message, so it updates stream accounting and credit without
confirming another push's success. Callbacks from an old connection cannot
settle pushes on a new connection. `message_id` and the RPC `request_id` remain
the business keys and the idempotency keys.

Control-plane-to-worker traffic uses two events:

| Event | Bodies |
| --- | --- |
| `command` | `workspace_open`, `workspace_close`, `tool_call`, `tool_cancel`, `turn_start`, `mailbox_updated`, `turn_control`, RPC requests |
| `reply` | RPC responses and errors |

Both events share one `transport_seq` per connection with `stream` set to
`STREAM_DURABLE`. The worker acknowledges what it accepted into its inbound
queue with one `ack` event:

```text
acked_seq       highest sequence the worker accepted, cumulative
message_credit  commands the worker can still take
byte_credit     bytes the worker can still take
```

One acknowledgement resolves every waiting command with a sequence at or
below `acked_seq`. The unacknowledged commands on one connection stay below
both the control-plane limit and the worker's last credit; beyond that a send
is `{:error, :backpressure}`.

`Ankole.AgentWorkers.WorkerRoute` is the only module that
sends to a worker. The route directory is
`Ankole.AgentWorkers.WorkerTracker`, a `Phoenix.Tracker`:

- One tracker topic per Worker: `worker/<worker_id>`. Authentication reads the
  Worker row across tenants and gives its tenant to the Channel.
- The key is the `connection_id`.
- The metadata holds `incarnation_id`. The tracker key already holds the
  connection ID, and the tracker entry supplies the process and node.
  Heartbeat, load, and capacity stay on the Worker row.
- `pool_size` sets the number of tracker shards; per-worker topics spread over
  them with `phash2(topic, pool_size)`. No scheduling path lists a topic.

A sender reads the route from the Agent's `agent_workers` row at send time.
Conversation inputs record no Worker route. A reconnected Worker is reached
on its current connection. A send follows these steps:

1. `Phoenix.Tracker.get_by_key/3` with the worker topic and the route.
2. Compare the tracker key and its `incarnation_id` with the current
   PostgreSQL route fence. A mismatch is `{:error, :stale_route}`.
3. Call the channel process directly. A process on another node receives the
   call through Distributed Erlang. No worker command uses a PubSub broadcast.
4. Wait for the worker's cumulative acknowledgement.
5. An empty directory, a stale entry, or a missing acknowledgement fails only
   this send.

`send_mandatory/2` returns `{:ok, :sent_or_queued}` only after the worker
acknowledged the command. It returns `{:error, :unknown_route}` when no channel
owns the route, `{:error, :stale_route}` when the entry does not match the
route fence, `{:error, :backpressure}` when the connection already holds the
maximum number of unacknowledged commands, `{:error, :timeout}` when the
acknowledgement does not arrive, and `{:error, :socket_closed}` when the
connection ends first. The Driver retains the pending call and probes it on
the next usable route. The Job owner retains its current attempt for adoption.
Only `unknown_route` and `socket_closed` mean that the connection is gone;
they also mark the Worker stale.

The tracker is eventually consistent. It can name a connection that no
longer exists. That only fails one send attempt; the row locks, the
`incarnation_id`, the route fence, and the acknowledgement timeout decide
correctness.

## Bounded Windows

Each stream has a window of unacknowledged messages and bytes on both sides.

| Stream | Control plane accepts in flight | Worker keeps in flight |
| --- | --- | --- |
| `control` | 32 messages, 4 MiB | 8 messages, 1 MiB |
| `durable` | 256 messages, 64 MiB | 64 messages, 16 MiB |
| `telemetry` | 64 messages, 16 MiB | 16 messages, 4 MiB |

The control plane answers `flow_control` when a message would exceed its
window, and every reply reports the remaining message and byte credit, so the
worker sends at most what the last credit allowed. The worker waits and
repeats a `control` or `durable` message with the same sequence number. It
drops a `telemetry` message when its own window is full, records the drop,
and does not block the other streams.

A `command` connection holds at most 64 unacknowledged commands. One WebSocket
frame contains at most 16 MiB. A channel process closes its connection when its
mailbox exceeds 10,000 messages; the worker reconnects, and PostgreSQL
AIGateway Response tape, receipts, and Job facts drive recovery.

A telemetry drop does not change turn correctness. Telemetry that must not be
lost needs a durable spool; RuntimeFabric does not provide one.

## Reconnect and Restart

The Phoenix client reconnects with capped exponential backoff and joins the
channel again. The join payload carries the ready fields, so each join is an
admission. The worker opens its send windows only after the join succeeded.

A reconnect with the same `incarnation_id` receives a new `connection_id`. The
join moves the Agent's `agent_workers` row to the new route and closes the old
connection. Turn fences do not change. When the old channel process then
closes, it does not mark the worker stale, because the worker's current route
is no longer that connection.

Before it settles unanswered RPC calls from the closed connection, the Worker
delivers replies already in its receive queue. A request that has not reached
the socket can wait for the next join until its original deadline. A sent
request with no reply fails with `socket_closed`. Its owning caller can repeat
a safe read after rejoin within the same deadline. The RPC layer does not
repeat an unknown-result write; that operation may already have completed.
Domain-specific idempotent completion and abort checks keep their own retry
rules.

A worker restart creates a new `incarnation_id`. The control plane keeps no
replay spool across that restart:

- The old connection's unacknowledged state is gone.
- Messages from the old route fail the route fence.
- An unacknowledged turn follows the existing failure and rebuild path.
- A repeated durable commit is absorbed by the existing unique constraints and
  idempotency keys.

If the control plane committed a transaction but the `ok` reply was lost, the
worker can repeat the message. The domain handler must stay idempotent; the
channel does not replay.

The Bun adapter handles:

- the Phoenix socket and channel lifecycle
- stream classification and windows
- acknowledgement of `command` pushes
- decoding of generated envelopes
- protocol-version checks after decoding
- worker drain before shutdown

The adapter does not schedule Sessions or decide when a run ends.

## Routing State

The Agent's `agent_workers` row records its Worker generation and credential.
It also records the connected process's route, incarnation, capacity, and load.
These rows are logged: loss of a generation credential would disconnect its
Worker. RuntimeFabric keeps no delivery or activation table.

`Sessions.Driver` has one `:global` name per Agent and Session. PostgreSQL
stores the signal queue and Response tape. `sessions.epoch` serializes
control-plane decisions. Control-plane tool transactions hold a shared row
lock; admission, round recording, and terminal commits hold an exclusive lock.
An old Driver cannot commit after a new admission changes the epoch.

A Worker echoes a `RunRef` for environment work. It does not hold the epoch.
Results belong to their Response and call IDs and can survive Driver replacement.
A Codex Job uses `JobTurnRef`; the Job owner checks its persisted attempt.
`WorkerRouteAuth` also checks that the connection belongs to the named Agent.
AgentWorkers owns Worker placement and capacity, not Session progress.

## Authenticate a Worker

Every generation of an Agent's Worker has its own random credential, 32 random
bytes in base64url. The control plane gives it to the instance that it
creates. The Agent's `agent_workers` row keeps the SHA-256 digest of the
credential for admission and an encrypted copy for a retry of the same
generation.

Worker startup requires these values:

```text
WORKER_ID=<agent_uid>
ANKOLE_RUNTIME_FABRIC_ENDPOINT=ws://control-plane:4000/runtime-fabric/worker
ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=<credential of this generation>
ANKOLE_WORKER_STORAGE=<mounted | nfs | adapter>
```

`ANKOLE_WORKER_STORAGE` tells the image entry how it prepares the persistent
Home before it starts the Worker: the platform mounted it (`mounted`), the
entry mounts `ANKOLE_WORKER_NFS_SOURCE` (`nfs`), or the entry restores the last
backup through `ANKOLE_WORKER_ADAPTER_URL` (`adapter`). The Agent Home is always
`/workspace`, so it is not a startup value (see
[AgentWorkers](AgentWorkers.md#worker-process)).

The worker sends the credential as the Phoenix socket auth token in the
`Sec-WebSocket-Protocol` header. The credential never appears in the URL. The
socket `connect/3` callback compares its digest with the row in constant time.
Only a row that is `starting`, `stale`, or `ready` accepts a connection: a row
that is `absent`, `paused`, `draining`, or `deleting`, and the credential of a
former generation, cannot connect. The Worker validates the endpoint, copies
the credential into memory, and removes it from the environment that child
processes inherit. The socket retains the generation that passed
authentication.

`worker_id` is the Agent UID in the authenticated socket parameters. Each
new process creates a fresh `incarnation_id`. Message bodies carry no Agent
identity: both hosts use the Agent of this connection.

The join payload carries `incarnation_id`, `max_slots`, and `available_slots`.
`join/3` registers the route and calls `WorkerAdmission`: under the Worker row
lock, it checks the authenticated generation, admission state, and stored
protocol version, then writes the route, incarnation, capacity, and heartbeat
time. Join success makes the connection ready. No second ready message is sent.
A former generation fails with `stale_worker_generation`.

A heartbeat carries current capacity and load. It renews only a row that is
`ready` or `draining` on the same route and incarnation. The Channel processes
its own lifecycle writes in order; RPC and Actor operations use supervised
tasks. There is no site-wide lifecycle dispatcher process.

On process shutdown, the worker sends `control_shutdown` to the control plane.
This direction means "the worker process is shutting down." The control plane
marks the Agent's Worker as `draining`. A draining Worker accepts no new
workspace or Codex Job but can finish its work and receive RPC responses.

A new incarnation replaces the old process. The control plane rejects delayed
frames from the former route or incarnation and broadcasts the Worker change.
Drivers probe environment calls on the new process. An unknown unsafe call is
recorded as interrupted; a retry-safe call can run again. The Job owner handles
a Codex attempt whose process is gone.

A worker becomes stale after 60 seconds without a valid heartbeat, or when its
current channel process terminates. The control plane closes a silent
connection; a live process connects again and joins. A heartbeat cannot make
a stale row ready.

This protocol authenticates trusted first-party workers. Database turn fences
still protect each write. Ankole does not provide public worker admission
here. TLS termination for `wss://` belongs to the ingress in front of the
control plane.

## Encode and Check Actor and RPC Messages

`app/kernel/proto/ankole/runtime_fabric/v1/envelope.proto` declares the message
structure and current protocol version, 9. The generated package namespace
remains `ankole.runtime_fabric.v1`.

Elixir uses Protox and the Worker uses protobuf-es. Generate committed
TypeScript output with `bun run gen:proto`. Each host uses its generated enum
to set the current version on send and reject other versions on receive.
The Rust kernel does not encode or validate RuntimeFabric envelopes.

The host supplies the message ID, transport sequence, stream, and body.
The authenticated connection supplies Agent identity. Domain consumers check
Run references, Job attempts, RPC scope, and tool calls against their owning
state. Database fences and unique constraints retain commit authority.

`worker_progress` carries the Job attempt reference as a keepalive. RPC
request and reply matching uses `request_id`. Each RPC method has its own
protobuf payload; its broker checks execution authority before it applies
business fields. Host code writes UTF-8 JSON into remaining `*_json` byte
fields. Empty bytes mean that the value is absent.

Golden fixtures live under `app/kernel/proto/golden`. Elixir and TypeScript
decode the same bytes and check representative typed and JSON RPC payloads.
These fixtures verify codec agreement; domain tests verify business authority.

## Execute Environment Tools and Codex Jobs

The control plane runs the main model loop and Workflow task loops. These loops
do not request a Worker until an environment tool needs one. Codex Jobs run on
the Worker's Codex app-server.

Worker capacity counts open workspaces and running Codex attempts. Join
reports maximum and available slots. The heartbeat reports those fields plus
active slots and task load; it is also sent when capacity changes. Multiple
tool calls in one workspace use one slot.

### Open a Workspace

`workspace_open` carries a `RunRef`, the PostgreSQL-owned numeric workspace ID,
the resolved Agent context, binding, trusted runtime environment, fetch
configuration as `FetchRuntimeConfig`, and inactivity timeout. `RunRef` contains `session_id` and
`signal_id`; the authenticated connection supplies the Agent.

The workspace ID names `/workspace/sessions/<workspace-id>` and stays stable
for one Agent and Session. The Worker prepares the current environment and
writes SOUL, MISSION, DESIGN, and ConfidentialityPolicy from the current
context, prepares its Skills, then returns `workspace_ready`. Preparation
failures return an error. Repeated open
messages for the same run adopt its existing workspace.

The control plane resolves Skills and their real paths before it requests a
Worker. WorkerBootstrap owns these path declarations. The Worker uses the same
declarations when it prepares the files. A Skill read alone needs no Worker.

### Run and Recover a Tool Call

Control-plane tools commit durable effects and receipts in one transaction.
Before a recovered round dispatches calls, the Driver restores those receipts
without validating them against the current tool definitions. A committed
result returns to the tape; a committed wait resumes observation from its
original start time. Only calls without a receipt require current validation
and execution. Recording the complete round removes its receipts.

`tool_call` carries the run, `response_id`, `call_id`, namespace, tool name,
arguments, and mode `execute` or `probe`. The Worker keeps one call entry per
Response and call ID. A duplicate execute adopts a running call or returns its
retained result. It does not run the operation again.

A probe of an unknown call returns `unknown` through `tool_status`. A running
call remains pending until its result is available. A completed call returns
its retained `tool_result` directly. `content_json` carries text parts. The
`images` field carries raw image bytes, which the control plane converts for
the model provider. The result also carries details and error classification. Progress
uses `tool_progress`. These retained facts live only in the Worker process.
After process loss, the Driver reruns only a declared retry-safe tool; it writes
an interrupted result for an unknown unsafe operation.

`tool_cancel` aborts the named call. `workspace_close` prevents further calls,
waits for pending work and result sends to finish, then releases the slot.
A stale Driver sends no close during takeover or planned control-plane shutdown:
the new Driver can adopt the work still on the Worker.

### Start or Adopt a Codex Attempt

`turn_start` is only for a Codex Job. It contains one Signal, a `JobTurnRef`,
model snapshot, request context, typed `HostedTool` values, trusted environment,
and the same `FetchRuntimeConfig` as `workspace_open`. A start also carries the
resolved `AgentConversationContext`. The control plane resolves the current
context outside the claim transaction. The claim freezes the Job runtime
projection; that projection selects the Skills from the resolved context. An
adopt carries no context and does not repeat preparation. `JobTurnRef`
contains Signal ID, Job ID, and attempt. The connection supplies the Agent
and the Job ID supplies the Session. The Job owns its project directory. Mode `start` starts the claimed attempt; `adopt` finds the
same local attempt without starting another Codex turn. If it is absent, the
Worker aborts that attempt and the Job owner applies its retry policy.

`turn_accepted` confirms that the attempt is present on the Worker. It does not
consume input. The Worker starts execution only after the control plane confirms
that acceptance. If the confirmation is lost, the same local attempt waits for
rejoin and confirms again through one background task. A repeated `turn_start`
does not launch another execution. The receive loop stays available for stop,
drain, and generation changes while confirmation is pending.

`mailbox_updated` delivers one persisted input in queue order.
The Worker keeps the Signal IDs that Codex applied. Terminal
`background_agent_job.status.update` carries those IDs; the control plane closes
only the trigger and applied inputs in the Job terminal transaction. Inputs
that arrived after the last applied event remain open for the next attempt.

`turn_control` interrupts an attempt or withdraws a Skill. A failed Worker
attempt calls `session_turn.abort`. Completion and abort use the Job's own
attempt identity, so Driver replacement cannot reject a still-running Codex
result. Duplicate terminal writes are idempotent at the Job owner.

### Trusted Runtime Environment

The control plane derives `ANKOLE_RUNTIME_` values from the current Signal.
They are execution facts, separate from operator WorkerEnv settings. An active
human requester contributes the sender Principal, access version, and derived
Lark profile. Scheduled and system inputs carry no human requester values.

The Lark profile is `ankole-u-<base64url HMAC-SHA256>`. Its HMAC input is the
Principal UID for access version 1, otherwise the UID, a NUL byte, and the access
version. The installation key `runtime_fabric.worker_auth_key` stays on the
control plane. Key rotation changes every profile and requires Lark user
authorization again. Worker credentials never enter a command or Codex
environment. The Worker checks the namespace and rejects a per-command override
of these facts. Shell code can change its own environment, so a consumer must
also validate the value it uses.

### Refresh the Lark Bot Credential

The Lark adapter resolves the current tenant access token through the control
plane token manager. It requires at least ten minutes of shortened safe
validity. The `worker_env.resolve` response carries that token only on the
trusted RPC path. Its request carries the current signal binding name. The
control plane uses that name to select the Lark application for this route. A
sole Lark binding stays implicit, but an Agent with several Lark bindings gets
no Lark credential variables when no binding matches the request.

Agent Computer removes the raw token before it builds a shell or Codex thread
environment. For each open workspace, Background Agent Job attempt, or
Automation Job attempt that has a Lark bot token, it writes one private file in
the Agent Home and refreshes that file every minute through the same WorkerEnv
RPC. Each successful write uses an atomic rename. Cleanup stops the refresh and
deletes the file. If the binding changes to another Lark app or domain during
an execution, Agent Computer removes the file and requires a new execution
instead of combining the old app identity with the new token.

The environment contains only
`ANKOLE_RUNTIME_LARK_TENANT_ACCESS_TOKEN_FILE`. The Worker image `lark-cli`
launcher reads that file for each command and rejects a file that has not been
confirmed for five minutes. It then passes the token only to the short-lived
official CLI process. A stalled refresh therefore fails as
`authentication/credential_unavailable` before it sends a stale token.

The control plane remains the credential owner. Agent Computer creates no app
secret, Job credential, or authoritative token record. The execution file is
a disposable runtime projection, not a new authorization subject.

## Call Functions in Another Process

The RPC lane uses `rpc_request`, `rpc_response`, and `rpc_error` envelopes.
Both control plane and worker clients correlate calls by request ID.

`app/kernel/proto/ankole/runtime_fabric/v1/rpc.proto` declares business messages.
The Bun `rpcOperations` table owns the method names, authorization facts,
effects, message-type pairs, and handlers. `gen-rpc-contract.ts` projects these facts into the committed
`rpc_methods.json` file. This file is the cross-language parity artifact. It is
not a third runtime registry.

Each contract row defines:

- the method name
- its authorization scope
- whether a turn method reads, writes, or completes a turn
- the request message type
- the response message type

Elixir derives the authorization facts and generated message modules from this
contract. It keeps only the method-to-broker mapping. A compile-time coverage
check requires the mapping and contract to contain the same methods. Tests
exercise the real broker functions and compare the generated contract. The control plane encodes and decodes all business payloads
in one place. It rejects a broker response struct whose module differs from the
declared response module. It accepts a plain map only when the declared response
module is `JSONPassthroughResponse`.

Turn-scoped frames carry exactly one `RunRef` or `JobTurnRef` outside the
payload. The connection must belong to that Agent. A worker-agent method takes its
Agent from the connection: the authenticated `worker_id` is the Agent UID, and
the frame carries no Agent.

The server authorizes the outer frame before it decodes the business payload.
Job lifecycle methods require `JobTurnRef`. The Job owner accepts an idempotent
terminal retry for the same attempt after the input closes. An ordinary run
method requires open input. Payloads do not repeat identity or request IDs.

The registry currently contains these method families:

- Codex attempt abort and terminal Job status.
- AIGateway API key resolution.
- WorkerEnv resolution.
- Agent drive files: `files.list`, `files.get`, and `files.commit` (see
  [Files](Files.md)).
- Automation job management, execution, and event emission.
- Webhook endpoint creation, cancellation, and listing.
- Worker observability span export.
- Best-effort Codex diagnostic log maintenance.
- Background Agent Job lifecycle and trajectory. Thread files remain in
  persistent Home; see [Background Agent Job](BackgroundAgentJob.md#persistent-thread-files).
- Skill overlay resolve: the rendered skill-lesson block for a Skill set.

Main-agent tools call their control-plane domain owners directly. They do not
use a Worker RPC for schedules, channel policy, Workflow, or Job management.

The RPC lane does not carry conversation history or compaction commits.
AIGateway owns both concerns.

Every `rpc_error` carries an explicit `retryable` boolean. `details_json`
carries diagnostic facts. Domain
validation and authorization errors default to false. If a control-plane
handler crashes or returns an invalid result, the error also contains one
`failure_id` that matches the control-plane log. Only a `turn_read` handler
failure is retryable. Worker-agent operations, writes, and completion stay
non-retryable because the control plane cannot prove that repeating them is
safe. Agent Computer preserves the code, retryability, details, and failure ID
when the error reaches Actor or Background Agent Job recovery.

Worker-originated RPC calls use the normal 300-second timeout. An automation
job execution is a control-plane-originated RPC. Its timeout is ten minutes
plus a short transport margin.

The Worker projects a transport push timeout as `runtime_fabric_timeout` and
an RPC deadline as `runtime_rpc_timeout`. These codes and `socket_closed` are
infrastructure interruptions for Job retry accounting. A generic `timeout` or
an arbitrary retryable domain error does not receive that classification.

## Worker Files

The control plane moves file bytes to and from one worker's Agent Home through
two worker-owned RPC methods:

- `worker_files.pull`: the worker downloads bytes from a relay URL and writes
  one file.
- `worker_files.push`: the worker uploads one file to a relay URL. With
  `bundle_paths`, the worker uploads one bundle of several files under the
  directory `home_relative_path`: for each path in order, a 4-byte big-endian
  path length, the UTF-8 path relative to that directory, an 8-byte big-endian
  content length, and the content.

`rpc.proto` defines the request and response messages. The RPC frame carries
no turn fence for these methods; the control plane is the caller. The drive
RPCs of [Files](Files.md) use these transfers: `files.get` pulls a drive file
into the Agent Home of the worker that called it, and `files.commit` pushes
files from there.

Each request names a path inside the Agent Home of the worker that receives
it, `home_relative_path`, without the Agent UID: the worker's connection
already names its Agent. For example:

```text
sessions/10000/drive/inbox/0123456789abcdef/file.png
```

The worker refuses a path that leaves its Agent Home and answers with the
number of bytes that it moved (`size`).

`Ankole.WorkerFiles` owns transfer bounds and the relay session. Every
transfer names its Worker: the drive RPCs pass the Worker that called them, so
the bytes go to the disk of the Worker that asked for them.

One file or one bundle can contain at most 100 MiB in either direction. A
write fails before the RPC when the input exceeds this limit. A read fails on
the worker before the upload when the file or bundle exceeds `max_bytes`, and
the relay rejects a larger request body with `413`. The control plane rejects
a bundle whose paths are not the requested paths in order.

The worker returns these error codes in `rpc_error.code`:

- `file_not_found`: the source path is absent.
- `not_regular_file`: the source is not a regular file.
- `file_changed`: the file changed while the worker uploaded it, or a bundled
  file changed its size while the worker wrote the bundle. The control plane
  does not accept the uploaded bytes as a successful read.
- `file_too_large`: the file exceeds `max_bytes`.
- `relay_failed`: the relay URL answered a non-2xx status or the HTTP request
  failed.
- `operation_failed`: any other failure.

These codes are the cross-runtime recovery contract. The message is for
diagnosis only.

## Transfer Files Safely

The relay keeps file bytes out of the RuntimeFabric connection and out of
control-plane memory:

1. The control-plane Pod that serves the drive RPC opens an in-memory relay
   session with a random `transfer_id` and a short expiry.
2. It sends `worker_files.pull` or `worker_files.push` with a URL on its own
   internal origin.
3. The worker sends `GET` (pull) or `PUT` (push) to that URL.
4. The relay streams the bytes in bounded chunks between a local file of the
   control plane and the worker request. It does not buffer a whole file.
5. The worker answers the RPC with the final size. The control plane then
   completes the drive RPC.

The URL is:

```text
<internal origin>/internal/runtime-fabric/file-relay/<transfer_id>?token=<token>
```

The token is 32 random bytes. The session and its token exist only in the
process of the issuing Pod, which compares the request's token with its own
copy, so the token needs no signature. A URL is valid for one request and one
method, and it expires with the session. The URL is a bearer credential:
neither runtime writes it to a log, and Phoenix filters the `token`
parameter.

The internal origin is the address of the issuing control-plane Pod, not a
load-balanced Service address, because only that Pod holds the relay session.
`ANKOLE_RUNTIME_FABRIC_INTERNAL_ORIGIN` sets it. When it is absent, the
control plane derives `http://<POD_IP>:<PORT>` from the Kubernetes Downward
API. Workers must be able to reach this origin.

The relay session is supervised memory state with an idle timeout. It is not a
PostgreSQL row. When the relay Pod, the worker, or the drive RPC fails, the
whole operation fails, both sides release their state, and the caller repeats
the request. There is no resume.

The worker rejects `..` traversal and symlinks that leave its Agent Home,
`/workspace`.

A pull writes to this scratch path and then moves the checked file into place
with an atomic rename:

```text
/tmp/ankole-file-transfer/<transfer-id>/
```

A push reads the file with one descriptor, records its identity and size
before the upload, and reports `file_changed` when the file differs after the
upload.

The relay does not compress file bytes. The transfer is HTTP inside the
cluster network, and the bounded chunk size limits memory on each hop.

The worker keeps no transfer state after the RPC answers. The filesystem keeps
the file. PostgreSQL records how Ankole uses it.

## Move Attachments without an Agent Turn

File operations do not require an Actor turn or a worker. An adapter can save
an attachment even when the message does not wake an Agent.

The inbound path is:

1. A provider adapter receives a resource reference or byte stream.
2. The control plane assigns a numeric attachment ID and records a pending
   provider observation in PostgreSQL.
3. The adapter stores the bytes in the file service with
   `Conversations.Attachments.store_attachment/3`.
4. The adapter replaces the pending observation with `blob_ref` and the drive
   `path` under `chats/<conversation_id>/inbox/`, or with a failed materialization state.

The outbound path is:

1. The model saves the deliverable in the drive, then calls `reply_attachment`
   with `drive_path`.
2. The control-plane tool owner records the original path and current digest.
3. The Driver records the structured tool result in the Response tape.
4. Conversations.Delivery checks that the drive names each content at its path.
5. The Run terminal transaction inserts attachment intent intents. The common
   Delivery commit check permits a file under `chats/<conversation_id>/` only for that
   destination Conversation UUID. Paths outside `chats/` are shared.
6. The provider adapter reads the bytes by `blob_ref` and uploads them.
7. Conversations records the Agent Message and external reference after provider confirmation.

Hosted tools make an exception for complete `image_generation_call` items.
AIGateway owns their artifact bytes. Sessions.Presentation stores those bytes under
`chats/<conversation_id>/generated/` in the Agent's drive during turn adoption. Without
a source Conversation, it uses the shared `generated/` prefix.

Ankole never searches model prose for file paths. The model must return a
structured attachment record.

## Keep Agent Skills in Sync

Agent Plugins and Skills combine filesystem packages with control-plane
enablement state.

Built-in packages remain on the deployment-instance filesystem.
Agent-installed Skills live under `skills/` in the Agent's drive. The control
plane reads the complete manifest set from Files to synchronize the catalog.
A failed read leaves the catalog unchanged, and manifest updates preserve
operator enablement overrides. Before a turn or Automation Job run, the
worker brings the Agent Home `installed-skills` cache in step with that folder
and stops preparation if the download fails (see [Files](Files.md)). The
worker reads these files when it prepares a run; it does not replace the catalog.

The worker reads per-Agent skill additions through one RPC method:

- `skills.overlay.resolve` reads the rendered skill-lesson block for a complete
  requested Skill set in one batch. Lessons are written by Dreaming and the
  Console only (see `docs/design-docs/SkillLessons.md`); the worker has no
  overlay write methods.

The resolve response contains exactly one entry for each unique requested name.
The control plane synchronizes the Agent registry once and performs set reads
for the Skill and lesson rows. A missing, disabled, invalid, or duplicate name
rejects the whole request. The worker rejects a partial, duplicate, or
unexpected response instead of materializing a mixed snapshot.

`skill_view` combines `SKILL.md` with the lessons in PostgreSQL. Dreaming and
the Console own lesson writes.

RuntimeFabric returns only Agent Plugins enabled for the requesting Agent.
A Job resolves that current catalog and its runtime-eligible Skill names on
every prepare.

See [Plugins](Plugins.md) for package and enabled-state rules.

## Deploy Matching Control-Plane and Worker Images

`.github/workflows/runtime-images.yml` publishes both runtime images.
One workflow run builds both images from the same 40-character Git revision.

The workflow publishes immutable multi-platform manifests.
It verifies release revision, protocol version, and architecture labels.
The pair artifact contains digest-pinned image references.

The control plane creates every Worker from the image in
`ANKOLE_AGENT_COMPUTER_IMAGE`. A deployment sets it to the Worker digest of the
same pair and deploys only the control plane. `AgentWorkers` replaces a Worker
whose protocol version differs from the control plane at once, and a Worker
whose image or backend template differs when it is idle (see
[AgentWorkers](AgentWorkers.md)).

The first upgrade to Session drivers requires a maintenance window.
Stop all old control-plane nodes before the migration. Old Workers use an
incompatible protocol; their open inputs resume under the new driver and can
repeat one interrupted operation. Later planned restarts adopt retained
Worker calls and Codex attempts. The migration removes activation and delivery
tables. An older image cannot run against this schema. A rollback requires
the pre-upgrade database and Worker storage backups.

Every control-plane Pod is one named Erlang node. DNSCluster discovers the
other Pods through a headless Service, the Pods share one release cookie, and
the distribution port is fixed so a NetworkPolicy can limit it to control-plane
Pods. Workers never use the distribution ports; they connect to the ClusterIP
Service for the channel and to the issuing Pod IP for a file relay. A Pod that
terminates leaves the Service first and then closes its channels, so Workers
reconnect to a remaining Pod. Drivers rebuild from PostgreSQL and adopt
retained Worker calls and Codex attempts.
Distributed Erlang provides process addressing only; it is not a durable
single-writer guarantee.

The release starts ERTS with a limit of 65,536 ports. This prevents a large
container file limit from reserving a large port table at startup. An operator
can override this limit with `ERL_FLAGS`, for example `+Q 1048576`.

## What RuntimeFabric Does Not Do

RuntimeFabric is not any of these systems:

- A durable message queue or replay spool.
- A general message broker.
- A per-lane socket farm.
- A control-plane NFS mount.
- An S3-compatible object store.
- A file-chunk protocol inside the worker connection.
- A conversation-history RPC service.
- A second set of domain records written by the worker.
