---
title: AppConfigure
description: Manage Ankole AppConfigure runtime settings in the Console and reference the built-in keys.
section: User guide
order: 43
---

**Console → AppConfigure** contains settings that an administrator can change while the deployment instance is in service. Examples include durable memory, Agent limits, directory synchronization intervals, and plugin switches.

LLM Providers, Identity Providers, chat channels, and environment variables have their own Console pages. Do not configure them again here.

## AppConfigure and environment variables

AppConfigure settings are stored in PostgreSQL. They control Ankole product behavior while the instance runs. Most changes apply to later work and do not require a new deployment.

[Deployment environment variables](../environment-variables/) start the control plane, PostgreSQL, and Workers. Restart the affected process after you change one.

Use [Agent environment variables](../worker-env/) when a Skill, command-line tool, or MCP service needs a custom value such as an API key.

## Find a setting

The page groups related settings. You can search by key or description, or open a group to see its settings together.

Each row has one of these states:

- **Editable:** open the row and change it here.
- **Read-only:** the row shows current state but cannot be changed here.
- **Managed elsewhere:** follow the management link to the Console page that owns the setting.

The key is the stable name of the setting. Its description explains what it controls and which unit a number uses.

## Understand scope and source

The AppConfigure page changes instance overrides. A key marked **Instance or Agent** also lets its owning feature store an override for one Agent, but this page does not select or edit an Agent.

When Ankole resolves one of these settings for an Agent, it uses this order:

1. the current Agent override;
2. the instance override;
3. the default declared by the installed version.

The AppConfigure list shows an instance override or the version default. **Reset to default** removes the instance override. All Agents without their own override then use the version default.

## Change a setting

1. Open the setting or setting group.
2. Read the field descriptions and confirm the scope and units.
3. Change the necessary values and save.
4. Return to the list and confirm that the row shows an override.

Common settings use a dedicated form. Some advanced settings use a JSON editor. Keep the existing field structure and do not remove fields that you do not understand.

Most changes apply to later work. If the page says that a change applies at the next start, restart the control plane at a suitable time.

## Reset a setting

When you no longer need a custom value, open the setting and select **Reset to default**. This removes the stored override and makes Ankole use the default declared by the installed version.

Resetting is different from entering the current default as a custom value. A reset follows a changed default in a later version. A stored custom value does not.

## Current built-in AppConfigure keys

The following AppConfigure keys are built into Ankole. A Control Plane Plugin can register more keys. The **AppConfigure** page in the current instance is the authoritative list.

### Agent runtime

| Key | Scope | Purpose |
|---|---|---|
| `ai_agent.max_iterations` | Instance or Agent | Maximum model iterations for one Agent turn |
| `ai_agent.max_output_tokens` | Instance or Agent | Output-token cap for one model response |
| `ai_agent.inactivity_timeout_ms` | Instance or Agent | Time to wait for an inactive model or Provider before ending the turn |
| `ai_agent.library.agent_plugin_defaults` | Instance | Default enablement for Agent Plugins |
| `ai_agent.library.skill_defaults` | Instance | Default enablement for Skills |

### AI Gateway and long-term memory

| Key | Scope | Purpose |
|---|---|---|
| `ai_gateway.compaction` | Instance | Automatic conversation-history compaction policy |
| `brain.knowledge` | Instance | Long-term memory projection budget and result limit |
| `brain.dreaming` | Instance or Agent | Dreaming and knowledge-curation policy |
| `brain.embedding` | Instance | Embedding model and vector dimensions |
| `brain.search` | Instance | Long-term memory decay and reranking policy |
| `brain.sources` | Instance | External-source synchronization and retention policy |

### Identity, Plugins, and instance defaults

| Key | Scope | Purpose |
|---|---|---|
| `principals.identity_providers.active` | Instance, read-only | Identity sources available for administrator sign-in; managed on the Identity Provider page |
| `principals.identity_providers.directory_full_sync_interval_hours` | Instance | Full organization-directory synchronization interval |
| `plugins.enabled_ids` | Instance | Control Plane Plugins to enable at the next start |
| `system.timezone` | Instance | Default time zone for schedules and other control-plane features |
| `i18n.default_locale` | Instance | Default language for the Ankole interface |

### Workers, web reading, and security

| Key | Scope | Purpose |
|---|---|---|
| `runtime_fabric.worker_auth_key` | Instance, read-only | Authentication key between the control plane and Workers; generated and maintained by the system |
| `agent_computer.background_agent_job.max_turns_per_worker` | Instance | Maximum concurrent Background Agent Job turns on each Worker |
| `worker.rendered_fetch_idle_ttl_ms` | Instance or Agent | Idle lifetime for the built-in `web_fetch` rendered fallback |
| `security.ssrf_filter` | Instance or Agent | Whether model-controlled fetches reject private, loopback, link-local, and CGNAT addresses |

Cloud metadata addresses are rejected even when this setting is off.

### First-run state

| Key | Scope | Purpose |
|---|---|---|
| `setup.bootstrap_activation_code` | Instance, read-only | Temporary activation code for the first-run setup page |
| `setup.completed` | Instance, read-only | Whether this instance has completed first-run setup |

The first-run setup flow owns these keys. To read the activation code, run `kit show bootstrap-activation-code`. Do not edit these keys on the AppConfigure page.

## Encrypted settings

Ankole stores credential settings in encrypted form and shows a mask in the list and editor. Saving the mask keeps the current value. Entering new content replaces it.

Use **Reveal** only when you must check the current value. Do not copy a revealed credential into chat, screenshots, or tickets.
