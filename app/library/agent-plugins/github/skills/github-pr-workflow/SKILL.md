---
name: github-pr-workflow
description: "Inspect and carry out an authorized GitHub pull-request lifecycle."
default_enabled: false
category: github
tags: [GitHub, Pull-Requests, CI-CD, Git, Automation, Merge]
version: 1.2.1
author: Ankole
license: MIT
platforms: [linux, macos, windows]
ankole-runtime: background_job
metadata:
  hermes:
    tags: [GitHub, Pull-Requests, CI/CD, Git, Automation, Merge]
    related_skills: [github-auth]
---

# GitHub Pull Request Workflow

A pull request joins two authorities: the local Git checkout owns the proposed
files and commits, while GitHub owns the PR, reviews, checks, and merge state.
The user's request defines which lifecycle stage is in scope.

Source `github-auth`, then establish both sides of that state:

```bash
source /repo/app/library/agent-plugins/github/skills/github-auth/scripts/gh-env.sh
test "$GH_AUTH_METHOD" = "gh"
test -n "$GH_OWNER_REPO"
git status --short
git branch --show-current
gh pr status --repo "$GH_OWNER_REPO"
```

## Inspect

Use GitHub's current PR object and checks as evidence:

```bash
gh pr view <number> --repo "$GH_OWNER_REPO" \
  --json number,title,body,state,isDraft,baseRefName,headRefName,reviewDecision,statusCheckRollup,url
gh pr diff <number> --repo "$GH_OWNER_REPO"
gh pr checks <number> --repo "$GH_OWNER_REPO"
```

Pending checks are not failures, and a green aggregate does not replace review
of the changed behavior. For a failed GitHub Actions check, read the failed job
log and attribute the failure before editing:

```bash
gh run list --repo "$GH_OWNER_REPO" --branch "<branch>" --limit 10
gh run view <run-id> --repo "$GH_OWNER_REPO" --log-failed
```

The focused failure patterns are in
[CI troubleshooting](references/ci-troubleshooting.md).

## Publish

Keep local Git operations scoped to the intended files and branch. The
[Conventional Commits reference](references/conventional-commits.md) is
available when the repository uses that convention.

```bash
git add <specific-paths>
git commit -m "<message>"
git push -u origin HEAD
gh pr create --repo "$GH_OWNER_REPO" \
  --title "<title>" \
  --body-file "<prepared-markdown-file>" \
  --draft
```

Use the bundled [bug-fix](templates/pr-body-bugfix.md) or
[feature](templates/pr-body-feature.md) body only when it fits the change.
The PR body states the outcome, material design choice, verification, and any
unverified boundary.

## Review and merge

Comments, review requests, and merge operations act on the GitHub PR:

```bash
gh pr comment <number> --repo "$GH_OWNER_REPO" --body-file "<comment-file>"
gh pr edit <number> --repo "$GH_OWNER_REPO" --add-reviewer "<login>"
gh pr ready <number> --repo "$GH_OWNER_REPO"
gh pr merge <number> --repo "$GH_OWNER_REPO" --squash --delete-branch
```

A completed lifecycle has an identifiable branch and commit, a GitHub PR URL,
the required reviews and checks, and the requested terminal state. Report
pending, failed, skipped, or unavailable evidence as such.
