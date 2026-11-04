---
title: Git integration
description: How an Ankole Agent uses git in a normal conversation or a Background Agent Job.
section: Guides
order: 303
---

An Ankole Agent runs standard `git` commands through the shell and file tools on its own Worker. Because those commands execute inside the Worker's persistent `/workspace` directory, cloned repositories survive Worker restarts, container replacements, and image updates. The same git workflow works both in interactive conversations and in Background Agent Jobs.

## What the agent can do with git

Through the `command` tool, the Agent runs `git` commands as the Worker's user:

```bash
git clone https://github.com/your-org/your-repo.git
git checkout -b feature/agent-fix
git add -A && git commit -m "Fix: resolve the null-pointer case"
git push origin feature/agent-fix
```

The Agent clones the repository into its workspace (under `/workspace/jobs/<job-id>/` or `sessions/<id>/`), modifies files with its editing and patching tools, and commits and pushes through the shell as the Worker's user.

During a normal conversation, the Agent runs these shell and file tools in the foreground. When the task is larger, the Agent can delegate it to a Background Agent Job, which runs in its own isolated job workspace and either returns a summary or finishes silently. See [Background Agent Jobs](../background-jobs/) for details on that workflow.

## What you need

- **Git credentials.** For GitHub (Cloud or Enterprise), connect a GitHub App installation or personal OAuth account in **Pod → Connections** (`Ankole.Connectors`): Ankole automatically injects a turn-scoped `GIT_ASKPASS` credential helper (`POST /api/internal/connectors/git-credentials`) so `git clone`, `git fetch`, and `git push` authenticate over HTTPS without storing static tokens in the Worker environment. For other Git hosts, store an SSH key or personal access token as an encrypted variable such as `GIT_SSH_KEY` or `GIT_TOKEN` in **Console → Environment variables** (see [Environment variables](../worker-env/)).
- **Network access from the Worker to the repository.** Confirm that the Worker can reach your git host, especially on a private network. In a Docker Compose deployment, Worker containers join the `ankole_workers` network, which can reach both the control plane and the public internet. In a Helm deployment with `networkPolicy.enabled`, Worker Pods can reach the control plane, DNS, and public IP addresses, but cannot reach a private git server whose address range falls inside `networkPolicy.workerDeniedCIDRs`.
- **A model profile for Background Agent Jobs, when needed.** Agents inherit Site and Pod model profiles automatically unless overridden, and Background Agent Jobs fall back from `coding` to `heavy` and `primary` across Agent, Pod, and Site scopes, so you only need to set `coding` if Background Agent Jobs require a dedicated provider or model.

## The workspace

The Agent clones git repositories into its per-session or per-job workspace directory:

```text
/workspace/
└── jobs/<job-id>/
    └── your-repo/       # cloned here
        ├── .git/
        └── ...           # the working tree
```

Repositories under `/workspace` survive Worker replacement and image updates, though you should always push to a remote repository or keep a backup to protect against underlying storage loss. When the Agent needs to share build artifacts or deliverables outside `/workspace`, it writes them directly into `/drive` (for example `/drive/ChatDrive` or `/drive/Public`, falling back to `ankole-files put` on Workers where FUSE is unavailable); see [File management](../file-management/).

## A worked example

To set up a coding Agent that reviews pull requests:

1. Connect your GitHub App or personal OAuth account in **Pod → Connections** (or store an SSH key or PAT in **Console → Environment variables** for non-GitHub hosts).
2. Create the Agent—it inherits your Site and Pod model profiles automatically; set Agent-specific overrides or a dedicated `coding` profile only if you want different models for interactive turns or Background Agent Jobs.
3. Configure the Agent's `AGENTS.md` contract in **Meta Ankole → Agents** with the target repository, review criteria, and branch naming conventions.
4. In a connected chat channel, ask the Agent: "Review the latest PR on `your-repo`. Clone, check out, run the tests, and report what you find."
5. The Agent clones the repository, checks out the branch, runs the test suite with `command`, and posts its findings—either directly in the conversation or through a Background Agent Job.

## What this guide is not

This page is not a general `git` tutorial, because the Agent simply runs standard `git` CLI commands. Nor does Ankole act as a built-in CI/CD runner, although an Agent can trigger external CI pipelines from the shell when your repository exposes a CLI or API for them. Finally, rather than enforcing a rigid code-review workflow, Ankole lets you define how the Agent reviews code through its mission instructions and Skills.

## Next steps

- For the shell tools, read [Code execution](../code-execution/).
- For background execution, read [Background Agent Jobs](../background-jobs/).
- For Git credentials, read [Environment variables](../worker-env/).
- For the Agent's drive, read [File management](../file-management/).
