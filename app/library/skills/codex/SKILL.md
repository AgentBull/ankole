---
name: codex
description: "Delegate coding to OpenAI Codex CLI (features, PRs)."
default_enabled: true
category: autonomous-ai-agents
tags: [Coding-Agent, Codex, OpenAI, Code-Review, Refactoring]
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [Coding-Agent, Codex, OpenAI, Code-Review, Refactoring]
    related_skills: [claude-code, hermes-agent]
---

# Codex CLI

Delegate coding tasks to [Codex](https://github.com/openai/codex) through BullX Computer. Codex is OpenAI's autonomous coding agent CLI.

## When to use

- Building features
- Refactoring
- PR reviews
- Batch issue fixing

Requires the codex CLI and a git repository.

## Prerequisites

- Codex installed: `npm install -g @openai/codex`
- OpenAI auth configured. In BullX, the preferred path is the encrypted runtime
  credential `skill/codex/auth_json`, materialized by `codex_delegate` to
  `/workspace/temp/.codex/auth.json`.
- **Must run inside a git repository** — Codex refuses to run outside one
- Prefer the native `codex_delegate` tool for delegated coding work. It handles
  credential materialization, prompt files, logs, and final-message capture.
- For direct TTY usage, use `interactive_terminal`, not `terminal`.

## One-Shot Tasks

Use the native tool:

```json
{"prompt":"Add dark mode toggle to settings","workdir":"/workspace/user-files/project"}
```

For scratch work (Codex needs a git repo):
```json
{"prompt":"Build a snake game in Python","workdir":"/workspace/temp/scratch","skipGitRepoCheck":true}
```

## Background Mode (Long Tasks)

```
codex_delegate(prompt="Refactor the auth module", workdir="/workspace/user-files/project", wait=false)
# Returns session_id

# Monitor progress
process(action="poll", session_id="<id>")
process(action="log", session_id="<id>")

# Kill if needed
process(action="kill", session_id="<id>")
```

## Key Flags

| Flag | Effect |
|------|--------|
| `exec "prompt"` | One-shot execution, exits when done |
| `--dangerously-bypass-approvals-and-sandbox` | No sandbox, no approvals. BullX uses the Computer boundary as the safety layer |
| `--sandbox danger-full-access` | No Codex sandbox; useful when the host service context breaks bubblewrap |

## BullX Computer Caveat

When invoking the Codex CLI from BullX Computer, Codex `workspace-write`
sandboxing may fail even when the same command works in an interactive shell. A typical symptom is
bubblewrap/user-namespace errors such as `setting up uid map: Permission denied`
or `loopback: Failed RTM_NEWADDR: Operation not permitted`.

In that context, prefer:

```
codex_delegate(..., bypassApprovals=true)
```

Use process boundaries as the safety layer instead: explicit `workdir`, clean git
status before launch, narrow task prompts, `git diff` review, targeted tests, and
human/agent confirmation before committing broad changes.

## PR Reviews

Clone to a temp directory for safe review:

```
interactive_terminal(action="start", session="codex-review-42", command="bash", workdir="/workspace")
interactive_terminal(action="send", session="codex-review-42", input="REVIEW=$(mktemp -d) && git clone https://github.com/user/repo.git $REVIEW && cd $REVIEW && gh pr checkout 42 && codex exec review --base origin/main", enter=true)
```

## Parallel Issue Fixing with Worktrees

```
# Create worktrees
command(command="git worktree add -b fix/issue-78 /workspace/temp/issue-78 main", workdir="/workspace/user-files/project")
command(command="git worktree add -b fix/issue-99 /workspace/temp/issue-99 main", workdir="/workspace/user-files/project")

# Launch Codex in each
codex_delegate(prompt="Fix issue #78: <description>. Commit when done.", workdir="/workspace/temp/issue-78", wait=false)
codex_delegate(prompt="Fix issue #99: <description>. Commit when done.", workdir="/workspace/temp/issue-99", wait=false)

# Monitor
process(action="list")

# After completion, push and create PRs
command(command="git push -u origin fix/issue-78", workdir="/workspace/temp/issue-78")
command(command="gh pr create --repo user/repo --head fix/issue-78 --title 'fix: ...' --body '...'", workdir="/workspace/temp/issue-78")

# Cleanup
command(command="git worktree remove /workspace/temp/issue-78", workdir="/workspace/user-files/project")
```

## Batch PR Reviews

```
# Fetch all PR refs
command(command="git fetch origin '+refs/pull/*/head:refs/remotes/origin/pr/*'", workdir="/workspace/user-files/project")

# Review multiple PRs in parallel
codex_delegate(prompt="Review PR #86. git diff origin/main...origin/pr/86", workdir="/workspace/user-files/project", wait=false)
codex_delegate(prompt="Review PR #87. git diff origin/main...origin/pr/87", workdir="/workspace/user-files/project", wait=false)

# Post results
command(command="gh pr comment 86 --body '<review>'", workdir="/workspace/user-files/project")
```

## Rules

1. **Prefer `codex_delegate`** — it materializes credentials and captures the final message
2. **Git repo required** — Codex won't run outside a git directory. Use `mktemp -d && git init` for scratch
3. **Use `exec` for one-shots** — `codex exec "prompt"` runs and exits cleanly
4. **Use the Computer boundary** — `bypassApprovals=true` is the default for delegated BullX runs
5. **Background for long tasks** — use `background=true` and monitor with `process` tool
6. **Don't interfere** — monitor with `poll`/`log`, be patient with long-running tasks
7. **Parallel is fine** — run multiple Codex processes at once for batch work
