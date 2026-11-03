---
title: Agent Library
description: Skill packages, Agent enablement and instruction contracts in Meta Ankole.
section: Developer guide
order: 107
---

The Agent Library owns Skill packages and Agent instruction contracts in PostgreSQL. In Pod, open **Meta Ankole → Skills** to browse packages and **Agents** to manage colleagues, your assistant and global instructions. Meta navigation branches start collapsed. Collaborative pages and the Brain knowledge graph have separate owners.

## Packages and enablement

Each Skill has a tenant-unique `slug`, a required `SKILL.md` manifest and optional reference files, scripts or binary assets. Members with custom-Skill permission can create or import packages; custom packages start disabled. The manifest is the entry point. Agents read companion files only when instructed by the manifest, and reviewed Skill lessons remain available through `skill_view`.

A Skill can be enabled for all Agents, selected colleagues or your own assistant. Enabling it for all locks individual switches while preserving their bindings. Turning that option off restores the individual choices. A Plugin Skill also requires its parent Agent Plugin to be enabled; Plugin defaults and overrides remain independent.

Skills depend on the Agent identity. Changing the requester or participants does not remove the Agent's enabled packages. Brain reads instead follow the intersection of the Agent, requester and disclosure audience.

## Editing and upgrades

The Skills editor manages the manifest, metadata and package files. Saves compare `base_revision` and reject stale edits. Skills and contracts keep their current revision without historical snapshots. Official package slugs are fixed; custom packages can be renamed or deleted.

Upstream synchronization compares the manifest and managed file hashes. An unchanged official package receives additions, updates and removals atomically. A local edit freezes that package until the edit is reconciled; extra local attachments remain in place.

## Agent contracts

**Meta Ankole → Agents → Global settings** owns the global `AGENTS.md` and `DESIGN.md` baselines. Each colleague or assistant can inherit, append to or override each baseline. DESIGN append mode merges metadata recursively and separates body sections with a horizontal rule. An empty override intentionally clears inherited content.

Only an assistant's owner can read or edit its configuration. A new assistant overrides AGENTS with the assistant template and inherits DESIGN. Members can read colleague and global settings; designated administrators can edit them.

The Worker mounts enabled packages at `/drive/Skills/<slug>/` and effective contracts at `/drive/AGENTS.md` and `/drive/DESIGN.md`. These read-only mounts share a warm cache across conversations; executable scripts retain execute permission. Saved changes invalidate that cache. Background Jobs keep the Skill set captured at admission, intersected with current enablement on resume.

See [Skill lessons](../skill-lessons/), [Writing a Skill](../writing-a-skill/) and [Prompt assembly](../prompt-assembly/).
