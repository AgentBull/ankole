---
title: Agent Library
description: What an agent can do — skills as file bundles, Agent Plugins as Codex packages, and a default-then-override enablement model resolved per agent.
section: Developer guide
order: 107
---

The Agent Library is the answer to one question: what is this agent actually allowed to do? It is the catalog of skills and Agent Plugins a deployment instance ships, plus the per-agent state that decides which of them are on for a given agent. This page maps that model against the real code in `Ankole.AIAgent.Library`.

Shipped Skills and Agent Plugins are file bundles in the app image. Installed Skills are stored under `skills/` in the Agent's control-plane Files drive. PostgreSQL holds the catalog, enablement, and authoritative file references; the object store holds installed file contents. The Worker downloads these files into a local execution cache.

## Two kinds of capability

The library keeps two related but distinct things:

- **A Skill** is a file bundle, identified by a `SKILL.md`. Skill names are lowercase, start with a letter, and use only letters, digits, `_`, and `-`, up to 64 characters. A skill is either `builtin` (shipped with the app image, synced from `app/library/skills`) or `installed` (stored under `skills/` in the Agent's Files drive). The `agent_skills` row records enablement, source kind, content hash, and sync time — it is explicitly not a file-content table.
- **An Agent Plugin** is a standard Codex Plugin package, plus Ankole's optional `workspace-template/` initialization directory. Package bytes and versions live in the instance library; PostgreSQL stores only sparse per-agent enablement overrides. Plugin identifiers follow the same format rules as skill names.

The two are connected: an Agent Plugin can carry skills, and skill rows record their `agent_plugin_id` for parent-enablement and catalog presentation. But Agent Plugin membership is independent metadata — it does not change how a skill is loaded.

## Enablement: tenant default, then Agent override

Tenant settings provide the effective defaults for Agent Plugins and Skills. A tenant without an override inherits the site setting; shipped catalog defaults apply when no operator setting exists. An Agent stores only its own overrides.

`effective_enabled` reflects the Agent override or inherited tenant default. A Plugin member Skill also requires its parent Plugin to be enabled. Disabling the parent keeps the member's saved setting, so it applies again when the parent is enabled.

The Console's [Agent Library capabilities](../console-api/) routes read and update defaults for the selected tenant, then allow a narrower Agent override. The API field `global_default_enabled` returns the selected tenant's effective default, including site inheritance.

## Recall-only Skill discovery

A shipped standalone Skill or Agent Plugin member can declare `brain-recall-only: true`. Shipped Skills share one global name space, so Plugin membership does not change the Skill name. Agent-installed Skills do not participate in this mode.

The Agent Library sends the Worker the complete effective Skill set. Ordinary Skills enter the model-visible Skill catalog. Recall-only Skills stay in the loadable set for `skill_view`, but the catalog omits them. A library sweep projects only their name, description, and tags into Brain as lightweight records at `lazyload-agent-skills/<skill-name>`; Skill bodies, resources, and Agent-specific lessons remain in their owning file and database paths.

The projection is shared within one tenant and remains present when an Agent disables a Skill. Brain queries and `skill_view` both apply that Agent's current effective Plugin and Skill state, so a disabled record cannot consume a retrieval slot or be loaded. Re-enabling the capability restores the existing projection.

## Durable Agent documents and Skill lessons

Alongside capabilities, the library holds the agent's own writable documents and Agent-specific Skill guidance:

- **Durable Agent documents** are `mission`, `soul`, `design`, and `confidentiality_policy`, the four `source_kind` values accepted by the container table. The first two define responsibility and behavior. `design` stores the design system for visual work. `confidentiality_policy` guides audience selection when the Agent writes to Brain. They live in `agent_library_container_entries` and use content hashes.
- **Skill lessons** are immutable semantic rows in `agent_skill_lessons`. Each row belongs to one Agent and one Skill, and records its author, evidence, lease state, and retirement history. Dreaming writes evidence-backed leased lessons. An operator can add a human lesson with no lease or retire any lesson.

A Skill view reads the Skill files and renders eligible lessons under `Agent-specific additions`. The base `SKILL.md` does not change. See [Skill lessons](../skill-lessons/) for the evidence, review, and delivery rules.

## Sync: keeping the registry honest

The control plane's `sync_agent_skills` combines two sources into one Agent's catalog:

- **Shipped Skills** come from the app image, including standalone Skills and Agent Plugin members. A new image can add or update these Skills on the next sync.
- **Installed Skills** come directly from `skills/<name>/SKILL.md` in the Agent's Files drive. Library reads every listing page and every manifest before it changes the catalog. Added or changed manifests update catalog rows; deleted manifests remove them. A read or parse failure leaves the catalog unchanged. Updates preserve the operator's existing `enabled_override`.

The Worker downloads installed Skills into its execution cache. It does not scan that cache to publish or replace the catalog. Content hashes let sync leave unchanged rows as they are.

## The operator surface

The Console routes already covered in the [Console](../console-api/) page drive this model. The capability routes, in particular:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/agent-library/capabilities` | Selected tenant catalog with defaults |
| `PUT` | `/agent-library/agent-plugins/:id` | Set a plugin's tenant default |
| `PUT` | `/agent-library/skills/:id` | Set a skill's tenant default |
| `GET` | `/agents/:agent_uid/library-capabilities` | One agent's effective capabilities |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | Override a plugin for one agent |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | Override a skill for one agent |
| `GET` | `/agents/:agent_uid/library-documents` | List the agent's mission/soul/design/confidentiality policy |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | Set one document |
| `GET` | `/agents/:agent_uid/skill-lessons` | List active and retired Skill lessons |
| `POST` | `/agents/:agent_uid/skill-lessons` | Add a human Skill lesson |
| `POST` | `/agents/:agent_uid/skill-lessons/:lesson_id/retire` | Retire a Skill lesson |

Reading `/agents/:agent_uid/library-capabilities` triggers an agent-skill sync from the app image and the Agent's Files drive. It does not require a running Worker.

## What the Agent Library is not

It is not a marketplace and not a hot-load system. Skills and Plugins are trusted, first-party bundles. Shipped bundles come with the deployment instance; installed Skills are stored in the Agent's Files drive. There is no third-party discovery, no isolation machinery beyond what the worker already provides. The library is not where the model's tools are defined; it is where the operator decides which capabilities an agent may bring to a turn. At execution time, the control plane loads main-Agent Skill instructions; the Worker prepares computer tools and Codex Job Skills.

## Next steps

- For the routes that configure the library, read the [Console](../console-api/) page.
- For Agent-specific process guidance, read [Skill lessons](../skill-lessons/).
- For the worker that runs an enabled skill during a turn, read the [Sessions](../sessions/) page.
- For the agent Principal a library is scoped to, read [Principal and AuthZ](../principal-authz/).
