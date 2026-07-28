# RuntimeFabric

RuntimeFabric connects the Elixir control plane to Agent Computer workers.
It carries live messages but does not store them. PostgreSQL stores any data
that Ankole needs after a restart.

The connection carries three groups of messages:

- Actor messages start, steer, stop, and complete Agent turns.
- RPC messages ask another process to read or change Ankole data.
- File messages read or change files on a worker.

All three groups use the same worker connection and authentication.

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
plane uses file messages when it needs a worker file.

All workers in one deployment instance must still see the same Agent Home
storage.
File messages do not replace shared storage.

## One ZeroMQ Connection per Worker

RuntimeFabric uses one ZeroMQ connection per worker.

- The control plane runs one Rust-managed `ROUTER` socket.
- Each worker runs one Rust-managed `DEALER` socket.
- The `DEALER` identity tells the control plane where to send a message.

Actor and RPC messages use Protobuf. File messages use raw multipart frames.

The control-plane envelope shape is:

```text
[transport_route, protobuf_envelope]
```

The worker receives:

```text
[protobuf_envelope]
```

The control-plane file shape is:

```text
[transport_route, ANKOLE_FILE/1, COMMAND, transfer_id, ...]
```

The worker receives:

```text
[ANKOLE_FILE/1, COMMAND, transfer_id, ...]
```

The parser accepts an empty delimiter or extra proxy identity frames, but the
generated Ankole protocol does not require them.

## Rust Owns the ZeroMQ Sockets

ZeroMQ requires each socket to stay on one thread. The Rust kernel runs those
threads.

- `ankole-runtime-fabric-router` owns the `ROUTER`.
- `ankole-runtime-fabric-dealer` owns one `DEALER`.
- `ankole-runtime-fabric-zap` owns the ZAP `REP` socket.

Elixir and Bun never operate a ZeroMQ socket directly. They send commands to
the Rust thread.

Elixir uses `Ankole.Kernel.RuntimeFabric` and the ActorRuntime transport broker.
Bun uses one host adapter over `RuntimeFabricDealer`.

The Bun adapter handles:

- limited send retries
- conversion of native errors
- decoding of generated envelopes
- calls to kernel validation
- separation of envelopes from file frames
- orderly shutdown of the `DEALER`

The adapter does not schedule Actors or decide when a turn ends.

## Socket Defaults Limit Waiting and Queues

These defaults keep queues and shutdown delays finite. An operator must not
treat them as product guarantees.

| Setting | Default |
| --- | --- |
| Send queue limit (ZeroMQ high-water mark) | 1,000 |
| Receive queue limit (ZeroMQ high-water mark) | 1,000 |
| Send timeout | 1,000 milliseconds |
| Receive timeout | 1,000 milliseconds |
| Linger | 0 milliseconds |
| Poll interval | 10 milliseconds |
| Host command timeout | 10,000 milliseconds |
| Dealer inbox events | 1,024 |
| Dealer inbox bytes | 64 MiB |

The limits let Ankole detect blocked sends, full queues, shutdown, and worker
loss.

If router startup fails late, Rust closes the bound socket. If the host command
sender disappears, Rust stops the socket loop.

The transport maps common ZeroMQ errors as follows:

| ZeroMQ error | RuntimeFabric result |
| --- | --- |
| `EHOSTUNREACH` | `unknown_route` |
| `EAGAIN` | `backpressure` |
| `ETERM` | `socket_closed` |
| Other errors | `zmq` transport error |

`unknown_route` marks the worker route as stale. ActorRuntime then decides
whether to retry stored work.

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

## Authenticate a Worker

RuntimeFabric uses ZeroMQ ZAP with PLAIN authentication.
The control plane stores one encrypted AppConfigure key:

```text
runtime_fabric.worker_auth_key
```

The control plane creates this key when necessary. Rust receives only its
decrypted in-memory value.

Worker startup requires these values:

```text
WORKER_ID=worker-a
RUNTIME_FABRIC_URL=tcp://:<worker-auth-key>@control-plane:port
```

The URL contains the endpoint and shared password. `WORKER_ID` supplies the
PLAIN username.

All workers can use the same key. Ankole does not store a different key for
each worker.

`worker_id` names a worker slot chosen by the operator. Each new process creates
a fresh `incarnation_id`.

Ready, heartbeat, and capacity messages contain both identifiers.
The control plane also records the authenticated route.

A new incarnation replaces the old process for the same worker ID. One
transaction releases the old assignments and invalidates their turn fences.

The control plane rejects delayed messages from the old process.

A worker becomes stale after 60 seconds without a valid heartbeat. Cleanup can
remove its routing record after 3,600 seconds.

After a router restart, the first authenticated worker lifecycle message
reconnects the route to its ZAP identity.

A valid worker lifecycle message can make a stale worker active again. It cannot
restore released assignments or old delivery attempts. A stopped worker cannot
reactivate itself.

Raw file frames cannot authenticate a new worker route because they contain no
worker lifecycle identity.

This protocol authenticates trusted first-party workers. Database turn fences
still protect each write. Ankole does not provide CURVE, TLS, or public worker
admission here.

## Validate Every Actor and RPC Message

`app/kernel/proto/ankole/runtime_fabric/v1/envelope.proto` defines the message
structure.
The generated package namespace remains `ankole.runtime_fabric.v1`.
The envelope header currently requires protocol version 3.

The runtimes generate codecs from the same file:

- Rust uses `prost-build`.
- Elixir uses `protox`.
- TypeScript uses `protoc-gen-es`.

Generate committed TypeScript output with `bun run gen:proto`.
A sidecar hash pins the source and generator inputs.

The Rust kernel checks every envelope before sending and after receiving it:

- `protocol_version` must equal 3.
- `message_id`, lane, durability, and body must exist.
- The body fixes its lane and durability class.
- Turn and RPC envelopes require a correlation ID.
- An RPC correlation ID must equal its request ID.
- A turn reference must contain all turn-fence fields.
- `turn_completed.final_response_id` must start with `resp_`.
- `turn_completed.outcome` must be explicit.
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

Tools can decode version 1 fixtures for diagnosis, but worker admission rejects
version 1 messages.

## Protocol Lanes and Durability Classes

The Protobuf protocol uses four technical lanes:

- `LANE_CONTROL` carries worker lifecycle and turn control.
- `LANE_TURN` carries turn start, acceptance, and completion.
- `LANE_PROGRESS` carries progress observations.
- `LANE_RPC` carries RPC requests and results.

The durability flag tells the control plane what it must store or replay.
It does not make ZeroMQ a stored queue.

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
- `turn_completed`
- `turn_noop_completed`
- `turn_error`

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
- The selected model reference.
- Current request context.
- Hosted tool configuration.
- Trusted runtime environment facts for this Turn.

Request context contains current request details, not conversation history.
AIGateway builds model history for each Response.

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

Read RPCs can use a current live revision.
Write RPCs must match the revision in the current turn fence.

### Add Input to a Running Turn

`mailbox_updated` contains one journaled actor event.
It injects a steer command into a running turn.

The control plane completes the command event after `sent_or_queued`. This means
that the worker received or queued it, not that the model read it.

The worker can finish before it reads the update. The delivery record keeps
that weaker result.

### Retry a Turn

`turn_control` with `command = "retry"` stops the named local turn. The worker
ends its loop, releases capacity, and does not report `turn_error`.

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

`turn_completed` contains the final Response ID and one outcome.

- `loop_finished` means the worker loop ended normally.
- `iteration_exhausted` means the local iteration budget ended.

Neither outcome proves the broader user task succeeded.

SignalsGateway checks that the Response chain did not change. It then completes
the ActorEvent and stores the replies in one transaction.

The same commit clears the current ActorEvent and briefly keeps the Session on
the worker for possible follow-up work.

AIGateway completion closes one Response only.
It does not complete the actor event.

RuntimeFabric sends no completion acknowledgement. If the commit fails, the
ActorEvent stays open and ActorRuntime can try again.

A turn with no reply uses `turn_noop_completed`. Silence alone never completes
a turn. A worker failure uses `turn_error` and the normal retry path.

## Call Functions in Another Process

The RPC lane uses `rpc_request`, `rpc_response`, and `rpc_error` envelopes.
Both control plane and worker clients correlate calls by request ID.

`app/kernel/proto/ankole/runtime_fabric/v1/rpc.proto` declares business messages.
`rpc_methods.json` is the method registry SSOT.

Each registry row defines:

- the method name
- its authorization scope
- whether a turn method reads or writes
- the request message type
- the response message type

Elixir and Bun tests check the same registry. The control plane encodes and
decodes all business payloads in one place.

Turn-scoped frames carry `ActorTurnRef` outside the payload.
Worker-agent frames carry a trusted `agent_uid` outside the payload.

The server authorizes the outer frame before it decodes the business payload.
The payload does not repeat identity or request IDs.

The registry currently contains these method families:

- Agent conversation context.
- Agent Plugin catalog.
- AIGateway API key resolution.
- AppConfigure and WorkerEnv resolution.
- Background Agent Job lifecycle and trajectory.
- Codex account resolution and authentication writeback.
- Brain memory operations.
- Schedule operations.
- Installed Skill observations.
- Skill overlay resolve, append, and replace operations.

Memory and schedule RPCs use `JSONPassthroughResponse`. The worker passes
`body_json` to the model without changing its fields.

The RPC lane does not carry conversation history or compaction commits.
AIGateway owns both concerns.

The worker RPC timeout is 300 seconds.
This runtime timeout is not a PostgreSQL transaction budget.

## Read and Change Worker Files

The worker file lane uses raw ZeroMQ multipart frames.
It does not use Protobuf or Base64 for file content.

The protocol marker is:

```text
ANKOLE_FILE/1
```

Text frames carry commands, transfer IDs, and paths. Binary frames carry sizes,
offsets, sequence values, timestamps, booleans, and compressed file blocks.

The protocol supports these operation groups:

- Write open, data, credit, commit, and abort.
- Read open, ready, data, credit, done, and abort.
- Stat.
- Directory list.
- Same-root move.
- File or explicit recursive delete.
- Structured error and malformed-command responses.

`READ_OPEN` uses `file_not_found` when the source path is absent and
`not_regular_file` when the source is not a regular file. These codes are the
cross-runtime recovery contract. The accompanying error message is for
diagnosis and is not a recovery key.

A read that observes a different path after `READ_READY` uses `file_changed`.
The control plane can retry this failure, but it does not accept bytes from the
old file descriptor as a successful read.

The control plane exposes these public roots:

- `user_files`
- `agent_installed_skills`
- `agent_sessions`

Each path begins with the Agent key and its canonical directory.
For example:

```text
/user_files/<agent-key>/user-files/inbox/file.png
```

The internal `agent_home_documents` root accepts only these files:

- `SOUL.md`
- `MISSION.md`
- `DESIGN.md`

The public root API does not expose this internal root.
The file lane never exposes `.codex` state.

`Ankole.WorkerFiles` owns root policy, route selection, and transfer bounds.
It selects any ready worker by default.
An operator path can pin one worker ID.
A pinned operation never falls back to another worker.

One file can contain at most 100 MiB in either direction.
A write fails before the first frame when the input exceeds this limit.

A read checks the authoritative size in `READ_READY`.
An oversized read sends `READ_ABORT` before any byte credit.

`MOVE` must stay inside one worker root.
A directory delete requires `recursive: true`.

## Transfer Files Safely

The worker rejects `..` traversal and symlinks that leave an allowed root. All
public roots stay under `ANKOLE_AGENTS_ROOT`, which defaults to `/agents`.

Inbound writes use this scratch path:

```text
/tmp/ankole-file-transfer/<transfer-id>/
```

`WRITE_COMMIT` moves the checked temporary file into place with an atomic
rename. `WRITE_ABORT` removes it.

The lane always uses zstd level 3 on the wire.
It does not negotiate another encoding.

Each `DATA` frame contains an independent zstd frame. One block contains at most
2 MiB before compression. The final file keeps the original bytes.

The Rust kernel provides zstd to both hosts.
Elixir uses a dirty CPU scheduler.
Bun uses an asynchronous native task.

A runtime without native zstd support cannot become ready. It does not use an
external binary or another compression format.

Stat and read metadata can include an XXH3 128-bit fingerprint.
This value can show that a file changed. It is not a cryptographic digest.

The process tracks active transfers in memory. The filesystem keeps the file.
PostgreSQL records how Ankole uses it.

## Move Attachments without an Agent Turn

File operations do not require an Actor turn. An adapter can save an attachment
even when the message does not wake an Agent.

The current inbound path is:

1. A provider adapter receives a resource reference or byte stream.
2. The control plane records a pending provider observation in PostgreSQL.
3. The adapter writes bytes through `Ankole.WorkerFiles.put`.
4. The adapter replaces the pending observation with the real Agent Home path
   or a failed materialization state.

The current path does not ask a worker to fetch an arbitrary provider URL.

The ordinary outbound path is:

1. The worker creates a file under the Agent `user-files` directory.
2. The model calls `reply_attachment` with that real path.
3. Agent Computer sends `turn_completed` with the final Response ID.
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

The worker uses these overlay RPC methods:

- `skills.overlay.resolve` reads the database overlay.
- `skills.overlay.append` appends one durable note.
- `skills.overlay.replace` replaces the complete overlay.

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

Before the `control-plane` phase, the deployment scales the old Worker to zero.
That phase keeps worker replicas at zero. After it succeeds, the `worker` phase
starts the matching worker image.

This order can briefly leave no workers during an incompatible protocol upgrade.
Stored ActorEvents and Jobs continue after matching workers connect.

Rollback uses the previous verified pair in the same two phases.
Do not roll back only one runtime.

## What RuntimeFabric Does Not Do

RuntimeFabric is not any of these systems:

- A durable ZeroMQ queue.
- A general message broker.
- A per-lane socket farm.
- A control-plane NFS mount.
- An S3-compatible object store.
- A Protobuf file-chunk protocol.
- A conversation-history RPC service.
- A second set of domain records written by the worker.
