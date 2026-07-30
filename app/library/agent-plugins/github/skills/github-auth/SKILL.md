---
name: github-auth
description: "Establish GitHub CLI authentication from the operator-managed Ankole WorkerEnv token."
default_enabled: false
category: github
tags: [GitHub, Authentication, Git, gh-cli, API]
version: 1.2.1
author: Ankole
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [GitHub, Authentication, Git, gh-cli, API]
    related_skills: [github-pr-workflow, github-issues, github-repo-management, github-webhooks]
---

# GitHub Authentication

Ankole Agent Computer includes GitHub CLI. The operator-managed
`GITHUB_TOKEN` arrives through WorkerEnv for the current turn. The shared
helper validates that token with `gh`, identifies the current GitHub user, and
derives the repository from the `origin` remote when one exists:

```bash
source /repo/app/library/agent-plugins/github/skills/github-auth/scripts/gh-env.sh
test "$GH_AUTH_METHOD" = "gh"
```

After the helper succeeds, `GH_USER` identifies the authenticated account.
Inside a GitHub checkout, `GH_OWNER`, `GH_REPO`, and `GH_OWNER_REPO` identify
the `origin` repository. For work outside a checkout, set those repository
values from the repository named in the task.

The token remains an Ankole runtime credential. Workspace files, Git remote
URLs, GitHub CLI credential storage, shell history, command arguments, and
chat are not credential sources or storage.

The helper is the complete authentication boundary. If it does not set
`GH_AUTH_METHOD=gh`, stop GitHub work and report that the operator must
configure a valid `GITHUB_TOKEN` in WorkerEnv. The Agent Computer can contain
unrelated credentials. Environment listings, files, configuration, auth
stores, and alternate credentials cannot satisfy this contract and can
disclose secrets.
