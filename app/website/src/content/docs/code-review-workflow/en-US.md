---
title: Code review workflow
description: How to set up an agent that reviews pull requests — clone, run tests, inspect the diff, and report findings with the right level of human escalation.
section: Guides
order: 329
---

A code review agent watches for PRs, clones the branch, runs the tests, inspects the diff, and reports what it found — escalating to a human when the change is risky or the tests fail. This guide is the practical shape of that workflow, from setup to the review loop.

The decisive property, stated up front: the agent reviews code **through the same shell tools a developer uses** — git, test runners, file reads — guided by its persona and skills. There is no special "code review API"; the agent clones, diffs, and tests, then writes its review as a message. The human decides what to merge.

## What you need

- **Git credentials in WorkerEnv.** Store the PAT or SSH key (`PUT /worker-envs/GIT_TOKEN`). See [Git integration](../git-integration/).
- **The `coding` model profile bound.** Code review benefits from a code-tuned model.
- **A signal binding** to the channel where PR notifications arrive (a webhook, a scheduled check, or a human @-mention).
- **The repo accessible from the worker.**

## The workflow shape

1. **A PR event arrives** — through a webhook (see [Automation blueprints](../automation-blueprints/)), a schedule that checks for open PRs, or a human asking "review PR #42."
2. **The agent clones the branch** — `git clone`, `git fetch origin pull/42/head:pr-42`, `git checkout pr-42`.
3. **The agent runs the tests** — `npm test`, `bun test`, `mix test`, or whatever the repo declares. Test failures are evidence, not opinions.
4. **The agent inspects the diff** — `git diff main...pr-42`, reads the changed files, checks for common issues (missing error handling, untested edge cases, style violations).
5. **The agent reports** — posts a structured review to the channel: what changed, whether tests pass, what it found, and a recommendation (merge, request changes, or escalate to a human).

## What the persona controls

The persona (`MISSION.md`) decides the review's quality and tone:

- **What to check** — naming conventions, error handling patterns, test coverage thresholds, security-sensitive areas.
- **When to escalate** — "if the diff touches authentication, payment, or database migrations, always request a human review."
- **How to report** — structured format (summary, test status, findings by severity, recommendation), not a wall of text.

A code review agent without a scoped persona gives generic advice; one with a persona that names your codebase's conventions gives useful reviews.

## A worked example

Set up a PR review agent for a Bun + TypeScript repo:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`/`light`/`heavy`/`coding`.
3. Author `MISSION.md`: "Review PRs on your-repo. Clone the branch, run `bun test`, inspect the diff. Report: test status, findings (critical/warning/nit), recommendation. Always escalate to a human if the diff touches `auth/` or `migrations/`."
4. Connect the agent to the channel where GitHub PR notifications arrive (through a webhook binding or by having a human @-mention it with the PR number).
5. The agent clones, tests, reviews, and posts the structured review.

## Delegate the heavy work

For a large PR, the agent can delegate the test run or the diff inspection to a background job (see [Delegation patterns](../delegate-patterns/)). The review fires as a `background_agent_job.completed` event; the agent posts the summary when the job finishes. This keeps the conversation responsive while the heavy work runs in the background.

## What this guide is not

It is not a CI/CD replacement — the agent runs tests and reviews code, but it does not gate merges. The human still decides. It is not a linting tool — use your repo's linter for style; the agent checks for things a linter cannot (logic errors, missing edge cases, design concerns). And it is not a substitute for human review on risky changes — the persona should escalate, not auto-approve.

## Next steps

- For git setup, read [Git integration](../git-integration/).
- For the shell tools, read [Code execution](../code-execution/).
- For delegation, read [Delegation patterns](../delegate-patterns/).
- For automation triggers, read [Automation blueprints](../automation-blueprints/).
