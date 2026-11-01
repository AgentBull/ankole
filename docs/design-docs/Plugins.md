# Plugins

Ankole uses the word "Plugin" for two unrelated extension mechanisms:

- **Agent Plugins** package model-facing capabilities and workspace files for an Agent.
- **Control Plane Plugins** compile trusted Elixir and OTP modules into the control plane.

Beyond the word "Plugin", the two mechanisms share nothing: they have separate
code paths, configuration keys, and activation rules.

## Agent Plugins

An Agent Plugin uses the standard Codex Plugin package layout, extended with one
optional Ankole directory, `workspace-template`, for seeding initial Job files:

```text
app/library/agent-plugins/<agent-plugin-id>/
├── .codex-plugin/plugin.json
├── skills/
├── hooks/                 # Optional Codex content
└── workspace-template/    # Optional Job Workspace content
```

Because a private deployment instance ships only trusted first-party packages,
both runtimes treat these packages as trusted code. Each `.codex-plugin/plugin.json`
manifest declares `name`, `version`, `description`, and `skills`, and its parent
directory name must match `name`. A package may also bundle auxiliary
directories that its member Skills read—such as the shared Playbook library in
`office`.

To build the capability catalog, the control plane reads each Plugin manifest
alongside its member Skill metadata. Agent Computer resolves that catalog
against the matching same-release package in its own container image, reading
the local manifest and member paths needed for materialization and rejecting
unsafe copy entries. `AgentCodexRuntime` is the sole owner of official Codex
`plugin/install` calls, Hook trust registration, the Plugin cache, and Codex
user-config mutations; individual Jobs never perform these steps, and
RuntimeFabric carries no separate package version or content-hash contract.

### Workspace Template

`workspace-template` holds plain initial files for a Job Workspace and never
contains a second manifest.

When creating a Job, the caller may specify a single `workspace_template_id`.
Agent Computer copies that Plugin's template once when first creating the Job
Workspace; if `workspace_template_id` is omitted, it copies nothing. Resuming a
Job preserves its existing workspace files, and refreshing runtime packages
never re-copies the template.

Choosing a `workspace_template_id` does not activate runtime Plugins. Instead, a
Job loads only the Plugins recorded in its persisted runtime projection, and
Ankole never interprets files inside a template as a Plugin activation contract.

### Built-in Packages

Ankole ships five built-in Agent Plugins:

| ID | Member Skills | Shipped default |
| --- | --- | --- |
| `lark` | `lark-im`, `lark-oa`, `lark-office-suite` | Disabled |
| `office` | `docx`, `xlsx`, `pptx` | Enabled |
| `deep-research` | `create-deep-research` | Enabled |
| `brain` | `brain-learning`, `resolve-before-asking`, `idea-lineage`, `applied-reading` | Enabled |
| `github` | `github-auth`, `github-issues`, `github-pr-workflow`, `github-repo-management`, `github-webhooks` | Disabled |

Member Skills live exclusively inside their parent Agent Plugin, while
standalone Skills live under `app/library/skills`. Three packages have notable
internal conventions:

- **`office`**: All three member Skills (`docx`, `xlsx`, `pptx`) share one
  Playbook library at the package root. Each Playbook declares the products that
  it applies to; a Skill lists Playbooks for its own product via
  `tools/list_playbooks.ts <product>` and reads those that match the user's
  request. Each Playbook contributes deliverable-specific rules without
  duplicating its Skill instructions. Because `office` needs no Job Workspace
  template, every Job reads Playbooks directly from the materialized package.
- **`deep-research`**: Its `create-deep-research` member Skill runs only in the
  main Agent, where it clarifies the research contract, launches one
  `BackgroundAgentJob`, and receives the result. The Job itself never loads that
  main-only Skill; instead, `workspace-template` governs the Job's research
  lifecycle, Playbook routing, working state, Markdown semantic draft, and
  contract-defined artifacts.
- **`github`**: The public `github` package owns repository webhook setup,
  reconciliation, redelivery, and removal inside its `github-webhooks` Skill.
  The Signals subsystem provides only the generic callback capability—it embeds
  no GitHub-specific adapter and stores no mirror of GitHub hook state.

Research routing distinguishes two epistemic objects—not two urgency tiers, and
not whether the reader plans to act afterward:

- `create-deep-research` investigates the external world: establishing facts,
  weighing evidence, explaining or assessing outside developments, and
  evaluating claims or forecasts. Questions about buying or holding equities,
  forecasting prices or demand, predicting competitive outcomes, or estimating
  risks belong here even when the user asks for a recommended action.
- `research-for-planning` investigates the operating environment around a
  controllable product, operational, market-entry, or launch decision. It
  compares feasible options and gathers market, competitor, channel, cost,
  compliance, and resource constraints so a planner can choose a course of
  action, without attempting to predict asset prices, target-market demand, or
  other external outcomes.

Neither research Skill triggers merely because a prompt says "plan", attaches a
source bundle, asks for a PDF, requests plan writing or review, or needs a
single quick lookup. When a prompt mixes both kinds of questions, split the
subquestions by their epistemic object first and then return to the requested
action; if there is no material knowledge gap, answer directly.

### Decide Which Capabilities an Agent Can Use

Each Agent Plugin and each Skill tracks its own enabled state. Tenant settings
define the baseline defaults (inheriting from the site when a tenant has no
override), and an Agent stores only explicit overrides that differ from its
tenant's effective defaults:

```text
Agent Plugin effective = agent override ?? tenant default
Plugin Skill effective = parent effective && (agent override ?? tenant default)
Standalone Skill effective = agent override ?? tenant default
Agent-installed Skill effective = agent override ?? source default
```

Every member Skill defaults to enabled. When an operator disables a parent
Plugin, all of its member Skills become unavailable without erasing their saved
individual settings, so re-enabling the parent restores each member's prior
choice.

AppConfigure stores tenant-scoped defaults under two keys:

- `ai_agent.library.agent_plugin_defaults` (boolean map per Agent Plugin)
- `ai_agent.library.skill_defaults` (boolean map per Skill)

Ordinary capability reads hit the AppConfigure cache. By contrast, initial Job
runtime projections and capability-change notifications read defaults directly
from PostgreSQL via `AgentPlugins.Config.defaults_in_tx/0` and pass the result
as `agent_library_defaults`: projection reads run inside the admission
transaction, whereas notification reads run after the configuration update
commits.

In persistence and APIs, Plugin member Skill IDs use `<agent-plugin-id>:<skill-name>`,
while standalone Skill IDs use the bare Skill name. PostgreSQL stores sparse
Agent Plugin overrides in `agent_plugin_overrides` and Skill overrides in
`agent_skills.enabled_override` (where `NULL` means inherit). Public API
projections serialize enum fields as strings, whereas internal Ash resource
records use atoms.

The Agent Library resources own sparse Plugin overrides, Skill catalog
synchronization, per-Agent enablement, and runtime document writes. Catalog sync
preserves saved enablement overrides and keeps all member Skill rows current—even
for disabled Plugins—so saved choices and the Console catalog stay intact.
Active documents preserve their partial unique path identity and exact content
bytes. Plugin member rows set `source_kind = "builtin"` and record their parent
in `agent_plugin_id`; Skill discovery and execution do not branch on a separate
source kind.

A shipped standalone or Plugin member Skill may set `brain-recall-only: true`.
Such a Skill retains its global Skill name and normal enablement rules, but
Ankole omits it from the prompt catalog. Instead, Brain indexes its name,
description, and tags as a lightweight discovery record, leaving `skill_view` as
the sole loader for its full body and resources. Agent-installed Skills cannot
use `brain-recall-only` mode.

### What a Job Saves and Loads

A Job persists an optional `workspace_template_id` alongside a typed runtime
projection of its logical Plugin and Skill selection captured at first execution
admission. Retries, resumes, and Worker migrations intersect that saved
projection with the Agent's current effective capability set, so disabling a
Plugin or Skill immediately drops it from subsequent executions. The projection
stores logical IDs only—never package bytes, overlays, credentials, or Hook
state.

Before starting the first Job thread for an Agent, `AgentCodexRuntime` executes
four steps inside a serialized per-Agent owner:

1. Resolves every trusted same-release package and refreshes its materialized
   files under Agent Home.
2. Installs every package via the official Codex `plugin/install` method.
3. Verifies the installed state and marks package Hooks trusted through Codex.
4. Sets every Agent Plugin entry in the Codex user config to `enabled = false`.

Installing all same-release packages up front avoids mutating the global Plugin
cache or user config later while sibling threads are running. Keeping every
entry globally disabled is equally deliberate: installation manages the package
lifecycle on disk without granting every Job access to every Plugin.

Each individual Job then performs purely thread-local selection:

1. Resolves its projected Plugin IDs and Background-eligible member Skills
   against the current catalog.
2. Renders ordinary selected members in the Job Skill index while keeping all
   selected members (including `brain-recall-only` Skills) loadable via Ankole's
   `skill_view`.
3. Projects MCP servers only from enabled member Skills that permit Background
   Agent Jobs.

A Job never passes Ankole Skill roots to Codex, writes `.agents/skills`, or
relies on Codex `skills/list`. As a result, a single Ankole enablement model
governs both the main Agent and Background Agent Jobs. Copying the optional
workspace template happens once at workspace creation and never alters runtime
Plugin selection.

Over RuntimeFabric, the control plane sends the enabled Agent Plugin catalog and
Skill summaries inside the Agent context of `workspace_open` and initial
`turn_start` commands. See [Background Agent Job](BackgroundAgentJob.md) for the
full Job lifecycle.

### Change Capability Settings through the Console

The Console API exposes site defaults, tenant defaults, and per-Agent effective capabilities
through six JSON:API endpoints (`application/vnd.api+json`):

- `GET /api/v2/agent-library/capabilities`
- `PUT /api/v2/agent-library/agent-plugins/:id`
- `PUT /api/v2/agent-library/skills/:id`
- `GET /api/v2/agents/:agent_uid/library-capabilities`
- `PUT /api/v2/agents/:agent_uid/library-capabilities/agent-plugins/:id`
- `PUT /api/v2/agents/:agent_uid/library-capabilities/skills/:id`

Default reads accept `defaults_scope=global|tenant`, and default writes accept
`{ "data": { "enabled": boolean, "defaults_scope": "global" | "tenant" } }`.
Omitting the scope selects tenant inheritance. Site-default operations additionally
require the corresponding AppConfigure read or update grants. Library validates
catalog existence before storing a choice and broadcasts site changes to active
tenants. Raw Console writes to the two AppConfigure default maps are rejected.
The Library UI preserves the selected scope and tab through detail links.

Per-Agent writes accept `{ "data": { "enabled": boolean | null } }` (where
`null` clears the override and restores inheritance). Each capability row
reports three boolean fields:

- `global_default_enabled` (the default in the selected site or tenant context;
  tenant context includes site inheritance)
- `override_enabled`
- `effective_enabled`

In responses, each Agent Plugin row nests its member Skills, while the top-level
Skill list contains standalone and Agent-installed Skills. The Console renders
Agent Plugins, standalone Skills, and installed Skills as distinct sections, and
exposes Control Plane Plugins only at the deployment-instance (site) level.
Each capability view reports errors from the queries that supply its available
controls.
The Console uses a tenant view for per-Agent overrides and one site view for
shared defaults.

## Control Plane Plugins

A Control Plane Plugin compiles trusted Elixir and OTP code directly into the
control plane to contribute metadata, AppConfigure definitions, domain adapters,
and supervised processes. Ankole never downloads or hot-loads arbitrary plugin
code at runtime.

Implementation modules live under `Ankole.Plugins.*`, and the host
`:control_plane_plugin_modules` configuration lists every module compiled into
the release. At boot, a GenServer validates that every declared module has a
unique Plugin ID—halting startup on any duplicate—and publishes the active list
as an immutable `:persistent_term` snapshot for lock-free reads without parsing
source files.

### Fixed source builds

`ANKOLE_EDITION=foss|saas` (default `foss`) selects which source trees compile
into the release:

- **`foss`**: Compiles public Plugins and ignores `internals` source code and
  migrations.
- **`saas`**: Additionally compiles `internals/control_plane/lib` and
  `internals/plugins/*/lib`, failing the build if those private directories are
  missing.

`app/control_plane` is a single Mix project and `:ankole` OTP application that
owns domain and web modules, configuration, migrations, release commands, test
support, and the root supervisor, compiling each `plugins/<name>/lib` tree into
that same application. Consequently, each release runs a single `Repo` and
migration ledger, while `foss` and `saas` builds write to separate `_build`
directories. In development, code reloading covers `:ankole` and its local Mix
dependencies, and protocol consolidation stays disabled so reloads do not
trigger a full protocol scan on every HTTP request.

The devkit validates and applies the selected database migrations before starting
Phoenix. Developers restart `bun dev` to apply migrations added during a running
session.

The six external provider clients live as internal modules of their respective
Plugins, each with distinct module names and error structs. Once `Repo` and
AppConfigure finish starting, the active Plugin cohort starts each Plugin's
caches, token supervisors, and persistent connections under supervision.

Static source dependencies point strictly inward from concrete Plugins to core
domain contracts: domain modules must not reference concrete Plugins, and
Plugins must not reference one another. `mix ankole.compile_cycles` enforces
this boundary across compile, export, and runtime edges in the compiled `xref`
graph. At runtime, Ankole resolves Plugins from the configured module list.

Reusable lower-level libraries with independent callers—`im_transport`,
`feishu_protocol`, the Rust/Elixir Kernel, and `tools/fake-feishu`—remain
separate Mix projects. To run unit tests for the six provider clients without
PostgreSQL, execute `bun run control-plane:test:plugins` from the repository
root (optionally passing one Plugin directory name such as `lark_adapter`); the
command compiles `:ankole`, skips full application startup, and uses each
client's test helper to boot only its local supervisor. The full control-plane
test suite runs these tests as well.

### Webapp entries and slots

Frontend build composition mirrors the backend split. `app/webapps/entries.json`
declares public SPA entries, while in SaaS builds
`internals/webapps/entries.json` adds an `entries` map for private SPAs and an
optional `overrides` map for wrappers around public entries. Every additional
entry must use a unique name, every override must target an existing public
entry, and both maps resolve source paths inside `internals/webapps`. Phoenix
and Vite consume the same resolved entry names, and every SPA loads the build's
merged locale catalog (allowing private extensions to define their own TOML key
namespaces).

The Console shell loads route components on demand. A route loader that uses a
page-owned query imports that page on the same route; the shared shell does not
pull unrelated editors into its initial module graph. TanStack Query owns the
fetched data, and the router renders a ready destination without a minimum
loading-screen duration.

An override wrapper passes typed `slots` into the public root component, whereas
public roots default to empty slots:

- **`PodAppSlots`**: Contributes account-menu items and lazy-loaded settings
  tabs. Each contribution names its owning `pluginId` and renders only when that
  Plugin appears in the HTML shell's snapshot of active site Plugins. Settings
  tabs declare `id`, `labelKey`, optional `when`, and a lazy `Component` wrapped
  in `Suspense`; tab IDs must be unique and cannot collide with `general`,
  `members`, `invitations`, or `providers`. Tabs without `when` activate
  alongside their Plugin, while OpenFeature evaluates any `when` flag—returning
  the settings view to `general` if the currently open tab becomes hidden.
- **`ConsoleAppSlots`**: Contributes lazy extension `routes` and `navSections`,
  gated by `pluginId` and optional `when`. IDs and route paths cannot collide
  with core Console routes. TanStack Router stores each route's
  `scope: 'site' | 'tenant'` in its static metadata; the Console reads the
  matched route to control the top-bar tenant switcher.
- **`AuthAppSlots.emailOtpChallenge`**: Contributes a lazy challenge component
  and optional `when` flag. The host passes `attemptKey` and
  `onChallengeStateChange({ready, headers})`, blocking email OTP requests and
  resends until the challenge reports `ready` and attaching the current
  attempt's `headers`. Submitting the form—or changing the auth flow, email
  address, or `when` condition—resets the challenge (though a `when` change
  preserves any typed email and code). Verifying a delivered email code uses the
  core login contract.

To bootstrap client-side gating without an extra round trip, the server HTML
shell embeds `ankole-active-plugins` and `ankole-features` `<meta>` tags
carrying the active site Plugin IDs and public feature snapshot. Before the
first render, `mountApp` initializes the official OpenFeature Web
`InMemoryProvider` and provides the active Plugin IDs via React context so
components can read feature flags through `OpenFeatureProvider` and standard
OpenFeature hooks.

### Share an implementation only when its contract matches

Shared transport libraries extract common protocol mechanics while leaving
provider-specific semantics with each adapter:

- **`im_transport`**: Provides shared JSON body primitives, request-body
  selection, `Retry-After` parsing, download filename parsing, WebSocket URL
  decomposition, and the Mint WebSocket connection. Callers supply their own
  error and empty-body mappings—DingTalk and WeCom map empty bodies through
  their own handlers, and Feishu applies its own filename rules.
- **`IMTransport.WebSocket`**: Opens the socket, completes the HTTP upgrade, and
  encodes/decodes frames without dictating reconnect intervals, heartbeats, or
  frame semantics. Gateways that require conventional HTTP/1 header casing can
  opt into canonical upgrade headers via a connection option. On invalid URLs,
  Feishu maps to its own URL error while Discord returns the shared URL error.
- **`IMTransport.TokenCache`**: Manages an ETS row `{key, token, expires_at}`
  with a three-minute expiry margin, a thirty-second proactive refresh lead, and
  single-flight miss coalescing so concurrent cache misses share one upstream
  request. DingTalk and WeCom use this single-key fetch while owning their own
  token HTTP calls and error structs; Feishu uses its multi-key token state
  machine with the same expiry margin; Microsoft and Google use last-write-wins
  caches. Response envelopes, error classifications, and reconnect callbacks
  stay inside each provider.
- **`feishu_protocol`**: Owns the Feishu WebSocket frame codec. Both the Lark
  Plugin and `tools/fake-feishu` depend on `feishu_protocol`, whereas the fake
  platform never depends on the control plane, allowing host integration tests
  to run the real Lark client against that standalone server.

For domain operations, call the owning domain module directly: shared Markdown
prose chunking lives in `Ankole.Plugins.MarkdownChunks`, normalized multi-send
results live in `Conversations.Delivery.Adapter`, and phone-number
normalization, Plugin field builders, configuration helpers, and connection
lifecycle contracts live in their respective domain modules. Calling a shared
domain function from multiple Plugins is reuse, not duplication.

Before extracting a helper across providers, verify that input semantics, `nil`
and empty-value handling, error shapes, units, side effects, and recovery
ownership all match. Keep renderer-specific checkpoint keys inside each adapter
even when two implementations look identical, and keep Lark's string-array
validator in Lark because of its custom whitespace rules. Shared helpers must
never accumulate branches that switch on the provider.

In addition to boundary checks, `mix ankole.compile_cycles` rejects any
dependency cycle containing a compile-time edge across `:ankole` and its local
Mix dependencies, running in CI under both `test` and `prod` environments.

Fixed build composition stays independent of `plugins.enabled_ids`: disabling an
optional Plugin at runtime never removes the compiled HTTP entry, Host policy,
site authentication sources, AppConfigure declarations, frontend entries,
locales, or migration paths. Each owning subsystem configures those elements
directly from the source build rather than through generic Plugin callbacks.
When the AppConfigure Registry restarts, it reloads fixed declarations first and
then restores active Plugin declarations.

See [Browser Sessions](BrowserSessions.md) for site authentication sources and
[CONTRIBUTING](../../CONTRIBUTING.md#source-builds) for source, resource, and
migration commands. Private SaaS modules use distinct module names and call
public domain functions; they never overwrite compiled modules or inject methods
at runtime.

### Enable a Control Plane Plugin

Each Control Plane Plugin's `activation/0` callback defaults to `:optional`,
governed by the global `plugins.enabled_ids` AppConfigure key (an empty list
activates no optional Plugins). A Plugin that returns `activation: :always` is
fixed by the selected source build and stays active permanently; the Console
marks it as included in the build and rejects disable requests.

During first-run setup, the UI renders `:always` Plugins as checked and
disabled; setup selection responses include them, whereas the persisted enable
list stores only `:optional` Plugin IDs. Because the setup URL encodes both the
active step and completed steps, reloading the page restores progress and
fetches the saved Plugin selection from the setup API.

On completed installations, the Plugin cohort reads `plugins.enabled_ids` once
at startup and freezes an immutable boot snapshot, so later edits take effect
only after a control-plane restart. First-run setup is the sole exception: while
`setup.completed` is `false`, the Registry activates every compiled Control
Plane Plugin so all bundled adapters, AppConfigure keys, and supervised
processes remain reachable while an operator steps through or restarts setup.
Once setup completes, the first subsequent restart applies the saved
`plugins.enabled_ids` policy, and completed installations fail closed.

The Console exposes both configured and live states through:

- `GET /api/v2/site/control-plane-plugins`
- `PUT /api/v2/site/control-plane-plugins`

`PUT` requests take `{ "data": { "id": string, "enabled": boolean } }` with
`Content-Type: application/vnd.api+json`, and each response row reports:

- `activation`
- `configured_enabled`
- `active`
- `restart_required`

Inactive Plugins still appear in the Console and keep their saved settings in
PostgreSQL, though they contribute no definitions, adapters, or processes until
activated on a subsequent boot.

Ankole blocks disabling an identity-provider Plugin while any tenant has an
enabled provider backed by it. Operators must disable those tenant providers
first, where the login policy verifies that at least one administrator sign-in
path remains.

Administrators can disable Worker-provider Plugins while Agents still reference
them. The configured choice takes effect on restart. Provider configuration and
Worker references remain stored; operations that need an inactive provider kind
report which Plugin must be re-enabled. Administrators are responsible for the
availability impact of their choice.

Both the Console Plugin controls and first-run setup write through
`Ankole.Plugins.Config`, backed by `AppConfigure.update_global/2` for validation,
storage, transaction framing, and key locking. General Console settings display
`plugins.enabled_ids` as read-only. Inside the write transaction,
`Ankole.Plugins.Contracts.veto_disable/2` lets the identity-provider subsystem
protect administrator sign-in. If the stored
enable list cannot be decoded, `Ankole.Plugins.Config` aborts the write; an
operator can recover by deleting the key via
`Ankole.AppConfigure.delete_global/1`.

Function Compute requires `china-market-ai-providers` (which enables both the
China-market model adapters and Function Compute), and Vercel Workers require
`vercel-worker-provider`. Neither Plugin is enabled by default; to enable them
programmatically before a restart:

```elixir
Ankole.Plugins.put_configured_enabled("china-market-ai-providers", true)
Ankole.Plugins.put_configured_enabled("vercel-worker-provider", true)
```

Each call accepts any compiled Plugin ID while preserving the rest of the saved
list.

### Recover the Boot Snapshot

`Ankole.Plugins.Cohort` supervises the Plugin Registry ahead of the Plugin
runtime supervisor under a `:rest_for_one` strategy. If the Registry crashes,
OTP restarts both processes from the original immutable boot snapshot, ensuring
that configuration edits saved after boot cannot alter the active Plugin set
mid-recovery. Conversely, if a child inside the Plugin runtime supervisor
crashes, that fault stays contained inside the runtime supervisor without
restarting the Registry.

Cross-recovery with AppConfigure stays consistent without restarting the rest of
the control plane: when the AppConfigure Registry restarts, it reads active
Plugin declarations from the live Plugin Registry; when the Plugin Registry
restarts, it replaces the entire Plugin declaration source in AppConfigure
before starting the Plugin runtime supervisor.

### Keep Plugin Code inside Control-Plane Contracts

Control Plane Plugins store all operator settings and encrypted secrets through
`Ankole.AppConfigure` rather than maintaining a separate config store, and
release builds fix the compiled module list before runtime configuration loads.
Core control-plane domains own persistence, authorization, setup, supervision,
and database commits; a Plugin implements only the atom-keyed callback contract
defined by its calling subsystem.

`Ankole.Plugins.Contracts` is the single dispatch table connecting the Plugin
Registry to owning subsystems. Each entry declares three callbacks: `validate`
(checks an active declaration at Registry startup), `refresh` (publishes the
subsystem's view of the boot snapshot), and `veto_disable` (blocks invalid
changes to `plugins.enabled_ids` inside the config transaction). Both the
Registry and `Plugins.Config` dispatch exclusively through this table without
hardcoding subsystem names. Adding a new subsystem contract requires one table
entry; declarations whose contract has no entry receive only the generic
structural check in `Plugins.Spec`.

Control Plane Plugins and Agent Plugins are enabled independently: enabling or
disabling a control-plane adapter never toggles a related Agent Plugin, or vice
versa.

### Features and domain transaction hooks

`Ankole.Features` wraps the official OpenFeature Elixir SDK for dynamic runtime
policy checks, allowing a feature's policy to change without restarting Plugins.
`evaluate_details/1` returns `OpenFeature.EvaluationDetails` (including the flag
key) and raises `ArgumentError` for undeclared keys; see
[App Configuration](AppConfiguration.md#feature-policies).

Active Plugins can also register synchronous pre-commit hooks via `hooks/0`—for
example, `[create_agent: MyPlugin.Quota]`—where the target module implements
`Ankole.Plugins.Hook.before_commit_in_tx/2`. At startup, the Registry indexes
hook contributions from active Plugins and dispatches them in Plugin ID order,
then declaration order. Returning `:ok` allows the commit to proceed, while
returning `{:error, reason}` rolls back the enclosing transaction.

`Ankole.Plugins.Hook.points/0` defines the supported hook points:
`:create_agent`, `:create_invitation`, `:enable_signal_binding`,
`:enable_identity_provider`, `:store_file`, `:commit_files`, `:create_pod_page`,
`:restore_pod_page`, `:insert_base_records`, and `:admit_compute`. Each hook
receives the domain attributes at that transaction boundary, runs under the
domain's established lock order, and may inspect the current tenant while the
host manages activation and dispatch. To let active Plugins enforce compute
quotas without scattering policy branches across core domains, both
`FunctionRuntime` and `AgentWorkers` report execution duration and expose stop
controls (in `AgentWorkers`, duration tracking covers active execution runs only
and excludes warm-idle keepalive).

For `:enable_signal_binding`, the hook receives the `Signals.Binding` write
attributes—including `agent_uid`, `name`, `adapter`, `config_ref`, and
`enabled: true`—on both initial creation and reactivation. Already-enabled
Bindings keep their admission across edits and moves within the same tenant, and
when enabling an existing Binding, the Signals domain locks the row before
invoking the hook.

At startup, `Plugins.Spec` validates the shape of every adapter declaration, the
Registry indexes active declarations by `{contract_id, adapter_id}`, and callers
look them up from the immutable site snapshot via `Ankole.Plugins.fetch_adapter/2`.

### Extension HTTP routes

A build-selected outer router may run a request `Plug` before forwarding to the
core router via `AnkoleWeb.runtime_forward`, using the core route's HTTP method
and path whenever it attaches an admission challenge.

An extension router can also mount scoped JSON:API routes on both the site Host
and Pod Hosts. Site extension routes enforce the site-administrator browser
session, CSRF proof, tenant-free execution (`Ankole.Repo.without_tenant/1`), and
the resource's Principal/AuthZ declaration via
`AnkoleWeb.JSONAPI.Context.before_dispatch/3` with `:saas_site`, whereas Pod
extension routes enforce the Pod browser session, CSRF proof, tenant binding,
and Principal/AuthZ declaration via `before_dispatch/3` with `:pod`. Each
extension domain declares typed JSON:API actions backed by the native AuthZ
authorizer and emits separate OpenAPI specs verified by `mix ankole.openapi.check`
for client code generation.

### Declare a Worker Provider Kind

To add a Worker backend, a Plugin declares `contract_id: "agent_workers.provider_kind"`,
a unique `id`, and a `module` implementing `Ankole.AgentWorkers.ProviderKind`
whose `definition/0` specifies the YAML schema, credential fields, example
config, pause support, and instance lifetime. The Worker subsystem validates
these declarations at Plugin startup while keeping durable provider
configuration and lifecycle state in core control-plane tables; see
[Agent Workers](AgentWorkers.md).

### Declare a Message Adapter

`Ankole.Plugins.Plugin.adapter_declarations/0` returns atom-keyed adapter maps.
Each messaging adapter declares `contract_id: "signals.adapter"`, a unique
adapter ID, catalog fields built with `Ankole.Plugins.Spec.field/5` (which fills
in shared keys and `advanced: false` around the Plugin's localized labels,
defaults, and constraints), and an `adapter_category` (`enterprise IM`,
`consumer IM`, or `Email`, used strictly for UI grouping rather than
authorization). `Ankole.Signals.Adapters` validates active declarations from the
boot snapshot.

Inbound and outbound responsibilities split across dedicated adapter modules:

- **Observation (`observe_module`)**: Converts provider events and calls
  `Ankole.Conversations.Observe`, implementing `chat_consumer/2` alongside
  callbacks for its declared inbound capabilities. Observation persists a shared
  Conversation, public Message, and `ExternalMessageRef` before routing work
  into the single `Ankole.Signals.accept_in_tx/1` intake. While the adapter
  supplies `provider_conversation_id` and `provider_message_id`, Conversations
  assigns the public UUIDs `conversation_id` and `message_id`.
- **Delivery (`deliver_module` and `reply_preview_module`)**: `deliver_module`
  implements `Ankole.Conversations.Delivery.Adapter` (`deliver/1` for one
  persisted provider intent, plus `reconcile/1` when `outbound_reconciliation`
  is declared), and `reply_preview_module` implements optional live reply
  previews. Delivery owns retry attempts and provider confirmation; adapters
  never create public Agent Messages before the upstream provider confirms a
  send.
- **Transport**: HTTP webhook adapters declare `signals.webhook_handler`,
  verifying provider signatures and committing observation before returning an
  HTTP acknowledgement. Long-lived socket adapters use
  `Ankole.Plugins.ConnectionLifecycle.start_owner/3` to register single-consumer
  connection owners keyed by tenant and config fingerprint while keeping their
  own socket state and wire protocol. When an event arrives,
  `Ankole.Conversations.AdapterContext.dispatch_chat/2` selects matching chat
  consumers and collects their results in Binding order, with each adapter
  parsing its own payload and supplying its own subject namespace.

Once per minute, a reconciliation pass invokes `binding_spec/2` for every
enabled Binding. `binding_spec/2` must remain pure—deriving the connection spec
from stored configuration without making network calls. Any runtime identity
lookup or upstream API call belongs in `owner_child_spec/3`, which executes in
the reconciler process behind an adapter-owned cache with both a success TTL and
failure backoff (preventing upstream outages from hammering the provider every
minute or blocking the shared connection supervisor). Failure tuples may return
`%{reason: term(), retry_at: DateTime.t()}`, where `retry_at` appears alongside
the reason without altering error identity. When the active error set first
appears or changes, the reconciler logs a warning; while the set stays
unchanged, it logs at most one `info` summary every ten minutes with the repeat
count, plus one `info` line when the set clears, and returns the error list to
callers of `reconcile/1`.

The built-in CloudEvents source needs no message-provider Plugin: it reuses
Signals Bindings and callback Endpoints to target an explicit Agent Session,
declaring neither a delivery module nor an IM sender policy. See
[Signals](Signals.md) for intake, filters, capabilities, and Endpoint security;
[Conversations](Conversations.md) for shared history and Delivery; and
[Sessions](Sessions.md) for turn execution and recovery.

## Rules

- Never treat `Agent Plugin` and `Control Plane Plugin` as interchangeable concepts.
- Package Agent Plugins as trusted Codex bundles with optional `workspace-template` content.
- Persist parent Agent Plugin overrides and member Skill overrides independently.
- Have `AgentCodexRuntime` install and trust all same-release Agent Plugins before the first Job thread starts, keeping global Codex entries set to `enabled = false`.
- Gate each Job's Plugin member Skills strictly through its projected Skill selection and Ankole's Skill index and `skill_view` loader.
- Use `workspace_template_id` solely to seed initial files when first creating a Job Workspace.
- Activate every compiled Control Plane Plugin while first-run setup is incomplete, require a restart for activation changes once setup completes, and keep newly added Control Plane Plugins inactive on existing installations until an operator enables them.
- Keep all durable business and configuration state in its owning subsystem.
