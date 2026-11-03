---
title: Agent Library
description: Manage tenant and per-Agent Agent Plugins and Skills, and site-scoped Control Plane Plugins.
section: User guide
order: 32
---

Members manage complete Skill packages in **Meta Ankole → Skills**. The **Agent Library** in the Console also provides capability controls, while site administrators manage Control Plane Plugins in the Site Admin Console. Built-in and Agent Plugin packages ship with Ankole; members with the appropriate permission can create or import custom Skills.

## Understand the three capability types

| Type | Scope | Purpose | When a change applies |
|---|---|---|---|
| **Agent Plugin** | Tenant default + per-Agent override | Bundles related Skills, MCP server dependencies, and workspace templates | The Agent's next turn |
| **Skill** | All Agents enabled, or explicit Agent bindings | Reusable instructions and helper files for one repeatable workflow | The Agent's next turn |
| **Control Plane Plugin** | Site-scoped only (`/api/v2/site/control-plane-plugins`) | Full-stack compile-time platform extension (adapters, OTP services, HTTP plugs, extension routes, domain hooks, config fields, and Web UI slots) | Always active with the build (`activation: :always`), or on the next control-plane start (`activation: :optional`) |

### Agent Plugin: capabilities that share one package

An Ankole Agent Plugin extends the <a href="https://developers.openai.com/plugins" target="_blank" rel="noreferrer">OpenAI Plugin</a> layout: like an OpenAI Plugin, it bundles one or more Skills, MCP dependencies, and optional UI assets into a single package, while adding an Ankole **workspace template** so a task receives working methods, tools, and its initial directory layout together.

Enabling an Agent Plugin in the Console makes its package available to the Agent, while still allowing you to enable or disable individual member Skills inside it.

#### Workspace templates prepare complex tasks

An Agent Plugin's `workspace-template/` directory seeds new Background Agent Job workspaces—populating `AGENTS.md`, subdirectories, research playbooks, validation scripts, and starter files inside a durable workspace that the Job can update and recover across restarts.

Ankole's [Deep Research](../deep-research-job/) workflow illustrates how these pieces fit together: the Main Agent clarifies the research brief in chat and launches a Background Agent Job seeded from the `deep-research` workspace template, giving the Job structured evidence directories, synthesis playbooks, and verification scripts in one self-contained workspace.

Enabling an Agent Plugin that includes a workspace template does not alter active conversations or spawn Jobs automatically; Ankole copies the template only when an Agent creates a Background Agent Job that selects it.

### Skill: one repeatable working method

Ankole Skills follow the <a href="https://agentskills.io/specification" target="_blank" rel="noreferrer">official Agent Skills specification</a>: each Skill directory contains a `SKILL.md` file with YAML frontmatter alongside optional `scripts/`, `references/`, and `assets/` subdirectories.

To keep prompts compact, the Agent initially sees only each Skill's name and short description, loading the full `SKILL.md` body and supporting files only when the current task matches. When a Skill needs live external data or authenticated actions, its instructions direct the Agent to pick a declared MCP tool and invoke it via `mcporter`—keeping MCP tools behind the Skill rather than exposing a second model-level tool catalog.

#### Ankole extension: select the Skill execution surface

Ankole extends standard Skill frontmatter with `ankole-runtime`:

```yaml
---
name: my-skill
description: Use for tasks that meet these conditions.
ankole-runtime: any
---
```

| Value | Where the Skill is available | Use it when |
|---|---|---|
| `any` | Main Agent and Background Agent Jobs | Either execution surface can complete the workflow safely (default when omitted) |
| `main` | Main Agent conversations only | The Skill clarifies requirements with the user or creates and manages a Background Agent Job |
| `background_job` | Background Agent Jobs only | The workflow is long-running, relies on a Job workspace, or drives browsers, files, or data pipelines inside a Job |

`ankole-runtime` controls which execution surface can see and load the Skill—it does not automatically launch a Background Agent Job. For example, the Deep Research entry Skill sets `ankole-runtime: main` so the Main Agent confirms the scope in chat and creates the Job, while the underlying research Skills run inside the Background Agent Job itself.

#### Shared Skill packages

Each Skill has a required `SKILL.md` and companion files, managed in [Meta Ankole](../agent-library/). An enabled Agent reads the complete package at `/drive/Skills/<slug>/`. `skill_view` loads the manifest; reference files are read explicitly by relative path. Skill instructions are separate from Brain knowledge.

### Control Plane Plugin: site-scoped full-stack platform extension

Unlike Agent Plugins, a Control Plane Plugin never enters an Agent's prompt context and is never scoped to an individual tenant or Agent. Instead, it is a compile-time, site-wide Elixir extension compiled into the release and frozen into an immutable `:persistent_term` snapshot at boot.

A Control Plane Plugin can extend every layer of the control plane:

- Subsystem adapters (`signals.adapter`, `principals.identity_provider`, `ai_gateway.provider`, `agent_workers.provider`) and supervised OTP processes (`children/0`)
- Outer HTTP edge plugs and scoped JSON:API extension routes
- Synchronous hooks inside domain transactions (`hooks/0` via `Ankole.Plugins.Hook`)
- Declarative `AppConfigure` schemas (`ConfigFields`) and typed Web UI Slots (`entries.json` `overrides`)

Each Control Plane Plugin declares `activation: :optional | :always`. Optional plugins (`:optional`, the default) are toggled via `plugins.enabled_ids` and take effect on the next control-plane restart, whereas platform plugins declaring `activation: :always` stay permanently active with the build. For runtime switches or progressive rollouts that apply without a restart, Ankole uses OpenFeature (`Ankole.Features`).

## Manage Agent Plugins and Skills

### Enable Skills

Open **Meta Ankole → Skills** and choose a Skill. An administrator can enable it for all Agents or bind individual AI colleagues. Each member can bind their own assistant. When the all-Agents switch is on, individual switches show enabled and are locked. Turning it off restores the saved individual bindings. Custom Skills start disabled.

A Skill bundled in an Agent Plugin also requires that Plugin to be enabled for the Agent. Changes apply on the next turn; an existing Background Agent Job remains limited to its initial capability whitelist.

### Configure Agent Plugins

In the Console’s **Agent Library**, choose **Global defaults** to set a Plugin default, or select an Agent and choose **Follow global**, **Enabled**, or **Disabled**. Disabling a Plugin makes its member Skills unavailable while preserving their bindings.

### Review Skill lessons

Alongside the shared `SKILL.md` instructions, an Agent can receive dated, per-Agent process cautions: Dreaming proposes leased cautions from Background Agent Job evidence, and operators can add permanent human cautions without modifying `SKILL.md`.

Switch the **Agent Library** scope to a specific Agent and open a Skill card to inspect active and retired lessons, supporting evidence Jobs, review timestamps, and retirement reasons, or to add and retire lessons (retired lessons stop appearing on the Agent's next turn).

Whenever a rule applies to every Agent rather than one Agent's environment, edit the shared `SKILL.md` source instead of duplicating human lessons across Agents. See [Skill lessons](../skill-lessons/) for evidence thresholds, lease reviews, and configuration.

## Manage Control Plane Plugins

### Enable or disable optional site plugins

Because Control Plane Plugins are strictly site-scoped (`/api/v2/site/control-plane-plugins`), they appear only in the Site Admin Console (`/site-admin-console`) when **Agent Library** is set to **Global defaults**:

1. In the Site Admin Console, open **Agent Library**, keep the scope on **Global defaults**, and select the **Control Plane Plugins** tab.
2. Locate an optional Plugin (`activation: :optional`) and switch it to **Enabled next start** (plugins with `activation: :always` are permanently active and show no toggle).
3. Save your changes and restart the control plane.
4. Return to **Control Plane Plugins** and verify that the Plugin now shows **Active now**.
5. Configure any Channel Provider, Identity Provider, Worker provider, or AppConfigure setting contributed by the Plugin.

Docker Compose:

```bash
docker compose restart control-plane
```

Kubernetes:

```bash
kubectl -n ankole rollout restart deployment/ankole-control-plane
```

Disabling an optional Control Plane Plugin likewise takes effect on the next control-plane restart. Subsystem contracts enforce `veto_disable` inside the configuration transaction: Ankole refuses to disable a Plugin that supplies Worker providers while any tenant still has an assigned Worker (including paused Workers or Agents pending deletion) using one of its provider kinds. Before disabling a Plugin, confirm that no active Channel Provider, Identity Provider, or Worker depends on it. Runtime feature flags that toggle without a restart belong in OpenFeature (`Ankole.Features`) rather than plugin activation settings.

## Troubleshoot

### Agent Plugins and Skills

- **A capability does not appear:** Check the installed package and the selected scope. Create or import custom Skills through Meta Ankole; official packages must be included in the deployment.
- **A Skill is enabled, but the Agent cannot use it:** Check whether its parent Agent Plugin is disabled, and start a fresh turn after making changes.
- **A Skill is visible only in certain runs:** Check its `ankole-runtime` field—`main` Skills are hidden inside Background Agent Jobs, and `background_job` Skills are hidden in main-Agent chat turns.
- **An Agent ignores a Plugin default change:** Check its explicit Plugin override. Skill enablement uses the all-Agents switch and individual bindings.
- **A Background Agent Job cannot use a workspace template:** Confirm that the owning Agent Plugin is enabled for that Agent and includes a `workspace-template/` directory.

### Control Plane Plugins

- **The Control Plane Plugins tab is missing:** Control Plane Plugins are site-scoped only; open the Site Admin Console (`/site-admin-console`) and set the **Agent Library** scope to **Global defaults**.
- **A Plugin stays in `Enabled next start`:** Ankole saved the change in `plugins.enabled_ids`, and you must restart the control plane to rebuild its boot snapshot.
- **A Plugin cannot be disabled:** Either the Plugin declares `activation: :always`, or Ankole rejected the change via `veto_disable` because a tenant still has an Agent Worker assigned to one of that Plugin's Worker provider kinds.
- **The control plane fails to boot after toggling a Plugin:** Inspect the control-plane startup logs and fix the missing configuration or dependency before restarting.
- **A Plugin's Channel Provider still does not appear:** Confirm that the Plugin status reads **Active now**, and then check its Channel Provider page.

See [Develop Skills and Control Plane Plugins](../writing-a-skill/) for authoring guides covering both extension mechanisms.
