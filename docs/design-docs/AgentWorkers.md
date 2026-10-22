# Agent Workers

Worker providers belong to the site; Agents and their Worker rows belong to a
tenant. Globally unique Agent UIDs are the runtime and storage ownership keys.
Docker and Kubernetes attach tenant labels for diagnosis; those labels do not
replace the generation and ownership checks. Tenant deletion uses the
same Agent cleanup owner to release instances, Home and cache.

Each Agent has its own Worker and persistent Home at `/workspace`. The control
plane can delete an instance, change its image, or resume a paused instance.
The Agent's Home survives those operations. A cache at `/var/cache/ankole`
can be lost without losing files or unfinished work.

`Ankole.AgentWorkers` owns placement, credentials,
and requests. `ReconcileJob` and `SweepJob` control the lifecycle.
`WorkerAdmission` owns connection facts. PostgreSQL keeps the decisions that
must survive a process failure. A provider adapter translates those decisions
into platform requests.

## Providers

A Worker provider is one pool: a type and one YAML document. Operators manage
providers through the Console's top-level Worker Providers page, beside LLM
Providers, and select one when they create an Agent. The selection cannot
change. Different instance sizes use separate providers of the same type.
There is no smaller pool inside a provider.

`AgentWorkers.Providers` owns the dedicated site `worker_providers` table,
configuration, credentials, default selection, and bootstrap import. Provider
records are separate from AppConfigure keys. The `Provider` Ash resource owns
identity validation, immutable fields, configuration parsing, and credential
encryption. Registry locks and the native unique index keep default selection
atomic. Loaded settings and decrypted credentials use `Providers.Runtime`;
they are not durable resource attributes. The type's `definition/0`
is the single source for its schema, credential fields, example, pause support,
and instance lifetime. The Console kinds endpoint returns the kind, example,
and credential fields; it has no separate list of supported types.

Docker, Kubernetes, Cloudflare, and Lambda are built in. Control Plane Plugins
declare other kinds with `contract_id: "agent_workers.provider_kind"`, an `id`,
and a `module` that implements `ProviderKind`. The declaration ID must match
`definition().kind`. Plugin projects check the behaviour at compile time with
warnings treated as errors. The Registry rejects unavailable modules,
mismatched kinds, duplicate kinds, and overrides of built-in kinds at startup.
Registry initialization builds one `persistent_term` map from the discovered
and active Plugin specs. Each kind has its module, owning Plugin ID, and active
state. Built-in kinds have no Plugin ID. Worker lookups read this map without
calling the Registry process. Registry recovery publishes the same boot snapshot;
the map remains readable while the process is down.

The `china-market-ai-providers` Plugin owns `function_compute` and its model
providers. The `vercel-worker-provider` Plugin owns `vercel`. Each Plugin keeps
its API client and platform helpers. The Worker image supplies Function
Compute bootstrap and OSS recovery programs.

After setup, enable the required Plugin and restart before using its kind.
During setup, all compiled kinds are visible, but a Plugin must also be selected
in `plugins.enabled_ids` before an Agent can use it. The kinds endpoint lists
active implementations. Saved provider rows remain visible when their Plugin
is inactive; their check reports the Plugin ID and the recovery action. A
provider's `selectable` field checks active and next-start Plugin state, without
cloud I/O. A provider list reads the next-start policy once for all its rows.
The Console uses this field for Agent provider choices.

Agent creation and legacy assignment hold the shared Worker provider registry
lock and read the next-start Plugin policy from PostgreSQL. Plugin selection
writes use the AppConfigure key lock to keep concurrent changes. A change that
removes Worker kinds also holds the exclusive Worker provider lock and rejects
assigned Worker rows in any tenant, including paused and deleting rows. Enabling
a Plugin or changing other Plugins does not take this Worker lock or query
Worker references.
This also rejects new assignments while a disable waits for restart. The same
guard covers setup, Plugin controls, and the Plugin configuration API. General
Console settings show the Plugin selection as read-only.
An inactive implementation does not cause automatic instance or storage deletion.

Save the required Plugin ID in `plugins.enabled_ids` before using a
Plugin-owned provider kind. See [Plugins](Plugins.md) for the
operator commands. Provider seed import starts after the Plugin cohort, so
configuration validation can resolve Plugin kinds. Oban starts before Plugins
because their startup can enqueue work. A recovered job can record
`worker_provider_missing` for an unassigned Worker before the seed runs.
The seed clears that error when it assigns the provider.

The database saves YAML exactly as the operator wrote it. Validation reports
the YAML path and line. Location and persistent-storage keys cannot change
after creation. Instance keys, including size, environment, endpoints, and
cache, enter `settings_digest`; a change replaces idle Workers. The cache stays
through a replacement. A change of the cache settings replaces the cache at the
next storage preparation. The generation
also saves their values in `instance_settings`. Repeated creates and connection
addresses use those saved values until replacement. Lifecycle
keys, such as `stopGraceSeconds`, take effect without replacement. Credentials
are encrypted separately and never enter the YAML or digest. The API returns
only whether each credential is set. In a write request, text replaces a
credential, an empty string or an absent key keeps it, and `null` removes an
optional credential. A required credential cannot be removed, and a
kubeconfig cannot change between in-cluster and remote access. An invalid saved configuration disables
that provider, not the control plane or other providers.

The Worker image owns the Skill roots: `/repo/app/library`, and
`/repo/internals/skills` in an internal image. Installed Skills use
`/workspace/installed-skills`. The control plane uses these fixed paths for
`skill_view` without loading a provider or starting a Worker. Provider values
for `ANKOLE_BUILTIN_SKILLS_ROOT` and `ANKOLE_INTERNAL_SKILLS_ROOT` have no effect.

The image exposes its installed Chromium headless shell as
`/usr/local/bin/chromium`. OfficeCLI uses PATH to find this browser. Its
Chrome-family lookup does not read `ANKOLE_BROWSER_CHROMIUM_EXECUTABLE` or
`PLAYWRIGHT_BROWSERS_PATH`.
The image builds OfficeCLI from its fixed stable source with a screenshot
patch. Screenshot failures return a nonzero exit code in resident mode.
Only a new, non-empty capture can replace the output PNG. A failed capture
retains the existing PNG, its permissions, and its symbolic link.
Remove this patch when a stable OfficeCLI release provides these guarantees.

A provider cannot be deleted while a Worker row refers to it. Without an
explicit provider or a default, Agent creation fails with
`worker_provider_required`. There is at most one default provider.

## Files and Isolation

| Path | Contract |
| --- | --- |
| `/workspace` | Persistent Home of this Agent |
| `/workspace/.codex` | Codex configuration and thread files |
| `/workspace/sessions/<workspace-id>` | Session workspaces |
| `/workspace/jobs/<workspace-owner-job-id>` | Job workspaces, shared by a continuation chain |
| `/var/cache/ankole/codex` | Rebuildable Codex SQLite and local process lock |
| `/agents/<agent_uid>` | Symbolic link to `/workspace` for persisted old paths |

File operations resolve symbolic links before they compare a path with Agent
Home. `/workspace` is a valid path in a Job request. Attachments, published
files, installed Skills, and Automation scripts also have paths in the Agent's
control-plane drive ([Files](Files.md)). Job workspaces and Codex thread files
stay in persistent Home. Jobs resume Codex sessions from these files.

Session and Job workspaces are temporary working directories. The drive is the
formal store and delivery outlet. Prompts name the conversation's stable
`chats/<channel>/` drive directory and tell the Agent to leave other
conversations' files alone. The control plane checks the destination of a
channel file when it commits an attachment Delivery intent; it does not restrict
the Agent's reads or track copied content. See [Files](Files.md#conversation-files-and-delivery).

The entry, supervisor, and Bun Worker run as root and hold the generation
credential. Model-driven commands, Codex app-server, MCP servers, the browser,
and Automation scripts run as uid 1000 with no supplementary groups, no
inherited or ambient capabilities, and `no-new-privs`. `agentProcessArgv` owns
this transition. Their environments exclude the Worker credential. Linux UID
checks prevent them from reading the trusted processes' environments, attaching
a debugger, or sending termination signals to those processes.

Agent-writable files, directories, and CLI sockets belong to uid 1000. On POSIX
storage, atomic writes keep read-only control-plane documents owned by root.
Image Plugin projections use read-only modes. These permissions prevent direct
writes, but not replacement in Agent-writable directories. A mount that maps
all file access to uid 1000 cannot preserve root ownership. Codex receives an
Agent-scoped AIGateway token with the `ankole.ai_gateway` audience; this token
cannot authenticate a Worker connection.

The instance is the Agent boundary. Sessions and Jobs share Agent Home.
Providers mount only this Agent's directory or volume. Storage must permit the
root Worker to write and give new files to uid 1000, or map all file access to
uid 1000, as an EFS access point or OSS mount does. An NFS export with root squash
and no such mapping does not support these writes.

Kubernetes starts the trusted processes as uid and gid 0. It drops all
capabilities, then adds only `SETUID`, `SETGID`, `CHOWN`, `FOWNER`, `DAC_OVERRIDE`,
and `KILL`. It keeps `allowPrivilegeEscalation: false`, RuntimeDefault seccomp,
and no ServiceAccount token. The Worker namespace must permit the Kubernetes
[baseline Pod Security Standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/).
The Worker Pod does not satisfy the restricted standard.

## The Worker Row

There is one logged `agent_workers` row per Agent. Agent creation inserts it
and its initial reconciliation job in the same transaction. The request
remains pending until the Worker first connects, including during a slow
image download or control-plane restart. There is no
foreign key from `agent_uid` to the Agent: deletion keeps this row until the
platform instances and storage are gone.

| Column | Meaning |
| --- | --- |
| `agent_uid`, `provider_id` | Agent and its fixed provider |
| `state` | `absent`, `starting`, `ready`, `stale`, `paused`, `draining`, or `deleting` |
| `generation` | Ten lowercase base32 characters that identify one creation attempt and its retries |
| `token_digest`, `token_ciphertext` | Credential hash for admission and encrypted value for retries |
| `instance_ref` | Platform ID, also used to select the only instance that can receive a launch contract |
| `instance_seen_at` | First observation of a real instance of this generation |
| `create_sent_at` | Database time committed before the first create request of this generation |
| `storage_ref` | Committed provider storage reference or storage-deletion progress |
| `image`, `protocol_version`, `settings_digest`, `instance_settings` | Target and instance configuration selected for this generation |
| `wanted_until` | A request needs a Worker until this time |
| `initial_start_pending` | Agent creation requests startup until the Worker first connects |
| `last_error`, `last_error_kind` | Console reason and acquisition category: `rejected`, `transient`, or `pending`; both are cleared together |
| `state_changed_at` | Lifecycle state time |
| `incarnation_id`, `transport_route` | Process admitted last and its unique connection route |
| `capacity`, `load`, `last_worker_heartbeat_at` | Connection reports |
| `drain_reason` | Why the Worker is draining |

An `absent` row has no generation. A `deleting` row can retain an unresolved
generation. A credential hash and encrypted retry value exist exactly with a
generation. Routes exist only in `ready` or `draining`; `ready` also requires
an incarnation. Lifecycle times come from PostgreSQL.

The `AgentWorker` Ash resource owns lifecycle transitions and the write
contracts for generation, admission, demand, capacity, and provider assignment.
Its state machine admits only the declared transition from the stored state.
`Ankole.AgentWorkers` is the Ash domain of the Worker resources. Each
operation that locks a row and writes more than one step is a generic action
of its subject resource: admission, heartbeat renewal, drain, route release,
connection expiry, provider assignment, each locked reconciliation step, and
the provider registry changes. The generic action owns the transaction, and
its publish function (for example `worker_changed`) runs only after the
commit. Platform requests run outside these transactions. Disconnect and
settlement derive the next state from this same machine. State time uses the
database clock and keeps one continuous not-ready budget across `starting`
and `stale`. Each action passes its target state to the clock change. The
clock compares that target with the stored state; a self-transition preserves
its time.
PostgreSQL constraints enforce generation credentials, connected routes,
ready incarnation, capacity, and paired acquisition errors.

## Creation and the Single Writer

Each reconciliation step has four parts:

1. Read the Worker row without a lock, then list the Agent's instances.
2. Lock the row. If its lifecycle fields (`provider_id`, `state`,
   `generation`, `instance_ref`, `instance_seen_at`, and `storage_ref`)
   changed after part 1, discard the list and start again. If not, compute the
   action, write its intent to the row, and commit. A new generation,
   `draining`, and `starting` are examples of intent.
3. Call the platform outside any transaction.
4. Lock the row again. Record the result only if the lifecycle fields still
   have the values from part 2. If not, discard the result; the next step
   observes again.

A database lock never waits for a platform request. Thus a slow provider
cannot hold the connection pool or delay admission and heartbeat renewal for
other Agents. Two jobs for the same Agent can send the same idempotent request
twice, but they cannot create two writers.

Creation prepares the image and storage outside the lock. It prepares storage
only while the row is still `absent` with the same provider. It commits a new
generation, credential, target, and `starting` state only when the list has no
instance of this Agent, including paused or terminating instances. Then it
calls `create_instance` and saves the returned reference.

The committed generation survives a crash before or after the platform call.
Until an instance has been observed, the only allowed create is a retry of
that same generation. A timeout, connection error, 5xx, or one empty list does
not release it. A permanent platform refusal, or confirmed disappearance of
an instance that was observed, can release it. `current_storage_ref` runs before
every transaction that clears a generation or sets `absent`, and that
transaction saves its result. This commits a Cloudflare backup before another
instance can start.

Docker container names and Kubernetes Pod and Secret names are unique for a
generation. Cloudflare's adapter makes the generation idempotent. Lambda uses
an Agent-and-generation `clientToken`. Vercel and Function Compute create
without Worker credentials; after `instance_ref` commits, only that instance
receives the launch command or contract file. Extra instances cannot start a
Worker and are removed.

Every listing is restricted to this installation and provider. Lambda cannot
tag instances, so each provider owns tagged images and lists their instances.
Ownership reads include all tenants. The first create of a generation does
not check for unknown instances. Reconciliation commits `create_sent_at`
before it sends that request. Only a retry checks unknown, non-terminated
instances whose `startedAt` is absent or at least `create_sent_at - 60 seconds`.
The 60 seconds allow for clock difference. Older instances and instances
owned by another tenant do not block the retry. A possible instance of this
generation blocks the retry until orphan cleanup terminates it.
Cleanup keeps unknown instances younger than 300 seconds. If a reference
is still not saved after that time, cleanup can terminate the instance; the
Agent then sees its instance disappear. An unresolved generation is retried
with the same `clientToken`. Only definite rejection or the confirmed end of
an observed instance permits a new generation.

Platform acceptance of a delete is not proof of absence. Kubernetes never
uses zero grace or removes finalizers. Docker removes a container with
`force: false` after it stops. A late Docker or Kubernetes create can make an
instance after its generation was revoked; its credential cannot pass
admission or receive work, and orphan cleanup removes it.

A platform that cannot give a definite result leaves the Agent in `starting`
or `deleting`, with `last_error`. Reconciliation continues when the platform
recovers. There is no operator confirmation endpoint. Storage creation is
idempotent by name; a late native storage-create request after deletion can
leave an empty storage object, but cannot start a writer.

## Admission and Routing

Each generation has a random 32-byte base64url credential. The Worker sends
its Agent UID as `worker_id` and the credential as the Phoenix auth token.
`RuntimeFabricSocket` compares its digest in constant time and retains the
authenticated generation. Only `starting`, `stale`, and `ready` can connect.
A Channel join locks the row and checks its state, generation, and protocol
on the locked row. Then one conditional update records the route and
incarnation. A different incarnation cannot replace a connected Worker whose
last heartbeat is less than 60 seconds old: the update has this condition, so
it changes no row, and admission returns `worker_incarnation_active`. The
condition uses database time and does not run a second query. Disconnect or
heartbeat silence permits a new incarnation. Join is the only transition into
`ready`.

The sweep includes connected rows with an expired or missing heartbeat.
Reconciliation expires the route under the Worker row lock before it makes
a lifecycle decision. It uses database time and keeps the generation and Home.
This also removes routes restored from a database backup after the old node stops.

The channel registers its route before admission so the first message after
commit can find it. Until commit, the route fence rejects that connection.
The same incarnation on a new connection changes only the route. A new
incarnation broadcasts `worker_changed`. Session Drivers probe pending
calls and adopt or recover Codex work through its Job owner. A disabled
Agent's Worker can join while its work drains.

Heartbeats carry capacity and load and renew only the same route and
incarnation in `ready` or `draining`. A lost connection, unknown route, or 60 seconds
without a heartbeat makes it stale. Admission closes a replaced or silent
connection. Only the connection owner clears its slots; a platform exit
observation cannot clear a live route first.

Outbound traffic reads the Agent's current Worker row. Worker RPCs derive
the Agent from the authenticated connection. Environment RPCs require a
`RunRef`; Codex RPCs require the current `JobTurnRef`. The installation
key `runtime_fabric.worker_auth_key` names Lark profiles in the control plane;
it is not a Worker credential. The control plane resolves the rendered-fetch
idle timeout and SSRF setting and sends them in `WorkspaceOpen` or `TurnStart`.

## Placement and Lifecycle

`reserve_slot_in_tx/2` locks the one Worker row with `FOR UPDATE` and reserves
a reported slot for a new Codex Turn. A non-ready
Worker returns `agent_worker_unavailable`. The caller requests it outside
the transaction and leaves the input open.
A full Worker returns `no_worker_capacity`. The locked caller classifies these
errors. The action reserves capacity with one conditional SQL update: the Worker
must be ready and have a positive slot count. It decrements `available_slots`
and increments `active_slots` without replacing other report fields. Provider
assignment checks its immutable binding once on the locked row.

The Worker owns environment Workspace admission through `Workspaces.open`;
it does not use the control-plane reservation. It reuses an open Workspace for
the same Run. A new Workspace uses the same slot limit as Codex Turns, counting
both open Workspaces and running Codex Turns. A full or draining Worker replies
with `CAPACITY` or `DRAINING`, and the Driver keeps the calls pending. A capacity
change broadcasts `worker_changed` to active Drivers. A Driver with pending
environment calls checks the route and probes calls already sent. It reuses a
ready Workspace across tool rounds. It opens a Workspace again only when
acquisition is waiting, the route changed, or the Driver recovered. The separate JobDriver observes an active Codex Job. When JobDriver deferred
placement because the Worker was unavailable, a `worker_changed` broadcast
probes Worker readiness and triggers admission immediately when the Worker is
ready.

`Sessions.WorkerAcquisition` owns one explicit acquisition state for the
Run: idle, opening, waiting, ready, or unavailable. Pure transitions return
effects; the Driver performs the I/O and forwards the result. A Worker change
discards earlier readiness and connection queries before the Driver reads the
current row. Transport sends keep their pending receipts. When a tool batch
commits, the Driver cancels that batch's pending acquisition tasks and timers.
An opening or waiting acquisition returns to idle. A ready Workspace and an
unavailable result remain with the Run.

Workspace acquisition reports its phase at once: starting, resuming,
preparing an image, retrying a temporary failure, replacing an instance, or
waiting for a slot. The Driver renews demand on each lifecycle wait. Its
first workspace open starts a monotonic 60-second acquisition deadline,
including time waiting for a transport receipt or `WorkspaceReady`. Phase
changes do not restart it. Readiness cancels it. If a tool batch commits while
acquisition is pending, the next batch starts a new acquisition and deadline.
A new Run or Driver restart also starts a new deadline. Expiry stays with the Run across later model rounds
and late workspace replies. It returns a tool error for a new call and an
interrupted result for an adopted call whose outcome is unknown. The model can
then answer without the computer. An absent Worker with a `rejected` error, a
missing provider, or an inactive Agent returns a definite error immediately.
Model and IM errors use fixed categories; platform logs remain in the Console.

`last_error_kind` supports acquisition feedback and definite failures only.
It does not change lifecycle decisions or sweep candidates. A new generation
and a successful join clear both error fields. A provider update clears old
`rejected` errors across tenants before it schedules reconciliation.

The Driver requests a Worker once when the model stream first adds a Worker
function call, using the same tool name and namespace lookup as dispatch.
This request does not open a workspace. Dispatch is the request point
for model providers that do not send that event.
`reply_attachment` accepts only a drive path. Its declaration and execution
belong to the control plane, so it does not request a Worker.

A completed run sends `WorkspaceClose` in a background task only if it tried
to open a workspace. The next input does not wait for the close receipt.
The Worker ignores a late close for an older `signal_id`; a new open
closes the older workspace, and idle expiry releases lost workspaces.
Pure questions send no Worker messages. `worker.workspace_prepared` records
`duration_ms` for each successful workspace preparation.

`request/1` keeps `wanted_until` at least five minutes ahead.
Agent creation sets `initial_start_pending` and queues reconciliation. The
creation response does not wait for the provider. Reconciliation prepares
storage and starts the computer; admission clears the initial request when
the Worker connects. A sweep recovers pending startup after a restart or a
lost job.
Environment calls, Codex placement, and Automation runs renew demand after
initial startup. Pure questions and control-plane tools do not request or
wait for a Worker. A disabled Agent does not start; deletion clears the
initial request and removes its instances and storage.

All provider types default `idleReleaseAfter` to `15m`. An operator can set
`never` explicitly, or update saved provider YAML in Console to use finite
release. Idle release rotates the
generation only when it deletes the instance. A memory pause retains the
generation and credential, so idle release is not an absolute credential TTL.

An Agent with work in progress stays running. Idle release requires a fresh
heartbeat, no active task, no open workspace or running Codex Turn, and no
pending request. Due Session input does not keep a Worker running.
A disabled Agent takes no new work and releases its instance when idle.

The pure `Decision.next/1` selects one action from current facts.
Reconciliation locks the row, reads the facts again, recomputes the action,
and commits its intent before the platform request. Placement and admission
use the same lock. A `draining` row has no free slot and refuses new
connections, so placement and admission cannot use an instance after its
release starts. No lock is held during a platform request.

- Idle release deletes an instance and keeps storage and cache. A provider
  with memory pause instead pauses, then marks `paused` only after the
  platform confirms it. Route removal commits before connection closure.
- Resume keeps generation and incarnation. A resume error keeps the paused
  instance for retry; only confirmed termination permits a new generation.
- A changed image or instance setting replaces an idle Worker and keeps the
  cache. A changed protocol replaces it immediately. An idle instance near 90 percent of its
  platform lifetime is replaced; an old paused instance is not resumed.
- `ready_timeout` rebuilds an observed instance that cannot become ready. It
  removes the cache after the old instance disappears, then creates a new
  generation. The timer includes only time observed by this control-plane
  node, so a long control-plane outage does not trigger mass replacement.
  It is an infrastructure threshold, not the Driver's acquisition deadline.
- An unobserved `starting` generation is retried after one minute, never
  declared absent because of that delay.
- A drain permits work to finish within `stopGraceSeconds`. An external stop
  also enters drain. After grace the provider ends the instance; Kubernetes
  uses normal deletion. A Job resumes from its persistent thread file,
  and a pending environment call is probed by its Driver. Calls whose result
  is unknown run again only if their declaration permits a safe retry.

`ReconcileJob` uses Oban with per-Agent queued-job uniqueness and a retry
backoff capped at 60 seconds. Executions can overlap; committed intent and
idempotent platform requests make this safe. Repeated unchanged decisions end the loop until another sweep.
Short platform waits schedule a follow-up after two seconds, for at most one
minute per wait. `SweepJob` runs each minute and scans provider objects every
five minutes. The object scan requests reconciliation only for an Agent that
has an instance of another generation, an instance whose phase differs from
the row, an instance past 90 percent of the platform lifetime, or no current
instance. It deletes an instance without a Worker row after it reads the row
again. Errors are retained for the Console.

Each successful provider load in the minute sweep enqueues a site-level
`PrepareImageJob`. Its unique key is `{provider_id, image, settings_digest}`,
including executing jobs. It prepares the current target image, snoozes for
15 seconds while preparation is pending, and lets Oban retry failures.
The create path prepares the image and storage before it allocates a
generation. Pending preparation sets `last_error_kind` to `pending` and does
not fail the tool immediately. Background preparation removes image builds
from the usual first-use path after deployment; completion depends on
the provider and queue. Kubernetes preparation does no image pull. Operators
must pre-pull the Worker image on new Kubernetes nodes to avoid a slow first
start.

All control-plane nodes in one deployment must use the same Worker image and
protocol version. The official Helm Deployment uses `Recreate`. Rolling or
blue-green upgrades need a separate site-wide target contract before support
can be added.

Agent deletion keeps unresolved creation state, settles that generation,
deletes every instance, then deletes persistent storage and cache, and
finally removes the Worker row. Agent UIDs are generated UUIDv7 values and
are never reused. A
legacy `deleting` row with no provider is removed directly.

### New Attempt Readiness

`AgentWorkers.wait_status/5` owns the readiness wait rule for new Background
Agent Job and Automation Job attempts. It reads no storage. The caller supplies
the observed Worker, its work-capacity result, the stored wait start, the current
time, and `Settings.ready_timeout_ms`. It returns `ready`, `wait`, or `timed_out`
with the wait start to persist.

| Observation | Wait start and decision |
| --- | --- |
| Worker is ready | Clear the start and return `ready`, even when work capacity is full. |
| Worker is not ready, work capacity is full, and no start is stored | Keep the start empty and return `wait`. |
| Worker is not ready, work capacity is full, and a start is stored | Keep the start and return `wait`, even after its deadline. |
| Worker is not ready, work capacity is available, and no start is stored | Store the current time and return `wait`. |
| Worker is not ready, work capacity is available, and a start is stored | Keep the start. Return `timed_out` at or after the deadline; otherwise return `wait`. |

Work capacity does not start or reset a readiness clock. An existing clock
continues through a capacity wait, but that wait cannot report a readiness
timeout. A ready observation clears the clock. A later unavailable observation
can then start a new clock. Retries and process restarts keep the persisted
start. A ready result does not reserve a Worker slot or admit a task.

Each caller owns its work-capacity query and admission transaction. It persists
the result on its Job or Run, uses its wakeup mechanism, and handles the
timeout according to its task contract. Background Agent Jobs reserve a Worker
slot under the Worker row lock; Automation Jobs enforce their per-Agent
script limit. This rule does not apply to adoption of an active attempt or to
environment Workspace acquisition.

Instance rebuilds use the same configured timeout value with different clocks:
`Decision.next/1` uses instance and lifecycle observations, including the local
observation period. Task waits use the persisted Job or Run start. These clocks
remain separate.

## Provider Implementations

| Type | Persistent Home | Cache | Idle operation |
| --- | --- | --- | --- |
| `docker` | Local named volume per Agent | Local named volume per Agent | Delete container |
| `kubernetes` | PVC per Agent or subdirectory of a shared PVC | Optional PVC, otherwise `emptyDir` | Delete Pod and Secret |
| `cloudflare` | Directory backup in R2 | Instance disk | Back up and delete container |
| `vercel` | Drive per Agent | Instance disk | Delete sandbox |
| `lambda` | Agent directory on EFS | Instance disk | Suspend MicroVM, including memory |
| `function_compute` | AgenticSpace per Agent, or Agent prefix in OSS | Instance disk | Pause sandbox, including memory |

ACS is not registered. Its default memory retention needs confirmation on
the target platform; an implementation
that only retains the filesystem does not satisfy this type's contract.

### Docker and Kubernetes

Docker is for development and a single host. It uses the local volume driver;
its data cannot survive loss of that host. The provider schema allows instance
size, network, runtime, and extra environment. It does not allow capability
or security-option overrides. Development source mounts come from the node's
development configuration.

Kubernetes owns the Pod, contract Secret, persistent PVCs, and optional cache
PVCs. Provider YAML selects either `storage.claimTemplate` or
`storage.sharedClaim`. The template controls resources and scheduling, while
the control plane owns credentials, mounts, and the trusted and model process
UID settings.
Persistent PVCs have no instance owner reference. kubelet creates a shared
directory when it first mounts it. A root helper Pod removes it by
renaming it under `.deleted/` before removal. The helper has no Worker probes
and uses the same UID and capability settings as a Worker Pod. The reason why
it cannot start goes to `last_error`. A cache PVC records
a digest of its claim template; storage preparation replaces a cache PVC that
has other settings. When the helper succeeds, cleanup requests deletion of
the helper Pod and returns success.
See the [Helm deployment guide](../../tools/deploy/helm/ankole-agent/README.md)
for RBAC, storage permissions, and network policy.

### Cloudflare

The [adapter Worker](../../tools/deploy/cloudflare/agent-workers/README.md)
uses one Durable Object per Agent and a provider-scoped registry. It restores
`/workspace` before the Worker starts and saves a new R2 backup after the
Worker drains. The entry restores when the instance disk has no restore
marker, so a container restart in the same generation restores the latest
backup again. Only a disk with the marker requests a backup. PostgreSQL commits the backup reference before the generation
ends. A forced platform stop can lose changes since the last backup; the
adapter reports backup errors and retains the last committed backup.

Finished generations stay recorded so a delayed create cannot restart them
or restore an old backup. The adapter recovers a pending destroy through its
alarm. It keeps a six-hour inactivity timeout and renews it after a Durable
Object restart; provider scans keep it active. Creation permits five minutes
for a cold image; timeout retries the same generation. The public file
relay requires one control-plane replica.

### Vercel

Each Agent owns one Drive. The provider creates a non-persistent sandbox in
the same region and mounts that Drive at `/workspace`. The target must be a
digest in the project's VCR repository. After session selection commits, a
root command with `sudo: false` prepares storage and starts the root Worker.
Model processes run as uid 1000. The custom image has no sudo binary. The command
entry records its first start under a lock; a later command cannot start a
second process even if the supervisor was killed. A saved session that
returns 404 or a terminal status before any observation is reported once as
exited, so its generation can end. Function Compute does the same for a saved
sandbox that returns 404.

Vercel deletion can affect all sessions of a named sandbox. The adapter first
stops the selected session and only deletes sandbox metadata when no other
session runs. Drive deletion waits for detachment. The maximum instance
lifetime is set by `sessionTimeoutSeconds`, with a default and maximum of
86,400 seconds. Set 2,700 seconds for an account with a 45-minute limit.
Creation and replacement use the same value. The saved instance settings
keep a generation's lifetime when provider configuration changes. See
[Provider Verification Evidence](#provider-verification-evidence) for cloud
coverage and remaining checks.

### Lambda MicroVMs

The provider builds its own arm64 MicroVM image from the target OCI digest.
A zip in the configured S3 bucket contains only a Dockerfile. A no-op build
step exports a new image, because Lambda can fail to activate an image that a
FROM-only Dockerfile builds. It keeps the inherited runtime config.
A build role lets AWS read it; the Worker has no execution role or AWS
credentials. Image tags isolate providers and distinguish Worker images from
deletion helpers.
Managed-base deprecation triggers a new version of the same image. Failed
builds require operator repair; old images and build objects are not collected
automatically.

A failed image with no active version must be removed before a new preparation
attempt. Existing active images keep their frozen launch artifacts.

The image initially runs only the AWS hooks. The entry writes a startup line
to stderr before Bun loads the hooks. `/run` receives the generation
contract. Root mounts EFS with NFS 4.1 `hard`, binds only the Agent directory
to Home, and blocks uid 1000 from direct TCP/UDP 2049 access to any address.
The entry keeps the Worker as root and model processes run as uid 1000.
The same payload can start the entry only once. `/terminate`
sends SIGTERM and waits within the hook deadline.

Run retries use identical payload bytes, frozen image settings, and the same
client token. List results cover every provider image; missing saved IDs get
a direct read. A 404 for an instance that was never observed is uncertain. `TERMINATED`, or
a 404 for an observed instance, settles it. A list for one Agent reads only
that Agent's row, so one unreadable instance cannot stop other Agents.
The eight-hour maximum includes suspension. All idle-policy fields are explicit.

Storage deletion sends a helper request with a client token derived from the
Agent UID, then saves the returned ID in `storage_ref`. A launch retry uses
the same token. The helper renames the Agent directory under `.deleted/` and
reports its run hook ready only after it removes the deleted files. The entry
must complete `rm -rf` before it writes `/run/ankole-entry-ready`; the run hook
waits for that marker before returning success. This ordering makes AWS
`RUNNING` a storage-deletion completion signal. The provider and entrypoint
share this contract. When AWS reports `RUNNING`, the control plane requests
helper deletion. Only an accepted
DELETE permits removal of the Worker row. A failed DELETE keeps `storage_ref`
for the reconciliation retry. The helper does not stop itself.

If AWS reports `TERMINATED` before completion, reconciliation saves that helper
ID. The next launch derives a new client token from the ID. Retries of that
launch keep the new token. The next helper continues removal under `.deleted/`.
Other states keep the current reference and wait. The run hook keeps its
55-second deadline; the one-hour instance limit is a fallback, not a normal
completion step. An accepted DELETE does not prove immediate quota release;
wait for AWS to report `TERMINATED` before using that allocation again.

Official Worker images require `memoryMiB` of `4096` or `8192`. Saved provider
configurations are validated again when loaded. A lower saved value is rejected
and blocks runtime or cleanup operations.

To repair an old configuration, open Worker Providers in Console, edit the
Lambda provider, set `memoryMiB` to `4096` or `8192`, and save it. The update
validates the new configuration, clears that provider's `rejected` Worker errors,
and queues reconciliation for its assigned Agents. Check the provider and Worker
status after reconciliation. Existing generations keep their frozen settings;
the repair does not rewrite their launch contract.

See [Provider Verification Evidence](#provider-verification-evidence) for cloud
coverage and remaining checks, and [CONTRIBUTING](../../CONTRIBUTING.md) for
the test environment and quota requirements.

### Alibaba Function Compute

The provider uses a second-generation template built from an amd64 image in
ACR Enterprise. The template captures a root process that waits for
`/run/ankole/contract.json`. It has no Agent identity or credential. After the
instance reference commits, the control plane uploads the contract through
envd. The process reads it once, removes sudo, and starts the command
entry, which keeps the trusted Worker as root. Model processes run as uid 1000
with `NoNewPrivs`. Every Worker entry first
exports the environment that the image recorded at build time, so the sudo
start command does not change the Worker environment. Provider `env` adds
variables; it cannot change a variable that the image sets. Repeated uploads cannot start
another Worker. Pause requests include `memory: true`; resume uses `connect`
with a new 24-hour timeout. For OSS storage, the provider then runs the image's
reconnection script through authenticated envd and waits for successful exit.
The script shuts down only TCP connections owned by the OSSFS2 Home process.
It preserves the process, mount, and open files. This makes OSSFS2 replace
connections that became unusable while memory was paused. The resumed Worker
rejoins as soon as `connect` returns, so a failed script cannot be retried on
that instance. On a command failure, stream error, or incomplete response, the
provider deletes the instance and reports the error; the next reconciliation
rebuilds the generation from Home. AgenticFS does not use this step.

AgenticFS uses a stable root directory named
`/ankole-<installation>-<agent-hash>`. Configuration requires byte capacity
and file count quotas. NAS creates the AgenticSpace and a RAM-enabled access
point; a Sandbox Volume record refers to that access point with uid/gid 1000.
A changed VPC creates new mount metadata for the same space. Deletion removes
all this Agent's Volume and access point records, then deletes the space by
its platform ID. Repeated access point creates can leave extra metadata, but
do not create another data copy. Agent deletion removes these records too.

The amd64 Worker image includes OSSFS2 2.0.10 and FUSE3 for the custom
template's OSS mounts. Function Compute does not install OSSFS2 in
second-generation custom images. The image keeps `/workspace` empty because
OSSFS2 cannot mount a nonempty directory. Build caches use a temporary mount;
the entry creates runtime directories after the storage mount.
OSS mounts only the absolute path `<root>/<agent_uid>` at Home. It does not
have full POSIX semantics. The entry first checks that uid 1000 can write Home.
It changes Home ownership only if that check fails. A writable OSS mount can
reject `chown` with EIO. Storage deletion commits a helper request in
`storage_ref`, then
selects one returned sandbox before it sends a deletion contract. Other
helpers have no permission to delete files. The selected helper removes the
prefix contents once and writes a completion marker. The control plane saves
completion, terminates the helper, and confirms its disappearance before
removing the Worker row. A late contract cannot repeat deletion.

Sandbox management uses the `2026-08-20` ROA protocol. NAS uses `2017-06-26`
RPC. Both use ACS3; E2B and envd use their own API tokens. Protocol fixtures
come from the official SDKs and real base-sandbox responses. See the evidence
table below for the recorded scope and remaining checks.
Old templates are not collected automatically.

## Provider Verification Evidence

This section owns cloud verification status. Protocol fixtures prove request
and response handling; they do not prove a deployed Worker lifecycle. A real
base sandbox also does not prove the Worker image, coordinator, or storage
deletion helper. The evidence below is the checked-in record as of 2026-10-20.

| Provider | Recorded evidence | Remaining boundary |
| --- | --- | --- |
| Vercel | The [fixture source record](../../app/control_plane/test/fixtures/worker_providers/vercel/SOURCES.md) records a Pro-account check on 2026-10-08: root entry, uid 1000, repeated entry, retained Drive data after stop and replacement, provider isolation, and Drive deletion. | OOM, host failure, long WebSocket connections, and the full 24-hour session. |
| Lambda MicroVMs | The [fixture source record](../../app/control_plane/test/fixtures/worker_providers/lambda/SOURCES.md) records protocol checks and real image-build and quota errors on 2026-10-08. Earlier manual notes report image builds, short memory pause, EFS retention through termination and image replacement, provider isolation, directory deletion, and failed-helper recovery. No dated run output is linked for those lifecycle observations. | A dated run record for the current Worker image and coordinator; long suspension and platform time limits. |
| Function Compute | The [fixture source record](../../app/control_plane/test/fixtures/worker_providers/function_compute/SOURCES.md) records real base-sandbox responses on 2026-10-08, root envd uploads, uid 1000 OSS writes, retention after sandbox replacement, and prefix isolation. | The full Worker image and coordinator lifecycle, storage deletion helper, memory pause and resume, template capture, AgenticFS, and the 24-hour limit. The base-sandbox check did not cover these paths. |

Earlier Function Compute notes report stalled OSSFS2 TCP connections after
memory resume, reads released by closing those connections, a 90-second pause
with retained-file reads, and a complete OSS lifecycle run. No dated run output
or Worker image digest is linked for those observations. They do not establish
a reproducible cloud-suite pass.

[CONTRIBUTING](../../CONTRIBUTING.md#run-the-right-checks) defines the opt-in
cloud commands and account requirements. Run the storage and bootstrap checks
against the target deployment. Record the date, region, image digest, exact
command, and result before extending this table's verified scope. A test
definition or a local protocol pass is not a cloud run.

## Worker Process

A Worker serves only `WORKER_ID`. Traffic for another Agent is a routing error
and ends the process. The entry prepares storage and the old-path link, then
runs `tini -s -g -- ankole-worker-supervisor` as root. The supervisor runs
the Worker in its own session and forwards each termination signal once. A
normal exit ends the instance. A crash first ends remaining uid 1000 processes
and any pending root `setpriv` wrappers,
then restarts with a delay of 1, 2, 4, up to 60 seconds. The new process has a
new incarnation; Home and generation remain.

A lost Channel connection leaves environment calls and Codex Turns running.
The same Worker process reconnects with its incarnation and retained results.
A Driver uses `probe` for environment calls and `adopt` for the current Job
attempt. Stop and instance termination cancel execution; a Session slot
is released only after its commands or Codex thread have ended.

The `command` tool runs one foreground command. A Python 3 supervisor starts
the command in its own process group and keeps the leader unreaped until group
cleanup finishes. Normal leader exit also ends remaining group members. A
timeout sends TERM, then KILL after five seconds if needed; the result is 124
or 137. Cancellation returns 130. The supervisor uses isolated Python startup,
so workspace modules and caller Python settings cannot change its imports.
Commands that deliberately create another session can leave this group; the
instance remains the containment boundary. Persistent work belongs to a
Background Job, not a detached child of the foreground tool.

Command stdout and stderr each retain their first and last MiB. The result's
`outputCapture` records `observedBytes`, `droppedBytes`, and `drained`.
`drained` means both streams reached EOF; it does not mean no bytes were dropped.
After the supervisor exits, remaining reads
have a one-second drain deadline; a cut-short capture reports an unknown
remaining size. `outputLogPath` names the retained capture before model-facing
text truncation. It does not promise a complete log. The loss notice stays
outside that truncated text. Binary file-transfer operations use their exact
byte path and do not use this collector or supervisor.

Turn-local CLI bridges share a Worker-wide limit of 64 admitted requests. An
incomplete request has ten seconds from connection acceptance to provide its
newline. A full request uses the operation budget; the read deadline
does not cancel a running handler. A request keeps its slot until both the
handler and socket finish, including after bridge replacement. Busy and read
timeout errors occur before dispatch and do not imply an operation ran. The
bridge does not retry operations with an unknown result.

The Worker reconnects after normal and abnormal WebSocket closure. A rejected
generation exits at once. Five minutes without admission also ends the
process. An event-loop gap over 30 seconds resets the disconnect timer and
starts reconnection, so resumed memory can return through admission.

Each WebSocket connection attempt has a 10-second deadline. Opening the socket
cancels that deadline. Expiry cancels a pending handshake and uses the
Phoenix reconnect backoff. An explicit disconnect or process stop also cancels
the deadline. Socket logs include the error type, close code, close reason, and
clean-close flag when those facts are available. A handshake that never opened
can report code `1006`, because it cannot send a close frame.

## Bootstrap and Seed Import

Node startup facts are `ANKOLE_AGENT_COMPUTER_IMAGE`,
`ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT`, and `ANKOLE_WORKER_INSTALLATION`.
`ANKOLE_WORKER_PROVIDERS_FILE` points to a seed file. Provider locations,
instance settings, and secrets are owned by PostgreSQL after import.
`agent_computer.worker.ready_timeout` defaults to ten minutes; idle release
belongs to provider YAML.

Seed import runs only when no provider exists. It is one generic action: it
imports all providers and assigns any unassigned Agent rows in one
transaction. Secret entries refer to an environment variable or mounted file.
A failed import assigns no Agent.

Control-plane nodes of different versions must not run together. The Worker
image and protocol of the running revision are the replacement target.
