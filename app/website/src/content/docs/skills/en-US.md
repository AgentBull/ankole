---
title: Skills
description: How an Ankole agent uses skills at runtime — the worker tools (skill_view, skill_append, skill_replace), the five builtin skills, the default-then-override enablement model, and how an operator turns a skill on or off for an agent.
section: User guide
order: 34
---

A skill is a filesystem bundle with a `SKILL.md` that teaches an agent how to do a job. The agent does not invent skills at runtime; it reads the ones the [Agent Library](../agent-library/) has enabled, learns from them, and records what it learned back. This page is the operator view of skills in use: what the worker tools are, what ships builtin, when the agent reads versus writes a skill, and how you turn one on or off.

The decisive property, stated up front: a skill is a filesystem bundle, not a database row. The bundle carries the instructions and any resources; the database holds only enablement and a sparse per-agent overlay of notes the agent has added while using the skill. The skill's own `SKILL.md` is the contract the model reads; the overlay is what the agent adds on top.

## What a skill is

A skill is a directory with a `SKILL.md` at its root, discovered by the [Agent Library](../agent-library/). A `SKILL.md` is frontmatter plus a Markdown body. The frontmatter carries the things the runtime needs:

- **`default_enabled`** — whether the skill is on for every agent unless an override narrows it.
- **`ankole-runtime: background_job`** — a marker that the skill's work runs as a [background job](../background-jobs-ops/), isolated from the owning turn, rather than inline.

The body is the instructions. For an inline skill, the agent reads the `SKILL.md` and any referenced files when it decides the task needs the skill. For a background-job skill, the agent reads only the `SKILL.md`, which carries routing guidance, and the actual work runs inside a background job.

## What ships builtin

Five skills ship in `app/library/skills/`, and they cover the heavy paths an agent is likely to need:

- **`browser`** — browser automation through the `ankole-browser` CLI against a runtime-owned Chromium session. See [Browser automation](../browser-automation/).
- **`brain-review`** — a conversational, post-hoc review of Brain memory. It runs only when a human explicitly asks to review, audit, clean up, or 复盘 the agent's memory. See [Memory](../memory/).
- **`design-md`** — visual artifacts and VIS design.
- **`jupyter-live-kernel`** — iterative Python through a Jupyter kernel that stays alive across executions. See [Code execution](../code-execution/).
- **`pdf`** — create, check, and edit PDF files.

Each is a `default_enabled` builtin unless an operator narrows it, so a fresh agent has them available. They are the canonical examples to read when you want to see how a skill is shaped.

## How the agent reads a skill

The worker ships three skill tools, all in `app/agent_computer/src/tools/library/skill-tools.ts`. They are the agent's only surface on skill content:

- **`skill_view`** (line 75) — read an enabled skill's file. For a `background_job` skill it returns only the routing guidance and rejects referenced resources; for an inline skill it reads referenced files only when needed, resolving relative paths from the returned skill directory. It is read-only, and its description is blunt: this tool cannot enable disabled skills.
- **`skill_append`** (line 123) — append a durable note to this agent's DB-backed overlay for an enabled skill. The control plane owns the read-modify-write transaction, so concurrent turns do not lose each other's additions.
- **`skill_replace`** (line 152) — replace the entire overlay for a skill, using the latest resolved content hash as an optimistic compare-and-swap fence. A concurrent change is rejected instead of silently overwriting.

The overlay is the key idea. The skill bundle itself is not agent-specific — it is shared across every agent that has the skill enabled. What is agent-specific is the layer of notes the agent has added while using it: corrections, local conventions, things it learned. `skill_append` adds to that layer; `skill_replace` rewrites it. The bundle stays in the filesystem; the overlay lives in PostgreSQL as sparse per-agent state.

## When the agent uses each tool

The shape of the work picks the tool:

- **`skill_view`** before the agent does anything the skill covers. The agent reads the `SKILL.md` to learn the procedure, then reads referenced files only when the procedure calls for them.
- **`skill_append`** when the agent learns something durable about this skill in this agent's context — a local convention, a corrected step, a gotcha. The description tells the model to use it only after reading the skill, and only for agent-specific additions learned while using it.
- **`skill_replace`** for revisions, deduplication, or budget-preserving compaction — when the overlay has grown past its memo budget, or the agent has learned enough to rewrite it more tightly. Read the skill first; a concurrent change by another turn is rejected.

The agent does not enable or disable skills. That is a control-plane decision, made through the [Agent Library](../agent-library/). The worker tools only read and annotate.

## How to enable a skill

Skills are governed by the default-then-override model, resolved per agent. Two layers:

1. **Installation-wide default** — `default_enabled` in the skill's `SKILL.md`. A builtin with `default_enabled: true` is on for every agent.
2. **Per-agent override** — narrow a skill for an agent that should not have it, or widen one you previously narrowed. The Console's library-capability routes set this; reading an agent's `library-capabilities` triggers a skill sync, so what you see is the registry reconciled against the current filesystem, not a stale snapshot.

The resolution is the `effective_enabled` field the capability endpoints return: take the default, apply the override if one exists. A skill with no override inherits the default; a skill with an override honors the override.

For a background-job skill, enabling it is necessary but not sufficient — the worker must also be able to run a background job, which is its own surface. See [Background jobs (operator view)](../background-jobs-ops/).

## What the operator does not touch

The skill bundle's files, the overlay's content hash fencing, and the filesystem layout under `/agents` are not operator-tunable. If a skill behaves wrong, the fix is in the `SKILL.md`, not in a worker environment variable. The overlay is agent-owned state: an operator does not edit it by hand — the agent appends and replaces it through its tools, and a human review of it happens through the same worker surface.

## Next steps

- For the catalog and enablement model that decides which skills are on, read the [Agent Library](../agent-library/) developer page.
- For how to author a new skill, read [Writing a skill](../writing-a-skill/).
- For the memory review skill and what it reviews, read [Memory](../memory/).
- For the worker that runs these tools, read the [Agent Computer](../agent-computer/) developer page.
