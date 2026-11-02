---
title: Agent Library
description: What an agent can do — skills as file bundles, Agent Plugins as Codex packages, and a default-then-override enablement model resolved per agent.
section: Developer guide
order: 107
---

The Agent Library resolves which Skills and Agent Plugins an Agent has enabled. Ankole stores shared Skill content in Pod under `/AnkoleBrain/skills/<name>`; each Skill homepage is a knowledge page, and its scripts and templates are file children. Agents can also install private bundles under `skills/` in their Files drive. PostgreSQL owns content, permissions, and enablement; Worker files are execution copies.

## Capabilities and enablement

A Skill has a `SKILL.md` manifest with a globally unique lowercase name. An Agent Plugin packages related Skills and an optional `workspace-template/`. Enablement resolves from shipped defaults through site and tenant settings to sparse per-Agent overrides. A Plugin member Skill also requires its parent Plugin to be enabled.

Enablement and visibility are separate. Ankole lists enabled Skills that the current conversation can read. A human-triggered turn uses the intersection of the Agent, requester, and applicable room participants; unattended automation uses the Agent's permissions. The catalog supplies names and descriptions, while `skill_view` loads the requested content.

## Shared content and upgrades

Operators edit shared Skills in Pod. Ankole appends visible knowledge children to a Skill's instructions; children with `metadata.role = "reference"` remain available by subpath for reading when needed. Agent-specific lessons add reviewed guidance when that Agent loads the Skill. See [Skill lessons](../skill-lessons/).

At startup and catalog synchronization, Ankole compares each shipped package with its stored baseline. The comparison includes homepage metadata and body, and every managed file's path, content hash, and mode. An unchanged package receives the upstream update atomically, including file additions and removals. Local edits preserve the whole package and record the pending upstream digest. Tenant-created supplements and custom files are outside the managed baseline.

## Agent contracts

`/AnkoleBrain/AGENTS.md` defines organization-wide behavior and responsibilities; `/AnkoleBrain/DESIGN.md` defines visual standards. Under `/AnkoleBrain/agents/<uid>/`, `AGENTS.md` appends Agent responsibilities and `AGENTS.override.md` replaces the global contract. The equivalent DESIGN files append body content with a metadata merge or replace the whole document. An empty override deliberately clears the inherited content.

Personal assistant pages are private to the owner and assistant. The owner manages the page, while the assistant reads it. Colleagues inherit organization contracts and need individual pages only for customization.

The Console shows effective capabilities and links document editing to Pod. `GET /agents/:agent_uid/library-documents` returns the effective AGENTS and DESIGN documents and their source pages. At each turn, Worker projections refresh `~/AGENTS.md`, `~/DESIGN.md`, and `$CODEX_HOME/AGENTS.md`; the project retains its own instruction files.

See [Skills](../skills/) for installation, [Prompt assembly](../prompt-assembly/) for execution, and [Console](../console-api/) for capability APIs.
