---
title: Agent Library
description: What an agent can do — skills as filesystem bundles, Agent Plugins as Codex packages, and a default-then-override enablement model resolved per agent.
section: Concepts
order: 13
---

The Agent Library is the answer to one question: what is this agent actually allowed to do? It is the catalog of skills and Agent Plugins an installation ships, plus the per-agent state that decides which of them are on for a given agent. This page maps that model against the real code in `Ankole.AIAgent.Library`.

The decisive property, stated up front: the skills and plugins themselves are filesystem bundles, not database rows. PostgreSQL holds enablement, registry semantics, and file observations — sparse per-agent overrides on top of installation-wide defaults. The bytes and versions stay in the installation library; the database only records who has what turned on.

## Two kinds of capability

The library keeps two related but distinct things:

- **A Skill** is a filesystem bundle, identified by a `SKILL.md`. Skill names are lowercase, start with a letter, and use only letters, digits, `_`, and `-`, up to 64 characters. A skill is either `builtin` (shipped with the app image, synced from `app/library/skills`) or `installed` (agent-installed under worker-visible storage). The `agent_skills` row records enablement, source kind, content hash, and sync time — it is explicitly not a file-content table.
- **An Agent Plugin** is a standard Codex Plugin package, plus Ankole's optional `workspace-template/` initialization directory. Package bytes and versions live in the installation library; PostgreSQL stores only sparse per-agent enablement overrides. Plugin identifiers follow the same format rules as skill names.

The two are connected: an Agent Plugin can carry skills, and skill rows record their `agent_plugin_id` for parent-enablement and catalog presentation. But Agent Plugin membership is independent metadata — it does not change how a skill is loaded.

## Enablement: default, then override

An agent's effective capabilities are resolved by walking the catalog with two layers:

1. **Installation-wide defaults** — `default_enabled` on each skill, and the global plugin defaults an operator sets.
2. **Per-agent overrides** — `enabled_override` on a skill row, or an Agent Plugin override scoped to one agent.

The resolution is the `effective_enabled` field the capability endpoints return: take the default, apply the override if one exists. A capability with no override inherits the default; a capability with an override honors the override. The catalog is bounded at 256 plugins, so the resolution stays cheap and the surface stays legible.

This is the model the Console's [Agent Library capabilities](../console/) routes expose: set the global default, then narrow or widen it per agent.

## Persona documents and skill overlays

Alongside capabilities, the library holds the agent's own writable documents and skill customizations:

- **Agent documents** are the runtime docs seeded per agent — `mission`, `soul`, and `design`, the three `source_kind` values the container table accepts. They live in `agent_library_container_entries` as agent-owned, content-addressed rows (`content_hash` per row), and they are the only agent-owned files that table holds.
- **Skill overlays** are semantic rows in `agent_skill_overlays`, one per `(agent, skill)`. They let an operator customize how a skill behaves for one agent without forking the skill bundle. An overlay supports compare-and-swap replacement, so concurrent edits resolve deterministically.

A skill view reads the skill's files plus any overlay the agent has for it, so the agent sees one coherent skill, not a bundle and a separate patch.

## Sync: keeping the registry honest

Because skills are filesystem bundles, the database registry has to track the filesystem. Two sync paths do that:

- **`sync_builtin_skills`** reconciles the `app/library/skills` tree against the builtin skill rows, returning whether anything changed, the content hash, and the counts of skills and files. It runs from the app image, so a new image can add or update builtin skills on the next sync.
- **`sync_agent_skills`** reconciles one agent's installed skills against what the worker-visible storage actually shows, and `replace_installed_skill_observations` writes the observed file set. A skill that disappears from storage is reflected in the registry; a skill that appears is picked up.

Sync is read-and-reconcile, not push-and-pray. The `content_hash` is what makes a sync idempotent: the same tree produces the same hash, and only a real change writes a row.

## The operator surface

The Console routes already covered in the [Console](../console/) page drive this model. The capability routes, in particular:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/agent-library/capabilities` | Global catalog with defaults |
| `PUT` | `/agent-library/agent-plugins/:id` | Set a plugin's global default |
| `PUT` | `/agent-library/skills/:id` | Set a skill's global default |
| `GET` | `/agents/:agent_uid/library-capabilities` | One agent's effective capabilities |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | Override a plugin for one agent |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | Override a skill for one agent |
| `GET` | `/agents/:agent_uid/library-documents` | List the agent's mission/soul/design |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | Set one document |
| `GET` | `/agents/:agent_uid/library-skill-overlays` | List skill overlays |
| `PUT` | `/agents/:agent_uid/library-skill-overlays/:skill_name` | Set a skill overlay |
| `DELETE` | `/agents/:agent_uid/library-skill-overlays/:skill_name` | Remove a skill overlay |

Reading `/agents/:agent_uid/library-capabilities` triggers an agent-skill sync, so what the operator sees is the registry reconciled against current storage — not a stale snapshot.

## What the Agent Library is not

It is not a marketplace and not a hot-load system. The skills and plugins are trusted, first-party bundles that ship with the installation or are installed into worker-visible storage; there is no third-party discovery, no isolation machinery beyond what the worker already provides. The database is not the source of the skill bytes — those live on the filesystem, and the registry only tracks what it sees. And the library is not where the model's tools are defined; it is where the operator decides which capabilities an agent may bring to a turn. Crossing from "enabled" into "actually invoked" is the Agent Computer's job, at turn time.

## Next steps

- For the routes that configure the library, read the [Console](../console/) page.
- For the worker that runs an enabled skill during a turn, read the [Actor Runtime](../actor-runtime/) page.
- For the agent Principal a library is scoped to, read [Principal and AuthZ](../principal-authz/).
