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
template when the field is absent. A resumed Job keeps the existing files.
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

A Plugin Skill ID uses `<agent-plugin-id>:<skill-name>`.
A standalone Skill ID uses its Skill name.

PostgreSQL stores Agent Plugin overrides in `agent_plugin_overrides`.
It stores Skill overrides in `agent_skills.enabled_override`.
A null Skill override means inheritance.

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
They intersect it with the current effective capability set, so a later disable
still removes the capability. The projection does not store package bytes,
overlays, credentials, or Hook state.

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

- `GET /api/v1/agent-library/capabilities`
- `PUT /api/v1/agent-library/agent-plugins/:id`
- `PUT /api/v1/agent-library/skills/:id`
- `GET /api/v1/agents/:agent_uid/library-capabilities`
- `PUT /api/v1/agents/:agent_uid/library-capabilities/agent-plugins/:id`
- `PUT /api/v1/agents/:agent_uid/library-capabilities/skills/:id`

Tenant default writes use `{ "enabled": boolean }`.
Agent writes use `{ "enabled": boolean | null }`.
A null value restores inheritance.

Capability rows include these state fields:

- `global_default_enabled`
- `override_enabled`
- `effective_enabled`

The field name `global_default_enabled` is retained in the API. Its value is
the effective default for the selected tenant, including site inheritance.

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
The Registry keeps the active list in memory for the current process.

### Fixed source builds

`ANKOLE_EDITION=foss|saas` selects the source build; the default is `foss`.
A FOSS build compiles public Plugins and ignores `internals` source and
migrations. A SaaS build also compiles `internals/control_plane/lib` into
`:ankole_core` and includes the selected private Plugin Mix projects. Missing
private source fails the build. One release has one Repo and one migration
ledger.

The Mix dependencies have one direction:

```text
:ankole (assembly and release)
  -> :ankole_core (domain and web code; no application callback)
  -> :ankole_<plugin> -> :ankole_core
                     -> shared libraries when required
```

`app/control_plane` owns configuration, migrations, deployment commands, test
support, and the existing application supervisor. `app/control_plane_core`
owns the public domain and web source. Each `plugins/<name>` directory is a
local Mix project named `:ankole_<name>`. Private projects use the same name
rule under `internals/plugins`. The assembly includes these projects at build
time. They do not depend on the assembly application.

The six provider clients are internal modules of their matching Plugins. Their
module names and provider error types remain distinct. Plugin applications have
no application callback. Their caches, token supervisors, and connections start
as children of the active Plugin cohort, after Repo and AppConfigure are ready.
The core package does not start a Repo or a Plugin when used as a dependency.

All projects use the host's lockfile and downloaded dependencies. Each direct
Mix invocation has its own build directory. A host build compiles its selected
dependencies together. Run a provider client's unit tests from its Plugin
project; the test helper starts only that client's supervisor.

### Share an implementation only when its contract matches

`im_transport` owns shared JSON body primitives, request-body selection,
Retry-After parsing, download filename parsing, and WebSocket URL decomposition.
These functions retain their callers' existing error and empty-value behavior.
DingTalk and WeCom keep their empty-body mapping. Feishu keeps its URL error and
filename rules. Response envelopes, error classifications, token state machines,
and reconnect callbacks remain provider-owned.

`feishu_protocol` owns the Feishu WebSocket frame codec. Both the Lark Plugin
and `tools/fake-feishu` depend on it; the fake platform does not depend on the
control plane.

Reuse an existing domain owner for domain operations. Shared Markdown prose
transformations live in `Ankole.Plugins.MarkdownChunks`; normalized multi-send
results live in `Conversations.Delivery.Adapter`. Identity phone normalization,
Plugin fields, configuration helpers, and connection lifecycle contracts keep
their existing owners. A repeated call to one of these functions is not a
second implementation.

Before sharing a function, compare its input meaning, nil and empty handling,
error shape, units, side effects, and recovery ownership. Renderer-specific
checkpoint keys remain adapter-owned even when two current implementations are
identical. The Lark string-array validator keeps its different whitespace
behavior. Shared code must not grow provider-selection branches.

`mix ankole.compile_cycles` checks the assembly and every local Mix dependency.
CI runs it in test and production environments. A smaller assembly-only xref
graph is not evidence that the core or Plugin graphs have no compile cycle.

Fixed build composition is separate from `plugins.enabled_ids`. The selected
HTTP entry, Host policy, site authentication sources, AppConfigure declarations,
frontend entries, locales, and migration paths cannot disappear because an
operator disables a Plugin. These use their owning subsystem's concrete build
configuration; they are not new generic Plugin callbacks. AppConfigure reloads
the fixed declarations when its Registry recovers, then restores active Plugin
declarations as before.

See [Browser Sessions](BrowserSessions.md) for site sources and
[CONTRIBUTING](../../CONTRIBUTING.md#source-builds) for source, resource, and
migration commands. Private modules have distinct names. They call public domain
functions; they do not replace a compiled module or use Ruby-style method
injection.

### Enable a Control Plane Plugin

The global AppConfigure key `plugins.enabled_ids` lists active Plugins. A
missing or empty list enables none. An operator must enable each new Plugin.

The Plugin cohort reads the list during startup and resolves one immutable boot
snapshot. A later change takes effect only after a restart.

First-run setup is the only exception. While `setup.completed` is false, the
Registry activates every discovered Control Plane Plugin. This keeps all
bundled adapters, AppConfigure keys, and supervised processes available while
the operator moves between setup choices or restarts an incomplete setup. The
enable list remains the durable post-setup policy. The first restart after setup
completes applies that list. Completed installations continue to fail closed.

The Console API makes both states visible.

- `GET /api/v1/control-plane-plugins`
- `PUT /api/v1/control-plane-plugins`

The write body uses `{ "id": string, "enabled": boolean }`.

Each response row includes these fields:

- `configured_enabled`
- `active`
- `restart_required`

The Console can still list an inactive Plugin, and its old settings can remain
in PostgreSQL. It adds no definitions, adapters, or processes until activation.

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

Control Plane Plugins do not control Agent capabilities. A control-plane
adapter and a related Agent Plugin can have different enabled states.

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
`ExternalMessageRef`; work then enters the sole `Ankole.Signals.accept_in_tx/2`
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
and collects their results in binding order. Each adapter still parses its own
event and supplies its own subject namespace.

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
