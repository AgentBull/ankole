# RuntimeFabric

RuntimeFabric is the control-plane to worker fabric. It has three lanes that
share worker transport and authentication, but they carry different kinds of
traffic:

- actor lane: turn lifecycle and live actor control;
- rpc lane: worker requests for control-plane semantic state;
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
The operator-facing concept is still one `pre auth token`; ZAP username/password
are implementation details:

- PLAIN username is the stable `worker_id`;
- PLAIN password is the pre-auth key/token;
- the control plane records the authenticated `worker_id` and `key_revision`
  against the transport route;
- lifecycle envelopes are admitted against that authenticated route identity.

The router supports three auth sources:

- database-backed worker auth keys, which is the normal control-plane path;
- static per-worker keys, useful for focused tests or controlled bootstrap;
- one shared secret, useful for narrow smoke tests.

This is authentication for first-party workers on the runtime fabric. It is not
a user authorization model, not a public-worker hardening story, and not a
replacement for control-plane fences. A compromised or stale worker still cannot
commit a newer turn because write effects are checked against PG-owned turn refs
and revisions.

CURVE/TLS and public worker admission are not part of the current mainline.
That keeps the v1 implementation tied to the actual deployment assumption:
operator-launched Docker workers, private fabric endpoints, PG-backed worker
keys, and control-plane-owned durability.

## Actor Lane

The actor lane carries RuntimeFabric protobuf envelopes. It is for turn
lifecycle and live actor control, not for file bytes.

Typical actor lane messages:

- `worker_ready`, `worker_heartbeat`, `worker_capacity`;
- `turn_start`;
- `turn_accepted`;
- `mailbox_updated`;
- `worker_progress`;
- `turn_final_proposal`;
- `turn_error`.

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

### Envelope Invariants

The native protobuf codec validates invariants before a message crosses into
normal Elixir or Bun handlers:

- `protocol_version` must be `1`;
- every envelope must have `message_id`, `lane`, `durability`, and exactly one
  body;
- body type fixes the allowed lane and durability class;
- turn and rpc envelopes require `correlation_id`;
- rpc `correlation_id` must equal `request_id`;
- `turn_control` with command `steer` must not smuggle steering payloads;
- `worker_progress.kind` is limited to control-plane-visible progress classes.

This is why host code keeps a JSON-shaped envelope map even though the wire
format is protobuf. Elixir and Bun can build ergonomic maps, but Rust is the
single protocol checker for both runtimes.

The protobuf lane values are lower-level than the product lane names:

- `LANE_CONTROL`: worker lifecycle, turn control, shutdown;
- `LANE_TURN`: turn start, mailbox update, accepted inputs, final proposal, turn
  error;
- `LANE_PROGRESS`: worker progress observations;
- `LANE_RPC`: request/response/error RPC envelopes.

The durability class is about control-plane replay/commit behavior, not ZeroMQ
persistence. `CONTROL_REPLAYABLE` and `CONTROL_DURABLE` still require PG-backed
facts; ZeroMQ never becomes the durable ledger.

## RPC Lane

The rpc lane also uses RuntimeFabric protobuf envelopes. Its body type is
`rpc_request`, `rpc_response`, or `rpc_error`. Payloads are small JSON-compatible
objects. Large file bytes do not belong in rpc payloads.

The worker uses the rpc lane for PG semantic state:

- `runtime.turn_context.resolve`: returns the batched turn context, including
  soul, mission, conversation window, enabled skills, and overlay digest;
- `skills.overlay.resolve`: returns one agent/skill overlay;
- `skills.overlay.replace`: replaces one overlay;
- `skills.overlay.clear`: clears one overlay;
- provider credential and profile resolution methods.

RPC requests that belong to a turn include `ActorTurnRef`. The server checks the
route and turn fence at the method boundary. Read methods may accept the current
live turn fence. Write methods must match the current revision.

The rpc lane should stay coarse enough to avoid chatty PG access. A turn starts
with one context resolve call. Skill overlays are resolved only when
`skill_view` or `skill_append` needs them.

The control-plane `RPCLane` is deliberately small. It dispatches methods and
wraps handler results as `rpc_response` or `rpc_error`; method handlers own
their domain checks. That keeps the transport broker from becoming a second
application service layer.

The worker's RPC client is in-process and request-id based. It sends
`rpc_request` envelopes over the same `DEALER` socket and waits for the matching
`rpc_response` or `rpc_error`. The current timeout is `60s`, which is a worker
runtime budget, not a database transaction budget.

## Worker File Lane

The worker file lane is RuntimeFabric's filesystem lane. It uses raw ZeroMQ
multipart frames for file bytes and small JSON frames for file operations. It
does not use protobuf and does not base64 encode file content.

The protocol marker is:

```text
ANKOLE_FILE/1
```

The current frame shape is:

```text
[ANKOLE_FILE/1, COMMAND, transfer_id, ...]
```

Commands are intentionally small:

- `PUT_BEGIN`: start writing a file;
- `PUT_CHUNK`: append one binary chunk;
- `PUT_COMMIT`: atomically publish the completed file;
- `PUT_ABORT`: discard an incomplete write;
- `GET`: stream a file back to the caller;
- `STAT`: return file size, kind, mtime, and optional XXH3 observation;
- `LIST`: list directory entries, optionally recursive and bounded;
- `MOVE`: move one file or directory within the same worker root;
- `DELETE`: delete one file, or a directory only when explicitly recursive;
- worker responses: `ACK`, `ERROR`, `GET_BEGIN`, `GET_CHUNK`, `GET_END`,
  `LIST_RESULT`.

Operation frames are JSON because operation data is small. File content is
always a binary frame. A `PUT_BEGIN`, `GET`, `STAT`, `DELETE`, or `LIST`
operation addresses a path with:

```json
{
  "root": "user_files",
  "relative_path": "inbox/lark/message-1/image.png"
}
```

Supported roots are worker filesystem roots, not S3 buckets:

- `user_files`: worker-visible user files;
- `agent_installed_skills`: worker-visible installed skill files.

The S3 comparison is only a product metaphor: the control plane can ask the
worker to read or write file-like objects. It is not a technical decision to
introduce S3 object keys, buckets, storage classes, presigned URLs, or a generic
object-store abstraction.

`MOVE` uses one root plus `from_relative_path` and `to_relative_path`. Cross-root
moves are not part of the lane.

### Worker File Implementation Notes

The worker currently implements the file service. It validates each transfer
against configured worker-visible roots and rejects paths that escape the root.
The supported roots are:

- `ANKOLE_USER_FILES_ROOT`, defaulting to `/workspace/shared/user-files`;
- `ANKOLE_AGENT_INSTALLED_SKILLS_ROOT`, defaulting to
  `/workspace/shared/skills/agents`.

Inbound `PUT` writes into a scratch directory under:

```text
ANKOLE_SHARED_FS_ROOT/.ankole-file-transfer/<transfer_id>/
```

The worker appends chunks in order, optionally verifies original size and
then publishes with an atomic rename into the target path. `PUT_ABORT` removes
the scratch directory. `GET` streams the file back in `1MiB` chunks. `STAT` and
`GET_BEGIN` can return an XXH3 128-bit observation fingerprint. This fingerprint
is for change detection and catalog observations, not security verification.

The control-plane `FileTransferLane` owns only in-memory request/response
correlation for the active operation. It does not add a durable worker-file
state machine. That is a deliberate v1 limit: files are durable once written
under the worker root and referenced from PG semantic rows; transient chunk
exchange does not need its own PG-backed broker unless retry/resume requirements
become real.

## Worker File Encoding

The worker file lane uses transparent wire encoding:

- `zstd`: the default; chunks form one zstd frame on the wire;
- `identity`: an explicit debug/escape mode where bytes are transferred as-is.

Stored files remain original bytes. For inbound `PUT` with `content_encoding:
"zstd"`, the worker decodes the received zstd frame before the final rename. For
outbound `GET` with `content_encoding: "zstd"`, the worker streams a zstd frame
back to the control plane. If `content_encoding` is omitted, both sides treat it
as `zstd`.

This is a bandwidth optimization, not a storage model. The worker image and the
control-plane runtime must provide `zstd` for high-level `put` and `get`.
Missing support is a readiness/runtime error, not a reason to fall back to
identity.

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
