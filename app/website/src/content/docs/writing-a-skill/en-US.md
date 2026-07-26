---
title: Writing a skill
description: How to author a skill bundle — the SKILL.md frontmatter, the prose the agent reads, optional MCP dependencies, and how an agent discovers and uses the skill.
section: Developer guide
order: 114
---

A skill is a filesystem bundle the agent reads during a turn to learn how to do something it was not built to do. This page is the contributor walkthrough: the bundle shape, the frontmatter that makes it discoverable, the prose that makes it useful, and the optional `openai.yaml` that declares MCP dependencies. It builds on the [Agent Library](../agent-library/) concept page; this is *how to write a skill*.

The decisive property, stated up front: a skill is prose the model reads, not code the worker runs. The `SKILL.md` is the skill; everything else (supporting files, MCP dependencies, platform tags) is context for that prose. A skill that the model cannot follow from reading the `SKILL.md` is a broken skill, regardless of how good its supporting files are.

## The bundle shape

A skill is a directory containing a `SKILL.md`, and optionally supporting files and an `openai.yaml`:

```text
my-skill/
├── SKILL.md          # required — the skill itself
├── openai.yaml       # optional — MCP dependencies and metadata
├── reference.md      # optional — supporting docs the SKILL.md references
└── templates/        # optional — files the skill uses
```

The skill name is the directory name (lowercase, `[a-z][a-z0-9_-]{0,63}`). A skill is either `builtin` (shipped in `app/library/skills`, synced into the registry) or `installed` (agent-installed under worker-visible storage). See [Agent Library](../agent-library/) for the enablement model.

## The SKILL.md frontmatter

The top of `SKILL.md` is YAML frontmatter the library reads for discovery and enablement:

```yaml
---
name: my-skill
description: "One sentence: when the agent should use this skill. The model reads this to decide."
default_enabled: true
category: productivity
tags: [MyDomain, Automation]
ankole-runtime: background_job
license: MIT
platforms: [linux]
---
```

The fields that matter most:

- **`name`** — must match the directory name. The registry and the agent address the skill by this.
- **`description`** — the one field the model reads to decide whether to use the skill. Write it as "use this skill when…" and be specific about the trigger; a vague description is a skill the model never reaches for.
- **`default_enabled`** — whether the skill is on for agents by default. An operator can override per agent.
- **`ankole-runtime`** — `background_job` if the skill's work needs the isolation of a background job (common for tool-heavy skills); omit if it runs in the foreground turn.
- **`platforms`** — the platforms the skill's tools work on (`linux`, for skills that use Linux-only tools). A skill that needs `pandoc` is `linux`-only; a skill that is pure prose is platform-agnostic.

The existing skills in `app/library/skills/` are the best reference for the shape — read a few before writing your own.

## The SKILL.md body

The body is the prose the agent reads when it uses the skill. Write it for a capable but uninformed reader: the model knows how to code and reason, but not your domain's conventions.

A useful shape:

1. **What the skill does**, in one paragraph.
2. **When to use it** — the trigger, expanded beyond the frontmatter description.
3. **How to do the task** — the steps, the tools, the conventions. This is the skill's core.
4. **What not to do** — the failure modes, the guardrails.

The body is where a skill is won or lost. A skill whose body is generic advice ("be careful", "check the docs") is no better than the model's default behavior; a skill whose body names the exact tools, the exact commands, and the exact conventions of your domain is what makes the agent do something it could not do without the skill.

## MCP dependencies (optional `openai.yaml`)

If the skill needs an MCP server, declare it in `openai.yaml` under `dependencies.tools`:

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-mcp-server
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MY_MCP_TOKEN
```

The agent sees the MCP server's tools only when the skill that declares it is enabled. See the [MCP server reference](../mcp/) for the transport shapes and the skill-as-registration-source model.

## How the agent discovers and uses the skill

During a turn, the Agent Computer reads the enabled skills' `SKILL.md` files and makes them available to the model. The model reads the `description` to decide which skill to reach for, then reads the skill's body when it uses it. A skill that is enabled but whose description the model never matches is invisible — write the description to be matched.

Supporting files (`reference.md`, `templates/`) are available to the model when it uses the skill, but the model reads them on demand, not by default. Reference them by name from the `SKILL.md` body ("read `reference.md` for the full API") so the model knows they exist.

## Test a skill

A skill is tested by using it: enable it on an agent, give the agent a task the skill covers, and read whether the agent follows the `SKILL.md`. If the agent ignores a step, the step was not clear enough; if the agent never reaches for the skill, the description was not matched. Iterate on the prose, not on machinery — the skill is the prose.

## What this guide is not

It is not a prompt-engineering tutorial — write clear prose for a capable reader, the same skill you would use for any documentation. It is not a way to run arbitrary code; the skill is prose and optional MCP dependencies, and the tools the model calls are the worker's tools, not the skill's. And it is not a substitute for reading the existing skills; `app/library/skills/` is the canonical reference for the shape, and reading a few is the fastest way to write a good one.

## Next steps

- For the concept page (filesystem bundles, enablement, sync), read [Agent Library](../agent-library/).
- For MCP dependencies in `openai.yaml`, read the [MCP server reference](../mcp/).
- For the `/agents/:agent_uid/library-capabilities` routes that enable skills, read the [Console API reference](../console-api/).
