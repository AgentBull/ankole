---
title: Code execution
description: How an Ankole Agent runs code in a conversation or as a durable Background Agent Job.
section: Developer guide
order: 122
---

An Agent can run commands and edit files inline during a conversation, or delegate long-running work to a Background Agent Job. Those two modes use separate runtime paths—conversation turns call foreground tools on the Agent Computer Worker, whereas every Background Agent Job runs through CodexRunner—chosen by the task's lifecycle rather than how much code appears in a message.

Every Agent command executes on that Agent's dedicated computer: an isolated Worker container where `/workspace` mounts Agent Home and commands run as the Worker user without a nested inner sandbox. While an Agent may freely modify its own Worker environment, it never shares a Worker container, cache disk, or credentials with any other Agent. By contrast, Pod Applet backend functions and AIGateway or Workflow Programmatic Tool Calling (PTC) scripts execute inside stateless isolates on `ankole-function-runtime` rather than on the Agent Computer Worker.

## Shell commands

Foreground turns execute shell commands through the `command` tool (`app/agent_computer/src/tools/computer/command-tool.ts`). Each command spawns in its own process group under the Worker user (`uid` `1000`, without `sudo`) with a clean environment stripped of the Worker credential, a working directory inside Agent Home, and a default 180-second foreground timeout—cancelling or timing out terminates the entire process group. The [browser](../browser-automation/) daemon, Codex app-server, and Automation scripts likewise run as the Worker user without requiring elevated kernel privileges.

Running as `uid` `1000` allows commands to write inside Agent Home, install user-space packages, and spawn subprocesses, while preventing system-level OS package installation. Sessions and Jobs belonging to one Agent share `/workspace`, while container boundaries isolate different Agents, and Workers hold neither database connections nor object-store credentials.

## File reads and apply_patch

Alongside shell execution, the Worker provides two dedicated file tools:

- **Read a file** — `read-file-tool.ts`, for reading file contents directly without shelling out to `cat`.
- **Edit files** — `apply-patch-tool.ts`, a freeform `apply_patch` tool sharing the exact patch grammar of the pinned Codex release.

During foreground turns, the main Agent sends raw patches through AIGateway as a `custom_tool_call`, which the Worker passes to the native Codex binary at `/usr/local/bin/apply_patch`; Background Agent Jobs receive the same freeform tool from the AIGateway model card and invoke the same binary.

Sharing one native binary keeps interactive turns and Background Agent Jobs on a single edit protocol: if a patch fails to match, the native binary rejects it cleanly and returns the error to the model. Use shell commands for quick searches and `apply_patch` for file edits.

## The /workspace filesystem

Each Agent's persistent Home directory mounts at `/workspace`, with `/agents/<agent_uid>` symlinked to `/workspace`. Path checks resolve all symbolic links before enforcing the Home boundary. Its layout is:

```text
/workspace/
├── .codex/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── ConfidentialityPolicy.md
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── AGENTS.md
    └── temp/
```

At the root, `SOUL.md`, `MISSION.md`, `DESIGN.md`, and `ConfidentialityPolicy.md` mirror the durable documents managed in the [Agent Library](../agent-library/): the first two define behavior and responsibilities, `DESIGN.md` specifies the design system for visual work, and `ConfidentialityPolicy.md` guides audience selection when writing to Brain. Alongside them, `installed-skills/` holds Agent Skills, `sessions/` holds conversation workspaces keyed by stable PostgreSQL numeric IDs starting at `10000`, and `jobs/` holds isolated Background Agent Job workspaces.

Agent Home survives instance deletion and container image updates—rebuilding a Worker clears only `/var/cache/ankole`. Storage durability follows the backing provider: local Docker volumes rely on the host disk, whereas forcing a Cloudflare Worker stop can lose writes made since the last R2 backup; see [Workers](../worker-management/) for provider storage limits.

Attachments, published files, Skills, and Automation scripts live separately in the control-plane Files drive. Agents run `ankole-files` to read from or publish to that drive and `ankole-pod` to read or update Pod pages, Base tables, and Applets through the control plane, while Job workspaces and Codex threads stay in persistent Home. Before starting a turn, the Worker synchronizes `installed-skills/` with the drive, and Background Agent Jobs load Skills on demand via `skill_view`.

## Jupyter live kernel for iterative Python

When a task requires stateful, iterative Python—keeping variables alive across steps, inspecting a DataFrame cell by cell, or exploring an API interactively—one-shot shell commands are the wrong fit. Instead, Agents use the `jupyter-live-kernel` Skill (`default_enabled: true`), which runs inside a [Background Agent Job](../background-jobs/) over Ankole's Unix-socket adapter around `hamelnb`. Because the Python kernel stays resident across cells, the Agent can load data once and iterate without re-importing or re-reading files on every step.

Follow the Skill's own rule of thumb: run short, stateless Python scripts directly in the shell, and reach for `jupyter-live-kernel` whenever you would naturally open a Jupyter notebook or stateful REPL—data science, DataFrame inspection, `.ipynb` editing, and interactive exploration. System Python, JupyterLab, `ipykernel`, and `hamelnb` come preinstalled in the Worker image, so Agents can start immediately with zero setup.

## CodexRunner for Background Agent Jobs

CodexRunner executes every Background Agent Job—whether a Job researches a topic, drafts a document, edits a repository, or performs other multi-step work, its background lifecycle (rather than its subject matter) routes it to CodexRunner. Communicating with the Codex app-server through `app-server-client.ts`, CodexRunner provisions an isolated Job workspace and runtime config.

In the Console, the corresponding model profile appears as **Background Agent Jobs**, stored in PostgreSQL and the API under the key `coding`.

## How these paths are selected

Operators govern these execution paths through three straightforward controls:

- **Computer tools** (`command`, `read_file`, and `apply_patch`) ship in every Worker and are available during foreground conversation turns.
- **Jupyter live kernel** is a `default_enabled` Skill managed in the [Agent Library](../agent-library/) just like the [browser](../browser-automation/) Skill; disable it per Agent whenever an Agent should not run stateful Python sessions.
- **CodexRunner** drives every Background Agent Job, routing all model calls through AIGateway. Configure the **Background Agent Jobs** (`coding`) profile when Jobs need a dedicated provider or model; if left unset, the control plane falls back to the Agent's `heavy` profile.

## Next steps

- For the Worker that runs these tools and owns the `/workspace` filesystem, read [Agent Computer Worker](../agent-computer-worker/).
- For the skill and enablement model behind the Jupyter skill, read [Agent Library](../agent-library/).
- For the Background Agent Jobs profile, whose internal key is `coding`, read [Background Agent Jobs](../background-jobs/#select-the-model-provider).
- For the Worker trust boundary and how to harden it, read [Security hardening](../security-hardening/).
