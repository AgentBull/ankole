---
title: Code formatter
description: How to set up an agent that runs the project's formatter, applies it, and reports what changed — the mechanical side of code style.
section: Guides
order: 360
---

A code formatter agent runs the project's formatter (Prettier, oxfmt, gofmt, mix format), applies the formatting, and reports what changed. This is the simplest code-quality agent — it does one thing mechanically and reports it. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **formats, it does not restyle**. It applies the project's configured formatter verbatim — no opinions, no adjustments, no "I think this looks better." The formatter is the authority; the agent is the hands. If the formatting is wrong, fix the formatter config, not the agent.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`). See [Git integration](../git-integration/).
- **`primary` profile bound** — minimal; the agent mostly runs a command and reads the diff.
- **A signal binding** to the channel where format reports post.
- **The project's formatter installed in the worker image.**

## The workflow

1. **A format task arrives** — scheduled, or before a commit.
2. **The agent runs the formatter** — `bun run fmt`, `npx prettier --write .`, `gofmt -w .`, `mix format`.
3. **The agent reads the diff** — `git diff` to see what the formatter changed.
4. **The agent reports** — file count, line count changed, and whether any file had manual formatting that the formatter overwrote.

## How it differs from the lint runner

| | Formatter | Lint runner |
|---|---|---|
| What it does | applies style (spacing, line length, quotes) | finds code issues (unused vars, complexity) |
| Authority | the formatter config — no opinions | the linter rules — some need judgment |
| Auto-fix | always (formatting is deterministic) | sometimes (`--fix` handles some, not all) |
| Human review needed | rarely (formatting is safe) | often (some findings need judgment) |

A formatter is deterministic — the same input always produces the same output. A linter has judgment calls. The formatter agent is simpler and safer; the lint runner is more valuable but needs tighter persona control.

## What the persona controls

- **The format command** — "run `bun run fmt` (which runs `oxfmt`)."
- **Scope** — "format all files" vs "format only files modified since the last commit."
- **Reporting** — "report the file count and line count. Do not post the full diff — it is noise."
- **Commit behavior** — "do not commit the formatting changes. Leave them in the working tree for the developer to commit."

## A worked example

Set up a formatter agent for a Bun repo:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`.
3. Author `MISSION.md`: "Run `bun run fmt`. Read `git diff --stat` for the summary. Report: files changed, lines changed. Do not commit. Do not post the full diff. If nothing changed, say 'Already formatted.'"
4. Add a schedule: `cron: "0 6 * * 1-5"` (6 AM weekdays).
5. The agent formats, reads the diff stat, and posts the summary.

## What this guide is not

It is not a style enforcer — the formatter enforces style; the agent runs it. It is not a lint runner — formatting is spacing and line shape; linting is code correctness. And it is not a substitute for the project's format CI gate — CI blocks on unformatted code; the agent formats and reports.

## Next steps

- For git setup, read [Git integration](../git-integration/).
- For the shell tools, read [Code execution](../code-execution/).
- For the lint runner (the related, more complex pattern), read [Code lint runner](../code-lint-runner/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).
