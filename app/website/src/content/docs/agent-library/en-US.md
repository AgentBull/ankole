---
title: Agent Library
description: What an agent can do — skills as file bundles, Agent Plugins as Codex packages, and a default-then-override enablement model resolved per agent.
section: Developer guide
order: 107
---

The Agent Library answers one central question: what is a given Agent allowed to do? It combines the catalog of Skills and Agent Plugins that a deployment ships with the per-Agent overrides that determine which capabilities are enabled. This page maps that model directly to `Ankole.AIAgent.Library`.

Shipped Skills and Agent Plugins live as file bundles inside the application image, while installed Skills live under `skills/` in the Agent's control-plane Files drive. PostgreSQL tracks the catalog, enablement state, and authoritative file references; object storage holds the installed file bytes, which the Worker downloads into a local execution cache.

## Two kinds of capability

The library manages two related but distinct capability types:

- **A Skill** is a file bundle identified by a `SKILL.md` manifest. Skill names must be lowercase, start with a letter, and contain only letters, digits, `_`, and `-` (up to 64 characters). Each Skill is either `builtin` (shipped in the app image and synced from `app/library/skills`) or `installed` (stored under `skills/` in the Agent's Files drive). Its `agent_skills` row records enablement, source kind, content hash, and sync timestamp—never raw file contents.
- **An Agent Plugin** is a standard Codex Plugin package paired with Ankole's optional `workspace-template/` initialization directory. Package bytes and versions reside in the instance library, while PostgreSQL stores only sparse per-Agent enablement overrides. Plugin identifiers follow the same naming rules as Skills.

The two intersect when an Agent Plugin bundles member Skills: those `agent_skills` rows record their parent `agent_plugin_id` for enablement checks and catalog grouping, while still loading at runtime through the standard Skill path.

## Enablement: tenant default, then Agent override

Capability enablement resolves across three layers: shipped catalog defaults, tenant defaults, and per-Agent overrides. When a tenant has no explicit setting for an Agent Plugin or Skill, Ankole inherits the site-level setting, or falls back to the shipped catalog default if no operator setting exists. Each Agent stores only its own sparse overrides.

The computed `effective_enabled` field reflects the Agent's override or its inherited tenant default. A Skill bundled inside an Agent Plugin also requires its parent Plugin to be enabled; disabling the parent Plugin suspends its member Skills while preserving their saved overrides, so those overrides take effect again if you re-enable the parent Plugin.

In the Console, the [Agent Library capabilities](../console-api/) endpoints read and update defaults for the selected tenant and apply narrower per-Agent overrides. In API responses, `global_default_enabled` reports the tenant's effective default after site inheritance.

## Recall-only Skill discovery

Any shipped standalone Skill or Agent Plugin member can declare `brain-recall-only: true`. Because all shipped Skills share one global namespace, belonging to a Plugin does not alter a Skill's name. Agent-installed Skills cannot use recall-only mode.

When preparing a turn, the Agent Library sends the Worker the complete set of effectively enabled Skills. Standard Skills appear directly in the model-visible Skill catalog, whereas recall-only Skills are omitted from that catalog while remaining loadable via `skill_view`. Instead, a library sweep indexes only their name, description, and tags into Brain as lightweight records under `lazyload-agent-skills/<skill-name>`, leaving Skill bodies, bundled resources, and Agent-specific lessons in their authoritative file and database stores.

All Agents within a tenant share these Brain projections, and disabling a Skill for one Agent leaves the shared record intact. At query and load time, both Brain retrieval and `skill_view` enforce the calling Agent's current effective Plugin and Skill state, ensuring that a disabled Skill cannot consume a retrieval slot or be loaded. Re-enabling the capability makes the existing projection available again immediately.

## Durable Agent documents and Skill lessons

Alongside capabilities, the library manages each Agent's writable identity documents and Agent-specific Skill guidance:

- **Durable Agent documents** use the four `source_kind` values accepted by `agent_library_container_entries`: `mission`, `soul`, `design`, and `confidentiality_policy`, tracked via content hashes. `mission` and `soul` define the Agent's responsibilities and behavior, `design` stores the visual design system, and `confidentiality_policy` guides audience selection when the Agent writes to Brain.
- **Skill lessons** are immutable semantic rows in `agent_skill_lessons`. Each row belongs to one Agent and one Skill, recording its author, supporting evidence, lease state, and retirement history. Dreaming writes evidence-backed leased lessons, whereas operators can add permanent human-authored lessons or retire any existing lesson.

When an Agent invokes a Skill view, Ankole reads the Skill files without modifying the base `SKILL.md` and appends eligible active lessons under `Agent-specific additions`. See [Skill lessons](../skill-lessons/) for the evidence, review, and delivery rules.

## Sync: keeping the registry honest

In the control plane, `sync_agent_skills` merges two sources into each Agent's catalog:

- **Shipped Skills** come from the app image, covering both standalone Skills and Agent Plugin members. Deploying a new image adds or updates these rows on the next sync.
- **Installed Skills** come directly from `skills/<name>/SKILL.md` in the Agent's Files drive. Before modifying the catalog, `Ankole.AIAgent.Library` reads every listing page and parses every manifest; if any read or parse fails, it aborts the sync and leaves the catalog unchanged. Otherwise, it inserts or updates rows for added and changed manifests, removes rows whose manifests were deleted, and preserves the operator's existing `enabled_override`.

At runtime, the Worker downloads installed Skills into its local execution cache without ever scanning that cache to publish or replace the catalog, and content hashes allow `sync_agent_skills` to skip unchanged rows.

## The operator surface

The Console endpoints documented in [Console](../console-api/) drive this model—in particular, the capability and document routes:

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

Calling `GET /agents/:agent_uid/library-capabilities` triggers an immediate skill sync from the app image and the Agent's Files drive without requiring a running Worker.

## What the Agent Library is not

The Agent Library is neither a third-party marketplace nor a dynamic hot-loading system. Skills and Agent Plugins are trusted, first-party bundles shipped with the deployment image or stored in the Agent's Files drive, with no third-party discovery or extra sandboxing beyond what the Worker container already provides. Nor is the library where raw model tools are implemented; instead, it is where operators govern which capabilities an Agent may bring to a turn. At execution time, the control plane loads main-Agent Skill instructions, while the Worker stages computer tools and Codex Job Skills.

## Next steps

- For the routes that configure the library, read the [Console](../console-api/) page.
- For Agent-specific process guidance, read [Skill lessons](../skill-lessons/).
- For the worker that runs an enabled skill during a turn, read the [Sessions](../sessions/) page.
- For the Agent Principal that a library is scoped to, read [Principal and AuthZ](../principal-authz/).
