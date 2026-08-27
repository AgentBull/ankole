# RuntimeFabric

RuntimeFabric connects the Elixir control plane to Agent Computer workers.
It carries live messages but does not store them. PostgreSQL stores any data
that Ankole needs after a restart.

The connection carries three groups of messages:

- Actor messages start, steer, stop, and report non-response terminal states.
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
- worker drain before shutdown of the `DEALER`

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
ANKOLE_RUNTIME_FABRIC_ENDPOINT=tcp://control-plane:port
ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=<worker-auth-key>
```

The endpoint and shared password are separate bootstrap facts. `WORKER_ID`
supplies the PLAIN username. The Worker validates the endpoint, copies the key
into memory, and removes the key from the environment that child processes
inherit.

All workers can use the same key. Ankole does not store a different key for
each worker.

`worker_id` names a worker slot chosen by the operator. Each new process creates
a fresh `incarnation_id`.

Ready, heartbeat, and capacity messages contain both identifiers.
The control plane also records the authenticated route.

On process shutdown, the worker sends `control_shutdown` to the control plane.
This direction means "the worker process is shutting down." The control plane
marks the worker, its assignments, and its live activations as `draining`. It
does not release their turn fences. A draining worker receives no new turns but
can finish terminal writes and receive RPC responses.

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
The envelope header must use the current protocol version owned by the Rust
kernel.

The runtimes generate codecs from the same file:

- Rust uses `prost-build`.
- Elixir uses `protox`.
- TypeScript uses `protoc-gen-es`.

Generate committed TypeScript output with `bun run gen:proto`.
A sidecar hash pins the source and generator inputs.

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

Tools can decode version 1 fixtures for diagnosis, but worker admission rejects
version 1 messages.

## Protocol Lanes and Durability Classes

The Protobuf protocol uses four technical lanes:

- `LANE_CONTROL` carries worker lifecycle and turn control.
- `LANE_TURN` carries turn start, mailbox updates, and acceptance.
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

Workers finish turns through the `actor_turn.complete`, `actor_turn.noop`, and
`actor_turn.abort` RPCs. All supported v0.70+ Workers use these RPCs, so the
compatibility window does not include the former terminal envelopes.

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
Protocol version 4 requires this field so a mixed-version worker cannot create
a different directory.

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

SignalsGateway checks that the Response chain did not change. It then completes
the main ActorEvent and every input delivery with `revision <= R`, and it stores
the replies in one transaction. A delivery with `revision > R` stays open.
Completion is stronger than `turn_accepted`, so it can commit an applied
delivery that is still `sent`. This removes a race between the actor-lane
acceptance task and the RPC task.

`actor_turn.noop` consumes the same applied prefix. `actor_turn.abort` validates
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
replayed. ActorRuntime dead-letters the event and commits a provider-visible
failure notice for manual recovery. A notice with no route, because its channel
takes no replies or its route rows are deleted, is logged and skipped. Worker
takeover never depends on an old event's channel.

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

Elixir keeps an explicit dispatch table because broker functions and request
modules are control-plane implementation facts. Package-local tests compare the
Bun projection and the Elixir table with the committed contract. The control
plane encodes and decodes all business payloads in one place.

Turn-scoped frames carry `ActorTurnRef` outside the payload.
Worker-agent frames carry a trusted `agent_uid` outside the payload.

The server authorizes the outer frame before it decodes the business payload.
The completion effect also accepts an idempotent retry from the same worker and
activation after the ActorEvent has completed. The payload does not repeat
identity or request IDs.

The registry currently contains these method families:

- Agent conversation context.
- Agent Plugin catalog.
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
