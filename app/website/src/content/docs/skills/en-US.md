---
title: Agent Library
description: Manage tenant and per-Agent Agent Plugins and Skills, and site-scoped Control Plane Plugins.
section: User guide
order: 32
---

The **Agent Library** page in the Site Admin Console manages two distinct extension boundaries: tenant- and Agent-scoped model capabilities (**Agent Plugins** and **Skills**), and strictly **site-scoped** platform extensions (**Control Plane Plugins**, visible only when the scope is set to **Global defaults**).

All three are trusted first-party components compiled or packaged into this deployment instance. Enabling an item here does not download unknown code from the internet.

## Understand the three capability types

| Type | Scope | Purpose | When a change applies |
|---|---|---|---|
| **Agent Plugin** | Tenant default + per-Agent override | Groups related Skills, MCP capabilities, and workspace templates | The Agent's next turn |
| **Skill** | Tenant default + per-Agent override | Instructions and resources for one repeatable kind of work | The Agent's next turn |
| **Control Plane Plugin** | Site-scoped only (`/api/v2/site/control-plane-plugins`) | Full-stack compile-time platform extension (adapters, OTP services, HTTP plugs, extension routes, domain hooks, config fields, and Web UI slots) | Fixed active with the build (`activation: :always`), or on the next control-plane start (`activation: :optional`) |

### Agent Plugin: capabilities that share one package

An Ankole Agent Plugin is a superset of an <a href="https://developers.openai.com/plugins" target="_blank" rel="noreferrer">OpenAI Plugin</a>.

An OpenAI Plugin can group one or more Skills, an MCP server, and optional UI in one package. Ankole keeps this structure and adds a **workspace template**.

An Agent Plugin can therefore provide working methods, execution tools, and the initial environment for a task. It is more than one prompt.

Enabling an Agent Plugin in the Console makes the package available to the Agent. You can still enable or disable each member Skill.

#### Workspace templates prepare complex tasks

The `workspace-template/` directory belongs to an Agent Plugin. When Ankole creates a Background Agent Job, it can copy this template into the new Job workspace.

A template can provide `AGENTS.md`, directories, research methods, validation scripts, Playbooks, and other task files. The Job receives a durable workspace that it can update and recover.

Ankole's state-of-the-art [Deep Research](../deep-research-job/) is a representative example. The main Agent first confirms the research request and then creates a Background Agent Job with the `deep-research` workspace template.

The template provides the research workflow, evidence directories, analysis methods, and validation tools. The Job can collect sources, revise its analysis, and create the final report in one workspace.

Enabling an Agent Plugin with a workspace template does not change an existing conversation or create a Job. Ankole initializes a new Job workspace only when a task selects that template.

### Skill: one repeatable working method

Ankole Skills conform to the <a href="https://agentskills.io/specification" target="_blank" rel="noreferrer">official Agent Skills specification</a>.

Each Skill contains at least one `SKILL.md` file with YAML frontmatter. It can also contain `scripts/`, `references/`, and `assets/`.

The Agent first sees the name and description. It loads the full instructions and required resources only after a task matches.

A Skill explains how to complete a kind of work. When the workflow needs live data, authentication, or a controlled action, the Skill can select an MCP domain tool and call it through mcporter. The MCP catalog is not a second model-visible tool registry.

#### Ankole extension: select the Skill execution surface

Ankole adds `ankole-runtime` to the standard frontmatter:

```yaml
---
name: my-skill
description: Use for tasks that meet these conditions.
ankole-runtime: any
---
```

| Value | Where the Skill is available | Use it when |
|---|---|---|
| `any` | Main Agent and Background Agent Jobs | Both execution surfaces can safely complete the work; this is also the default when the field is absent |
| `main` | Main Agent conversations only | The Skill must ask the user, confirm a choice, or create and manage a Background Agent Job |
| `background_job` | Background Agent Jobs only | The work is long-running, depends on the Job workspace, or processes files, browser work, or data in one Job |

This field controls where the Skill is visible. It does not create a Background Agent Job.

The Deep Research entry Skill uses `main` because it confirms the request in the original conversation and creates the Job. The research Skills can then run inside the Background Agent Job.

#### Ankole extension: discover a Skill through Brain

Some SOPs and methods are useful only when the current work matches them, so listing them in every prompt would waste context. A shipped Skill can declare `brain-recall-only: true`. It remains a standard Skill and keeps the same Agent Plugin, Skill enablement, execution-surface, and `skill_view` rules, but Brain discovers it by meaning instead of placing it in the model-visible Skill catalog.

Brain searches the Skill's name, description, and tags. After a match, the Agent calls `skill_view`, which applies `ankole-runtime` and either loads the Skill on a compatible execution surface or returns the correct routing or rejection result. Disabling the Skill, or its parent Agent Plugin, removes it from both Brain discovery and loading for that Agent. Brain must be enabled for this semantic discovery path. This mode is suitable for shipped methods and SOPs that should be available on demand without occupying every prompt.

### Control Plane Plugin: site-scoped full-stack platform extension

A Control Plane Plugin is not an OpenAI Plugin, does not enter the Agent's working context, and is never tenant-scoped or Agent-scoped. It is a compile-time, site-scoped extension compiled into the release and resolved into an immutable `:persistent_term` snapshot at boot.

A Control Plane Plugin can contribute across the full stack:

- Subsystem adapters (`signals.adapter`, `principals.identity_provider`, `ai_gateway.provider`, `agent_workers.provider`) and supervised OTP processes (`children/0`)
- Outer HTTP edge plugs and scoped extension JSON:API routes
- Synchronous domain transaction `hooks/0` (`Ankole.Plugins.Hook`)
- Declarative `AppConfigure` fields (`ConfigFields`) and typed Web UI Slots (`entries.json` `overrides`)

Each Control Plane Plugin declares `activation: :optional | :always`. Optional plugins (`:optional`, the default) are selected in `plugins.enabled_ids` and apply on the next control-plane start. Platform plugins with `activation: :always` remain fixed active with the source build and cannot be disabled. For dynamic runtime switches or gradual rollouts that apply without a restart, Ankole uses OpenFeature (`Ankole.Features`).

## Manage Agent Plugins and Skills

### Set instance defaults

1. Open **Agent Library** in the Console.
2. Set the scope to **Global defaults**.
3. Find the capability under **Agent Plugins** or **Skills**.
4. Enable or disable its default.

The global default applies to new Agents and to Agents that do not have an override. A turn that has already started does not change. The Agent reads the new capability set on its next turn.

Enable common, low-risk capabilities by default and narrow them for exceptions.

A capability that applies to a small role, needs special credentials, or has material risk is easier to manage when it is disabled by default and enabled only where needed.

### Override one Agent

1. At the top of Agent Library, change the scope to the target Agent.
2. Find the Agent Plugin or Skill.
3. Select **Follow global**, **Enabled**, or **Disabled**.

**Follow global** removes the exception. Later changes to the instance default then apply to this Agent. An explicit enabled or disabled value remains as that Agent's override.

An Agent Plugin can contain several Skills. Disabling the parent makes its Skills unavailable but does not rewrite each Skill setting. When you enable the parent again, the Skills return to their own effective states.

### Review Skill lessons

An Agent can receive dated process cautions with its full Skill instructions. Dreaming derives leased lessons from Job evidence, and an operator can add a human lesson. The shared `SKILL.md` stays unchanged.

Change the Agent Library scope to the target Agent, then find the Skill card. The card lists active and retired lessons, evidence Jobs, review dates, and retirement reasons. An operator can add a lesson or retire one; the Agent stops reading a retired lesson on its next turn.

Do not copy a general rule into every Agent's lessons. Change the Skill source when the rule applies to all Agents. See [Skill lessons](../skill-lessons/) for the evidence rules, leases, and settings.

## Manage Control Plane Plugins

### Enable or disable optional site plugins

Control Plane Plugins are strictly site-scoped (`/api/v2/site/control-plane-plugins`). They appear only in the Site Admin Console (`/site-admin-console`) when the Agent Library scope is set to **Global defaults**:

1. In the Site Admin Console, open **Agent Library**, keep the scope set to **Global defaults**, and open the **Control Plane Plugins** tab.
2. Find an optional Plugin (`activation: :optional`) and set it to **Enabled next start**. Plugins with `activation: :always` are fixed active with the build and do not offer a disable toggle.
3. Save and restart the control plane.
4. Return to **Control Plane Plugins** and confirm that the Plugin is **Active now**.
5. Configure the Channel Provider, identity source, Worker provider, or setting that the Plugin provides.

Docker Compose:

```bash
docker compose restart control-plane
```

Kubernetes:

```bash
kubectl -n ankole rollout restart deployment/ankole-control-plane
```

Disabling an optional Control Plane Plugin also applies on the next start. Contracts enforce `veto_disable` inside the configuration transaction: a Worker-provider Plugin cannot be disabled while any tenant has an assigned Worker (including paused Workers or Agents being deleted) for one of its provider kinds. Confirm that no active Channel Provider, identity source, or Worker depends on the Plugin before you disable it. Dynamic runtime feature flags that change without a restart use OpenFeature (`Ankole.Features`) rather than plugin activation toggles.

## Troubleshoot

### Agent Plugins and Skills

- **A capability is missing:** confirm that the deployment package contains it. The library can show only installed components.
- **A Skill is enabled but unavailable to the Agent:** check whether its parent Agent Plugin is disabled, and start a new turn.
- **A Skill appears only in some tasks:** inspect `ankole-runtime`. A `main` Skill does not enter a Background Agent Job, and a `background_job` Skill does not enter a normal main-Agent conversation.
- **Some Agents ignore a global change:** they can have per-Agent overrides. Select each Agent scope and inspect the setting.
- **A Background Agent Job cannot select a workspace template:** confirm that the Agent Plugin is enabled for the Agent and that the Plugin contains `workspace-template/`.

### Control Plane Plugins

- **The Control Plane Plugins tab is not visible:** Control Plane Plugins are site-scoped only. Open the Site Admin Console (`/site-admin-console`) and set the **Agent Library** scope to **Global defaults**.
- **A Control Plane Plugin says Enabled next start:** the setting is saved in `plugins.enabled_ids`, and the control plane must restart to rebuild its boot snapshot.
- **A Control Plane Plugin cannot be disabled:** either the Plugin declares `activation: :always` (fixed active with the build), or `veto_disable` rejected the change because a tenant still has an Agent Worker assigned to one of the Plugin's Worker provider kinds.
- **The control plane does not start after a restart:** read the startup log and correct the Plugin configuration or dependency before starting it again.
- **The Channel Provider is still missing:** confirm that the Plugin is **Active now**, and then inspect its Channel Provider configuration.

See [Develop Skills and Control Plane Plugins](../writing-a-skill/) for both extension paths.
