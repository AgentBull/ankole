# RuntimeFabric

RuntimeFabric is the control-plane to worker fabric. It has three lanes that
share worker transport and authentication, but they carry different kinds of
traffic:

- actor lane: turn lifecycle and live actor control;
- rpc lane: bidirectional bounded request/response calls for semantic methods;
- worker file lane: read, write, list, move, and delete operations against a
  worker-owned filesystem.

The lanes are not three product objects. They are a small routing split that
keeps durable semantics, request/response semantics, and bytes from pretending
to be the same thing.

RuntimeFabric uses lane names consistently. The older bus terminology is not
part of the current public architecture.

## Current ZeroMQ Shape

The current implementation multiplexes RuntimeFabric over one ZeroMQ connection
per worker:

- the control plane owns one Rust-managed `ROUTER` socket;
- each agent computer worker owns one Rust-managed `DEALER` socket;
- the `DEALER` identity is the transport route used by the control plane;
- actor and rpc traffic are protobuf envelope payload frames;
- worker file traffic is raw multipart data-plane traffic marked with
  `ANKOLE_FILE/1`.

The lane split is therefore not a socket split. Actor, rpc, and worker-file
traffic share the same route identity, socket authentication, high-water marks,
timeouts, and liveness failure modes. They differ at the frame and codec layer.

The control-plane `ROUTER` frame shape for an envelope is:

```text
[transport_route, protobuf_envelope]
```

The worker `DEALER` sees the envelope as:

```text
[protobuf_envelope]
```

The worker-file frame shapes are:

```text
[transport_route, ANKOLE_FILE/1, COMMAND, transfer_id, ...]
[ANKOLE_FILE/1, COMMAND, transfer_id, ...]
```

The Rust parser tolerates an empty delimiter frame and extra proxy-style leading
identity frames where useful, but the protocol we should document and generate
is the simpler shape above. That keeps interoperability room without making the
delimiter part of Ankole's own contract.

## Why ZeroMQ Here

ZeroMQ is used as the live actor fabric, not as durable storage. It gives the
runtime a small set of properties that match the worker pool:

- `ROUTER`/`DEALER` gives each connected worker a route identity without
  requiring a long-lived HTTP request or a per-worker server port;
- mandatory `ROUTER` send turns a missing route into an explicit
  `unknown_route` result instead of silent message loss;
- multipart frames let file operations carry binary chunks without JSON/base64
  or protobuf chunk wrappers;
- the same connection can carry control, turn, rpc, progress, and worker-file
  frames without inventing a second in-process worker protocol;
- Rust can own socket affinity, framing, ZAP, and protobuf validation while
  Elixir keeps PostgreSQL semantics and commit authority.

The tradeoff is intentional: ZeroMQ provides live routing and backpressure
signals, while PostgreSQL remains the source of replay, fences, reconciliation,
and final commit. The system should not recover actor state by asking ZeroMQ
what happened. If a fact matters after process death, it must be journaled or
committed in PG.

## Ownership

The control plane owns PostgreSQL semantic state:

- actor input journals;
- turn status, messages, summaries, and final commits;
- SOUL, MISSION, profile, and skill enablement;
- per-agent skill overlays;
- provider mirror and outbox state.

Workers are trusted first-party execution environments, but they do not own PG
domain rules. Worker reads and writes that touch PG semantics go through the
rpc lane. The worker process may keep a RuntimeFabric connection directly; it
does not need a native daemon turn-child protocol between Bun and the fabric.

Workers own their mounted filesystem roots. The control plane does not need to
mount worker NFS. When the control plane needs a file placed into, or read from,
the worker-visible filesystem, it uses the worker file lane.

## Transport Ownership

ZeroMQ sockets are thread-affine, so the native kernel owns socket threads:

- `ankole-runtime-fabric-router` owns the control-plane `ROUTER`;
- `ankole-runtime-fabric-dealer` owns the worker `DEALER`;
- `ankole-runtime-fabric-zap` owns the inproc ZAP `REP` socket when auth is
  enabled.

Elixir and Bun do not manipulate ZeroMQ sockets directly. They send commands
into the native socket thread and receive decoded events back through the host
binding:

- Elixir uses `Ankole.Kernel.RuntimeFabric` and
  `Ankole.ActorRuntime.Transport.Broker`;
- Bun uses `RuntimeFabricDealer`, `sendEnvelope`, `sendFileFrame`, and
  `recvRaw`;
- envelope encoding and decoding always pass through the Rust protobuf codec.

Current socket defaults favor bounded behavior over hidden buffering:

- `sndhwm` and `rcvhwm`: `1000`;
- `sndtimeo_ms` and `rcvtimeo_ms`: `1000`;
- `linger_ms`: `0`;
- receive poll interval: `10ms`;
- host command timeout: `1000ms`.

These are not product guarantees. They are operational defaults that keep
shutdown, worker loss, and backpressure visible while the runtime is still
small. Callers may tune them, but they should not depend on unbounded ZeroMQ
queues for correctness.

ZeroMQ send errors are mapped into actor-runtime language:

- `EHOSTUNREACH` becomes `unknown_route`;
- `EAGAIN` becomes `backpressure`;
- `ETERM` becomes `socket_closed`;
- other socket errors remain `zmq` transport errors.

`unknown_route` is a scheduling signal. The actor runtime should mark the worker
route stale and rely on durable delivery projections for retry instead of
treating the turn as delivered.

## Worker Authentication

RuntimeFabric uses ZeroMQ ZAP with PLAIN for worker bootstrap authentication.
Operators configure one global `worker_auth_key`; ZAP username/password are
implementation details:

- the control plane owns `runtime_fabric.worker_auth_key` in AppConfigure;
- the AppConfigure definition is encrypted and global-scope only;
- if the key is missing at startup, the control plane generates and persists a
  UUID value;
- PLAIN username is `WORKER_ID`;
- PLAIN password is the worker auth key from `RUNTIME_FABRIC_URL`;
- the control plane records the authenticated `worker_id` and key revision
  against the transport route;
- lifecycle envelopes are admitted against that authenticated route identity.

Worker startup needs only two worker identity/fabric environment variables:

```text
WORKER_ID=worker-a
RUNTIME_FABRIC_URL=tcp://:worker_auth_key@control-plane:port
```

`RUNTIME_FABRIC_URL` carries the control-plane endpoint and the shared auth key.
It does not carry a username; `WORKER_ID` stays separate so Docker Compose,
Kubernetes, or an operator script can choose a stable process identity. The
worker parses the URL into the ZeroMQ endpoint `tcp://control-plane:port` and
the PLAIN password. The same global `worker_auth_key` may be used by many
workers with different `WORKER_ID` values.

There is no per-worker auth-key table in the mainline and Rust does not receive
a database URL. Rust only receives the current in-memory worker auth key needed
for ZAP verification.

This is authentication for first-party workers on the runtime fabric. It is not
a user authorization model, not a public-worker hardening story, and not a
replacement for control-plane fences. A compromised or stale worker still cannot
commit a newer turn because write effects are checked against PG-owned turn refs
and revisions.

CURVE/TLS and public worker admission are not part of the current mainline.
That keeps the v1 implementation tied to the actual deployment assumption:
operator-launched Docker workers, private fabric endpoints, an AppConfigure
global worker key, and control-plane-owned durability.

## Envelope Invariants

The native protobuf codec validates invariants before a message crosses into
normal Elixir or Bun handlers:

- `protocol_version` must be `1`;
- every envelope must have `message_id`, `lane`, `durability`, and exactly one
  body;
- body type fixes the allowed lane and durability class;
- turn and rpc envelopes require `correlation_id`;
- rpc `correlation_id` must equal `request_id`;
- `turn_control` must remain a control envelope, not a second actor input
  payload channel;
- `worker_progress.kind` is limited to control-plane-visible progress classes.

This is why host code keeps a JSON-shaped envelope map even though the wire
format is protobuf. Elixir and Bun can build ergonomic maps, but Rust is the
single protocol checker for both runtimes.

The protobuf lane values are transport-level lanes shared by the whole
RuntimeFabric connection. They are lower-level than the product lane names and
are not subsections of the actor lane:

- `LANE_CONTROL`: worker lifecycle, turn control, shutdown;
- `LANE_TURN`: turn start, mailbox update, accepted inputs, final proposal, turn
  error;
- `LANE_PROGRESS`: worker progress observations;
- `LANE_RPC`: request/response/error RPC envelopes handled by the RPC lane.

The durability class is about control-plane replay/commit behavior, not ZeroMQ
persistence. `CONTROL_REPLAYABLE` and `CONTROL_DURABLE` still require PG-backed
facts; ZeroMQ never becomes the durable ledger.

## Actor Lane

The actor lane carries RuntimeFabric protobuf envelopes. It is for turn
lifecycle and live actor control, not for file bytes.

Typical actor lane messages:

- `worker_ready`, `worker_heartbeat`, `worker_capacity`;
- `turn_start`;
- `turn_accepted`;
- `mailbox_updated`;
- `turn_control`;
- `worker_progress`;
- `turn_final_proposal`;
- `turn_error`.

`turn_start` carries the current turn's delivery facts:

- `turn`: the `ActorTurnRef` fence;
- `inputs`: the accepted actor input envelopes;
- `model_ref`: the control-plane-selected runtime model profile for ordinary
  generation;
- `request_context`: current-turn facts such as schedule origin, turn mode, and
  `silent_success_allowed`.

`request_context` is not conversation history and is not agent identity. Worker
prompt construction reads durable transcript rows through RPC when it needs
history.

`turn_control(command = "retry")` is a stop signal for a turn the control plane
has already fenced in PostgreSQL. The worker should abort its local AI loop,
drop any late proposal for that turn, and release capacity. It should not report
the controlled stop as `turn_error`; `turn_error` remains reserved for worker
execution failure that makes the input retryable through the normal failure
path.

Every turn message carries an `ActorTurnRef`. The control plane validates this
turn fence against current database rows before accepting write effects. The
important fields are:

- actor key: `agent_uid` and `session_id`;
- `activation_uid`;
- `actor_epoch`;
- `llm_turn_id`;
- `revision`.

The fence is deliberately not a separate permission system. It is the minimum
runtime equality check that prevents old workers or old turn attempts from
committing into a newer actor state.

Final assistant output still returns as `turn_final_proposal`. The
`CommitCoordinator` owns the transaction that consumes actor inputs, writes the
assistant message, updates turn status, and appends provider-visible outbox
effects.

## RPC Lane

The rpc lane also uses RuntimeFabric protobuf envelopes. Its body type is
`rpc_request`, `rpc_response`, or `rpc_error`. Payloads are small JSON-compatible
objects. Large file bytes do not belong in rpc payloads.

The rpc lane is request/response traffic for semantic methods. It is not tied
to worker-owned files or actor-lane facts. Either side may initiate a bounded
RPC call when it needs a method owned by the other side.

The current worker-to-control-plane methods are mostly for PG semantic state:

- `agent_conversation.context.resolve`: returns the current
  `ai_agent_conversations` context: agent display facts, conversation id/key,
  started time, timezone, soul, mission, enabled skills, and optional cache key.
  It does not return request context or transcript messages;
- `conversation.history.resolve`: returns complete active conversation
  transcript rows for `purpose = "prompt"` or `purpose = "compression"`.
  Each row carries `id`, `role`, `kind`, `content`, `metadata`, `created_at`,
  and optional `covers_range`. `created_at` is `ai_agent_messages.inserted_at`;
- `conversation.summary.commit`: commits a worker-produced `/compress` summary.
  The worker supplies summary text and covered message ids for the older prefix
  being folded; the recent tail remains normal transcript and is not covered by
  the summary. The control plane validates the turn fence and that covered ids belong to the active
  conversation, writes the summary row, consumes the `command.compress` actor
  input, and appends fixed provider-visible feedback. Accepted `/steer` inputs
  on the compression turn are released for the next turn instead of being
  consumed by the summary commit. It does not generate summaries or choose
  coverage;
- `skills.overlay.resolve`: returns one agent/skill overlay;
- `skills.overlay.replace`: replaces one overlay;
- `skills.overlay.clear`: clears one overlay;
- `ai_gateway.api_key_for.create_or_find_by_agent`: returns an agent-scoped
  AIGateway API key for the turn's actor.

The current control-plane-to-worker methods are worker-owned semantic methods:

- `worker.runtime.describe`: returns worker process/runtime facts such as worker
  identity, active turn count, and configured workspace roots.

RPC requests that belong to a turn include `ActorTurnRef`. The server checks the
route and turn fence at the method boundary. Read methods may accept the current
live turn fence. Write methods must match the current revision.

The rpc lane should stay coarse enough to avoid chatty PG access. A normal text
turn resolves agent conversation context once and history once before building
the prompt. Skill overlays are resolved only when `skill_view` or
`skill_append` needs them.

The control-plane `RPCLane` is deliberately small. It dispatches methods and
wraps handler results as `rpc_response` or `rpc_error`; method handlers own
their domain checks. That keeps the transport broker from becoming a second
application service layer.

The worker's RPC client is in-process and request-id based. It sends
`rpc_request` envelopes over the same `DEALER` socket and waits for the matching
`rpc_response` or `rpc_error`. The current timeout is `60s`, which is a worker
runtime budget, not a database transaction budget.

The control-plane RPC client is also request-id based. It sends `rpc_request`
envelopes through the existing mandatory route send, stores a pending caller in
the transport broker, and resolves that caller when the worker replies with
`rpc_response` or `rpc_error` on the same route.

## Worker File Lane

The worker file lane is RuntimeFabric's filesystem lane. It uses raw ZeroMQ
multipart frames, not protobuf, and it does not base64 encode file content.
Frame roles are explicit:

- protocol marker, command, and `transfer_id` are text frames;
- numbers such as sequence, offset, byte credit, sizes, and timestamps are
  unsigned big-endian binary integer frames;
- booleans are one-byte frames;
- paths are virtual worker-root paths such as
  `/user_files/inbox/lark/message-1/image.png`;
- directory listings use a compact typed binary table;
- file content is carried only by `DATA` binary chunk frames.

The protocol marker is:

```text
ANKOLE_FILE/1
```

The current frame shape is:

```text
[ANKOLE_FILE/1, COMMAND, transfer_id, ...]
```

Transfer commands are intentionally small:

- `WRITE_OPEN`: start writing one zstd stream to a scratch path;
- `WRITE_READY`: worker accepted the scratch write and grants initial byte
  credit;
- `DATA`: one binary zstd chunk with sequence, wire offset, and eof flag;
- `CREDIT`: receiver grants more bytes to the sender;
- `WRITE_COMMIT`: ask the worker to decode, verify, and publish atomically;
- `WRITE_COMMITTED`: final write result with size and optional XXH3
  observation;
- `WRITE_ABORT`: discard an incomplete write;
- `READ_OPEN`: ask the worker to stream one file;
- `READ_READY`: read metadata before chunks start;
- `READ_DONE`: read terminator with chunk count and wire size;
- `READ_ABORT`: stop an active read stream;
- `STAT`: return file size, kind, mtime, and optional XXH3 observation;
- `STAT_OK`: stat result;
- `LIST`: list directory entries, optionally recursive and bounded;
- `LIST_OK`: typed list result;
- `MOVE`: move one file or directory within the same worker root;
- `MOVE_OK`: move result;
- `DELETE`: delete one file, or a directory only when explicitly recursive;
- `DELETE_OK`: delete result;
- `ERROR`: operation failure with code and message;
- `RTFM`: malformed file-lane protocol command.

There is no JSON metadata frame in the file lane. Small structured values are
separate typed frames because ZeroMQ already gives the protocol multipart
boundaries. File content is always a `DATA` binary chunk frame. A `WRITE_OPEN`,
`READ_OPEN`, `STAT`, `DELETE`, or `LIST` operation addresses a path like:

```text
/user_files/inbox/lark/message-1/image.png
```

Supported roots are worker filesystem roots, not S3 buckets:

- `user_files`: worker-visible user files;
- `agent_installed_skills`: worker-visible installed skill files.

The S3 comparison is only a product metaphor: the control plane can ask the
worker to read or write file-like objects. It is not a technical decision to
introduce S3 object keys, buckets, storage classes, presigned URLs, or a generic
object-store abstraction.

`MOVE` uses two virtual paths and must stay inside the same worker root.
Cross-root moves are not part of the lane.

### Worker File Implementation Notes

The worker currently implements the file service. It validates each transfer
against configured worker-visible roots and rejects paths that escape the root.
The supported roots are:

- `ANKOLE_USER_FILES_ROOT`, defaulting to `/workspace/shared/user-files`;
- `ANKOLE_AGENT_INSTALLED_SKILLS_ROOT`, defaulting to
  `/workspace/shared/skills/agents`.

Inbound `WRITE_OPEN` writes into a scratch directory under:

```text
ANKOLE_SHARED_FS_ROOT/.ankole-file-transfer/<transfer_id>/
```

The worker appends `DATA` chunks in sequence and verifies original size after
zstd decode. `WRITE_COMMIT` decodes the scratch zstd stream into a final temp
path and publishes with an atomic rename. `WRITE_ABORT` removes the scratch
directory. `READ_OPEN` streams the file back as zstd `DATA` chunks under
control-plane byte credit. `READ_ABORT` stops the worker-side read stream when
the control-plane caller times out or cancels. `STAT` and `READ_READY` can return
an XXH3 128-bit observation fingerprint. This fingerprint is for change
detection and catalog observations, not security verification.

The control-plane `FileTransferLane` owns only in-memory request/response
correlation for the active operation. It does not add a durable worker-file
state machine. Files are durable once written under the worker root and
referenced from PG semantic rows; transient chunk exchange does not need its own
PG-backed broker unless retry/resume requirements become real.

## Worker File Encoding

The worker file lane always uses zstd on the wire. There is no identity mode and
no per-operation content-encoding negotiation.

Stored files remain original bytes. For inbound writes, the control plane sends
one zstd stream split across `DATA` frames and the worker decodes that stream
before the final rename. For outbound reads, the worker compresses the stored
file into a zstd stream and returns that stream across `DATA` frames.

This is a bandwidth optimization, not a storage model. The worker image and the
control-plane runtime must provide `zstd` for high-level `put` and `get`.
Missing support is a readiness/runtime error, not a reason to fall back to
another encoding.

The reason for raw multipart plus default `zstd` is practical:

- binary frames avoid JSON/base64 expansion and extra copies;
- protobuf remains reserved for small semantic envelopes;
- zstd never changes the stored bytes;
- failed zstd availability is a worker readiness/runtime issue, not a fallback
  storage format.

## Files And Actor Turns

Worker file operations are fully decoupled from actor sessions and turns. This
matters for read-only or ambient group messages: the system may need to
materialize an image or file for future recall even when no actor turn is
started.

The current inbound path is:

1. A provider adapter receives a message with a provider resource reference or
   byte stream.
2. The control plane records provider observations and source references in PG.
3. The control plane asks a worker to materialize the file through the file
   lane.
4. PG stores the worker-visible path observation for later actor inputs.

For Lark/Feishu resource messages, the production inbound consumer downloads
the provider resource bytes and writes them through `ActorRuntime.put_worker_file`
to `user_files`. The signal attachment keeps the provider reference and gains a
`/workspace/user-files/...` path plus XXH3 observation when materialization
succeeds.

Provider-direct worker fetch from a URL can be added later as an optimization,
but it is not the current production contract. The current contract is bytes in
over the file lane.

The current outbound path is:

1. A worker writes or references a file under its visible roots.
2. The model calls `reply_attachment` to register an existing
   `/workspace/user-files/...` file as a native provider attachment.
3. The final proposal carries `reply.attachments`; the commit coordinator stores
   those attachments in the assistant transcript and the SignalsGateway outbox
   payload.
4. The provider adapter reads the file through `ActorRuntime.get_worker_file`,
   uploads bytes to the provider, and sends the provider-native file message.
5. On send success, SignalsGateway mirrors the outbound entry with the same
   worker-visible attachment observation.

Do not infer outbound attachments by scraping text for `/workspace/...` paths.
The structured attachment field is the contract.

The Lark/Feishu v1 adapter supports one native file attachment per outbox row.
Multiple provider-visible files should be modeled as separate outbox intents
rather than hidden behind one durable row.

Actor turns can reference files, but file materialization does not require an
actor turn.

This decoupling matters for ZMQ routing too. A file operation is addressed to a
worker route and filesystem root, not to an `ActorTurnRef`. Actor references are
PG semantic rows written elsewhere. If a future file operation needs
actor-scoped policy, that policy should be checked before issuing the file
command rather than hidden inside the file lane.

## Skills

Builtin skills and agent-installed skills are both filesystem skills.

- Builtin skills live in the image/repo. They exist by default, but their
  default enabled state comes from metadata.
- Agent-installed skills live in the worker-visible installed-skills root.
- PG stores domain semantics and file observations: registry, enablement,
  display/category data, overlay data, observed XXH3 fingerprints, and
  observation timestamps.
- The control plane does not discover agent-installed skills by mounting worker
  NFS. Installed-skill registry rows are refreshed from explicit worker file
  lane observations, not from control-plane directory scans. The worker remains
  the reader of the actual installed skill files.

`skill_view` reads the base skill file from the filesystem and merges the
database overlay when reading `SKILL.md`. `skill_append` keeps its external tool
name for compatibility, but it replaces the database overlay. It does not write
`AGENT_APPEND.md`.

## Non-Goals

RuntimeFabric is not:

- TigerFS;
- a control-plane NFS mount;
- a durable ZeroMQ queue;
- a general message broker;
- a separate per-lane socket farm;
- a full FileMQ implementation;
- an S3 clone;
- a protobuf file-chunk protocol;
- a turn-scoped file-write API;
- a second PG domain owner inside the worker.

The useful boundary is small: actor facts over protobuf, semantic PG requests
over protobuf RPC, and bytes over raw multipart frames.
