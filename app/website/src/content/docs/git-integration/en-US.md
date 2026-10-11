---
title: Git integration
description: How an Ankole Agent uses git in a normal conversation or a Background Agent Job.
section: Guides
order: 303
---

An Ankole Agent uses standard git commands through the shell tools that the Worker provides. The same tools are available in a normal conversation and in a Background Agent Job.

The Agent runs git on its own Worker in persistent `/workspace`. It uses the normal shell and file tools. The repository remains when the instance or image changes.

## What the agent can do with git

Through the `command` tool, the agent runs git commands as the Worker's user:

```bash
git clone https://github.com/your-org/your-repo.git
git checkout -b feature/agent-fix
git add -A && git commit -m "Fix: resolve the null-pointer case"
git push origin feature/agent-fix
```

The agent clones into the workspace (under `/workspace/jobs/<job-id>/` or `sessions/<id>/`), makes changes through file edit and patch tools, commits, and pushes — all through the shell, as the Worker's user.

During a normal conversation, the Agent uses the foreground shell and file tools. If it delegates the work to a Background Agent Job, the Job runs in its own workspace and can return a result or finish silently. See [Background Agent Jobs](../background-jobs/) for this workflow.

## What you need

- **Git credentials.** In **Console → Environment variables**, store the SSH key or PAT as an encrypted variable such as `GIT_SSH_KEY` or `GIT_TOKEN`. The new value is available from the Agent's next turn. See [Environment variables](../worker-env/).
- **The repo accessible from the worker.** The worker needs network access to the git host. In a private network, confirm the worker can reach the git server. The Docker Compose deployment puts Worker containers on the `ankole_workers` network, which reaches the control plane and the internet, so a public git host is reachable. With the Helm chart's `networkPolicy.enabled`, Worker Pods reach the control plane, DNS, and public addresses; a git server on a private address is not reachable while its range is in `networkPolicy.workerDeniedCIDRs`.
- **A Background Agent Jobs model profile, when needed.** The default fallback is enough to start. Configure this profile only when Jobs need a different provider or model.

## The workspace

Git repos clone into the per-session or per-job workspace:

```text
/workspace/
└── jobs/<job-id>/
    └── your-repo/       # cloned here
        ├── .git/
        └── ...           # the working tree
```

Repositories under `/workspace` survive Worker replacement and image changes. Keep a remote repository or another backup for recovery from storage loss. Publishing with `ankole-files put` makes files available in the [Agent drive](../file-management/).

## A worked example

Set up a coding agent that reviews PRs:

1. In **Console → Environment variables**, store the PAT as an encrypted variable named `GIT_TOKEN`.
2. Create the Agent and bind its required `primary`, `light`, and `heavy` profiles. Configure Background Agent Jobs separately only if you need to override its fallback.
3. Author a `MISSION.md` that names the repo, the review criteria, and the branch naming convention.
4. In a channel, ask the agent: "Review the latest PR on `your-repo`. Clone, check out, run the tests, report what you find."
5. The Agent clones, checks out, runs tests through `command`, and reports back. It can do this in the conversation or delegate it to a Background Agent Job.

## What this guide is not

It is not a git tutorial — the agent uses standard git commands. It is not a CI/CD integration — Ankole does not run CI; the agent can trigger CI through shell commands if the repo's CI is command-driven. And it is not a code-review automation guide — the agent reviews code the way its persona tells it to, through the shell tools.

## Next steps

- For the shell tools, read [Code execution](../code-execution/).
- For background execution, read [Background Agent Jobs](../background-jobs/).
- For Git credentials, read [Environment variables](../worker-env/).
- For the Agent's drive, read [File management](../file-management/).
