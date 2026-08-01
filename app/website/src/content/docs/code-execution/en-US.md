---
title: Code execution
description: How an Ankole Agent runs code in a conversation or as a durable Background Agent Job.
section: Developer guide
order: 122
---

An Agent can run commands and edit files during a normal conversation. It can also delegate durable work to a Background Agent Job. These are separate runtime paths: a conversation uses the Agent Computer Worker's foreground tools, while every Background Agent Job uses CodexRunner. The amount of code in a message does not select between them.

The decisive property, stated up front: every command runs confined. Shell commands run under bubblewrap with `SYS_ADMIN`, an unconfined seccomp, and an unmasked `/proc` — that is the worker hard requirement, not an operator choice. The agent works inside a per-agent filesystem under `/agents`, and it never escapes that sandbox by way of the shell.

## Shell commands under bubblewrap

The Agent runs shell commands through the command tool, backed by `app/agent_computer/src/tools/computer/command-tool.ts` and the bubblewrap confinement in `bubblewrap.ts`. Every command the model requests runs under bubblewrap with `SYS_ADMIN`, an unconfined seccomp policy, and an unmasked `/proc`. The unmasked `/proc` and the `SYS_ADMIN` capability let the [browser](../browser-automation/) daemon and the Jupyter kernel run in the same confinement. This profile is a Worker image requirement documented in [Quick start](../quickstart/#deployment); you do not tune it for each Agent.

What this means in practice: a shell command can read and write files under the agent's workspace, run installed tools, and start subprocesses the worker image provides. It cannot reach another agent's workspace, and it cannot reach control-plane state. The sandbox is the boundary.

## File reads and apply_patch

Alongside the shell, the computer tools give the Agent two file primitives:

- **Read a file** — `read-file-tool.ts`, for inspecting a file's contents directly rather than shelling out to `cat`.
- **Edit files** — `apply-patch-tool.ts`, a freeform `apply_patch` tool that uses the same grammar as the pinned Codex release.

The Main Agent sends the raw patch through AIGateway as a `custom_tool_call`. The Worker passes it to the native Codex binary through `/usr/local/bin/apply_patch`. Background Agent Jobs get the same freeform tool from the AIGateway model card and use the same binary. Ankole does not keep a separate patch parser.

This shared path keeps normal conversations and Background Agent Jobs on one edit protocol. A patch that does not match fails in the native tool and returns that failure to the model. For a quick search, the shell is fine. Use `apply_patch` for file edits.

## The /agents filesystem

Everything the agent reads and writes lives under `/agents`, laid out per agent key. The agent sees the container path directly — the worker does not translate paths for the model:

```text
/agents/<agent-key>/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── user-files/
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── .ankole/skills/
    └── temp/
```

`SOUL.md`, `MISSION.md`, and `DESIGN.md` are durable documents in the [Agent Library](../agent-library/). The first two define responsibility and behavior. `DESIGN.md` is the design system for visual work. `installed-skills/` holds Agent Skills. `sessions/` holds conversation workspaces with stable PostgreSQL-owned numeric IDs that start at 10000, and `jobs/` holds separate Background Agent Job workspaces.

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

- For the Worker that runs these tools and owns the `/agents` filesystem, read [Agent Computer Worker](../agent-computer-worker/).
- For the skill and enablement model behind the Jupyter skill, read [Agent Library](../agent-library/).
- For the Background Agent Jobs profile, whose internal key remains `coding`, read [Background Agent Jobs](../background-jobs/#select-the-runtime).
- For the confinement the Worker image requires, read [Quick start](../quickstart/#deployment).
