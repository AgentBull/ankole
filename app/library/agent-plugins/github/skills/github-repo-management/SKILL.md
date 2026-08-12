---
name: github-repo-management
description: "Inspect and manage GitHub repositories, settings, releases, workflows, and secrets."
default_enabled: false
category: github
tags: [GitHub, Repositories, Git, Releases, Secrets, Configuration]
version: 1.2.1
author: Ankole
license: MIT
ankole-runtime: background_job
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [GitHub, Repositories, Git, Releases, Secrets, Configuration]
    related_skills: [github-auth, github-pr-workflow, github-issues]
---

# GitHub Repository Management

GitHub is authoritative for repository identity, visibility, settings,
protection, releases, workflows, and stored secret names. The local checkout
is authoritative for its files, commits, branches, and remotes. The requested
outcome must identify the owner and repository before a GitHub mutation.

Source `github-auth`:

```bash
source /repo/app/library/agent-plugins/github/skills/github-auth/scripts/gh-env.sh
test "$GH_AUTH_METHOD" = "gh"
```

Inside a GitHub checkout, `GH_OWNER_REPO` comes from `origin`. Outside one, use
the repository named in the task.

## Repository state

Read the current GitHub object before choosing a mutation:

```bash
gh repo view "$GH_OWNER_REPO" \
  --json nameWithOwner,description,visibility,defaultBranchRef,isArchived,url
gh repo list "$GH_USER" --limit 100
```

Clone and fork operations have direct GitHub CLI forms:

```bash
gh repo clone <owner/repo> [directory]
gh repo fork <owner/repo> --clone
```

Repository creation needs an explicit owner, name, visibility, and source
choice. These commands represent the common shapes:

```bash
gh repo create <owner/name> --public
gh repo create <owner/name> --private --source <local-directory>
gh repo create <owner/name> --template <owner/template>
```

`--push` also publishes local commits, so it belongs only in an outcome that
includes that publication.

## Settings and protection

Repository settings are independent fields. Preserve fields that the task does
not change:

```bash
gh repo edit "$GH_OWNER_REPO" --description "<description>"
gh repo edit "$GH_OWNER_REPO" --enable-issues=true --enable-wiki=false
gh repo edit "$GH_OWNER_REPO" --add-topic "<topic>"
gh api "repos/$GH_OWNER/$GH_REPO/branches/<branch>/protection"
```

Branch-protection writes require the complete desired policy object, because a
partial assumption can replace current repository policy.

## Releases and workflows

Tags, release state, artifacts, workflow inputs, and the selected branch are
part of the requested outcome:

```bash
gh release list --repo "$GH_OWNER_REPO"
gh release create <tag> --repo "$GH_OWNER_REPO" --draft --generate-notes
gh workflow list --repo "$GH_OWNER_REPO"
gh run list --repo "$GH_OWNER_REPO" --limit 20
gh workflow run <workflow> --repo "$GH_OWNER_REPO" --ref <branch>
```

Read the created or changed object after mutation. A draft release, queued
workflow, completed workflow, and successful workflow are distinct states.

## Secrets

GitHub returns secret names and timestamps, never stored values:

```bash
gh secret list --repo "$GH_OWNER_REPO"
printf '%s' "$SECRET_VALUE" | gh secret set <name> --repo "$GH_OWNER_REPO"
gh secret delete <name> --repo "$GH_OWNER_REPO"
```

Secret values belong on standard input. They do not belong in command
arguments, logs, files created for convenience, or the final report.
