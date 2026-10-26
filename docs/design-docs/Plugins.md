# Plugins

Ankole uses the word Plugin for two unrelated extension types:

- An Agent Plugin gives model-facing capabilities to an Agent.
- A Control Plane Plugin adds trusted Elixir and OTP code to the control plane.

They share a name only. They use different code, configuration, and activation
rules.

## Agent Plugins

An Agent Plugin uses the standard Codex Plugin package format. Ankole adds one
optional directory, `workspace-template`, for initial Job files.

```text
app/library/agent-plugins/<agent-plugin-id>/
├── .codex-plugin/plugin.json
├── skills/
├── hooks/                 # Optional Codex content
└── workspace-template/    # Optional Job Workspace content
```

A private deployment instance trusts these first-party packages. Each manifest defines
`name`, `version`, `description`, and `skills`. The package directory must have
the same name as the manifest. A package can carry more directories that its
member Skills read, such as the `office` Playbook library below.

The control plane reads each manifest and its member Skill metadata to build the
catalog. Agent Computer resolves that catalog against the same-release package
in its own image. It reads the local manifest and member paths needed for
materialization and rejects unsafe copy entries. `AgentCodexRuntime` is the sole
owner of official `plugin/install` calls, Hook trust, the Plugin cache, and
Codex user-config changes. A Job does not perform any of these operations.
RuntimeFabric does not carry a second package version or content hash contract.

### Workspace Template

`workspace-template` contains initial files. It does not contain another
manifest.

Job creation can set one `workspace_template_id`. Agent Computer copies that
Plugin's template when it first creates the Job Workspace. It does not copy a
template when the field is absent. A resumed Job keeps its workspace files.
Runtime package refresh does not copy the template again.

The template selection does not select runtime Plugins. A Job loads only the
Plugins in its persisted runtime projection. Ankole does not interpret template
content as a separate Plugin activation contract.

### Built-in Packages

Ankole includes these Agent Plugins:

| ID | Member Skills | Shipped default |
| --- | --- | --- |
| `lark` | `lark-im`, `lark-oa`, `lark-office-suite` | Disabled |
| `office` | `docx`, `xlsx`, `pptx` | Enabled |
| `deep-research` | `create-deep-research` | Enabled |
| `brain` | `brain-learning`, `resolve-before-asking`, `idea-lineage`, `applied-reading` | Enabled |
| `github` | `github-auth`, `github-issues`, `github-pr-workflow`, `github-repo-management`, `github-webhooks` | Disabled |

Member Skills exist only inside their Agent Plugin.
Standalone Skills remain under `app/library/skills`.

The three `office` member Skills share one Playbook library in their package
root. A Playbook declares the products it applies to, and each Skill lists only
its own product with `tools/list_playbooks.ts <product>`, then reads the
Playbooks that match the request. A Playbook adds the rules for one kind of
deliverable and does not repeat its Skill. The library needs no Job Workspace
template, so every Job reads it from the package copy.

The `deep-research` member Skill runs only in the main Agent. It clarifies the
research contract, starts one BackgroundAgentJob, and accepts the result. Its
`workspace-template` owns the Job's research lifecycle, Playbook routing,
working state, Markdown semantic draft, and contract-defined artifacts. The Job
does not load the main-only member Skill.

Research routing has two different epistemic objects, not two levels of
urgency and not a split based on whether the reader will act:

- `create-deep-research` investigates the external world. It establishes
  facts, compares evidence, explains or assesses external developments, and
  evaluates claims or forecasts. Stock buy/hold questions, price and demand
  forecasts, competitive outcomes, and risk estimates stay here even when the
  requested answer contains an action.
- `research-for-planning` investigates the environment of a controllable
  operating, product, market-entry, or launch choice. It compares feasible
  options and gathers market, competitor, channel, cost, compliance, and
  resource constraints so a planner can select an action combination. It does
  not predict the target market, asset prices, demand, or other external
  outcomes.

Neither Skill is triggered by the word “plan”, a supplied bundle of sources, a
PDF deliverable, plan writing or review, or a single quick lookup. A mixed
request splits subquestions by this research object and then returns to the
requested action. If there is no material investigation gap, answer directly.

The public `github` package owns GitHub repository webhook setup,
reconciliation, redelivery, and removal in its `github-webhooks` Skill.
Signals supplies only the callback capability. It does not contain a
GitHub adapter or store a copy of GitHub hook state.

### Decide Which Capabilities an Agent Can Use

An Agent Plugin and each Skill have separate enabled states. Tenant settings
provide defaults, with site inheritance when the tenant has no override. An
Agent stores only values that override its tenant's effective defaults.

```text
Agent Plugin effective = agent override ?? tenant default
Plugin Skill effective = parent effective && (agent override ?? tenant default)
Standalone Skill effective = agent override ?? tenant default
Agent-installed Skill effective = agent override ?? source default
```

Every member Skill starts enabled. Disabling the parent Plugin makes all members
unavailable without changing their saved settings. Those settings apply again
when the parent becomes enabled.

AppConfigure stores the defaults in these tenant-scoped keys:

- `ai_agent.library.agent_plugin_defaults` stores Agent Plugin booleans.
- `ai_agent.library.skill_defaults` stores Skill booleans.

Ordinary capability reads use the AppConfigure cache. The first Job runtime
projection and capability-change notifications read defaults directly through
`AgentPlugins.Config.defaults_in_tx/0` and pass the result as
`agent_library_defaults`. The projection read stays in the admission transaction;
notifications read after the configuration update commits.

A Plugin Skill ID uses `<agent-plugin-id>:<skill-name>`.
A standalone Skill ID uses its Skill name.

PostgreSQL stores Agent Plugin overrides in `agent_plugin_overrides`.
It stores Skill overrides in `agent_skills.enabled_override`.
A null Skill override means inheritance.

The Agent Library resources own sparse Plugin overrides, Skill catalog sync,
per-Agent enablement, and runtime document writes. Catalog sync preserves saved
enablement overrides. Active documents keep their partial unique path
identity and exact content bytes. Public API projections use string enum
values; resource records use atoms.

Plugin member rows use `source_kind = "builtin"`.
The `agent_plugin_id` field records their parent.
Skill discovery and execution do not depend on a special source kind.

The Agent Library keeps all member Skill records current, including members of
disabled Plugins. This keeps saved choices and the Console catalog intact.

A shipped standalone or Plugin member Skill can declare
`brain-recall-only: true`. It keeps the same global Skill name and all normal
enablement rules, but it is omitted from the prompt catalog. Brain indexes its
name, description, and tags as a small discovery record; `skill_view` remains
the only loader for its full body and resources. Agent-installed Skills do not
use this discovery mode.

### What a Job Saves and Loads

The Job stores one optional `workspace_template_id`. At first execution
admission, it also stores the logical Plugin and Skill selection in its typed
runtime projection. Retry, resume, and Worker migration use that projection.
They intersect it with the current effective capability set, so disabling a
capability removes it from subsequent executions. The projection does not store
package bytes, overlays, credentials, or Hook state.

Before the first Job thread starts, `AgentCodexRuntime` performs these actions
in one per-Agent serialized owner:

1. Resolve every trusted same-release package and refresh its stable material
   under the Agent Home.
2. Install every package through the official Codex `plugin/install` method.
3. Verify the official installed state and trust package Hooks through Codex.
4. Set every Agent Plugin entry in Codex user config to `enabled = false`.

Installing all same-release packages before any thread avoids later global
cache and config mutation while sibling threads are active. The global disabled
state is deliberate: installation owns package lifecycle, but it does not grant
every Job the capability.

Each Job then performs only thread-owned selection:

1. Resolve its projected Plugin IDs and Background-eligible members against the
   current catalog.
2. Render the ordinary members in the Job Skill index and keep all selected
   members in the Ankole `skill_view` load set.
3. Project enabled Skill-owned MCP servers separately.

The Job does not pass Ankole Skill roots to Codex, use `.agents/skills`, or
depend on Codex `skills/list`. This keeps Plugin and Skill selection inside the
same Ankole enablement owner for the main Agent and Background Agent Jobs.

Only enabled members that permit Background Agent Jobs add MCP settings. The
optional workspace template is copied once and does not change runtime Plugin
selection.

RuntimeFabric carries the enabled Agent Plugin catalog and Skill summaries in
the Agent context of `workspace_open` and a starting `turn_start`.
See [Background Agent Job](BackgroundAgentJob.md) for the complete Job contract.

### Change Capability Settings through the Console

The Console API exposes the selected tenant's defaults and Agent-specific
effective state.

- `GET /api/v2/agent-library/capabilities`
- `PUT /api/v2/agent-library/agent-plugins/:id`
- `PUT /api/v2/agent-library/skills/:id`
- `GET /api/v2/agents/:agent_uid/library-capabilities`
- `PUT /api/v2/agents/:agent_uid/library-capabilities/agent-plugins/:id`
- `PUT /api/v2/agents/:agent_uid/library-capabilities/skills/:id`

Requests use `application/vnd.api+json`. Tenant default writes use
`{ "data": { "enabled": boolean } }`. Agent writes use
`{ "data": { "enabled": boolean | null } }`.
A null value restores inheritance.

Capability rows include these state fields:

- `global_default_enabled`
- `override_enabled`
- `effective_enabled`

The API field `global_default_enabled` reports the effective default for the
selected tenant, including site inheritance.

Each Agent Plugin row contains its member Skills. The top-level Skill list
contains standalone and Agent-installed Skills.

The Console shows Agent Plugins, standalone Skills, and installed Skills as
separate groups. It shows Control Plane Plugins only for the deployment
instance.

## Control Plane Plugins

Ankole trusts the Elixir and OTP code in a Control Plane Plugin. A Plugin can
add metadata, AppConfigure definitions, adapters, and supervised processes.

Ankole does not download or load arbitrary plugin code at runtime.

Implementation modules use the `Ankole.Plugins` namespace.
The host configuration `:control_plane_plugin_modules` list names every Plugin module.
Each release compiles that complete list. Startup does not read or parse plugin
source files.

Plugin IDs must be unique across the declared modules.
Duplicate IDs stop application startup.
The Registry publishes the active list as an immutable `:persistent_term`
snapshot. Reads use that snapshot directly. The GenServer owns startup and
snapshot publication.

### Fixed source builds

`ANKOLE_EDITION=foss|saas` selects the source build; the default is `foss`.
A FOSS build compiles public Plugins and ignores `internals` source and
migrations. A SaaS build also compiles `internals/control_plane/lib` and
`internals/plugins/*/lib`. Missing private source fails the build.

`app/control_plane` is one Mix project and one `:ankole` OTP application. It
owns domain and web code, configuration, migrations, deployment commands,
test support, and the application supervisor. It compiles source from each
`plugins/<name>/lib` directory into the same application. One release has one
Repo and one migration ledger. FOSS and SaaS use separate build directories.
Development builds reload the application and its local dependencies. Protocol
consolidation is disabled in development so dependency reloads do not cause a
full protocol scan on each HTTP request.

The six provider clients are internal modules of their matching Plugins. Their
module names and provider error types are distinct. Plugin caches, token
supervisors, and connections start as children of the active Plugin cohort,
after Repo and AppConfigure are ready.

The source dependency direction is from a concrete Plugin to its domain
contracts. A domain module cannot statically reference a concrete Plugin, and
one Plugin cannot statically reference another Plugin.
`mix ankole.compile_cycles` checks compile, export, and runtime references from the
compiled xref graph. Two exact references are allowed for persisted Slack and
Microsoft credential migration: `Ankole.Upgrade202610` can call
`Ankole.Plugins.SlackAdapter.Config` and
`Ankole.Plugins.Microsoft365Adapter.Config`. Plugin selection uses the configured
module list at runtime.

`im_transport`, `feishu_protocol`, the Kernel, and the fake Feishu platform keep
their own Mix projects. They own reusable contracts with independent callers.

Run `bun run control-plane:test:plugins` from the repository root for the six
provider clients' unit tests without PostgreSQL. Add a Plugin directory name,
such as `lark_adapter`, to select one client. The command compiles the
`:ankole` application, skips application
startup, and uses each client's test helper to start only its supervisor.
The ordinary control-plane test suite also runs these tests.

### Webapp entries and slots

`app/webapps/entries.json` declares public SPA entries. The private
`internals/webapps/entries.json` has an `entries` map for additional SPAs and
an optional `overrides` map for public entry wrappers. An additional entry
must have a unique name. An override must name a public entry. Both maps
resolve source files inside the private webapp directory. Phoenix and Vite
use the same selected entry names.

A wrapper passes typed `slots` to the public root component. Public roots use
empty slots by default. `PodAppSlots` supplies account-menu content and lazy
settings tabs. Each contribution declares its owning `pluginId`. The host
renders it only when that Plugin is in the HTML shell's site activation
snapshot. Each tab also declares `id`, `labelKey`, optional `when`, and a lazy
`Component`. IDs must be unique and must not claim `general`, `members`,
`invitations`, or `providers`. A slot without `when` is enabled with its Plugin.
OpenFeature evaluates a declared `when` condition. A hidden active
tab returns the settings view to `general`. A Suspense boundary loads the
selected extension component.

`ConsoleAppSlots` supplies lazy extension `routes` and `navSections` (checked for
unique IDs that do not collide with core Console routes, with `scope: 'site' |
'tenant'` controlling the top-bar tenant selector), `tenantDetailSections` on
`/tenants/$tenantID`, and `homeWidgets` on the Console home page, all gated by
the owning `pluginId` and optional `when` condition.

Every SPA loads the build's merged locale catalog. Extension labels can use
their own namespaces in the private TOML catalogs.

`AuthAppSlots.emailOtpChallenge` supplies a lazy component and an optional
`when` key. The component receives `attemptKey` and
`onChallengeStateChange({ready, headers})`. The form requires a ready challenge
before it requests or resends an email code. The current attempt supplies the
request headers. Sending a request or changing the flow, email, or condition
resets the challenge. A condition change preserves the entered email and code.
Verification of a delivered email code uses the core login contract.

The HTML shell supplies `ankole-active-plugins` and `ankole-features` meta
elements. They contain the active site Plugin IDs and the public feature
snapshot. `mountApp` loads the official OpenFeature Web `InMemoryProvider`
and supplies active Plugin IDs through React context before the first render.
React components read feature values through
`OpenFeatureProvider` and the official hooks.

### Share an implementation only when its contract matches

`im_transport` owns shared JSON body primitives, request-body selection,
Retry-After parsing, download filename parsing, WebSocket URL decomposition,
and the Mint WebSocket connection. Callers supply their own error and
empty-value mappings: DingTalk and WeCom map empty bodies through their own
handlers, and Feishu applies its own filename rules.

`IMTransport.WebSocket` opens the socket, completes the upgrade, decodes frames,
and sends frames. It does not choose reconnect timing, heartbeats, or frame
meaning. A canonical HTTP/1 upgrade header form is a connection option for a
gateway that requires conventional header names. Feishu uses its own URL
error, and Discord reports the shared URL error.

`IMTransport.TokenCache` owns one ETS row `{key, token, expires_at}`, the
three-minute expiry margin, the thirty-second refresh lead, and the single-key
fetch that joins concurrent misses into one upstream request. DingTalk and
WeCom use that fetch and own their token HTTP requests and error
structs. Feishu uses its multi-key token state machine with the same expiry
margin. Microsoft and Google use last-write-wins caches. Response envelopes,
error classifications, and reconnect callbacks belong to each provider.

`feishu_protocol` owns the Feishu WebSocket frame codec. Both the Lark Plugin
and `tools/fake-feishu` depend on it; the fake platform does not depend on the
control plane. The host integration suite runs the real client against that
standalone platform.

Reuse the owning domain module for domain operations. Shared Markdown prose
transformations live in `Ankole.Plugins.MarkdownChunks`; normalized multi-send
results live in `Conversations.Delivery.Adapter`. Identity phone normalization,
Plugin fields, configuration helpers, and connection lifecycle contracts belong
to their domain owners. A repeated call to one of these functions is not a
second implementation.

Before sharing a function, compare its input meaning, nil and empty handling,
error shape, units, side effects, and recovery ownership. Renderer-specific
checkpoint keys belong to each adapter even when two implementations are
identical. The Lark string-array validator uses its own whitespace
rules. Shared code must not grow provider-selection branches.

`mix ankole.compile_cycles` also rejects dependency cycles that contain a
compile-time dependency in the control plane and each local Mix dependency.
CI runs it in test and production environments.

Fixed build composition is separate from `plugins.enabled_ids`. The selected
HTTP entry, Host policy, site authentication sources, AppConfigure declarations,
frontend entries, locales, and migration paths cannot disappear because an
operator disables a Plugin. These use their owning subsystem's concrete build
configuration; they are not generic Plugin callbacks. AppConfigure reloads
the fixed declarations when its Registry recovers, then restores active Plugin
declarations.

See [Browser Sessions](BrowserSessions.md) for site sources and
[CONTRIBUTING](../../CONTRIBUTING.md#source-builds) for source, resource, and
migration commands. Private modules have distinct names. They call public domain
functions; they do not replace a compiled module or use Ruby-style method
injection.

### Enable a Control Plane Plugin

A Plugin's `activation/0` callback returns `:optional` by default. The global
AppConfigure key `plugins.enabled_ids` selects optional Plugins. An empty
list activates none of them. A Plugin with `activation: :always` is part of the selected source build and
remains active. The Console identifies these Plugins as included in the build
and rejects a disable request.

Setup shows fixed Plugins as selected and disables their checkboxes. Its
selection response includes fixed Plugins; the saved enable list contains
only optional Plugins.

The Plugin cohort reads the list during startup and resolves one immutable boot
snapshot. A later change takes effect only after a restart.

First-run setup is the only exception. While `setup.completed` is false, the
Registry activates every discovered Control Plane Plugin. This keeps all
bundled adapters, AppConfigure keys, and supervised processes available while
the operator moves between setup choices or restarts an incomplete setup. The
enable list is the durable post-setup policy. The first restart after setup
completes applies that list. Completed installations fail closed.

The Console API makes both states visible.

- `GET /api/v2/site/control-plane-plugins`
- `PUT /api/v2/site/control-plane-plugins`

The write body uses `{ "data": { "id": string, "enabled": boolean } }` with
`Content-Type: application/vnd.api+json`.

Each response row includes these fields:

- `activation`
- `configured_enabled`
- `active`
- `restart_required`

The Console lists inactive Plugins, and their saved settings stay
in PostgreSQL. An inactive Plugin adds no definitions, adapters, or processes until activation.

A Worker-provider Plugin cannot be disabled while any tenant has an assigned
Worker row for one of its kinds. Paused Workers and Agents being deleted count
as references. Remove those Agents and wait for their Worker cleanup before
disabling the Plugin. New Agent assignments require both current activation
and next-start selection. A pending disable therefore rejects new assignments.
The Plugin controls and setup selection use this same check. The
`plugins.enabled_ids` entry is read-only in general Console settings. Use the
Control Plane Plugin controls to change it. These writes belong to
`Ankole.Plugins.Config`. AppConfigure supplies validation, storage, the
transaction, and its key lock (`AppConfigure.update_global/2`). In that
transaction, `Ankole.Plugins.Contracts.veto_disable/3` lets each contract stop
the change. Only changes that remove Worker kinds also take the Worker
provider lock and check Worker references. Enabling Plugins and changes to other
Plugins do not run that check. A stored list that cannot be decoded stops the
write; delete the key with `Ankole.AppConfigure.delete_global/1` to recover.

Function Compute requires `china-market-ai-providers`; Vercel requires
`vercel-worker-provider`. The China-market Plugin enables both its model
adapters and Function Compute. Neither Plugin is enabled by default. To select
them through the configuration API before a restart:

```elixir
Ankole.Plugins.put_configured_enabled("china-market-ai-providers", true)
Ankole.Plugins.put_configured_enabled("vercel-worker-provider", true)
```

These calls preserve other selected IDs and accept any compiled Plugin ID.

### Recover the Boot Snapshot

`Ankole.Plugins.Cohort` supervises the Registry before the Plugin runtime
supervisor with `rest_for_one`. A Registry crash restarts both processes from
the same immutable boot snapshot, so a later configuration edit cannot change
the active set during fault recovery. A failure inside one Plugin child stays
inside the runtime supervisor and does not restart the Registry.

The AppConfigure Registry can read the active Plugin declarations from the
live Plugin Registry when it recovers. If the Plugin Registry recovers, it
replaces the complete Plugin declaration source before the runtime supervisor
starts. These two paths keep the active snapshot, declarations, and supervised
children consistent without restarting the rest of the control plane.

### Keep Plugin Code inside Control-Plane Contracts

Control Plane Plugin settings use `Ankole.AppConfigure` for validation,
encryption, and storage. Plugins do not have a separate configuration database
or secret store.

Module selection cannot depend on AppConfigure.
The release build selects modules before runtime configuration.

The control plane handles storage, authorization, setup, supervision, and
database commits. A Plugin implements only the callback contract of the
subsystem that calls it. Each subsystem document defines that contract.
Callback declarations use atom keys.

`Ankole.Plugins.Contracts` is the one table of these contracts. Each entry
names the functions of the owning subsystem: `validate` checks one active
declaration at Registry startup, `refresh` publishes the subsystem view of the
boot snapshot, and `veto_disable` can stop a change of the enable list. The
Registry and `Plugins.Config` call only this table; they do not name a
subsystem. A new contract adds one entry. A declaration of a contract without
an entry keeps only the generic shape check of `Plugins.Spec`.

Control Plane Plugins do not control Agent capabilities. A control-plane
adapter and a related Agent Plugin can have different enabled states.

### Features and domain transaction hooks

`Ankole.Features` uses the official OpenFeature Elixir SDK for dynamic
consumer decisions. A feature's declared policy can change without a Plugin
restart. `evaluate_details/1` returns the SDK's `OpenFeature.EvaluationDetails`,
including the flag key. An undeclared key raises `ArgumentError`. See
[App Configuration](AppConfiguration.md#feature-policies).

Plugins declare transaction hooks through `hooks/0`, with entries such as
`[create_agent: MyPlugin.Quota]`. The module implements
`Ankole.Plugins.Hook.before_commit_in_tx/2`. The Registry indexes these
contributions from active Plugins at startup. Dispatch uses Plugin ID order,
then each Plugin's declaration order. The callback returns `:ok` or
`{:error, reason}`; an error rolls back the calling transaction.
`Ankole.Plugins.Hook.points/0` declares `:create_agent`, `:create_invitation`,
`:enable_signal_binding`, `:enable_identity_provider`, `:store_file`,
`:commit_files`, `:create_pod_page`, `:restore_pod_page`,
`:insert_base_records`, and `:admit_compute`. The payload contains the
attributes at that domain's transaction boundary. Hooks use the domain's
existing lock order. A consumer owns its rules and can inspect the current
tenant. The host owns activation and dispatch. `AgentWorkers` (scoped to active
execution runs, excluding warm-idle keepalive) and `FunctionRuntime` also expose
execution-duration reporting and stop controls so an active Plugin can enforce
compute limits without placing policy branches in core domains.

The Binding hook receives the attributes for the `Signals.Binding` write,
including `agent_uid`, `name`, `adapter`, `config_ref`, and `enabled: true`.
It checks creation and reactivation. An enabled Binding keeps its admission
during edits and moves within its tenant. The domain locks an existing Binding
before it checks an enable transition.

`Plugins.Spec` validates each adapter declaration's shape at startup. The
Registry indexes validated active declarations by contract and adapter ID.
`Ankole.Plugins.fetch_adapter/2` resolves that immutable site snapshot.
`veto_disable` keeps the owning subsystem's checks inside the transaction
that changes the next-start selection.

### Extension HTTP routes

A build-selected outer router can run a request Plug before it forwards to the
core router with `AnkoleWeb.runtime_forward`. A Plug uses the core operation's
method and path when it adds an admission challenge.

An extension router can mount scoped JSON:API routes on the site Host and on
Pod Hosts. Pod extension routes require the browser session, CSRF proof, tenant
binding, and the resource's Principal/AuthZ declaration, and call
`AnkoleWeb.JSONAPI.Context.before_dispatch/3` with `:pod`. Each extension
domain declares typed JSON:API actions with the native AuthZ authorizer and
publishes separate OpenAPI documents checked by `mix ankole.openapi.check` for
client generation.

### Declare a Worker Provider Kind

A Plugin contributes `contract_id: "agent_workers.provider_kind"`, a unique
`id`, and a `module`. The module implements `Ankole.AgentWorkers.ProviderKind`.
Its `definition/0` owns the YAML schema, credential fields, example, pause
support, and instance lifetime. The Worker subsystem validates this contract
at Plugin startup. It keeps durable provider configuration and lifecycle
decisions in the core. See [Agent Workers](AgentWorkers.md).

### Declare a Message Adapter

`Ankole.Plugins.Plugin.adapter_declarations/0` returns atom-keyed declarations.
Each messaging adapter declares `contract_id: "signals.adapter"`, a unique
adapter ID, catalog fields, and an `adapter_category`. `Ankole.Signals.Adapters`
validates the declaration from the active Plugin snapshot. The catalog category
groups enterprise IM, consumer IM, and Email; it does not grant authority.

`Ankole.Plugins.Spec.field/5` builds the common catalog field shape. Plugins
supply localized text, defaults, and constraints; the builder only sets the
shared keys and the default `advanced: false` value.

`observe_module` converts provider events and calls `Ankole.Conversations.Observe`.
It provides `chat_consumer/2` and the callbacks for its declared inbound
capabilities. Observation records a shared Conversation, public Message, and
`ExternalMessageRef`; work then enters the sole `Ankole.Signals.accept_in_tx/1`
intake. The adapter supplies `provider_conversation_id` and
`provider_message_id`. Public `conversation_id` and `message_id` are UUIDs
assigned by Conversations.

`deliver_module` implements the `Ankole.Conversations.Delivery.Adapter`
behaviour through `deliver/1`. It receives one persisted provider intent.
`outbound_reconciliation` also requires `reconcile/1`.
`reply_preview_module` implements the optional provider preview contract.
Delivery owns attempts and provider confirmation; provider adapters do not
create public Agent Messages before the provider confirms a send.

An HTTP provider adapter declares `signals.webhook_handler`. Its handler
verifies the provider protocol and commits observation before it acknowledges
the request. Long connections use `Ankole.Plugins.ConnectionLifecycle`.
Its `start_owner/3` registers single-consumer owners with the tenant and config
fingerprint; each adapter keeps its own connection state and protocol.
`Ankole.Conversations.AdapterContext.dispatch_chat/2` selects chat consumers
and collects their results in binding order. Each adapter parses its own
event and supplies its own subject namespace.

The reconcile pass runs every minute and calls `binding_spec/2` for every
enabled Binding. `binding_spec/2` must be pure: it reads stored configuration
and returns the connection specification without a provider call. A runtime
identity or other provider lookup belongs to `owner_child_spec/3`, which runs
in the reconciler process, behind an adapter-owned cache with a success
lifetime and a failure backoff, so a provider error cannot repeat once per pass
and the shared connection supervisor never waits on a provider call. A reason
may be `%{reason: term(), retry_at: DateTime.t()}`; the retry time is reported
next to the reason and is not part of the error identity.

The pass logs an error set once as a warning when it appears or changes. While
the set stays equal, it logs at most one info line every ten minutes with the
repeat count, and an info line when the set becomes empty. The pass result
also lists the errors for callers of `reconcile/1`.

The built-in CloudEvents source needs no message-provider Plugin. It reuses
Signals Bindings and callback Endpoints to select an explicit Agent Session.
It does not declare a delivery module or IM sender policy. See
[Signals](Signals.md) for intake, filters, capabilities, and Endpoint security;
see [Conversations](Conversations.md) for shared history and Delivery, and
[Sessions](Sessions.md) for execution and recovery.

## Rules

- Never use `Agent Plugin` and `Control Plane Plugin` as interchangeable names.
- Treat Agent Plugins as trusted Codex packages with optional Job Workspace content.
- Store parent state and member Skill state independently.
- Let `AgentCodexRuntime` install and trust same-release Agent Plugins before the
  first Job thread, then keep the global entries disabled.
- Limit each Job's Plugin member Skills through its projected Skill selection
  and the Ankole Skill index and loader.
- Use `workspace_template_id` only to copy one initial Job Workspace template.
- Keep every compiled Control Plane Plugin active until first-run setup
  completes.
- Require a restart after setup for Control Plane Plugin activation changes.
- Keep new Control Plane Plugins inactive on completed installations until an
  operator enables them.
- Keep durable state with its owning subsystem.
