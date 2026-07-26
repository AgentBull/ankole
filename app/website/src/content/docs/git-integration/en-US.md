---
title: Git integration
description: How an Ankole Agent uses git in a normal conversation or a Background Agent Job.
section: Guides
order: 303
---

An Ankole Agent uses standard git commands through the shell tools that the Worker provides. The same tools are available in a normal conversation and in a Background Agent Job.

The decisive property, stated up front: the agent runs git **inside the worker's sandbox**, against the `/agents/<key>/` filesystem. It does not have a special git integration layer — it uses the same shell tools it uses for everything else, and the filesystem is the workspace. The `design-md` skill and the persona carry the conventions; the tools carry the execution.

## What the agent can do with git

Through the `command` tool, the agent runs any git command the sandbox allows:

```bash
git clone https://github.com/your-org/your-repo.git
git checkout -b feature/agent-fix
git add -A && git commit -m "Fix: resolve the null-pointer case"
git push origin feature/agent-fix
```

The agent clones into the workspace (under `/agents/<key>/jobs/<job-id>/` or `sessions/<id>/`), makes changes through file edit and patch tools, commits, and pushes — all through the shell, all under bubblewrap confinement.

During a normal conversation, the Agent uses the foreground shell and file tools. If it delegates the work to a Background Agent Job, the Job runs in its own workspace and can return a result or finish silently. See [Background Agent Jobs](../background-jobs/) for this workflow.

## What you need

- **Git credentials.** In **Console → Environment variables**, store the SSH key or PAT as an encrypted variable such as `GIT_SSH_KEY` or `GIT_TOKEN`. The new value is available from the Agent's next turn. See [Environment variables](../worker-env/).
- **The repo accessible from the worker.** The worker needs network access to the git host. In a private network, confirm the worker can reach the git server.
- **A Background Agent Job runtime, when needed.** The default configuration is enough to start. Configure the Background Agent Jobs profile only when Jobs need a different model or a named ChatGPT subscription account.

## The workspace

Git repos clone into the per-session or per-job workspace:

```text
/agents/<agent-key>/
└── jobs/<job-id>/
    └── your-repo/       # cloned here
        ├── .git/
        └── ...           # the working tree
```

The workspace is persistent on the Agent Home volume — a worker restart does not lose the clone. See [File management](../file-management/) for the layout.

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
- For the filesystem layout, read [File management](../file-management/).
