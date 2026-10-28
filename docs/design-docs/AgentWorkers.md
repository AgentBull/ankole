# Agent Workers

Worker providers belong to the site, whereas Agents and their Worker rows belong
to individual tenants. Globally unique Agent UIDs act as the ownership keys for
both runtime routing and storage. Although Docker and Kubernetes attach tenant
labels to instances for operator diagnostics, those labels never replace
generation and ownership checks. When a tenant is deleted, Ankole runs the same
Agent cleanup path to release every Worker instance, persistent Home, and cache.

Each Agent gets its own dedicated Worker and persistent Home mounted at
`/workspace`. Even if the control plane deletes an instance, upgrades its image,
or resumes a paused instance, the Agent's Home survives intact. By contrast,
`/var/cache/ankole` holds rebuildable cache data that can be lost without losing
user files or unfinished work.

Within the control plane, `Ankole.AgentWorkers` manages placement, credentials,
and demand requests; `ReconcileJob` and `SweepJob` drive the instance lifecycle;
and `WorkerAdmission` tracks live connection state. PostgreSQL persists every
decision that must survive a process crash, while provider adapters translate
those committed decisions into platform API calls.

## Providers

Each Worker provider represents a single pool defined by a provider type and one
YAML configuration document. Operators configure providers on the top-level
Worker Providers page in the Console (next to LLM Providers) and pick one
provider when creating an Agent. Once assigned, an Agent's provider cannot
change, and there are no sub-pools inside a provider—operators configure
separate providers of the same type when they need different instance sizes.

`AgentWorkers.Providers` manages the site-owned `worker_providers` table,
configuration parsing, credentials, default-provider selection, and bootstrap
seed import (kept separate from AppConfigure keys). On the persistence side, the
`Provider` Ash resource enforces identity validation, immutable fields, YAML
parsing, and credential encryption, while registry locks and a native unique
index keep default-provider selection atomic. Decrypted credentials and parsed
settings live in memory via `Providers.Runtime` rather than as durable resource
attributes. Each provider type's `definition/0` callback serves as the single
source of truth for its configuration schema, credential fields, example YAML,
memory-pause support, and maximum instance lifetime; the Console kinds endpoint
projects `kind`, `example`, and credential fields directly from `definition/0`
without maintaining a separate type list.

`Ankole.AgentWorkers.Providers` is a separate Ash domain from
`Ankole.AgentWorkers` because each Ash domain mounts in one JSON:API router:
providers are site resources under `/api/v2/site/worker-providers`, whereas a
tenant's Worker rows are Console resources under `/api/v2`. The site API lists,
creates, updates, and deletes providers through the generic actions `add`,
`configure_provider`, and `delete_provider`, projecting the calculated fields
`agent_count`, `selectable`, and `stored_credentials` (which lists only the
names of configured credentials, never their secret values). Validation errors
surface operator-facing messages from `Providers.Errors.rejection/1`, such as
YAML errors annotated with exact path and line numbers. Operators query the kind
catalog at `GET /api/v2/site/worker-provider-kinds` and run live connectivity
checks at `GET /api/v2/site/worker-providers/:provider_id/check`, whose typed
transport action invokes the provider adapter outside any database transaction
and returns the platform name and diagnostic reason on failure. At the tenant
level, the Console lists each Agent's Worker via `GET /api/v2/agent-workers`
(`console_list` on `AgentWorker`) and supports one-time provider assignment for
an unassigned Agent via `PUT /api/v2/agents/:agent_uid/worker-provider`
(`console_assign_provider`), returning `404` if the Agent or provider does not
exist and `409` if the Agent already has a provider or is being deleted.

Docker, Kubernetes, Cloudflare, and Lambda are built in. Control Plane Plugins
can register additional provider kinds by declaring
`contract_id: "agent_workers.provider_kind"`, an `id`, and a `module`
implementing `ProviderKind` whose `definition().kind` matches `id` (verified at
compile time with `warnings_as_errors`). At startup, the Plugin Registry rejects
missing modules, mismatched kind IDs, duplicate kinds, and attempts to override
built-in kinds. It then publishes a single `persistent_term` map containing each
discovered kind's module, owning Plugin ID (`nil` for built-in kinds), and
active flag. Worker lookups read this `persistent_term` map directly without
calling the Registry GenServer, so lookups keep working even while the Registry
process restarts and republishes its boot snapshot.

Two first-party Plugins provide cloud Worker kinds today:
`china-market-ai-providers` owns `function_compute` (alongside its model
providers), and `vercel-worker-provider` owns `vercel`. Each Plugin encapsulates
its own API client and platform helpers, while the shared Worker image includes
the Function Compute bootstrap and OSS recovery binaries.

To use a Plugin-owned provider kind after setup, an operator must add the
Plugin ID to `plugins.enabled_ids` and restart the control plane (see
[Plugins](Plugins.md) for the operator commands). During initial setup, all
compiled kinds appear in the UI, though an Agent still cannot use a Plugin-owned
kind until that Plugin is enabled in `plugins.enabled_ids`. Afterward, the kinds
endpoint lists only active implementations. If a saved provider's Plugin becomes
inactive, its row stays visible in the Console and its connectivity check names
the inactive Plugin ID and how to re-enable it; inactive Plugins never trigger
automatic deletion of running instances or persistent storage. Each provider's
`selectable` field reflects both the currently active Plugin snapshot and the
next-start `plugins.enabled_ids` policy (read once per list request without
cloud I/O), which the Console uses to filter provider choices during Agent
creation.

Concurrency locks keep Plugin disablement and Agent assignment consistent:

- Creating an Agent or assigning a provider acquires the shared Worker provider
  registry lock and checks the next-start Plugin policy in PostgreSQL, blocking
  new assignments to a Plugin whose disablement is awaiting restart.
- Updating `plugins.enabled_ids` acquires the AppConfigure key lock. If the
  change removes any Worker provider kind, it also acquires the exclusive Worker
  provider lock and rejects the update if any Worker row in any tenant—including
  paused or deleting rows—references an affected provider. Enabling a Plugin or
  changing non-Worker Plugins skips both the Worker lock and the cross-tenant
  check.
- Setup flows, Console Plugin controls, and the Plugin configuration API all
  share this guard, while general Console settings display `plugins.enabled_ids`
  as read-only.
- During node boot, Oban starts before Plugins (because Plugin startup can
  enqueue jobs), and provider seed import runs after the Plugin cohort so YAML
  validation can resolve Plugin-owned kinds. If a recovered Oban job runs before
  seed import and records `worker_provider_missing` on an unassigned Worker,
  seed import clears that error once it assigns the provider.

PostgreSQL stores each provider's YAML verbatim as entered by the operator and
reports validation failures with YAML path and line numbers. Location and
persistent-storage settings are immutable after creation. Instance settings—such
as size, environment variables, endpoints, and cache configuration—are hashed
into `settings_digest` and snapshotted in `instance_settings` on each
generation: changing them replaces idle Workers while keeping existing caches
(if cache settings themselves changed, the cache is replaced on the next storage
preparation), whereas repeated creates and connection lookups for an active
generation continue using `instance_settings` until replacement. Lifecycle
knobs, such as `stopGraceSeconds`, apply immediately without replacing running
instances. Provider credentials are encrypted separately, never appear in the
YAML or `settings_digest`, and are projected by the API only as boolean
presence flags. On credential updates, a non-empty string replaces the stored
secret, an empty string or omitted key preserves it, and `null` clears an
optional credential; required credentials cannot be cleared, and Kubernetes
providers cannot switch `kubeconfig` between in-cluster and remote modes. If a
saved provider configuration later fails validation, Ankole disables only that
provider without disrupting the control plane or other providers.

Inside the Worker image, built-in Skill roots are fixed at `/repo/app/library`
(plus `/repo/internals/skills` in internal images), and installed Skills live at
`/workspace/installed-skills`. Because these paths are fixed, the control plane
resolves `skill_view` directly without loading a provider or starting a Worker,
and provider overrides for `ANKOLE_BUILTIN_SKILLS_ROOT` or
`ANKOLE_INTERNAL_SKILLS_ROOT` have no effect.

The Worker image also installs its Chromium headless shell at
`/usr/local/bin/chromium`, which `OfficeCLI` locates via `PATH` rather than
`ANKOLE_BROWSER_CHROMIUM_EXECUTABLE` or `PLAYWRIGHT_BROWSERS_PATH`. The Worker
image installs the official stable `OfficeCLI` release binary for its Linux
architecture. The Dockerfile pins the release version and the SHA-256 digest
of each binary.

Ankole refuses to delete a provider while any Worker row still references it.
At most one provider can be marked as the default; if no default exists and the
caller omits an explicit provider, Agent creation fails with
`worker_provider_required`.

## Files and Isolation

| Path | Contract |
| --- | --- |
| `/workspace` | Persistent Home of this Agent |
| `/workspace/.codex` | Codex configuration and thread files |
| `/workspace/sessions/<workspace-id>` | Session workspaces |
| `/workspace/jobs/<workspace-owner-job-id>` | Job workspaces, shared by a continuation chain |
| `/var/cache/ankole/codex` | Rebuildable Codex SQLite and local process lock |
| `/agents/<agent_uid>` | Symbolic link to `/workspace` for persisted old paths |

File operations resolve symbolic links before checking whether a path stays
within Agent Home, and Job requests can target `/workspace` directly.
Attachments, published files, installed Skills, and Automation scripts also map
to paths in the Agent's control-plane drive (see [Files](Files.md)). Both Job
workspaces and Codex thread files live in persistent Home so Background Agent
Jobs can resume Codex sessions across instance restarts.

Session and Job workspaces serve as scratch directories, whereas the
control-plane drive acts as the durable store and delivery outlet. System
prompts give the Agent the conversation's `chats/<channel>/` drive path and
instruct it not to touch other conversations' directories. At delivery time, the
control plane verifies a channel file's destination when committing an
attachment Delivery intent, without restricting local file reads or tracking
copied content (see [Files](Files.md#conversation-files-and-delivery)).

Within each Worker instance, the entrypoint, supervisor, and Bun Worker process
run as `root` and hold the generation credential. Every untrusted or
model-driven child—shell commands, the Codex `app-server`, MCP servers, the
headless browser, and Automation scripts—transitions through `agentProcessArgv`
to run as `uid 1000` with no supplementary groups, no inherited or ambient
Linux capabilities, `no-new-privs`, and an environment stripped of the Worker
credential. Standard Linux UID isolation prevents `uid 1000` processes from
reading `root` process environments, attaching a debugger, or signaling the
trusted supervisor and Worker.

Agent-writable files, directories, and CLI sockets belong to `uid 1000`. On
POSIX filesystems, atomic writes keep read-only control-plane documents owned by
`root`, and image Plugin projections mount with read-only permissions (which
prevent in-place edits, though `uid 1000` can still unlink and replace entries
inside directories that `uid 1000` owns; mounts that squash all access to
`uid 1000` cannot preserve `root` ownership). Codex receives only an
Agent-scoped AIGateway token carrying the `ankole.ai_gateway` audience, which
cannot authenticate a Worker channel connection.

The Worker instance itself is the per-Agent isolation boundary: Sessions and
Jobs for the same Agent share `/workspace`, and providers mount only that
Agent's volume or directory. Backing storage must either let `root` write and
`chown` new files to `uid 1000`, or map all file access to `uid 1000` (as AWS
EFS access points and Alibaba OSS mounts do); an NFS export with `root_squash`
and no `uid 1000` mapping will fail.

On Kubernetes, Worker Pods start trusted processes as `uid 0` / `gid 0`, drop
all default capabilities, add back only `SETUID`, `SETGID`, `CHOWN`, `FOWNER`,
`DAC_OVERRIDE`, and `KILL`, enforce `allowPrivilegeEscalation: false` and the
`RuntimeDefault` seccomp profile, and mount no `ServiceAccount` token. As a
result, the Worker namespace must allow the Kubernetes
[baseline Pod Security Standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/),
as Worker Pods cannot run under the `restricted` profile.

## The Worker Row

PostgreSQL maintains one logged `agent_workers` row per Agent. Creating an Agent
inserts this row and enqueues its initial reconciliation job in the same
transaction, keeping `initial_start_pending` set until the Worker connects for
the first time (even across slow image pulls or control-plane restarts).
`agent_uid` deliberately carries no foreign key to the `agents` table so that,
when an Agent is deleted, its `agent_workers` row survives until reconciliation
finishes tearing down all platform instances and storage.

| Column | Meaning |
| --- | --- |
| `agent_uid`, `provider_id` | Agent and its fixed provider |
| `state` | `absent`, `starting`, `ready`, `stale`, `paused`, `draining`, or `deleting` |
| `generation` | Ten lowercase base32 characters that identify one creation attempt and its retries |
| `token_digest`, `token_ciphertext` | Credential hash for admission and encrypted value for retries |
| `instance_ref` | Platform ID; also identifies the single instance allowed to receive a launch contract |
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

PostgreSQL check constraints enforce row invariants across states: an `absent`
row has no `generation` (whereas a `deleting` row can retain an unresolved
generation), `token_digest` and `token_ciphertext` are present if and only if
`generation` is set, `transport_route` exists only in `ready` or `draining`
(`ready` also requires `incarnation_id`), capacity values stay non-negative, and
`last_error` and `last_error_kind` are set or cleared together. All lifecycle
timestamps come from the PostgreSQL clock.

The `AgentWorker` Ash resource owns state-machine transitions—admitting only
declared transitions from the current stored state, including on disconnect and
settlement—along with the write actions for generations, admission, demand,
capacity, and provider assignment. Within the `Ankole.AgentWorkers` Ash domain,
every multi-step operation that locks a Worker row executes inside
`Repo.transact_top_level/2` (admission, heartbeat renewal, drain, route release,
connection expiry, provider assignment, and each locked reconciliation phase)
and publishes live notifications such as `worker_changed` only after commit,
while provider-registry mutations live on `Provider` in
`Ankole.AgentWorkers.Providers`. Platform API calls always run outside database
transactions. When updating `state_changed_at`, each action passes its target
state to the database-clock helper: self-transitions preserve the existing
timestamp, and transitions between `starting` and `stale` share one continuous
not-ready timer.

## Creation and the Single Writer

Every reconciliation step follows a four-phase lock-free I/O pattern:

1. **Observe unlocked**: Read the `agent_workers` row without a lock and list
   the Agent's instances on the platform.
2. **Commit intent**: Lock the `agent_workers` row. If any lifecycle column
   (`provider_id`, `state`, `generation`, `instance_ref`, `instance_seen_at`, or
   `storage_ref`) changed since phase 1, discard the observation and restart.
   Otherwise, compute the next action, persist its intent (such as allocating a
   new `generation` and moving to `starting`, or entering `draining`), and
   commit.
3. **Execute platform I/O**: Call the cloud or container provider outside any
   database transaction.
4. **Record outcome**: Re-acquire the row lock and persist the result only if
   those same lifecycle columns still match phase 2; otherwise discard the stale
   result and let the next reconciliation pass re-observe.

Because no database lock is ever held across a platform call, a slow provider
cannot exhaust the database connection pool or block Worker admission and
heartbeats for other Agents. Even if two reconciliation jobs overlap for the
same Agent, at most they repeat an idempotent platform call—they can never start
two concurrent writers.

When creating a Worker from `absent`, reconciliation first prepares the target
image and storage outside the lock (preparing storage only while the row remains
`absent` on the same provider). Under the phase-2 lock, it allocates a new
`generation`, credential, target snapshot, `create_sent_at`, and `starting`
state only if phase 1 observed zero platform instances for this Agent—including
paused or terminating instances—before calling `create_instance` and saving the
returned `instance_ref`.

Once committed, that `generation` survives crashes before or after the platform
call. Until an instance of that generation has actually been observed,
reconciliation may only retry creating that exact generation: timeouts, network
errors, HTTP 5xx responses, or a single empty instance list never release an
unobserved generation. Ankole clears a generation only after a permanent
platform rejection or the confirmed disappearance of an already-observed
instance. Before any transaction clears `generation` or transitions to `absent`,
reconciliation calls `current_storage_ref` and commits the returned reference in
that same transaction—ensuring, for example, that a Cloudflare R2 backup
reference is durable before a replacement container can start.

Each provider enforces single-writer idempotency for a generation in its own
way:

- **Docker and Kubernetes** embed the `generation` in container, Pod, and Secret
  names.
- **Cloudflare** makes generation creation idempotent inside the Agent's Durable
  Object.
- **Lambda** passes an Agent-and-generation `clientToken`.
- **Vercel and Function Compute** create sandboxes without Worker credentials
  first; only after `instance_ref` commits in PostgreSQL does Ankole send the
  launch command or contract file to that single winning instance, while any
  duplicate sandboxes cannot start a Worker and are cleaned up.

Provider instance listings cover all tenants within this installation and
provider (because Lambda cannot tag instances directly, each Lambda provider
tags its images and lists instances across those images). The initial create of
a generation skips unknown-instance checks and commits `create_sent_at` first.
On retries, however, reconciliation inspects non-terminated instances with no
known owner whose `startedAt` is missing or at least `create_sent_at - 60s`
(allowing 60 seconds for clock skew); older instances and instances belonging to
other tenants do not block the retry, whereas a candidate instance that might
belong to this retry blocks further creates until orphan cleanup terminates it.
Orphan cleanup spares unknown instances younger than 300 seconds so an in-flight
create can save its `instance_ref`; after 300 seconds, cleanup may terminate the
unrecorded instance, after which the Agent observes its disappearance and
retries with the same `clientToken` until a definite rejection or confirmed
termination allows a new generation.

On container platforms, an accepted delete request does not prove the instance
has stopped: Kubernetes never uses a zero grace period or strips finalizers, and
Docker removes containers with `force: false` only after they exit. If a delayed
Docker or Kubernetes create materializes an instance after its generation was
revoked, its revoked credential fails admission so it can never receive work,
and orphan cleanup deletes it. Likewise, if a platform returns an indeterminate
error, Ankole leaves the row in `starting` or `deleting` with `last_error` and
keeps retrying automatically once the platform recovers (there is no manual
operator override endpoint). Native storage creation is idempotent by name; a
delayed storage-create call arriving after Agent deletion may leave an empty
storage object behind, which cannot start a writer.

## Admission and Routing

Every generation receives a fresh 32-byte random base64url credential. When the
Worker connects to `RuntimeFabricSocket`, it presents its Agent UID as
`worker_id` and that credential as the Phoenix auth token; the socket verifies
the token digest in constant time, retains the authenticated generation, and
allows connections only while the row is `starting`, `stale`, or `ready`.

Joining the Worker Channel is the sole transition into `ready`. During join,
`WorkerAdmission` locks the `agent_workers` row, verifies its state, generation,
and protocol version, and executes a single conditional update that records
`transport_route` and `incarnation_id`. To prevent split-brain replacements, a
new incarnation cannot evict a connected Worker whose
`last_worker_heartbeat_at` is less than 60 seconds old (measured by the
PostgreSQL clock inside the `UPDATE` predicate without a second query); when
that guard triggers, the update touches zero rows and admission returns
`worker_incarnation_active`. Once the previous connection closes or goes silent
for 60 seconds, a new incarnation can join. Even if an Agent is disabled, its
Worker may still join so in-flight work can finish draining.

Before running the admission transaction, the channel registers its local route
behind a pre-commit fence: messages arriving before commit are rejected, and
messages arriving immediately after commit find the route ready. If the same
`incarnation_id` reconnects on a new socket, admission updates only
`transport_route`. When a new `incarnation_id` joins, Ankole broadcasts
`worker_changed` so active Session Drivers probe pending environment calls and
Job owners adopt or recover active Codex turns.

Connected Workers send periodic heartbeats carrying `capacity` and `load`, which
renew `last_worker_heartbeat_at` only if the row is still `ready` or `draining`
with the matching `transport_route` and `incarnation_id`. Socket closure, an
unrecognized route, or 60 seconds of heartbeat silence transitions the Worker to
`stale`, and admission actively closes any replaced or silent socket. Only the
connection owner clears reported slots—observing a platform exit never clears a
live route ahead of the socket lifecycle. In addition, periodic sweeps include
connected rows with missing or expired heartbeats, and reconciliation expires
stale routes under the Worker row lock (using database time while preserving
`generation` and Home), which also cleans up stale routes if PostgreSQL is
restored from a backup after an old control-plane node stops.

For live traffic, outbound control-plane calls look up the Agent's current
`agent_workers` row, while inbound Worker RPCs derive the Agent Principal from
the authenticated socket—requiring a valid `RunRef` on environment RPCs and the
active `JobTurnRef` on Codex RPCs. (The site key
`runtime_fabric.worker_auth_key` only derives Lark profile names in the control
plane and never authenticates Workers.) When opening a workspace or starting a
turn, the control plane resolves the rendered-fetch idle timeout and SSRF policy
and passes them in `WorkspaceOpen` or `TurnStart`.

## Placement and Lifecycle

For a new Codex Turn, `reserve_slot_in_tx/1` locks the Agent's `agent_workers`
row with `FOR UPDATE` and reserves a reported slot via a single conditional SQL
update. If the Worker is not `ready`, the call returns
`agent_worker_unavailable` (so the caller requests startup outside the
transaction and leaves the input open); if the Worker is `ready` with zero free
slots, it returns `no_worker_capacity`, and the locked caller classifies both
errors. When capacity is available, the conditional update verifies that the
Worker is `ready` with a positive slot count, decrements `available_slots`, and
increments `active_slots` without overwriting other heartbeat fields.
One-time provider assignment likewise verifies immutability on the locked row.

Environment workspaces take a different admission path: the Worker itself gates
admission inside `Workspaces.open` without using `reserve_slot_in_tx/1`. It
reuses any workspace already open for the same Run and enforces a shared slot
ceiling across both open environment workspaces and running Codex Turns. When a
Worker is full or draining, it replies with `CAPACITY` or `DRAINING`, and the
Session Driver keeps the tool calls pending. Whenever Worker capacity changes,
Ankole broadcasts `worker_changed` to active Drivers:

- A Session Driver with pending environment calls checks the current route,
  probes calls already sent, and reuses a ready workspace across tool rounds—only
  reopening the workspace when acquisition is still waiting, the route changed,
  or the Driver itself recovered.
- The separate `JobDriver` watches active Codex Jobs; if `JobDriver` deferred
  placement because the Worker was unavailable, receiving `worker_changed`
  probes Worker readiness and triggers admission as soon as the Worker is ready.

`Sessions.WorkerAcquisition` models workspace acquisition for a Run as a pure
state machine (`idle`, `opening`, `waiting`, `ready`, or `unavailable`) that
emits side-effect descriptions for the Session Driver to execute. When a
`worker_changed` event arrives, the Driver discards any in-flight readiness or
connection queries before reading the fresh row, while keeping pending transport
receipts intact. Once a tool batch commits, the Driver cancels that batch's
pending acquisition tasks and timers: an `opening` or `waiting` state resets to
`idle`, whereas a `ready` workspace or `unavailable` verdict stays attached to
the Run.

Workspace acquisition immediately reports its current phase—starting, resuming,
preparing an image, retrying a temporary failure, replacing an instance, or
waiting for a slot—and the Driver renews Worker demand on each lifecycle wait.
The first attempt to open a workspace starts a monotonic 60-second acquisition
deadline covering transport receipts and `WorkspaceReady`:

- Phase transitions do not reset the 60-second timer; Worker readiness cancels
  it.
- If a tool batch commits while acquisition is still pending, the next batch
  gets a fresh acquisition and deadline, as does a new Run or Driver restart.
- Once the deadline expires, that `unavailable` verdict sticks for the remainder
  of the Run (across subsequent model rounds and late workspace replies),
  returning a tool error for newly issued calls and an `interrupted` result for
  adopted calls whose outcome is unknown so the model can respond without the
  Worker.
- If the Worker is `absent` with a `rejected` error, lacks a provider, or
  belongs to an inactive Agent, acquisition fails immediately without waiting.
  Model- and IM-facing messages use fixed error categories while keeping raw
  platform diagnostics in the Console.

`last_error_kind` drives only acquisition feedback and immediate failure
fast-paths—it never alters lifecycle decisions or sweep eligibility. Allocating
a new generation or completing a Channel join clears both `last_error` and
`last_error_kind`, and updating a provider clears existing `rejected` errors
across all tenants before scheduling reconciliation.

To warm up the Worker early, the Session Driver calls `request/1` once as soon
as the model stream emits the first Worker function call (matching tool names
and namespaces with the same lookup used at dispatch, or falling back to
dispatch time for model providers that do not stream tool-call starts). This
warm-up call extends `wanted_until` by at least five minutes without opening a
workspace. Control-plane tools—such as `reply_attachment`, which accepts only
drive paths and executes entirely in the control plane—never request a Worker,
nor do pure conversational turns.

When a Run finishes, the Driver dispatches `WorkspaceClose` asynchronously in a
background task only if the Run attempted to open a workspace during any of its
model rounds, so the next input never blocks on a close receipt. On the Worker
side, late close messages for older `signal_id` values are ignored, opening a
new workspace closes any older one, and idle expiry reclaims abandoned
workspaces. Each successful workspace preparation emits the
`worker.workspace_prepared` telemetry event with `duration_ms`.

Demand and idle release follow explicit rules:

- Creating an Agent sets `initial_start_pending` and enqueues reconciliation
  without blocking the HTTP response; reconciliation prepares storage and boots
  the Worker, `WorkerAdmission` clears `initial_start_pending` on first join,
  and `SweepJob` recovers pending startups after a node restart or dropped job.
- Subsequent environment calls, Codex placements, and Automation runs call
  `request/1` to keep `wanted_until` at least five minutes in the future.
  Disabled Agents never start, and deleting an Agent clears
  `initial_start_pending` before tearing down instances and storage.
- Every provider type defaults `idleReleaseAfter` to `15m` (operators can set
  `never` or another duration in provider YAML). Releasing an idle Worker
  requires a fresh heartbeat, zero active tasks, zero open workspaces or running
  Codex Turns, and no unexpired `wanted_until` demand (due Session inputs alone
  do not keep a Worker awake; a disabled Agent accepts no new work and releases
  its instance once idle). Because memory-pausing providers retain the active
  generation and credential across pause/resume, `idleReleaseAfter` rotates the
  generation only when deleting an instance—it is not an absolute credential
  TTL.

The pure function `Decision.next/1` computes the next lifecycle action from
observed facts. Reconciliation locks the Worker row, re-reads those facts,
re-evaluates `Decision.next/1`, and commits its intent before calling the
platform—sharing the same row lock with placement and admission so a `draining`
row (which exposes zero free slots and rejects new joins) can never accept work
after release begins:

- **Idle release**: Deletes the instance while keeping persistent Home and
  cache—except on memory-pause providers, which pause the instance first and
  record `paused` only after platform confirmation. Route removal commits before
  the control plane closes the socket.
- **Resume**: Preserves both `generation` and `incarnation_id`. If resume fails,
  the row stays `paused` for retry; only confirmed instance termination allows a
  new generation.
- **Configuration or lifetime replacement**: Changing the target image or
  instance settings replaces idle Workers while keeping their cache; changing
  `protocol_version` triggers immediate replacement. Idle instances past 90% of
  their platform lifetime are replaced proactively, and aged paused instances
  are replaced rather than resumed.
- **Readiness timeout (`ready_timeout`)**: Rebuilds an observed instance that
  fails to become `ready`, clearing the cache once the old instance is gone
  before allocating a new generation. Because this timer counts only time
  observed by the running control-plane node (as an infrastructure health
  threshold separate from the Driver's 60-second acquisition deadline), a
  prolonged control-plane outage does not trigger mass Worker replacement on
  recovery. Unobserved `starting` generations retry after one minute and are
  never marked `absent` merely because startup is slow.
- **Drain**: Gives active work up to `stopGraceSeconds` to finish (external
  platform stops also enter `draining`), after which the provider terminates the
  instance (using standard graceful deletion on Kubernetes). Background Agent
  Jobs resume from their persistent thread files in `/workspace/.codex`, and
  Session Drivers probe pending environment calls—re-running calls with unknown
  outcomes only when the tool declaration marks retry as safe.

`ReconcileJob` runs on Oban with per-Agent uniqueness across queued jobs and
retry backoff capped at 60 seconds. Overlapping executions are safe thanks to
committed row intents and idempotent provider calls; when `Decision.next/1`
produces no new change, the loop stops until the next trigger, while short
platform transitions schedule a two-second follow-up (up to one minute per
wait). `SweepJob` runs every minute and scans cloud/container objects every five
minutes, enqueueing reconciliation only when an Agent has an instance from
another generation, an instance whose platform phase disagrees with the row, an
instance past 90% of its platform lifetime, or no current instance. If an
instance has no matching `agent_workers` row, `SweepJob` re-reads the database
before deleting the orphan, retaining errors for the Console.

During each minute sweep, every successfully loaded provider also enqueues a
site-level `PrepareImageJob` keyed uniquely by
`{provider_id, image, settings_digest}` (including `executing` jobs). This job
pre-builds or warms the target image in the background—snoozing in 15-second
intervals while preparation is in progress and letting Oban retry failures—so
deployments rarely pay image-build latency on first Worker use. When Worker
creation encounters an image still being prepared, it sets `last_error_kind` to
`pending` rather than failing the tool call immediately. Note that Kubernetes
`PrepareImageJob` performs no node image pull; operators should pre-pull the
Worker image onto new Kubernetes nodes to avoid cold-start pull delays.

Every control-plane node in a deployment must target the exact same Worker image
and `protocol_version` (the official Helm chart uses the `Recreate` Deployment
strategy; rolling or blue-green control-plane upgrades would require a separate
site-wide target contract).

When deleting an Agent, reconciliation preserves any unresolved creation state
until that generation settles, terminates all platform instances, deletes
persistent Home and cache storage, and finally deletes the `agent_workers` row
(rows in `deleting` with no assigned provider are deleted immediately). Because
Agent UIDs are UUIDv7 values, deleted UIDs are never reused.

### New Attempt Readiness

`AgentWorkers.wait_status/5` is a pure function (with no database I/O) that
governs readiness waits for new Background Agent Job and Automation Job
attempts. Given the observed Worker state, the caller's work-capacity result,
the persisted wait-start timestamp, the current time, and
`Settings.ready_timeout_ms`, it returns `ready`, `wait`, or `timed_out` together
with the updated wait-start value to persist:

| Observation | Wait start and decision |
| --- | --- |
| Worker is ready | Clear the start and return `ready`, even when work capacity is full. |
| Worker is not ready, work capacity is full, and no start is stored | Keep the start empty and return `wait`. |
| Worker is not ready, work capacity is full, and a start is stored | Keep the start and return `wait`, even after its deadline. |
| Worker is not ready, work capacity is available, and no start is stored | Store the current time and return `wait`. |
| Worker is not ready, work capacity is available, and a start is stored | Keep the start. Return `timed_out` at or after the deadline; otherwise return `wait`. |

In short, lack of work capacity neither starts nor resets the readiness clock:
an already-running clock stays paused against timeout while capacity is full,
observing `ready` clears the clock (allowing a later outage to start a fresh
one), and retries or node restarts preserve the persisted timestamp. Returning
`ready` does not itself reserve a slot or admit the task.

Each task subsystem owns its own capacity query, admission transaction, wakeup
trigger, and timeout handling—persisting the wait timestamp on its Job or Run
row (Background Agent Jobs reserve a Worker slot under the `agent_workers` lock,
whereas Automation Jobs enforce their per-Agent concurrency limit). This rule
applies only to new attempts, not to adopting an in-flight attempt or acquiring
an environment workspace. Although instance rebuilds in `Decision.next/1` read
the same `ready_timeout` setting, their local infrastructure observation clock
remains independent of each task's persisted wait clock.

## Provider Implementations

| Type | Persistent Home | Cache | Idle operation |
| --- | --- | --- | --- |
| `docker` | Local named volume per Agent | Local named volume per Agent | Delete container |
| `kubernetes` | PVC per Agent or subdirectory of a shared PVC | Optional PVC, otherwise `emptyDir` | Delete Pod and Secret |
| `cloudflare` | Directory backup in R2 | Instance disk | Back up and delete container |
| `vercel` | Drive per Agent | Instance disk | Delete sandbox |
| `lambda` | Agent directory on EFS | Instance disk | Suspend MicroVM, including memory |
| `function_compute` | AgenticSpace per Agent, or Agent prefix in OSS | Instance disk | Pause sandbox, including memory |

Alibaba Container Compute Service (ACS) is intentionally not registered: its
default memory retention on the target platform is unverified, and a provider
that preserves only filesystem state does not satisfy the memory-pause contract.

### Docker and Kubernetes

Docker targets local development and single-host deployments using the local
volume driver (so data does not survive losing the host). Its provider schema
accepts instance size, network, OCI runtime, and extra environment variables,
while disallowing Linux capability or `security-opt` overrides; source-tree bind
mounts in development come from the node's dev configuration. Running `bun dev`
configures the local Worker image, Docker socket, provider seed, and control-plane
addresses: both FOSS and SaaS Workers connect back to `host.docker.internal` on
the control-plane port, and SaaS dev mode accepts
`runtime_fabric_internal_origin` as a valid site origin so Worker WebSockets and
AIGateway calls route over the Docker bridge (production SaaS uses the canonical
site origin). Setup commands can boot the control plane without a Worker image,
whereas running Workers requires the full runtime settings supplied by `bun dev`.

Kubernetes manages the Worker Pod, launch-contract Secret, persistent Home PVCs,
and optional cache PVCs. Provider YAML chooses between `storage.claimTemplate`
(one PVC per Agent) and `storage.sharedClaim` (per-Agent subdirectories on a
shared PVC): the Pod template governs resource requests and node scheduling,
while the control plane enforces credentials, volume mounts, and `root` /
`uid 1000` security contexts. Persistent PVCs carry no Pod `ownerReferences`. On
a `sharedClaim` volume, `kubelet` creates the Agent's subdirectory on first
mount, and Agent deletion spawns a probe-less `root` helper Pod (with the same
UID and capability profile as a Worker Pod) that renames the directory under
`.deleted/` before removing it—recording any startup failure in `last_error` and
deleting the helper Pod once cleanup succeeds. Cache PVCs record a digest of
their claim template so storage preparation replaces them whenever cache
template settings change. See the
[Helm deployment guide](../../tools/deploy/helm/ankole-agent/README.md) for
RBAC, storage permissions, and `NetworkPolicy` setup.

### Cloudflare

The [Cloudflare adapter Worker](../../tools/deploy/cloudflare/agent-workers/README.md)
coordinates each Agent through a dedicated Durable Object plus a provider-scoped
registry. Before the Worker process starts, the container entrypoint checks for
a local restore marker and—if absent—restores `/workspace` from R2 (so an
in-generation container restart cleanly re-restores the latest backup). After
the Worker drains, only an instance disk carrying that restore marker uploads a
new R2 backup, and PostgreSQL commits the new backup reference before ending the
generation. Although an abrupt platform kill can lose writes made after the last
backup, the adapter surfaces backup errors and preserves the last committed R2
snapshot.

Completed generations remain recorded in the Durable Object so delayed create
requests can neither resurrect an old generation nor restore a stale backup.
Pending destroys recover via Durable Object alarms, and a six-hour inactivity
timer (renewed on Durable Object restarts and periodic provider scans) bounds
idle state. Cold-image creation allows up to five minutes before retrying the
same generation. Note that Cloudflare's public file relay requires running a
single control-plane replica.

### Vercel

On Vercel, each Agent owns a persistent Drive mounted at `/workspace` inside an
ephemeral sandbox in the same region, using an image digest from the project's
VCR repository. Once session selection commits, Ankole invokes a `root` launch
command (`sudo: false`; the custom image omits the `sudo` binary) that prepares
storage and starts the `root` Worker under a startup lock—preventing duplicate
commands from spawning a second Worker even if the supervisor was killed—while
model subprocesses run as `uid 1000`. If a saved session returns `404` or a
terminal state before ever being observed, the adapter reports it once as exited
so reconciliation can close out the generation (Function Compute handles `404`
on unobserved sandboxes the same way).

Because deleting a named Vercel sandbox can affect every session under that
name, the adapter stops the target session first and deletes sandbox metadata
only when no other sessions remain active; Drive deletion likewise waits until
the Drive detaches. `sessionTimeoutSeconds` caps instance lifetime (defaulting
to and maxing out at `86,400` seconds; set `2,700` on accounts with a 45-minute
ceiling) across both initial creates and replacements, and each generation's
snapshot preserves its lifetime when provider YAML changes. See
[Provider Verification](#provider-verification) for cloud test coverage and
verification steps.

### Lambda MicroVMs

The Lambda provider builds an `arm64` MicroVM image from the target OCI digest
by uploading a minimal `Dockerfile` zip to the configured S3 bucket and running
a no-op build step that exports a fresh image layer while keeping the inherited
runtime configuration (working around Lambda activation failures on `FROM`-only
builds). An AWS build role grants image-pull access during build, while the
running Worker MicroVM gets no IAM execution role and no AWS credentials. Image
tags isolate providers and separate Worker images from storage-deletion helpers.
When AWS deprecates a managed base layer, Ankole builds a new image version
automatically while active generations keep their frozen launch artifacts;
failed builds with no active version must be removed by an operator before
retrying preparation, and old images and S3 build artifacts are not garbage-collected
automatically.

At boot, the MicroVM runs only the AWS lifecycle hooks (writing an initial line
to `stderr` before Bun loads the hook server):

- `/run` receives the generation contract once (rejecting duplicate payloads),
  mounts EFS with NFSv4.1 `hard`, bind-mounts only this Agent's directory onto
  `/workspace`, blocks `uid 1000` from direct TCP/UDP port `2049` traffic to any
  address, keeps the Worker as `root`, and runs model subprocesses as `uid 1000`.
- `/terminate` forwards `SIGTERM` and waits within the hook deadline.

Create retries send identical payload bytes, frozen image settings, and the same
`clientToken`. Instance listings query across all provider images and fall back
to direct ID lookups when a saved ID is missing from list results—scoping
per-Agent queries to that Agent's row so one unreadable MicroVM cannot stall
other Agents. An unobserved MicroVM returning `404` remains indeterminate,
whereas `TERMINATED` (or `404` for an already-observed MicroVM) settles the
generation. Lambda's eight-hour maximum lifetime includes suspended time, and
all idle-policy fields are configured explicitly.

To delete persistent EFS storage, reconciliation launches a deletion-helper
MicroVM using a `clientToken` derived from the Agent UID and saves its ID in
`storage_ref` (reusing that token on launch retries). Inside the helper, the
entrypoint renames the Agent directory under `.deleted/` and completes `rm -rf`
before writing `/run/ankole-entry-ready`; `/run` waits for that marker before
returning success, making AWS `RUNNING` status proof that EFS deletion finished.
Once AWS reports `RUNNING`, the control plane sends `DELETE` for the helper
(which never self-terminates) and removes the `agent_workers` row only after
`DELETE` is accepted, retaining `storage_ref` on `DELETE` failures. If the
helper enters `TERMINATED` before reaching `RUNNING`, reconciliation records
that helper ID, derives a fresh `clientToken` from it for the next helper
launch, and resumes deleting `.deleted/` (keeping the 55-second `/run` hook
deadline, with the one-hour MicroVM lifetime acting only as a safety backstop;
note that an accepted `DELETE` does not free AWS quota until AWS reports
`TERMINATED`).

Official Worker images require `memoryMiB` set to `4096` or `8192`. Because
Ankole re-validates saved provider YAML on load, a smaller `memoryMiB` value
blocks both runtime startup and cleanup. To repair a rejected Lambda provider,
open **Worker Providers** in the Console, set `memoryMiB` to `4096` or `8192`,
and save: the update validates the new YAML, clears `rejected` errors on its
Workers, and enqueues reconciliation without rewriting active generations'
frozen launch contracts.

See [Provider Verification](#provider-verification) for cloud test coverage and
[CONTRIBUTING](../../CONTRIBUTING.md) for test environment and AWS quota
requirements.

### Alibaba Function Compute

The `function_compute` provider builds a second-generation sandbox template from
an `amd64` image in ACR Enterprise. The template boots a credential-free `root`
waiter watching `/run/ankole/contract.json`. Once `instance_ref` commits in
PostgreSQL, the control plane uploads the contract over `envd`; the waiter reads
it once, deletes `sudo`, restores the build-time image environment (so `sudo`
invocation does not pollute Worker variables; provider `env` entries can add new
variables without overriding image-defined ones), and starts the `root` Worker
while running model subprocesses as `uid 1000` with `NoNewPrivs`. Duplicate
contract uploads cannot start a second Worker.

Pausing sends `memory: true`, and resuming calls `connect` with a fresh 24-hour
timeout. When Home uses OSS, resume immediately runs the image's OSS
reconnection script over authenticated `envd` and waits for exit `0`—shutting
down stale TCP sockets owned by the `ossfs2` Home daemon while keeping the
daemon, FUSE mount, and open file descriptors alive so `ossfs2` opens fresh
connections after memory pause. Because the resumed Worker rejoins the control
plane as soon as `connect` returns, a failed reconnection script cannot be
retried in place: on any script error, stream error, or incomplete response, the
adapter deletes the sandbox and reports the failure so the next reconciliation
rebuilds the generation from Home (AgenticFS mounts do not need this step).

For storage backends:

- **AgenticFS** mounts a stable root directory named
  `/ankole-<installation>-<agent-hash>` with explicit byte-capacity and
  file-count quotas. NAS provisions the `AgenticSpace` and a RAM-enabled access
  point referenced by a Sandbox Volume at `uid 1000` / `gid 1000` (changing the
  VPC creates new mount metadata against the same space, and repeated
  access-point creates may leave extra metadata without duplicating data).
  Deleting an Agent removes all of its Volume and access-point records before
  deleting the `AgenticSpace` by platform ID.
- **OSS** relies on `ossfs2` `2.0.10` and `FUSE3` baked into the `amd64` Worker
  image (Function Compute does not bundle `ossfs2` into custom v2 images). The
  image leaves `/workspace` completely empty at build time (using a temporary
  mount for build caches) because `ossfs2` refuses to mount over a non-empty
  directory, and the entrypoint creates runtime subdirectories after mounting
  `<root>/<agent_uid>` at `/workspace`. Because OSS lacks full POSIX semantics
  and can reject `chown` with `EIO` even on a writable mount, the entrypoint
  tests whether `uid 1000` can write `/workspace` first and runs `chown` only if
  that write probe fails. Deleting OSS storage records a helper request in
  `storage_ref`, picks a single winning sandbox to receive the deletion contract
  (leaving any extra helpers without delete authority), deletes the prefix
  contents once, writes a completion marker, and confirms helper termination
  before removing the `agent_workers` row.

Sandbox lifecycle calls use the `2026-08-20` ROA API and NAS calls use the
`2017-06-26` RPC API (both signed with ACS3, while E2B/`envd` requests use their
own API tokens), verified against protocol fixtures captured from official SDKs
and live sandboxes. Old templates are not garbage-collected automatically.

## Provider Verification

Provider verification tests bootstrap, Worker admission, persistent Home
retention, and storage cleanup against live target infrastructure, alongside
local protocol fixtures that pin request and response shapes. Fixture provenance
and verified environments are recorded in:

- [Vercel](../../app/control_plane/test/fixtures/worker_providers/vercel/SOURCES.md)
- [Lambda MicroVMs](../../app/control_plane/test/fixtures/worker_providers/lambda/SOURCES.md)
- [Function Compute](../../app/control_plane/test/fixtures/worker_providers/function_compute/SOURCES.md)

See [CONTRIBUTING](../../CONTRIBUTING.md#run-the-right-checks) for cloud test
commands and account prerequisites, and record the date, region, image digest,
command, and outcome for every live verification run.

## Worker Process

Each Worker process serves exclusively the Agent named in `WORKER_ID`—receiving
traffic for any other Agent is treated as a fatal routing error that terminates
the process immediately. At container boot, the entrypoint prepares storage and
the legacy `/agents/<agent_uid>` symlink before exec'ing
`tini -s -g -- ankole-worker-supervisor` as `root`. The supervisor spawns the
Bun Worker in its own process session and forwards termination signals once: a
clean Worker exit terminates the instance, whereas an unexpected crash kills any
lingering `uid 1000` processes and pending `root` `setpriv` wrappers before
restarting the Worker with exponential backoff (`1s`, `2s`, `4s`, up to `60s`)
under a new `incarnation_id` while preserving `/workspace` and `generation`.

If the Phoenix Channel drops while work is running, active environment commands
and Codex Turns keep executing locally: once the same Worker process reconnects
with its `incarnation_id` and cached results, Session Drivers call `probe` for
environment calls and `JobDriver` calls `adopt` for the active Job attempt.
Explicit stops and instance termination cancel running work, and a Session slot
is freed only after its child commands or Codex thread have exited.

Foreground shell commands (`command` tool) run under an isolated Python 3
supervisor (started with isolated flags so `/workspace` modules and caller
`PYTHONPATH` settings cannot hijack its imports). The supervisor places the
command in a dedicated process group, keeps the group leader unreaped until all
group members exit, and cleans up stragglers on normal leader exit (commands
that explicitly call `setsid` can escape the process group, with the Worker
instance itself acting as the outer containment boundary; long-lived background
daemons belong in Background Agent Jobs rather than detached foreground
commands). On timeout, the supervisor sends `SIGTERM` followed by `SIGKILL`
after five seconds, returning exit code `124` or `137` (`130` on explicit
cancellation).

Command `stdout` and `stderr` each retain their first and last `1 MiB`. In the
tool result, `outputCapture` reports `observedBytes`, `droppedBytes`, and
`drained` (`drained: true` means both pipes hit EOF—not that zero bytes were
dropped; after supervisor exit, remaining pipe reads have a one-second drain
deadline, reporting an unknown remaining byte count if cut short).
`outputLogPath` points to this retained capture prior to model-facing text
truncation, with any byte-loss notice kept outside the truncated text. Binary
file transfers use a dedicated byte-exact channel that bypasses this text
collector and Python supervisor.

Turn-local CLI bridges enforce a shared Worker-wide cap of 64 concurrent
requests: each accepted socket has 10 seconds to send its newline-terminated
request, after which a full request runs under the operation's own timeout
(the 10-second read timer never cancels an active handler) and holds its slot
until both handler and socket close, even across bridge replacement. `BUSY` and
read-timeout errors happen strictly before dispatch—proving the operation never
ran—and the CLI bridge never auto-retries operations with unknown outcomes.

For control-plane connectivity, the Worker reconnects after both normal and
abnormal WebSocket closures, giving each handshake a 10-second open deadline
(canceled once the socket opens, or on explicit disconnect/shutdown; an expired
handshake aborts and enters Phoenix reconnect backoff, and handshakes that never
open may log close code `1006` because no close frame can be sent). Socket logs
record the error type, close code, close reason, and clean-close flag whenever
available. If admission rejects the Worker's `generation`, the process exits
immediately; it also exits if five minutes pass without successful admission.
Finally, if the Bun event loop stalls for more than 30 seconds (as happens
during VM memory pause), the Worker resets its five-minute disconnect timer and
initiates a fresh reconnect so a resumed MicroVM or sandbox can rejoin cleanly.

## Bootstrap and Seed Import

Control-plane nodes read three Worker bootstrap variables from the OS
environment: `ANKOLE_AGENT_COMPUTER_IMAGE`,
`ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT`, and `ANKOLE_WORKER_INSTALLATION`, plus
an optional `ANKOLE_WORKER_PROVIDERS_FILE` path for first-boot seed import. Once
imported, PostgreSQL owns all provider locations, instance settings, and
encrypted secrets (`agent_workers.ready_timeout_seconds` lives in AppConfigure
with a 10-minute default, while `idleReleaseAfter` lives in provider YAML).

Seed import runs only when `worker_providers` is completely empty, executing in
a single `Repo.transact_top_level/2` transaction that imports all declared
providers (resolving secret references from environment variables or mounted
files) and assigns any unassigned Agent rows atomically—if import fails, zero
Agents are assigned.

Control-plane nodes running different Ankole versions must never share a cluster
at the same time; the running release's Worker image and protocol version define
the active replacement target.
