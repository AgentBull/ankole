---
title: Git integration
description: How an Ankole agent works with git — the shell tools, the workspace layout, and the CodexRunner path for code-heavy work.
section: Guides
order: 325
---

Ankole agents that do coding work interact with git through the shell tools the worker provides — `command` under bubblewrap, file read and patch, and the CodexRunner for code-heavy turns. This guide is the practical shape of that integration: what the agent can do, what the workspace looks like, and how to set up an agent for git work.

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

For code-heavy turns, the CodexRunner path (see [Codex integration](../codex-integration/)) provides the Codex app-server for structured code work. For lighter edits, the `patch` and `apply-patch` tools handle file changes directly.

## What you need

- **A git credential in WorkerEnv.** Store the SSH key or PAT as a WorkerEnv secret (`PUT /worker-envs/GIT_SSH_KEY` or `GIT_TOKEN`). The worker picks it up on the next turn. See [WorkerEnv management](../worker-env-management/).
- **The repo accessible from the worker.** The worker needs network access to the git host. In a private network, confirm the worker can reach the git server.
- **A `coding` model profile bound.** Code-heavy work benefits from a model tuned for code; bind the `coding` slot if the agent does significant coding.

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

1. Store the git credential: `PUT /worker-envs/GIT_TOKEN` with the PAT.
2. Create the agent, bind `primary`, `light`, `heavy`, and `coding` profiles.
3. Author a `MISSION.md` that names the repo, the review criteria, and the branch naming convention.
4. In a channel, ask the agent: "Review the latest PR on `your-repo`. Clone, check out, run the tests, report what you find."
5. The agent clones, checks out, runs tests through `command`, and reports back.

## What this guide is not

It is not a git tutorial — the agent uses standard git commands. It is not a CI/CD integration — Ankole does not run CI; the agent can trigger CI through shell commands if the repo's CI is command-driven. And it is not a code-review automation guide — the agent reviews code the way its persona tells it to, through the shell tools.

## Next steps

- For the shell tools, read [Code execution](../code-execution/).
- For the CodexRunner path, read [Codex integration](../codex-integration/).
- For storing git credentials, read [WorkerEnv management](../worker-env-management/).
- For the filesystem layout, read [File management](../file-management/).
