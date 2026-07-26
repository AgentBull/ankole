---
title: Pull request summaries
description: How to set up an agent that reads a PR's diff and posts a structured summary — what changed, why, impact areas, and review focus — so reviewers start fast.
section: Guides
order: 361
---

A pull request summaries agent reads the diff of each new or updated PR, understands what changed and why, and posts a structured summary so reviewers can start reviewing without reading the full diff first. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **summarizes for the reviewer, it does not review**. It tells you what changed and where to look; it does not tell you whether the change is correct. The value is in reducing the reviewer's ramp-up time — the 5 minutes of "what is this PR even doing?" — not in replacing the review.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`). See [Git integration](../git-integration/).
- **`primary` and `coding` profiles bound** — reading a diff and summarizing its intent requires code comprehension.
- **A signal binding** to the channel where PR summaries post, or a webhook that fires on PR open/update.
- **The repo accessible from the worker.**

## The workflow

1. **A PR event arrives** — webhook, schedule, or human request.
2. **The agent fetches the diff** — `git diff base...head` or the PR API.
3. **The agent reads the diff** — identifies the files changed, the functions modified, the logic added or removed.
4. **The agent reads the PR description and commit messages** — for the intent (why the change was made).
5. **The agent posts a structured summary** — what changed, why, impact areas, and suggested review focus.

## The summary format

```text
**PR #142 — Add webhook retry with backoff**

**What changed**:
- Added retry logic to `src/webhooks/send.ts` (exponential backoff, max 3 retries)
- Added `RetryConfig` type to `src/types.ts`
- Updated tests in `test/webhooks.test.ts`

**Why**: Webhooks to provider X fail intermittently; without retry, the signal is lost.

**Impact areas**: webhook delivery, signal reliability

**Review focus**: the backoff formula (line 45), the max-retry cap, and whether 3 is enough for provider X.
```

The "review focus" is the key value — it tells the reviewer where to spend their attention, not just what changed.

## What the persona controls

- **Summary depth** — "one paragraph" vs "file-by-file breakdown with suggested review focus."
- **What to include** — "always include: what changed, why, impact areas, and 1-3 review-focus points."
- **What not to do** — "do not approve or reject the PR. Do not run tests (that's the QA agent). Summarize only."
- **Linking** — "link to the specific files and lines that need attention, not just the PR URL."

## A worked example

Set up a PR summaries agent triggered by webhook:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`/`coding`.
3. Set up a webhook binding that fires on PR open (through a `signals_gateway.webhook_handler` plugin or a monitoring channel).
4. Author `MISSION.md`: "When a PR opens, fetch the diff. Read the changes and the PR description. Post a structured summary: what changed, why, impact areas, 1-3 review-focus points with file:line links. Do not review or approve."
5. The agent wakes on the webhook, fetches, reads, summarizes, and posts.

## What this guide is not

It is not a code review — the agent summarizes; it does not judge. For judgment, read [Code review workflow](../code-review-workflow/). It is not a CI report — it reads the diff, not the test results. And it is not a changelog entry — it summarizes one PR for reviewers, not the release for users.

## Next steps

- For the code review pattern (judgment, not just summary), read [Code review workflow](../code-review-workflow/).
- For webhook triggers, read [Automation blueprints](../automation-blueprints/).
- For git setup, read [Git integration](../git-integration/).
- For the release notes pattern (user-facing, not reviewer-facing), read [Release notes agent](../release-notes-agent/).
