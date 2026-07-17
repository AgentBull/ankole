# Plugins

Ankole has two unrelated extension boundaries. Their names are deliberately
different because they have different owners, lifecycles, and enablement
semantics:

- an **Agent Plugin** is a model capability package consumed by Agent Computer;
- a **Control Plane Plugin** is trusted Elixir/OTP code compiled into the
  control plane.

Sharing the word “Plugin” does not create a bridge between them.

## Agent Plugins

An Agent Plugin is Ankole's superset of a Codex Plugin. It uses the standard
`.codex-plugin/plugin.json` manifest and standard Codex package layout. Ankole
adds one optional directory, `workspace-template/`, for initializing a
BackgroundAgentJob's private project.

```text
app/library/agent-plugins/<agent-plugin-id>/
├── .codex-plugin/plugin.json
├── skills/
├── hooks/                 # optional Codex content
└── workspace-template/    # optional Ankole initialization content
```

The installation owns these trusted first-party packages. The control plane
validates each manifest, follows its declared `skills` directory, reads member
Skills, rejects symlinks and invalid package entries, enforces package bounds,
and computes a stable content hash. Agent Computer follows the same manifest
path and installs the complete package through Codex. The tree above shows the
current packages; `skills/` is not a second Ankole convention.

`workspace-template/` is a directory, not another declaration format. When a
Job first initializes its private project, Agent Computer copies every file in
each selected template into the project. Resume reuses that project. Conflicts
between selected templates fail initialization rather than depending on copy
order.

### Built-in packages

Ankole ships exactly these Agent Plugins:

| ID | Member Skills | Default |
|---|---|---|
| `lark` | `lark-im`, `lark-oa`, `lark-office-suite` | disabled |
| `office` | `docx`, `xlsx`, `pptx` | enabled |
| `deep-research` | `deep-research` | enabled |

Member Skills live only inside their Agent Plugin. Standalone Skills such as
`nano-pdf` and `design-md` remain in `app/library/skills/`.

### Enablement

Agent Plugin state and Skill state are separate. Global state provides the
default inherited by every Agent; an Agent stores only explicit overrides.

```text
Agent Plugin effective = agent override ?? global default
Plugin Skill effective = parent effective && (agent override ?? global default)
Standalone Skill effective = agent override ?? global default
Agent-installed Skill effective = agent override ?? source default
```

All Agent Plugin member Skills default to enabled. Disabling a parent gates its
members but does not rewrite their defaults or Agent overrides, so their prior
choices become effective again when the parent is re-enabled.

Global defaults are installation settings in AppConfigure:

- `ai_agent.library.agent_plugin_defaults` maps Agent Plugin IDs to booleans;
- `ai_agent.library.skill_defaults` maps stable Skill IDs to booleans.

A Plugin Skill ID is `<agent-plugin-id>:<skill-name>`. A standalone Skill keeps
its name as its ID. Agent Plugin overrides are sparse rows in
`agent_plugin_overrides`. Skill overrides use nullable
`agent_skills.enabled_override`; `null` means inheritance. Plugin member rows
use the ordinary `source_kind = "builtin"` and record `agent_plugin_id` only
for parent enablement and Console grouping. Skill discovery, file lookup,
overlays, MCP loading, and execution use the same ordinary Skill path for
members and standalone Skills.

The Agent Library always synchronizes every member Skill, including members of
a disabled parent. That preserves independent Skill choices and lets the
Console display the complete package.

### Job projection

At Job creation the control plane accepts only Agent Plugins that are
effectively enabled for the target Agent. The Job persists their IDs in
`agent_plugin_ids`; `skill_names` contains only selected standalone Skill
names. It does not persist package versions, hashes, or member-Skill state.

Before every execution or resume, Agent Computer resolves the saved IDs and
names against the current enabled catalogs. A selected Plugin or Skill that is
disabled or missing is unavailable and preparation fails. Otherwise Agent
Computer stages and installs the current complete package, discovers its member
Skills through `skills/list`, writes every member's current effective state
through `skills/config/write` using the absolute discovered path, and lists
again to verify the result. Only enabled member Skills contribute Skill-level
MCP configuration. Package-level hooks, resources, MCP configuration, and the
one-time `workspace-template/` initialization remain controlled by the parent
selection.

The RuntimeFabric catalog method is `agent_plugin.list`. The complete Job and
resume contract is defined in `BackgroundAgentJob.md`.

### Console and API

The Agent Library API exposes global defaults and per-Agent effective state:

- `GET /api/v1/agent-library/capabilities`;
- `PUT /api/v1/agent-library/agent-plugins/:id`;
- `PUT /api/v1/agent-library/skills/:id`;
- `GET /api/v1/agents/:agent_uid/library-capabilities`;
- `PUT /api/v1/agents/:agent_uid/library-capabilities/agent-plugins/:id`;
- `PUT /api/v1/agents/:agent_uid/library-capabilities/skills/:id`.

Global writes use `{ "enabled": boolean }`. Agent writes use
`{ "enabled": boolean | null }`; `null` restores inheritance. Capability rows
return `global_default_enabled`, `override_enabled`, and `effective_enabled`.
Agent Plugin rows embed their member Skills, while the top-level Skills list
contains only standalone and Agent-installed Skills.

The Console's Agent Library page has `Agent Plugins`, `Skills`, and
`Control Plane Plugins` tabs. Global defaults are the first scope; Agent scopes
use follow-global/on/off controls. Member Skills appear only in their parent
detail page. Control Plane Plugins appear only in the global scope.

## Control Plane Plugins

A Control Plane Plugin is a trusted, first-party Elixir/OTP package available
at process boot. It may contribute metadata, AppConfigure definitions, setup
metadata, subsystem adapters, and supervised children. It is not a marketplace
or an arbitrary-code loading boundary.

The implementation lives under `Ankole.Plugins.*`. Discovery reads local
source indexes from `plugins/` and optional `internals/plugins/`. Release images
may override those roots with the bootstrap-only `ANKOLE_PLUGIN_PATHS`
environment variable. The code is still compiled into the release; changing
the source paths requires a new process start.

Control Plane Plugin IDs are unique across discovery roots. A duplicate ID is a startup
configuration error. The Registry stores discovered specs and the active set;
it is not durable configuration storage.

### Activation

All discovered Control Plane Plugins are configured enabled unless their IDs
appear in the global AppConfigure key `plugins.disabled_ids`.

Activation is boot-time state. Editing `plugins.disabled_ids` changes the next
start configuration and does not hot-start or hot-stop OTP code. The API makes
the difference explicit:

- `GET /api/v1/control-plane-plugins`;
- `PUT /api/v1/control-plane-plugins` with `{ "id": string, "enabled": boolean }`.

Each row returns `configured_enabled`, `active`, and `restart_required`. The
Console displays both states and asks for a restart whenever they differ.

A disabled package remains discoverable, and its existing AppConfigure rows
may remain in PostgreSQL. It contributes no active definitions, adapters, or
supervised children until the next process starts with it enabled.

### Runtime boundary

Control Plane Plugin settings use the same `Ankole.AppConfigure` registry,
validation, global scope, and encryption as core settings. There is no separate
Control Plane Plugin configuration database or secret store. Discovery itself cannot
depend on AppConfigure because discovery precedes runtime configuration.

The control plane owns persistence, authorization, setup writes, supervision,
and durable domain commits. A Control Plane Plugin implements only the callback contracts of
the subsystem consuming it. Concrete adapter contracts belong in that
subsystem's design document.

Control Plane Plugins do not own Agent-level enablement. A Lark adapter can be
active while the `lark` Agent Plugin is disabled for every Agent, or vice versa.
The former controls whether the control plane integration is running; the
latter controls whether a model may use Lark Skills in a Job.

## Invariants

- “Agent Plugin” and “Control Plane Plugin” are never interchangeable names.
- Agent Plugins are trusted first-party Codex packages plus optional
  `workspace-template/` content.
- Parent and member Skill state are stored independently; parent state only
  gates effective availability.
- BackgroundAgentJobs store capability selections and resolve the current
  enabled catalogs on every prepare.
- Control Plane Plugin activation changes require restart and never masquerade
  as immediate runtime changes.
- Neither plugin kind may claim durable state owned by another subsystem.
