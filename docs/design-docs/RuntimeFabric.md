# RuntimeFabric

RuntimeFabric connects the Elixir control plane to Agent Computer workers.
It carries live messages but does not store them. PostgreSQL stores any data
that Ankole needs after a restart.

The connection carries two groups of messages:

- Actor messages start, steer, stop, and report non-response terminal states.
- RPC messages ask another process to read or change Ankole data.

Both groups use the same worker connection and authentication. File bytes do
not travel on this connection. A worker-file operation is a control-plane RPC
to the worker, and the worker moves the bytes over HTTP with a one-time signed
relay URL (see "Read and Change Worker Files").

## Which Process Stores What

The control plane stores:

- ActorEvents and their delivery records
- Session activations and turn fences
- AIGateway conversations and messages
- Agent documents and enabled capabilities
- copies of provider messages and provider outbox rows
- Background Agent Job state

Workers run Agent code and access mounted files. They do not define PostgreSQL
rules or commit business records.

Workers use RPC when they need to read or change stored Ankole data. The control
plane uses the worker-file RPC methods when it needs a worker file.

All workers in one deployment instance must still see the same Agent Home
storage.
Worker-file operations do not replace shared storage.

## Two Transports until Every Worker Switches

The control plane accepts two physical transports at the same time, and each
worker uses exactly one, selected by the scheme of
`ANKOLE_RUNTIME_FABRIC_ENDPOINT`:

- `ws://` or `wss://`: the Worker Channel described below. This is the target
  transport.
- `tcp://`: the ZeroMQ transport that earlier worker images use. The control
  plane keeps one Rust-owned `ROUTER` bound at
  `ANKOLE_RUNTIME_FABRIC_BIND_ENDPOINT` with ZAP `PLAIN` authentication
  (`WORKER_ID` as the username, the shared key as the password). The route is
  the `DEALER` identity, and a send returns `{:ok, :sent_or_queued}` when the
  socket queued the envelope; there is no acknowledgement. The `stream` and
  `transport_seq` envelope fields are zero on this transport.

The dual stack is a migration tool. When every worker connects with `ws://`,
the ROUTER, its port, the ZAP code, and the worker `DEALER` are removed in one
change. Nothing else depends on them.

The protocol version stays at 5 across the migration. The `stream` and
`transport_seq` fields are additive, and a published ZeroMQ worker image
must keep passing the kernel's version check.

## One Phoenix Channel per Worker

RuntimeFabric uses one WebSocket connection per worker, carried by a Phoenix
Channel on the control plane.

- The control plane serves `AnkoleWeb.RuntimeFabricSocket` at
  `/runtime-fabric/worker`.
- Each worker joins one channel on the topic `worker/installation/<worker_id>`.
  The `installation` segment is a fixed namespace; it is not a tenant model.
- The channel process is the address of the worker connection. Its
  `connection_id` is the `transport_route` that PostgreSQL stores.

Every connection has three identities:

| Identity | Owner | Changes when |
| --- | --- | --- |
| `worker_id` | operator slot | never |
| `incarnation_id` | worker process | the worker process restarts |
| `connection_id` | control plane | the WebSocket reconnects |

Actor and RPC messages use Protobuf. The WebSocket carries the existing
envelope bytes as binary frames. There is no JSON or Base64 wrapper.

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
| `control` | `worker_ready`, `worker_heartbeat`, `worker_capacity`, `control_shutdown` | after the admission handler returns |
| `durable` | `turn_accepted`, `worker_progress`, RPC requests, RPC responses, RPC errors | after the PostgreSQL transaction commits; an RPC request is answered when its task starts, and its response is the durable answer |
| `telemetry` | `observability.spans.export` requests | after the request enters the bounded telemetry window |

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

The Phoenix reply reference correlates the reply with the push. It is
transport state only; `message_id`, `correlation_id`, and the RPC
`request_id` remain the business keys and the idempotency keys.

Control-plane-to-worker traffic uses two events:

| Event | Bodies |
| --- | --- |
| `command` | `turn_start`, `mailbox_updated`, `turn_control`, RPC requests |
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

`Ankole.SignalsGateway.ActorRuntime.WorkerRoute` is the only module that
sends to a worker. The route directory is
`Ankole.SignalsGateway.ActorRuntime.WorkerTracker`, a `Phoenix.Tracker`:

- One topic per worker: `worker/<scope>/<worker_id>`. The `scope` is the
  fixed namespace `installation`; a future multi-tenant deployment would vary
  it together with admission, the route fence, and the file roots.
- The key is the `connection_id`.
- The metadata holds only stable connection identity: `worker_id`,
  `incarnation_id`, `connection_id`, `channel_pid`, and `node`. Heartbeat,
  load, and capacity never enter the tracker.
- `pool_size` sets the number of tracker shards; per-worker topics spread over
  them with `phash2(topic, pool_size)`. No scheduling path lists a topic.

A send follows these steps:

1. A route that spoke on the ZeroMQ `ROUTER` goes to that socket.
2. Otherwise `Phoenix.Tracker.get_by_key/3` with the worker topic and the
   route.
3. Compare the entry's `incarnation_id` and `connection_id` with the current
   PostgreSQL route fence. A mismatch is `{:error, :stale_route}`.
4. Call the channel process directly. A process on another node receives the
   call through Distributed Erlang. No worker command uses a PubSub broadcast.
5. Wait for the worker's cumulative acknowledgement.
6. A route in neither directory goes to the `ROUTER` when one is bound, so a
   ZeroMQ worker that reconnected after a control-plane restart is reached
   before its first lifecycle message registers it here.
7. An empty directory, a stale entry, or a missing acknowledgement fails only
   this send. The caller keeps the PostgreSQL delivery and never changes
   durable state from a directory result.

`send_mandatory/2` returns `{:ok, :sent_or_queued}` only after the worker
acknowledged the command. It returns `{:error, :unknown_route}` when no channel
owns the route, `{:error, :backpressure}` when the connection already holds the
maximum number of unacknowledged commands, and `{:error, :timeout}` when the
acknowledgement does not arrive. The caller keeps the PostgreSQL delivery and
does not change durable state from a routing result.

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
delivery state drives any repeat.

A telemetry drop does not change turn correctness. Telemetry that must not be
lost needs a durable spool; RuntimeFabric does not provide one.

## Reconnect and Restart

The Phoenix client reconnects with capped exponential backoff and joins the
channel again. The join payload carries the ready fields, so each join is an
admission. The worker opens its send windows only after the join succeeded.

A reconnect with the same `incarnation_id` receives a new `connection_id`. One
transaction moves the worker projection, its live assignments, and its live
deliveries to the new route. Turn fences do not change. When the old channel
process then closes, it does not mark the worker stale, because the worker's
current route is no longer that connection.

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
- calls to kernel validation
- worker drain before shutdown

The adapter does not schedule Actors or decide when a turn ends.

## Temporary Routing Tables

ActorRuntime can rebuild these routing tables after a restart:

- `actor_event_deliveries`
- `agent_computer_workers`
- `actor_session_worker_assignments`
- `actor_session_activations`

These UNLOGGED tables use text states with database checks. Their values describe
only the current transport state.

Each heartbeat carries the worker's full identity, runtime, version, capacity,
and load snapshot. An authenticated heartbeat recreates a missing worker row
after PostgreSQL clears the UNLOGGED registry.

Durable domain tables can still use PostgreSQL enums.

Transactions that need both routing and event locks take the Worker and
activation before the current ActorEvent, and the ActorEvent before its
deliveries. Placement and operator Job changes take the existing Session
assignment advisory lock before the Worker. Steer handling uses this same
assignment lock without changing placement or capacity, then checks that the
command is still open after it acquires the routing locks. This order lets a
Job terminal commit consume an unaccepted steer into one successor without
deadlocking against that steer's delivery.

WorkerPool owns assignment locks and placement. TurnRef owns Worker identity
and turn-fence checks. Domain owners retain their terminal transactions.
Draining Workers can still commit terminal results, and completed ActorEvents
remain the authority for completion retries after routing state is gone.

## Authenticate a Worker

The control plane stores one encrypted AppConfigure key:

```text
runtime_fabric.worker_auth_key
```

The control plane creates this key when necessary.

Worker startup requires these values:

```text
WORKER_ID=worker-a
ANKOLE_RUNTIME_FABRIC_ENDPOINT=ws://control-plane:4000/runtime-fabric/worker
ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=<worker-auth-key>
```

The worker sends the key as the Phoenix socket auth token in the
`Sec-WebSocket-Protocol` header. The key never appears in the URL. The socket
`connect/3` callback compares it with the stored key in constant time and
rejects the upgrade on a mismatch. The Worker validates the endpoint, copies
the key into memory, and removes the key from the environment that child
processes inherit.

All workers can use the same key. Ankole does not store a different key for
each worker.

`worker_id` names a worker slot chosen by the operator. The socket parameters
carry it, and the channel topic must name the same worker. Each new process
creates a fresh `incarnation_id`.

The join payload carries the `worker_ready` fields: `worker_id`,
`incarnation_id`, `runtime`, `version`, `max_turns`, and
`available_turn_slots`. `join/3` builds the ready message from them, calls
`WorkerAdmission` with the authenticated route, and registers the connection
in the tracker. A payload whose `worker_id` differs from the topic or the
socket fails the join with `identity_mismatch`. A `worker_ready` envelope sent
after the join is an ordinary lifecycle message.

Ready, heartbeat, and capacity messages contain both identifiers. The control
plane records the authenticated route.

On process shutdown, the worker sends `control_shutdown` to the control plane.
This direction means "the worker process is shutting down." The control plane
marks the worker, its assignments, and its live activations as `draining`. It
does not release their turn fences. A draining worker receives no new turns but
can finish terminal writes and receive RPC responses.

A new incarnation replaces the old process for the same worker ID. One
transaction releases the old assignments and invalidates their turn fences.

The control plane rejects delayed messages from the old process.

A worker becomes stale after 60 seconds without a valid heartbeat, or when its
current channel process terminates. Cleanup can remove its routing record after
3,600 seconds.

A valid worker lifecycle message can make a stale worker active again. It cannot
restore released assignments or old delivery attempts. A stopped worker cannot
reactivate itself.

This protocol authenticates trusted first-party workers. Database turn fences
still protect each write. Ankole does not provide public worker admission
here. TLS termination for `wss://` belongs to the ingress in front of the
control plane.

## Validate Every Actor and RPC Message

`app/kernel/proto/ankole/runtime_fabric/v1/envelope.proto` defines the message
structure.
The generated package namespace remains `ankole.runtime_fabric.v1`.
The envelope header must use the current protocol version owned by the Rust
kernel.

The runtimes generate codecs from the same file:

- Rust uses `prost-build`.
- Elixir uses `protox`.
- TypeScript uses `protoc-gen-es`.

Generate committed TypeScript output with `bun run gen:proto`.

The Rust kernel seals every envelope at the send boundary: a host supplies
only the ids, the send time, and the body, and the kernel writes
`protocol_version`, lane, and durability from its `BodySpec` table. A host
cannot choose a wrong header field, because the kernel overwrites all three.

The kernel then validates every envelope before sending and after receiving
it:

- `protocol_version` must equal the kernel's current `PROTOCOL_VERSION`.
- `message_id`, lane, durability, and body must exist.
- The body fixes its lane and durability class.
- Turn and RPC envelopes require a correlation ID.
- An RPC correlation ID must equal its request ID.
- A turn reference must contain all turn-fence fields.
- A `turn_control` steer payload must be empty.
- Worker progress must use an approved progress class.

Approved worker progress classes are:

- `summary`
- `checkpoint`
- `reply_presentation`
- `artifact_ref`
- `cancellation_observed`
- `retryable_error`
- `final_error`

Host code writes UTF-8 JSON into `*_json` byte fields. Empty bytes mean that the
value is absent.

Each RPC method has its own protobuf payload. The kernel transports those bytes
without interpreting their business fields.

Golden fixtures live under `app/kernel/proto/golden`.
Rust, Elixir, and TypeScript decode the same fixture bytes.
RPC fixtures cover the outer frame and representative typed and JSON payloads.

## Protocol Lanes and Durability Classes

The Protobuf protocol uses four technical lanes:

- `LANE_CONTROL` carries worker lifecycle and turn control.
- `LANE_TURN` carries turn start, mailbox updates, and acceptance.
- `LANE_PROGRESS` carries progress observations.
- `LANE_RPC` carries RPC requests and results.

The durability flag tells the control plane what it must store or replay.
It does not make the worker connection a stored queue.

- `CONTROL_DURABLE` requires a durable control-plane fact.
- `CONTROL_REPLAYABLE` requires a replayable PostgreSQL fact.
- `CONTROL_EPHEMERAL` carries live observation only.

## Start and Control Agent Turns

The actor lane carries these common messages:

- `worker_ready`
- `worker_heartbeat`
- `worker_capacity`
- `turn_start`
- `mailbox_updated`
- `turn_accepted`
- `turn_control`
- `worker_progress`

Workers finish turns through the `actor_turn.complete`, `actor_turn.noop`, and
`actor_turn.abort` RPCs. A release runs one matching control-plane and Worker
image pair; RuntimeFabric does not keep former terminal envelope variants.

Worker capacity has one scheduling representation. `worker_ready`,
`worker_heartbeat`, and `worker_capacity` carry integer `max_turns` and
`available_turn_slots` fields. `worker_heartbeat` and `worker_capacity` also
carry integer `active_turns` fields.
The kernel rejects zero maximum capacity, available capacity above the maximum,
and capacity updates whose active and available values do not equal the maximum.
The control plane does not derive capacity from load or parse JSON and string
alternatives.

### Start a Turn

`turn_start` contains one actor event.
It does not contain an event list.

The message contains these main values:

- An `ActorTurnRef` turn fence.
- One durable ActorEvent envelope.
- The PostgreSQL-owned numeric Session workspace ID.
- The selected model reference.
- Current request context.
- Hosted tool configuration.
- Trusted runtime environment facts for this Turn.

Request context contains current request details, not conversation history.
AIGateway builds model history for each Response.

TurnStart also projects the current Agent's custom model profile names and
descriptions. Agent Computer uses this bounded catalog to build the optional
`create_background_job.model_profile` enum. The control plane validates the
selected name again when it handles `background_agent_job.create`.

`BackgroundAgentJobCreateRequest.model_profile` carries only that logical
custom name. An empty value selects `coding`. `BackgroundAgentJobResponse`
returns the persisted logical name. The Job Turn's model reference carries the
resolved provider, model, options, reasoning effort, direct input modalities,
and an optional directly image-capable vision fallback instead of a caller
supplied raw model.

The Session workspace ID names `/agents/<agent-key>/sessions/<workspace-id>`.
It starts at 10000 and stays stable for one `{agent_uid, session_id}` pair.
The current protocol requires this field so each runtime resolves the same
directory.

Turn runtime environment names use the `ANKOLE_RUNTIME_` prefix. These values
are not WorkerEnv configuration. The control plane derives them from the current
ActorEvent, and Agent Computer can add values that require worker-only bootstrap
material.

A Turn with an active human requester carries:

```text
ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL=<principal_uid>
```

Turns without an active human requester, such as scheduled and system Turns, do
not carry this value. Agent Computer derives the Lark profile name as:

```text
ANKOLE_RUNTIME_LARK_PROFILE=ankole-u-<base64url HMAC-SHA256>
```

The HMAC input is the sender Principal UID. The HMAC key is the RuntimeFabric
worker authentication key that deployment bootstraps from
`ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`. The key stays in the trusted worker
process; only the derived profile enters the Agent shell. A worker authentication
key rotation changes this profile name and requires Lark user authorization
again. The bootstrap variable itself is not a Turn environment value. Agent
Computer rejects it if it appears in the Turn map.

Agent Computer validates the namespace before it injects these values. A
per-command environment map cannot replace them. Shell code can still change
its own process environment, so a consumer must also validate the value that it
uses.

### Refresh the Lark Bot Credential

The Lark adapter resolves the current tenant access token through the control
plane token manager. It requires at least ten minutes of shortened safe
validity. The `worker_env.resolve` response carries that token only on the
trusted RPC path. Its request carries the current signal binding name. The
control plane uses that name to select the Lark application for this route. A
sole Lark binding stays implicit, but an Agent with several Lark bindings gets
no Lark credential variables when no binding matches the request.

Agent Computer removes the raw token before it builds a shell or Codex thread
environment. For each active main Turn, Background Agent Job attempt, or
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

### Reject Writes from an Old Turn

Every turn message contains an `ActorTurnRef`. This turn fence identifies the
current attempt and contains these values:

- `agent_uid`
- `session_id`
- `activation_uid`
- `actor_epoch`
- `actor_event_id`
- `revision`

The control plane checks these values before it accepts a worker write. An old
worker or earlier attempt cannot change a newer turn.

The activation revision `A` is the highest revision that the control plane has
issued. The Worker revision `R` is the highest revision that the Worker has
applied. The control plane requires `0 <= R <= A`.

Read and ordinary write RPCs use the current live fence rules. A
`turn_accepted` message must match one exact revision. A terminal RPC matches
the static attempt fence and can use an older applied revision `R` when the
activation already has a newer pending revision `A`.

### Add Input to a Running Turn

`mailbox_updated` contains one journaled actor event.
It injects a steer command into a running turn.

`sent_or_queued` does not complete the command event. A normal text Turn sends
`turn_accepted` only after the steer enters model input. A Background Agent Job
sends it only after Codex accepts `turn/steer`. The accepted revision advances
`R`. For a reply-eligible text Turn, that exact acceptance also moves the live
reply preview to the steer event. Before acceptance, the old preview owner
continues to receive progress from the current model round.

If the Worker finishes first at an older revision, the control plane supersedes
the newer delivery attempt. Its ActorEvent stays open and gets a new delivery in
the next Turn.

### Retry a Turn

`turn_control` with `command = "retry"` stops the named local turn. The worker
ends its loop, releases capacity, and does not call `actor_turn.abort`.

An input supersession uses this control only as a best-effort token stop. The
control plane first retracts the generating Response and invalidates the
delivery fence in PostgreSQL. It updates the same ActorEvent with the new
attachment and does not release that event until attachment materialization
finishes or reaches its cap. A late worker completion cannot pass the old
fence.

The control plane does not supersede a turn after it sees a tool call, a tool
result, or a committed outbox operation. It queues the attachment as a new turn
because replay could repeat an external write.

### Complete a Turn

The Worker ends an attempt with one of three turn-scoped RPCs:

- `actor_turn.complete` commits a final Response.
- `actor_turn.noop` commits the applied input prefix without a visible reply.
- `actor_turn.abort` fails the attempt without consuming any input.

`actor_turn.complete` carries the final Response ID and one outcome.

- `loop_finished` means the worker loop ended normally.
- `iteration_exhausted` means the local iteration budget ended.

Neither outcome proves the broader user task succeeded.

`actor_turn.noop` records the outcome `silent`. It carries the final Response
ID when the Worker ran a model loop and adopted a Response, and no ID when the
turn made no gateway Response. A completed ActorEvent therefore always records
how the turn ended, and which Response ended it when one exists.

SignalsGateway checks that the Response chain did not change. It then completes
the main ActorEvent and every input delivery with `revision <= R`, and it stores
the replies in one transaction. A delivery with `revision > R` stays open.
Completion is stronger than `turn_accepted`, so it can commit an applied
delivery that is still `sent`. This removes a race between the actor-lane
acceptance task and the RPC task.

`actor_turn.noop` consumes the same applied prefix through the same completion
transaction, without provider-visible output. `actor_turn.abort` validates
the static attempt fence and `R <= A`, supersedes the attempt deliveries, and
keeps every ActorEvent open for retry or dead-letter handling. It does not
depend on the lease still being alive.

The same commit clears the current ActorEvent and briefly keeps the Session on
the worker for possible follow-up work.

AIGateway completion closes one Response only.
It does not complete the actor event.

Each RPC response acknowledges its durable terminal operation. The Worker does
not release its active Turn until it receives this response. If the response is
lost after commit, the Worker repeats the request. A completion or no-op returns
`already_completed`, and an abort returns `already_aborted`.

On `SIGTERM` or `SIGINT`, the worker first sends `control_shutdown`, rejects new
turns, and keeps its RuntimeFabric receive loop open while active tasks wait for
completion responses. Kubernetes can still end the process at its external
termination deadline; drain does not claim an unbounded shutdown guarantee.

If a worker disappears before a completion commit, ActorRuntime checks the
AIGateway output before it makes the ActorEvent ready again. A suffix containing
only message and reasoning items is replay-safe: ActorRuntime retracts that
visible suffix, fails any generating Response, and retries the event. A suffix
that contains a tool call, tool result, or another effect-bearing item is not
replayed. ActorRuntime dead-letters the event, records a bounded and redacted
copy of the failure reason on it, and commits a provider-visible failure notice
for manual recovery. A notice with no route, because its channel takes no
replies or its route rows are deleted, is logged and skipped. Worker takeover
never depends on an old event's channel.

A Turn with no reply uses `actor_turn.noop`. Silence alone never completes a
Turn. A Worker failure uses `actor_turn.abort` and the normal retry path. The
activation lease remains a process-crash fallback. It is not the normal way to
finish a Worker attempt.

## Call Functions in Another Process

The RPC lane uses `rpc_request`, `rpc_response`, and `rpc_error` envelopes.
Both control plane and worker clients correlate calls by request ID.

`app/kernel/proto/ankole/runtime_fabric/v1/rpc.proto` declares business messages.
The Bun operation tables own the method names, authorization facts, effects, and
message-type pairs. `gen-rpc-contract.ts` projects these facts into the committed
`rpc_methods.json` file. This file is the cross-language parity artifact. It is
not a third runtime registry.

Each contract row defines:

- the method name
- its authorization scope
- whether a turn method reads, writes, or completes a turn
- the request message type
- the response message type

Elixir keeps an explicit dispatch table because broker functions and generated
request and response modules are control-plane implementation facts.
Package-local tests compare the Bun projection and the Elixir table with the
committed contract. The control plane encodes and decodes all business payloads
in one place. It rejects a broker response struct whose module differs from the
declared response module. It accepts a plain map only when the declared response
module is `JSONPassthroughResponse`.

Turn-scoped frames carry `ActorTurnRef` outside the payload.
Worker-agent frames carry a trusted `agent_uid` outside the payload.

The server authorizes the outer frame before it decodes the business payload.
The completion effect also accepts an idempotent retry from the same worker and
activation after the ActorEvent has completed. The payload does not repeat
identity or request IDs.

The registry currently contains these method families:

- Agent conversation context with one coherent Agent Plugin and Skill catalog.
- Actor turn completion.
- AIGateway API key resolution.
- AppConfigure and WorkerEnv resolution.
- Automation job management, execution, and event emission.
- Best-effort Codex diagnostic log maintenance.
- Background Agent Job lifecycle and trajectory.
- Schedule operations.
- Signal channel ambient judgments and standing orders.
- Installed Skill observations.
- Skill overlay resolve: the rendered skill-lesson block for a Skill set.

Schedule RPCs use `JSONPassthroughResponse`. The worker passes
`body_json` to the model without changing its fields.

The RPC lane does not carry conversation history or compaction commits.
AIGateway owns both concerns.

Every `rpc_error.details_json` contains an explicit `retryable` boolean. Domain
validation and authorization errors default to false. If a control-plane
handler crashes or returns an invalid result, the error also contains one
`failure_id` that matches the control-plane log. Only a `turn_read` handler
failure is retryable. Worker-agent operations, writes, and completion stay
non-retryable because the control plane cannot prove that repeating them is
safe. Agent Computer preserves the code, retryability, details, and failure ID
when the error reaches Actor or Background Agent Job recovery.

Worker-originated RPC calls use the normal 300-second timeout. An automation
job execution is a control-plane-originated RPC. Its timeout is ten minutes
plus a short transport margin. `codex_logs2.daily_maintenance` is also a
control-plane-originated RPC. The control plane holds the transaction-scoped
Agent placement lock during its ten-second RPC budget. The Worker does not wait
behind Codex Home setup; it returns `skipped_setup_busy` and lets the next daily
reset try again.

## Read and Change Worker Files

The control plane reads and changes worker files through five worker-owned RPC
methods:

- `worker_files.pull`: the worker downloads bytes from a signed relay URL and
  writes one file.
- `worker_files.push`: the worker uploads one file to a signed relay URL.
- `worker_files.list`: directory list, with a `max_entries` bound.
- `worker_files.move`: same-root move or rename.
- `worker_files.delete`: file delete, or explicit recursive directory delete.

`rpc.proto` defines the request and response messages. The RPC frame carries
no turn fence for these methods; the control plane is the caller.

The control plane exposes these public roots:

- `user_files`
- `agent_installed_skills`
- `agent_sessions`

Each path begins with the Agent key and its canonical directory.
For example:

```text
/user_files/<agent-key>/user-files/inbox/10000/file.png
```

When an adapter limits a filename to ASCII, it first uses the native AnyAscii
transliterator and then removes unsafe filename characters. This keeps readable
Latin filenames instead of replacing each non-ASCII word with underscores.

The internal `agent_home_documents` root accepts only these files:

- `SOUL.md`
- `MISSION.md`
- `DESIGN.md`

The public root API does not expose this internal root.
The worker never exposes `.codex` state.

`Ankole.WorkerFiles` owns root policy, route selection, transfer bounds, and
the relay session. It selects any ready worker by default. An operator path can
pin one worker ID. A pinned operation never falls back to another worker.

One file can contain at most 100 MiB in either direction. A write fails before
the RPC when the input exceeds this limit. A read fails on the worker before
the upload when the file exceeds `max_bytes`, and the relay rejects a larger
request body with `413`.

The worker returns these error codes in `rpc_error.code`:

- `file_not_found`: the source path is absent.
- `not_regular_file`: the source is not a regular file.
- `file_changed`: the file changed while the worker uploaded it. The control
  plane does not accept the uploaded bytes as a successful read.
- `file_too_large`: the file exceeds `max_bytes`.
- `relay_failed`: the relay URL answered a non-2xx status or the HTTP request
  failed.
- `operation_failed`: any other failure.

These codes are the cross-runtime recovery contract. The message is for
diagnosis only.

`move` must stay inside one worker root. A directory delete requires
`recursive: true`.

## Transfer Files Safely

The relay keeps file bytes out of the RuntimeFabric connection and out of
control-plane memory:

1. The control-plane Pod that serves the user request opens an in-memory relay
   session with a random `transfer_id` and a short expiry.
2. It sends `worker_files.pull` or `worker_files.push` with a signed URL on
   its own internal origin.
3. The worker sends `GET` (pull) or `PUT` (push) to that URL.
4. The relay streams the bytes in bounded chunks between the user request and
   the worker request. It does not buffer a whole file.
5. The worker answers the RPC with the final size and fingerprint. The
   control plane then completes the user request.

The signed URL is:

```text
<internal origin>/internal/runtime-fabric/file-relay/<transfer_id>?token=<signature>
```

The signature is an HMAC-SHA256 over the method, scope, worker ID, incarnation ID,
transport route, root, relative path, `max_bytes`, expiry, nonce, and
`transfer_id`, keyed with the global worker authentication key. A URL is valid
for one request, one method, and one worker connection, and it expires with
the session. The URL is a bearer credential: neither runtime writes it to a
log, and Phoenix filters the `token` parameter.

The internal origin is the address of the issuing control-plane Pod, not a
load-balanced Service address, because only that Pod holds the relay session.
`ANKOLE_RUNTIME_FABRIC_INTERNAL_ORIGIN` sets it. When it is absent, the
control plane derives `http://<POD_IP>:<PORT>` from the Kubernetes Downward
API. Workers must be able to reach this origin.

The relay session is supervised memory state with an idle timeout. It is not a
PostgreSQL row. When the relay Pod, the worker, or the user request fails, the
whole operation fails, both sides release their state, and the caller repeats
the request. There is no resume.

The worker rejects `..` traversal and symlinks that leave an allowed root. All
public roots stay under `ANKOLE_AGENTS_ROOT`, which defaults to `/agents`.

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

Push and pull metadata include an XXH3 128-bit fingerprint. This value can show
that a file changed. It is not a cryptographic digest.

The worker keeps no transfer state after the RPC answers. The filesystem keeps
the file. PostgreSQL records how Ankole uses it.

## Move Attachments without an Agent Turn

File operations do not require an Actor turn. An adapter can save an attachment
even when the message does not wake an Agent.

The current inbound path is:

1. A provider adapter receives a resource reference or byte stream.
2. The control plane assigns a numeric attachment ID and records a pending
   provider observation in PostgreSQL.
3. The adapter writes bytes through `Ankole.WorkerFiles.put`.
4. The adapter replaces the pending observation with the real cross-session
   user-files path or a failed materialization state.

The current path does not ask a worker to fetch an arbitrary provider URL.

The ordinary outbound path is:

1. The worker creates a file under the Agent `user-files` directory.
2. The model calls `reply_attachment` with that real path.
3. Agent Computer calls `actor_turn.complete` with the final Response ID.
4. SignalsGateway validates structured attachment outputs.
5. The actor completion transaction inserts attachment outbox intents.
6. The provider adapter reads and uploads the file.
7. SignalsGateway records the outbound mirror after success.

Hosted tools make an exception for complete `image_generation_call` items.
AIGateway owns their artifact bytes. SignalsGateway materializes those bytes
under `user-files` during turn adoption.

Ankole never searches model prose for file paths. The model must return a
structured attachment record.

## Keep Agent Skills in Sync

Agent Plugins and Skills combine filesystem packages with control-plane
enablement state.

Built-in packages remain on the deployment-instance filesystem.
Agent-installed Skills remain under the Agent Home `installed-skills` directory.

Before a turn, the worker scans installed Skills and reports the full observed
set through `skills.installed.replace`. Each observation contains registry
metadata from `SKILL.md`; it does not contain a content hash or file inventory.
PostgreSQL stores the current registry set. The worker keeps the files in the
Agent Home and reads them when it prepares a run.

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

`skill_view` combines `SKILL.md` with the database note. `skill_append` changes
that note and does not write `AGENT_APPEND.md`.

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
It also contains two Helm values files with the verified release revision and
RuntimeFabric protocol version.

The Helm chart lives under `internals/helm-chart/ankole-agent`.
It requires digest-pinned images, the matching release revision, the protocol
version, and an explicit rollout phase.

Before the `control-plane` phase, the deployment scales the old Worker to zero
and waits until every old Worker Pod has terminated. That phase keeps worker
replicas at zero. After it succeeds, the `worker` phase starts the matching
Worker image. The chart sets the phase replica count, but the deployment
executor owns the pre-apply wait.

This order can briefly leave no workers during an incompatible protocol upgrade.
Stored ActorEvents and Jobs continue after matching workers connect.

Rollback uses the previous verified pair in the same two phases.
Do not roll back only one runtime.

Every control-plane Pod is one named Erlang node. DNSCluster discovers the
other Pods through a headless Service, the Pods share one release cookie, and
the distribution port is fixed so a NetworkPolicy can limit it to control-plane
Pods. Workers never use the distribution ports; they connect to the ClusterIP
Service for the channel and to the issuing Pod IP for a file relay. A Pod that
terminates leaves the Service first and then closes its channels, so Workers
reconnect to a remaining Pod and continue from PostgreSQL delivery state.
Distributed Erlang provides process addressing only; it is not a durable
single-writer guarantee.

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
