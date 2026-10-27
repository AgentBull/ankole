---
title: Develop Skills and Control Plane Plugins
description: Add a work method for Agents, or add site-scoped adapters, configuration, domain hooks, supervised services, and UI slots to the control plane.
section: Developer guide
order: 113
---

Skills and Control Plane Plugins extend Ankole at two very different boundaries—pick the mechanism that matches what you are building before writing code:

| Requirement | Use |
|---|---|
| Teach an Agent a repeatable workflow or operating procedure | Skill |
| Wrap an MCP server with domain selection and usage rules | Skill |
| Add a new Identity Provider, chat adapter, LLM Provider, or Worker provider kind | Control Plane Plugin |
| Add site-scoped settings, supervised OTP services, hooks inside domain transactions, `/api/v2` extension routes, or Web UI Slots | Control Plane Plugin |
| Toggle runtime behavior dynamically without restarting the control plane | OpenFeature (`Ankole.Features`) |

A Skill is a directory of Markdown and helper files read by an Agent at runtime, requiring no control-plane rebuild. By contrast, a Control Plane Plugin is a site-scoped, first-party Elixir extension compiled into the release (never scoped to an individual tenant or Agent): `:optional` Plugins activate on the next control-plane start after a `siteadmin` enables them, while `:always` Plugins stay permanently active with the build.

## Write a Skill

Every Skill is a directory containing `SKILL.md`, alongside optional reference docs, templates, and `agents/openai.yaml`:

```text
my-skill/
├── SKILL.md
├── agents/
│   └── openai.yaml
├── reference.md
└── templates/
```

Name the directory using lowercase letters, digits, hyphens, or underscores. Shipped first-party Skills live under `app/library/skills/`, while per-Agent installed Skills live in that Agent's drive space.

### Write the frontmatter

YAML frontmatter at the top of `SKILL.md` governs discovery, defaults, and execution surface:

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

Write a concrete trigger condition in `description`, because the Agent scans descriptions in its catalog to decide when to load the full Skill. Set `ankole-runtime: background_job` whenever the workflow requires an isolated Background Agent Job workspace, and add `platforms: [linux]` only if the Skill invokes Linux-only binaries.

### Make a shipped Skill discoverable through Brain

Set `brain-recall-only: true` on specialized SOPs or playbooks that would clutter every system prompt if listed globally, yet should surface automatically when a task matches their topic:

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

Ankole supports `brain-recall-only` on shipped standalone Skills and Skills bundled inside Agent Plugins (not on Agent-installed Skills). Every shipped Skill `name` stays globally unique—Agent Plugin membership adds no namespace prefix—and Brain derives the synthetic discovery entry `lazyload-agent-skills/<name>` directly from the Skill's standard frontmatter.

Do not add Brain Object frontmatter keys such as `slug`, `type`, `title`, or `aliases`: Brain indexes only `name`, `description`, and `tags` (using `name` and `tags` for natural-language lookup), while keeping the `SKILL.md` body, companion files, and per-Agent lessons out of Brain storage so they load exclusively through `skill_view` after discovery.

### Write the body

Write `SKILL.md` for a capable Agent that has no prior context about your team's local conventions, spelling out:

1. when to trigger the Skill;
2. which inputs and files to inspect first;
3. the exact sequence of steps;
4. the required output format and verification checks; and
5. actions that are forbidden or require explicit human approval.

Link every companion reference file or template explicitly from `SKILL.md`—because the Agent reads companion files lazily on demand, any file left unmentioned in `SKILL.md` will go unused.

### Declare MCP dependencies

Declare MCP server connections inside `agents/openai.yaml`:

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-mcp-server
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MY_MCP_TOKEN
```

Agent Computer injects this dependency only while the Skill is enabled. In `SKILL.md`, list the relevant domain tools and selection rules, instruct the Agent to inspect only the chosen tool's schema via `mcporter list server.tool --schema --json`, and pass JSON arguments over `stdin`. See [MCP reference](../mcp/) for the full `openai.yaml` schema.

### Verify the Skill

Enable the Skill on a test Agent and run a realistic prompt end to end, verifying that the Agent picks the Skill, reads any linked reference files, and satisfies every completion check. If the Agent skips the Skill, sharpen `description`; if steps drift out of order, tighten the numbered procedure and constraints.

When testing a `brain-recall-only` Skill, confirm that it is omitted from the default system prompt catalog yet discoverable via Brain search across its `name`, `description`, and `tags`. Verify that `skill_view` loads the full Skill on a compatible runtime surface and applies the expected routing or rejection behavior on an incompatible surface, then disable the Skill (or its parent Agent Plugin) and confirm that the Agent can neither recall nor load it.

## Develop a Control Plane Plugin

Build a Control Plane Plugin whenever you need site-scoped capabilities inside the Elixir control plane. Every plugin module implements `Ankole.Plugins.Plugin`; at minimum, it defines a stable lowercase slug ID:

```elixir
defmodule Ankole.Plugins.MyPlugin do
  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "my-plugin"
end
```

Implement optional callbacks only for the extension points that your Plugin uses:

| Callback | Purpose |
|---|---|
| `activation/0` | `:optional` (default, toggled via `plugins.enabled_ids` for the next boot) or `:always` (compiled active with no Console toggle) |
| `display_name/0`, `description/0` | Localized title and summary displayed in the Site Admin Console |
| `adapter_declarations/0` | Register IdP, chat, LLM Provider, Worker provider (`agent_workers.provider_kind`), or webhook handler adapters |
| `hooks/0` | Register synchronous hooks inside domain transactions (`[{hook_point, module}]` implementing `Ankole.Plugins.Hook`) |
| `app_config_definitions/0` | Register static AppConfigure keys |
| `app_config_patterns/0` | Register parameterized AppConfigure key patterns |
| `children/0` | Supervise long-lived connections, registries, or reconcilers under the Plugin supervisor |

Full-stack build extensions can additionally wrap the Phoenix router with an outer HTTP Plug, mount typed `/api/v2/*` JSON:API routes, and bind typed Web UI Slots (`PodAppSlots`, `ConsoleAppSlots`, `AuthAppSlots`) via `overrides` in `entries.json`.

### Register the Plugin

List your module under `:control_plane_plugin_modules` in `config/config.exs`:

```elixir
config :ankole, :control_plane_plugin_modules, [
  Ankole.Plugins.MyPlugin
]
```

Once registered, the Plugin appears in the site-scoped catalog inside the **Site Admin Console** (`/site-admin-console` with scope set to **Global defaults**, backed by `GET` / `PUT /api/v2/site/control-plane-plugins`). After a `siteadmin` enables an `:optional` Plugin, the next control-plane boot freezes it into the `:persistent_term` snapshot and activates its AppConfigure fields, adapters, transaction hooks, and supervised processes (`veto_disable` blocks disabling a Plugin that provides Worker providers while any tenant references one of its Worker kinds). `:always` Plugins activate unconditionally on every boot. Because Control Plane Plugins never hot-load at runtime, use OpenFeature (`Ankole.Features`) for policies that must toggle dynamically without a restart.

### Declare an adapter

Return adapter maps from `adapter_declarations/0`, using `contract_id` to target the owning subsystem:

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

Each subsystem defines the extra fields required on its adapter map: chat adapters implement the [Signals](../signals/) contract, while Identity Providers, LLM Providers, and Worker providers plug into their respective subsystem registries—never invent a parallel config store inside your Plugin.

### Declare settings, hooks, and services

Expose operator-tunable runtime settings through `app_config_definitions/0` or `app_config_patterns/0`, reserving OS environment variables strictly for bootstrap secrets needed before PostgreSQL is reachable.

Use `hooks/0` to run synchronous admission or quota checks inside domain transactions (`:create_agent`, `:create_invitation`, `:enable_signal_binding`, `:enable_identity_provider`, `:store_file`, `:commit_files`, `:create_pod_page`, `:restore_pod_page`, `:insert_base_records`, `:admit_compute`). Each hook module implements `Ankole.Plugins.Hook.before_commit_in_tx/2`, returning `:ok` or `{:error, reason}` inside the caller's database transaction.

Return standard OTP child specs from `children/0` to place long-lived sockets and reconcilers under the Plugin supervisor; Ankole starts them when the Plugin activates at boot and stops launching them on the next restart after disablement.

### Verify the Plugin

Run the control-plane test suite and static analyzers. For an `:optional` Plugin, enable it in the **Site Admin Console** (`/site-admin-console`) and restart the control plane (`:always` Plugins start automatically on boot). Confirm that the Plugin reports **Active now**, its AppConfigure fields render cleanly, its transaction hooks enforce their invariants, and every declared adapter completes a live end-to-end check (including protocol integration tests for external services).

## Continue

- See [Agent Library](../skills/) for Skill enablement, inheritance, and installation.
- See [Control Plane Plugins](../control-plane-plugins/) for discovery and activation.
- See [Add a Provider](../adding-a-provider/) for a new LLM Provider.
