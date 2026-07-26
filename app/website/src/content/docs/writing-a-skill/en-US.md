---
title: Develop Skills and Control Plane Plugins
description: Add a work method for Agents, or add identity, channel, configuration, and supervised services to the control plane.
section: Developer guide
order: 113
---

Skills and Control Plane Plugins both extend Ankole, but they solve different problems. Select the correct extension point before you write code.

| Requirement | Use |
|---|---|
| Teach an Agent how to perform a type of work | Skill |
| Give an Agent MCP tools and usage instructions | Skill |
| Add an IdP, chat adapter, or Provider kind | Control Plane Plugin |
| Add control-plane settings or a supervised service | Control Plane Plugin |

A Skill is a set of files that an Agent reads. It does not require a new control-plane build. A Control Plane Plugin is a first-party Elixir module compiled into the control plane. It needs registration and activates at the next control-plane start.

## Write a Skill

A Skill is a directory with `SKILL.md`. It can also contain references, templates, and `openai.yaml`:

```text
my-skill/
├── SKILL.md
├── openai.yaml
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

### Write the body

Write for a capable Agent that does not know your local rules. State:

1. when to use the Skill;
2. which inputs to read;
3. the order of work;
4. the required result;
5. actions that are forbidden or need approval.

Link each reference and template by name from `SKILL.md`. The Agent reads these files only when needed, so it cannot use a file that the main instructions do not identify.

### Declare MCP dependencies

Declare an MCP tool in `openai.yaml`:

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-mcp-server
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MY_MCP_TOKEN
```

The Agent sees this tool only while the Skill is enabled. See [MCP reference](../mcp/) for all fields.

### Verify the Skill

Enable the Skill on a test Agent and give it a real task. Confirm that the Agent selects the Skill, reads the required files, and follows the completion criteria. If selection fails, improve `description`. If execution is unstable, make the order and constraints explicit.

## Develop a Control Plane Plugin

Use a Control Plane Plugin for capabilities owned by the control plane. The module implements `Ankole.Plugins.Plugin`. The smallest valid Plugin has one stable ID:

```elixir
defmodule Ankole.Plugins.MyPlugin do
  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "my-plugin"
end
```

Use a lowercase slug for the Plugin ID. Implement other callbacks only when needed:

| Callback | Purpose |
|---|---|
| `display_name/0`, `description/0` | Name and description shown in the Console |
| `adapter_declarations/0` | Declare IdP, chat, or other adapters |
| `app_config_definitions/0` | Declare fixed AppConfigure settings |
| `app_config_patterns/0` | Declare settings with dynamic IDs |
| `children/0` | Start connections, registries, or reconcilers |

### Register the Plugin

Add the module to `config/config.exs`:

```elixir
config :ankole, :control_plane_plugin_modules, [
  Ankole.Plugins.MyPlugin
]
```

The Plugin then appears in the Console catalog. After an administrator enables it, the next control-plane start registers its settings, adapters, and supervised processes. Plugins do not support hot loading.

### Declare an adapter

`adapter_declarations/0` returns adapter declarations. The `contract_id` selects the subsystem that reads each declaration:

```elixir
@impl true
def adapter_declarations do
  [
    %{
      contract_id: "signals_gateway.adapter",
      id: "my-adapter",
      plugin_id: plugin_id()
    }
  ]
end
```

The owning subsystem defines the adapter-specific fields. A chat adapter follows the [SignalsGateway](../signals-gateway/) contract. IdPs and model Providers use their existing registries. Do not create a parallel configuration path inside the Plugin.

### Declare settings and services

Use `app_config_definitions/0` or `app_config_patterns/0` for settings that operators manage at runtime. Use environment variables only for startup facts that must exist before the database is available.

`children/0` returns standard OTP child specifications. Put connections and reconcilers under the Plugin supervisor. They start when the Plugin activates and stop after disablement at the next control-plane start.

### Verify the Plugin

Run the control-plane tests and static checks. Enable the Plugin in the Console and restart the control plane. Confirm that it is active, its settings are visible, and each declared adapter completes a real connection. Run the related integration test when the Plugin implements an external protocol.

## Continue

- See [Agent Library](../skills/) for Skill enablement, inheritance, and installation.
- See [Control Plane Plugins](../control-plane-plugins/) for discovery and activation.
- See [Add a Provider](../adding-a-provider/) for a new LLM Provider.
