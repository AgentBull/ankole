---
title: Code execution
description: How an Ankole Agent runs code in a conversation or as a durable Background Agent Job.
section: Developer guide
order: 122
---

An Agent can run commands and edit files during a normal conversation. It can also delegate durable work to a Background Agent Job. These are separate runtime paths: a conversation uses the Agent Computer Worker's foreground tools, while every Background Agent Job uses CodexRunner. The amount of code in a message does not select between them.

The decisive property, stated up front: every command runs on the Agent's own computer. Each Agent has its own Worker container, and the container is the only isolation boundary. Commands run as the Worker's user without an inner sandbox, and the agent works in its Agent Home under `/workspace`. The Agent may change its own computer; it shares no Worker, cache disk, or credential with another Agent.

## Shell commands

The Agent runs shell commands through the command tool, backed by `app/agent_computer/src/tools/computer/command-tool.ts`. Each command runs as the Worker's user in its own process group, with a fresh environment that does not contain the Worker credential. A cancellation or a timeout ends the whole group; the default foreground budget is 180 seconds. The working directory must be inside the Agent Home. The [browser](../browser-automation/) daemon, the Codex app-server, and Automation scripts also run as the Worker's user, and the Worker needs no extra kernel privileges.

Commands run as uid 1000 without sudo. They can write Home, install user-space packages, and start subprocesses; they cannot install system packages. Sessions and Jobs of one Agent can see its files. The instance isolates Agents; the Worker has no database connection or object-store credentials.

## File reads and apply_patch

Alongside the shell, the computer tools give the Agent two file primitives:

- **Read a file** — `read-file-tool.ts`, for inspecting a file's contents directly rather than shelling out to `cat`.
- **Edit files** — `apply-patch-tool.ts`, a freeform `apply_patch` tool that uses the same grammar as the pinned Codex release.

The Main Agent sends the raw patch through AIGateway as a `custom_tool_call`. The Worker passes it to the native Codex binary through `/usr/local/bin/apply_patch`. Background Agent Jobs get the same freeform tool from the AIGateway model card and use the same binary. Ankole does not keep a separate patch parser.

This shared path keeps normal conversations and Background Agent Jobs on one edit protocol. A patch that does not match fails in the native tool and returns that failure to the model. For a quick search, the shell is fine. Use `apply_patch` for file edits.

## The /workspace filesystem

Agent Home is persistent storage at `/workspace`. The old `/agents/<agent_uid>` path links to it; path checks resolve symbolic links before checking the Home boundary. Its layout is:

```text
/workspace/
├── .codex/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── AGENTS.md
    └── temp/
```

`SOUL.md`, `MISSION.md`, and `DESIGN.md` are durable documents in the [Agent Library](../agent-library/). The first two define responsibility and behavior. `DESIGN.md` is the design system for visual work. `installed-skills/` holds Agent Skills. `sessions/` holds conversation workspaces with stable PostgreSQL-owned numeric IDs that start at 10000, and `jobs/` holds separate Background Agent Job workspaces.

Home survives instance deletion and image changes. A rebuild removes only `/var/cache/ankole`. Docker local volumes depend on their host; a forced Cloudflare stop can lose writes since the last R2 backup. See [Workers](../worker-management/) for provider storage limits.

The control-plane drive separately holds attachments, published files, Skills, and Automation scripts. Use `ankole-files` to read or publish drive files. Job workspaces and Codex threads remain in persistent Home. Before a turn, the Worker brings `installed-skills/` in step with the drive.

Background Agent Jobs load Skills through Ankole `skill_view`; they do not copy Skill roots into the Job workspace.

## Jupyter live kernel for iterative Python

When the work is iterative Python — variables that must persist across executions, a DataFrame you want to inspect cell by cell, or a stateful REPL — the shell is the wrong tool. The `jupyter-live-kernel` skill is the right one. It is a builtin skill (`default_enabled: true`) that runs as a [background job](../background-jobs/), built on Ankole's Unix-socket adapter around hamelnb. The kernel stays alive across executions, so you can define a variable in one step and read it in the next, instead of reloading data every call.

The skill's own guidance is the rule of thumb: prefer a one-shot shell execution for short, stateless Python scripts; prefer this skill when you would normally want a Jupyter notebook or a stateful Python REPL. Data science, DataFrame inspection, notebook editing, and stateful API exploration are its sweet spot. The system Python, JupyterLab, ipykernel, and the hamelnb helper are already in the worker image, so a fresh agent can use the skill without installing anything.

## CodexRunner for Background Agent Jobs

CodexRunner is the execution engine for every Background Agent Job. A Job can research a topic, produce a document, modify a repository, or do other long-running work; its lifecycle, not its subject, selects CodexRunner. The runner talks to the Codex app-server through `app-server-client.ts` and prepares a separate Job workspace and runtime configuration.

Console calls the corresponding model profile **Background Agent Jobs**. Its stored key and API name remain `coding` for now. This is a legacy name, not a rule that detects code-heavy conversations.

## How these paths are selected

The operator surface is narrow:

- **Computer tools** (`command`, `read_file`, and `apply_patch`) ship with every Worker. They are available during normal conversation turns.
- **Jupyter live kernel** is a `default_enabled` skill, so you control it through the [Agent Library](../agent-library/) the same way you control the [browser](../browser-automation/) skill. Narrow it for an agent that should not run iterative Python.
- **CodexRunner** runs every Background Agent Job. Every model call goes through AIGateway. Configure the Background Agent Jobs profile when Jobs need a different provider or model. If it is unset, the control plane uses the Agent's `heavy` profile.

## Next steps

- For the Worker that runs these tools and owns the `/workspace` filesystem, read [Agent Computer Worker](../agent-computer-worker/).
- For the skill and enablement model behind the Jupyter skill, read [Agent Library](../agent-library/).
- For the Background Agent Jobs profile, whose internal key remains `coding`, read [Background Agent Jobs](../background-jobs/#select-the-model-provider).
- For the Worker trust boundary and how to harden it, read [Security hardening](../security-hardening/).
