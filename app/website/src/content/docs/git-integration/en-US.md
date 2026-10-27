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

- **Git credentials.** In **Console → Environment variables**, store an SSH key or personal access token as an encrypted variable such as `GIT_SSH_KEY` or `GIT_TOKEN`. The Agent receives the updated variable starting on its next turn. See [Environment variables](../worker-env/).
- **Network access from the Worker to the repository.** Confirm that the Worker can reach your git host, especially on a private network. In a Docker Compose deployment, Worker containers join the `ankole_workers` network, which can reach both the control plane and the public internet. In a Helm deployment with `networkPolicy.enabled`, Worker Pods can reach the control plane, DNS, and public IP addresses, but cannot reach a private git server whose address range falls inside `networkPolicy.workerDeniedCIDRs`.
- **A model profile for Background Agent Jobs, when needed.** The default fallback profile is enough to get started, so you only need to configure the `coding` profile if Background Agent Jobs require a dedicated provider or model.

## The workspace

The Agent clones git repositories into its per-session or per-job workspace directory:

```text
/workspace/
└── jobs/<job-id>/
    └── your-repo/       # cloned here
        ├── .git/
        └── ...           # the working tree
```

Repositories under `/workspace` survive Worker replacement and image updates, though you should always push to a remote repository or keep a backup to protect against underlying storage loss. When the Agent needs to share build artifacts or deliverables outside `/workspace`, it can run `ankole-files put` to publish them to the [Agent drive](../file-management/).

## A worked example

To set up a coding Agent that reviews pull requests:

1. In **Console → Environment variables**, store your personal access token as an encrypted variable named `GIT_TOKEN`.
2. Create the Agent and bind its `primary`, `light`, and `heavy` model profiles. Configure the Background Agent Jobs profile only if you want to override its fallback model.
3. Write a `MISSION.md` document that specifies the target repository, review criteria, and branch naming conventions.
4. In a connected chat channel, ask the Agent: "Review the latest PR on `your-repo`. Clone, check out, run the tests, and report what you find."
5. The Agent clones the repository, checks out the branch, runs the test suite with `command`, and posts its findings—either directly in the conversation or through a Background Agent Job.

## What this guide is not

This page is not a general `git` tutorial, because the Agent simply runs standard `git` CLI commands. Nor does Ankole act as a built-in CI/CD runner, although an Agent can trigger external CI pipelines from the shell when your repository exposes a CLI or API for them. Finally, rather than enforcing a rigid code-review workflow, Ankole lets you define how the Agent reviews code through its mission instructions and Skills.

## Next steps

- For the shell tools, read [Code execution](../code-execution/).
- For background execution, read [Background Agent Jobs](../background-jobs/).
- For Git credentials, read [Environment variables](../worker-env/).
- For the Agent's drive, read [File management](../file-management/).
