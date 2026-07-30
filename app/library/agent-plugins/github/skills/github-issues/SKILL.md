---
name: github-issues
description: "Inspect, create, triage, and update GitHub issues with GitHub CLI."
default_enabled: false
category: github
tags: [GitHub, Issues, Project-Management, Bug-Tracking, Triage]
version: 1.2.1
author: Ankole
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [GitHub, Issues, Project-Management, Bug-Tracking, Triage]
    related_skills: [github-auth, github-pr-workflow]
---

# GitHub Issues

GitHub owns issue state. The task names the repository, issue set, and desired
outcome; current GitHub data supplies the facts. Source `github-auth` first:

```bash
source /repo/app/library/agent-plugins/github/skills/github-auth/scripts/gh-env.sh
test "$GH_AUTH_METHOD" = "gh"
test -n "$GH_OWNER_REPO"
```

Use `--repo "$GH_OWNER_REPO"` when the current directory does not identify the
target repository.

## Read

Read the current issue before classifying or changing it:

```bash
gh issue list --repo "$GH_OWNER_REPO" --state open --limit 100
gh issue list --repo "$GH_OWNER_REPO" --state all --search "<query>"
gh issue view <number> --repo "$GH_OWNER_REPO" \
  --json number,title,body,state,stateReason,author,labels,assignees,comments,url
```

The REST `/issues` endpoint also returns pull requests. `gh issue` keeps issue
work on the issue surface.

## Create

An issue needs a concrete title, enough evidence to reproduce or evaluate it,
and an explicit expected outcome. Use the bundled
[bug report](templates/bug-report.md) or
[feature request](templates/feature-request.md) template when it matches the
task:

```bash
gh issue create --repo "$GH_OWNER_REPO" \
  --title "<title>" \
  --body-file "<prepared-markdown-file>"
```

Labels, assignees, milestones, and projects describe existing repository
policy. Read the available values before selecting them.

## Update

GitHub CLI owns the normal mutations:

```bash
gh issue edit <number> --repo "$GH_OWNER_REPO" --add-label "<label>"
gh issue edit <number> --repo "$GH_OWNER_REPO" --add-assignee "<login>"
gh issue comment <number> --repo "$GH_OWNER_REPO" --body-file "<comment-file>"
gh issue close <number> --repo "$GH_OWNER_REPO" --reason completed
gh issue reopen <number> --repo "$GH_OWNER_REPO"
```

For triage, the useful result is a small set of current issues with justified
category, priority, ownership, and next action. For bulk work, resolve and
review the exact issue numbers before mutation. Re-read changed issues so the
reported state comes from GitHub rather than command intent.
