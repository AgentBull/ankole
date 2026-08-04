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

| ID | Member Skills | Global default |
| --- | --- | --- |
| `lark` | `lark-im`, `lark-oa`, `lark-office-suite` | Disabled |
| `office` | `docx`, `xlsx`, `pptx` | Enabled |
| `deep-research` | `create-deep-research` | Enabled |
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

The public `github` package owns GitHub repository webhook setup,
reconciliation, redelivery, and removal in its `github-webhooks` Skill.
SignalsGateway supplies only the callback capability. It does not contain a
GitHub adapter or store a copy of GitHub hook state.

### Decide Which Capabilities an Agent Can Use

An Agent Plugin and each Skill have separate enabled states. Instance
settings provide defaults. An Agent stores only values that override them.

```text
Agent Plugin effective = agent override ?? global default
Plugin Skill effective = parent effective && (agent override ?? global default)
Standalone Skill effective = agent override ?? global default
Agent-installed Skill effective = agent override ?? source default
```

Every member Skill starts enabled. Disabling the parent Plugin makes all members
unavailable without changing their saved settings. Those settings apply again
when the parent becomes enabled.

AppConfigure stores the instance defaults in these global keys:

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
2. Atomically rebuild a stable Job package view that contains only those
   members and their current database-backed overlays.
3. Pass the Job package roots through
   `thread/start.selectedCapabilityRoots` with environment ID `local`.

`thread/resume` restores the selected roots stored in the existing Codex
thread; that method does not accept a new root list. The Job rebuilds the same
view path before resume, so current disables still remove members from the
stored root. Codex 0.146 does not apply `skills.config` to Plugin members, so
Ankole does not use that setting as a member-selection guarantee. Standalone
Skills use project discovery under `.agents/skills`. Plugin member Skills stay
inside the native Plugin package and are not projected as standalone project
Skills.

Only enabled members that permit Background Agent Jobs add MCP settings. The
optional workspace template is copied once and does not change runtime Plugin
selection.

RuntimeFabric exposes the catalog through `agent_plugin.list`.
See [Background Agent Job](BackgroundAgentJob.md) for the complete Job contract.

### Change Capability Settings through the Console

The Console API exposes global defaults and Agent-specific effective state.

- `GET /api/v1/agent-library/capabilities`
- `PUT /api/v1/agent-library/agent-plugins/:id`
- `PUT /api/v1/agent-library/skills/:id`
- `GET /api/v1/agents/:agent_uid/library-capabilities`
- `PUT /api/v1/agents/:agent_uid/library-capabilities/agent-plugins/:id`
- `PUT /api/v1/agents/:agent_uid/library-capabilities/skills/:id`

Global writes use `{ "enabled": boolean }`.
Agent writes use `{ "enabled": boolean | null }`.
A null value restores inheritance.

Capability rows include these state fields:

- `global_default_enabled`
- `override_enabled`
- `effective_enabled`

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
The compile-time `:control_plane_plugin_modules` list names every Plugin module.
Each release compiles that complete list. Startup does not read or parse plugin
source files.

Plugin IDs must be unique across the declared modules.
Duplicate IDs stop application startup.
The Registry keeps the active list in memory for the current process.

### Enable a Control Plane Plugin

The global AppConfigure key `plugins.enabled_ids` lists active Plugins. A
missing or empty list enables none. An operator must enable each new Plugin.

The Registry reads the list during startup. A later change takes effect only
after a restart.

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

## Rules

- Never use `Agent Plugin` and `Control Plane Plugin` as interchangeable names.
- Treat Agent Plugins as trusted Codex packages with optional Job Workspace content.
- Store parent state and member Skill state independently.
- Let `AgentCodexRuntime` install and trust same-release Agent Plugins before the
  first Job thread, then keep the global entries disabled.
- Let each Job select only its projected Plugin roots at `thread/start`.
- Use `workspace_template_id` only to copy one initial Job Workspace template.
- Keep every compiled Control Plane Plugin active until first-run setup
  completes.
- Require a restart after setup for Control Plane Plugin activation changes.
- Keep new Control Plane Plugins inactive on completed installations until an
  operator enables them.
- Keep durable state with its owning subsystem.
