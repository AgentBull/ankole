---
title: Code execution
description: How an Ankole agent runs code — shell commands under bubblewrap confinement, file read and patch, the apply-patch workflow, the /agents filesystem layout, the Jupyter live-kernel skill for iterative Python, and CodexRunner for code-heavy turns.
section: User guide
order: 31
---

Code execution is what an agent does when it runs commands, edits files, or works through real code to answer a question or finish a task. In Ankole this is a set of computer tools the Agent Computer ships, plus two heavier paths for iterative and code-heavy work: the Jupyter live-kernel skill and the CodexRunner. This page is the operator view of all three.

The decisive property, stated up front: every command runs confined. Shell commands run under bubblewrap with `SYS_ADMIN`, an unconfined seccomp, and an unmasked `/proc` — that is the worker hard requirement, not an operator choice. The agent works inside a per-agent filesystem under `/agents`, and it never escapes that sandbox by way of the shell.

## Shell commands under bubblewrap

The agent runs shell commands through the command tool, backed by `app/agent_computer/src/tools/computer/command-tool.ts` and the bubblewrap confinement in `bubblewrap.ts`. Every command the model requests runs under bubblewrap with `SYS_ADMIN`, an unconfined seccomp policy, and an unmasked `/proc`. The unmasked `/proc` and the `SYS_ADMIN` capability are what make the deeper tools — the [browser](../browser-automation/) daemon, the Jupyter kernel — able to run inside the same confinement rather than being broken out of it. This combination is the worker image's hard requirement, documented in [installation](../installation/) and [platform support](../platform-support/); you do not tune it per agent.

What this means in practice: a shell command can read and write files under the agent's workspace, run installed tools, and start subprocesses the worker image provides. It cannot reach another agent's workspace, and it cannot reach control-plane state. The sandbox is the boundary.

## File read, patch, and apply-patch

Alongside the shell, the computer tools give the agent structured file primitives, each with its own tool in `app/agent_computer/src/tools/computer/`:

- **Read a file** — `read-file-tool.ts`, for inspecting a file's contents directly rather than shelling out to `cat`.
- **Patch a file** — `patch-tool.ts`, for applying a targeted edit to an existing file.
- **apply-patch from the CLI** — `apply-patch-cli.ts`, the apply-patch workflow the agent uses for larger, structured changes.

These primitives exist because a free-form shell edit is brittle — the model can drift on whitespace, repeat a block, or miss a closing brace. The patch tools take a structured edit description, so a failed edit fails cleanly instead of corrupting the file. For a one-line read or a quick `grep`, the shell is fine; for a real edit, the patch tools are the safer path.

## The /agents filesystem

Everything the agent reads and writes lives under `/agents`, laid out per agent key. The agent sees the container path directly — the worker does not translate paths for the model:

```text
/agents/<agent-key>/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── user-files/
├── installed-skills/
├── sessions/<base64url-session-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── .ankole/skills/
    └── temp/
```

The persona documents — `SOUL.md`, `MISSION.md`, `DESIGN.md` — are the agent-owned library documents the [Agent Library](../agent-library/) surfaces. `installed-skills/` holds agent-installed skill bundles. `sessions/` is the per-session workspace, and `jobs/` is the per-job workspace for background work, including the Codex config a code-heavy job uses. File transfer to and from the control plane runs over a dedicated file lane, not over the RPC lane.

## Jupyter live kernel for iterative Python

When the work is iterative Python — variables that must persist across executions, a DataFrame you want to inspect cell by cell, or a stateful REPL — the shell is the wrong tool. The `jupyter-live-kernel` skill is the right one. It is a builtin skill (`default_enabled: true`) that runs as a [background job](../background-jobs-ops/), built on Ankole's Unix-socket adapter around hamelnb. The kernel stays alive across executions, so you can define a variable in one step and read it in the next, instead of reloading data every call.

The skill's own guidance is the rule of thumb: prefer a one-shot shell execution for short, stateless Python scripts; prefer this skill when you would normally want a Jupyter notebook or a stateful Python REPL. Data science, DataFrame inspection, notebook editing, and stateful API exploration are its sweet spot. The system Python, JupyterLab, ipykernel, and the hamelnb helper are already in the worker image, so a fresh agent can use the skill without installing anything.

## CodexRunner for code-heavy turns

For a turn whose core is writing or editing a lot of code, Ankole routes the work through the CodexRunner — the Codex app-server integration in `app/agent_computer/src/tools/codex/`. The runner talks to the Codex app-server through `app-server-client.ts`, with its own sandbox and runtime config, so a code-heavy turn runs against the Codex execution model rather than the plain shell. This is the path the `coding` model profile slot exists to serve; see [Providers and models](../providers-and-models/) for how that slot binds.

The CodexRunner is for sustained, code-shaped work — a refactor, a multi-file feature, a debugging session that needs several tool iterations. For a single command or a quick file read, the shell and the patch tools are cheaper and faster, and the agent should reach for them first.

## How to enable these paths

All three paths are on by default, and the operator surface is narrow:

- **Computer tools** (shell, read-file, patch) ship with every worker — there is no enablement to set. They are available on every turn the Agent Computer runs.
- **Jupyter live kernel** is a `default_enabled` skill, so you control it through the [Agent Library](../agent-library/) the same way you control the [browser](../browser-automation/) skill. Narrow it for an agent that should not run iterative Python.
- **CodexRunner** is wired into the worker and engages when a turn is code-heavy. The thing to configure is the agent's `coding` model profile, so the runner has a model to call; without that binding, a code-heavy turn cannot resolve a model.

## Next steps

- For the worker that runs these tools and owns the `/agents` filesystem, read [Agent Computer](../agent-computer/).
- For the skill and enablement model behind the Jupyter skill, read [Agent Library](../agent-library/).
- For the `coding` profile slot the CodexRunner uses, read [Providers and models](../providers-and-models/).
- For the confinement the worker image requires, read [Installation](../installation/) and [Platform support](../platform-support/).
