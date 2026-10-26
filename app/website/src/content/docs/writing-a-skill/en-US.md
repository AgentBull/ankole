---
title: Develop Skills and Control Plane Plugins
description: Add a work method for Agents, or add site-scoped adapters, configuration, domain hooks, supervised services, and UI slots to the control plane.
section: Developer guide
order: 113
---

Skills and Control Plane Plugins both extend Ankole, but they solve different problems. Select the correct extension point before you write code.

| Requirement | Use |
|---|---|
| Teach an Agent how to perform a type of work | Skill |
| Give an Agent an MCP-backed workflow and usage instructions | Skill |
| Add an IdP, chat adapter, LLM Provider, or Worker provider kind | Control Plane Plugin |
| Add site-scoped settings, supervised services, domain transaction hooks, extension `/api/v2` routes, or Web UI Slots | Control Plane Plugin |
| Switch consumer behavior dynamically at runtime without a restart | OpenFeature (`Ankole.Features`) |

A Skill is a set of files that an Agent reads. It does not require a new control-plane build. A Control Plane Plugin is a site-scoped, first-party full-stack extension compiled into the release (never tenant-scoped or Agent-scoped). An `:optional` Plugin activates on the next control-plane start after a `siteadmin` enables it, while an `:always` Plugin is fixed active with the source build.

## Write a Skill

A Skill is a directory with `SKILL.md`. It can also contain references, templates, and `agents/openai.yaml`:

```text
my-skill/
├── SKILL.md
├── agents/
│   └── openai.yaml
├── reference.md
└── templates/
```

Use lowercase letters, numbers, hyphens, or underscores in the directory name. Built-in Skills live in `app/library/skills/`. An installed Skill lives in the file space for its Agent.

### Write the frontmatter

The YAML at the top of `SKILL.md` controls discovery and enablement:

```yaml
---
name: my-skill
description: "Use when the Agent must review a vendor contract."
default_enabled: true
category: productivity
tags: [Contracts]
ankole-runtime: background_job
platforms: [linux]
---
```

The `description` must state a specific trigger because the Agent uses it to decide whether to read the Skill. Set `ankole-runtime: background_job` when the work needs Job isolation. Set `platforms: [linux]` only when the Skill needs Linux tools.

### Make a shipped Skill discoverable through Brain

Use `brain-recall-only` for an SOP or method that should not appear in every prompt but should be found when the current work is semantically related:

```yaml
---
name: idea-lineage
description: Trace how one idea evolved through memory — first mention, best articulation, reversals, and the current live version, each cited from stored evidence.
tags:
  - idea lineage
  - how my thinking evolved
brain-recall-only: true
---
```

This field is supported only for shipped standalone Skills and Skills in an Agent Plugin. Agent-installed Skills do not use this discovery mode. A shipped Skill name remains globally unique; Agent Plugin membership does not add a namespace. Brain derives the discovery record as `lazyload-agent-skills/<name>` from the standard Skill metadata.

Do not add Object fields such as `slug`, `type`, `title`, or `aliases` to the Skill. Brain searches `name`, `description`, and `tags`, and uses the name and tags for natural-language resolution. The Skill body, all other Skill files, and Agent-specific lessons do not enter Brain. They remain available only through `skill_view` after discovery.

### Write the body

Write for a capable Agent that does not know your local rules. State:

1. when to use the Skill;
2. which inputs to read;
3. the order of work;
4. the required result;
5. actions that are forbidden or need approval.

Link each reference and template by name from `SKILL.md`. The Agent reads these files only when needed, so it cannot use a file that the main instructions do not identify.

### Declare MCP dependencies

Declare an MCP execution dependency in `agents/openai.yaml`:

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-mcp-server
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MY_MCP_TOKEN
```

The dependency is available only while the Skill is enabled. In `SKILL.md`, name the domain tools and selection rules, tell the Agent to inspect only the selected tool with `mcporter list server.tool --schema --json`, and call it with JSON on stdin. See [MCP reference](../mcp/) for the complete contract.

### Verify the Skill

Enable the Skill on a test Agent and give it a real task. Confirm that the Agent selects the Skill, reads the required files, and follows the completion criteria. If selection fails, improve `description`. If execution is unstable, make the order and constraints explicit.

For a `brain-recall-only` Skill, also confirm that the normal Prompt does not list it and Brain can find it by its name, description, and tags. Confirm that `skill_view` loads the full Skill on a compatible execution surface and preserves the existing routing or rejection behavior on an incompatible surface. Then disable the Skill or its parent Agent Plugin and confirm that the same Agent can neither discover nor load it.

## Develop a Control Plane Plugin

Use a Control Plane Plugin for site-scoped capabilities owned by the control plane. The module implements `Ankole.Plugins.Plugin`. The smallest valid Plugin has one stable ID:

```elixir
defmodule Ankole.Plugins.MyPlugin do
  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "my-plugin"
end
```

Use a lowercase slug for the Plugin ID. Implement optional callbacks only when needed:

| Callback | Purpose |
|---|---|
| `activation/0` | `:optional` (default, selected via `plugins.enabled_ids` for next start) or `:always` (fixed active with the build; no Console toggle) |
| `display_name/0`, `description/0` | Localized name and description shown in the Site Admin Console |
| `adapter_declarations/0` | Declare IdP, chat, LLM Provider, Worker provider (`agent_workers.provider_kind`), or webhook adapters |
| `hooks/0` | Declare synchronous domain transaction hooks (`[{hook_point, module}]` implementing `Ankole.Plugins.Hook`) |
| `app_config_definitions/0` | Declare fixed AppConfigure settings |
| `app_config_patterns/0` | Declare settings with dynamic IDs |
| `children/0` | Start connections, registries, or reconcilers under the Plugin supervisor |

A full-stack build extension can also wrap the core router with an outer request Plug, mount typed `/api/v2/*` JSON:API routes, and bind typed Web UI Slots (`PodAppSlots`, `ConsoleAppSlots`, `AuthAppSlots`) through `entries.json` `overrides`.

### Register the Plugin

Add the module to `config/config.exs`:

```elixir
config :ankole, :control_plane_plugin_modules, [
  Ankole.Plugins.MyPlugin
]
```

The Plugin then appears in the site-scoped catalog in the **Site Admin Console** (`/site-admin-console` under **Global defaults** scope, `GET` / `PUT /api/v2/site/control-plane-plugins`). When a `siteadmin` enables an `:optional` Plugin, the next control-plane start resolves it into the immutable `:persistent_term` boot snapshot and registers its settings, adapters, hooks, and supervised processes (`veto_disable` blocks disabling a Worker-provider Plugin while any tenant references its Worker kind). An `:always` Plugin is active whenever compiled into the release. Plugins do not support hot loading; use OpenFeature (`Ankole.Features`) for policies that must switch dynamically without a restart.

### Declare an adapter

`adapter_declarations/0` returns adapter declarations. The `contract_id` selects the subsystem that reads each declaration:

```elixir
@impl true
def adapter_declarations do
  [
    %{
      contract_id: "signals.adapter",
      id: "my-adapter",
      plugin_id: plugin_id()
    }
  ]
end
```

The owning subsystem defines the adapter-specific fields. A chat adapter follows the [Signals](../signals/) contract. IdPs, LLM Providers, and Worker providers use their existing registries. Do not create a parallel configuration path inside the Plugin.

### Declare settings, hooks, and services

Use `app_config_definitions/0` or `app_config_patterns/0` for settings that operators manage at runtime. Use environment variables only for startup facts that must exist before the database is available.

Use `hooks/0` to attach synchronous admission or quota checks to domain transactions (`:create_agent`, `:create_invitation`, `:enable_signal_binding`, `:enable_identity_provider`, `:store_file`, `:commit_files`, `:create_pod_page`, `:restore_pod_page`, `:insert_base_records`, `:admit_compute`). Each hook module implements `Ankole.Plugins.Hook.before_commit_in_tx/2` and returns `:ok` or `{:error, reason}` inside the caller's transaction.

`children/0` returns standard OTP child specifications. Put connections and reconcilers under the Plugin supervisor. They start when the Plugin activates and stop after disablement at the next control-plane start.

### Verify the Plugin

Run the control-plane tests and static checks. For an `:optional` Plugin, enable it in the **Site Admin Console** (`/site-admin-console`) and restart the control plane; an `:always` Plugin activates directly on start. Confirm that it is active, its settings are visible, its hooks enforce their contract, and each declared adapter completes a real connection. Run the related integration test when the Plugin implements an external protocol.

## Continue

- See [Agent Library](../skills/) for Skill enablement, inheritance, and installation.
- See [Control Plane Plugins](../control-plane-plugins/) for discovery and activation.
- See [Add a Provider](../adding-a-provider/) for a new LLM Provider.
