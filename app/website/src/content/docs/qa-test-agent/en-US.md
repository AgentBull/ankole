---
title: QA test agent
description: How to set up an agent that works through a test backlog, runs the tests, gathers evidence, and hands off failures with enough context for review.
section: Guides
order: 336
---

A QA test agent works through a test backlog — runs the test suite, identifies failures, gathers evidence (logs, screenshots, stack traces), and hands off each failure with enough context for a human to review without reproducing it. This is one of the patterns named in the architecture overview — "a QA agent works through a test backlog, gathers evidence, and hands failures off." This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **runs tests and gathers evidence, it does not fix bugs**. It finds the failure, captures the context, and reports it. A human decides whether to fix it, defer it, or close it as expected behavior. The agent's value is thoroughness and speed of evidence gathering, not diagnostic authority.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`). The agent clones the repo to run the tests. See [Git integration](../git-integration/).
- **`primary` and `coding` profiles bound.** Reading test output and classifying failures requires reasoning.
- **A signal binding** to the channel where test reports post.
- **The worker image** — the test runner (Bun, pytest, mix test, etc.) must be installed in the image. Most standard runners are.

## The workflow

1. **The agent receives a test task** — either from a schedule ("run the full suite nightly"), a webhook ("a PR was merged, run the tests"), or a human ("run the integration tests on branch X").
2. **The agent clones and checks out** — `git clone`, `git checkout <branch>`.
3. **The agent runs the tests** — `bun test`, `pytest`, `mix test`, or whatever the repo declares. It captures the full output.
4. **The agent classifies** — pass or fail. For failures, it reads the stack trace, the test name, and the assertion that failed.
5. **The agent gathers evidence** — the failing test's output, the relevant log lines, the diff from the last known-good commit (if git history allows). For UI tests, a screenshot if the browser skill is available.
6. **The agent reports** — posts a structured failure report: test name, what failed, the evidence, and a link to the commit. It does not propose a fix.

## What the persona controls

- **Scope** — "run the full suite" vs "run only the integration tests" vs "run only tests that touch the payments module."
- **Evidence depth** — "capture the stack trace and the last 50 log lines" vs "capture the full log and a screenshot."
- **Classification** — "classify failures as regression (new failure on a previously passing test), flaky (intermittent), or known (matches an existing issue in Brain)."
- **Reporting** — "post each failure as a separate message with evidence, or batch them into one summary."
- **What not to do** — "do not attempt to fix the failure. Do not modify the test. Report and hand off."

## The failure report

A good failure report the agent posts:

```text
**FAIL: tests/payments/refund.test.ts > "should refund within 24h"**
- **Type**: regression (passed on commit abc123)
- **Error**: AssertionError: expected status 200, got 500
- **Stack**: server.ts:142 → refund handler threw on null customer_id
- **Log**: [last 20 lines of server output]
- **Commit**: def456 (merge of PR #789)
- **Runbook**: Brain entry "refund test failures" (if it matches a known pattern)
```

This gives the human reviewer enough to start debugging without reproducing — the test name, the error, the stack, the log, and the commit that introduced it.

## Delegate the heavy runs

For a large test suite, delegate the test run to a background job (see [Delegation patterns](../delegate-patterns/)). The job runs the suite; the agent classifies and reports when the job completes. A full suite that takes 20 minutes should not block the conversation.

## The known-failure pattern

Maintain a Brain knowledge entry for known failures — tests that fail intermittently (flaky) or fail because of a known unfixed issue. When the agent encounters a failure, it checks Brain: if the failure matches a known pattern, it classifies it as "known" and points to the issue, rather than reporting it as a new regression.

## A worked example

Set up a nightly QA agent for a web app:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`/`light`/`heavy`/`coding` + `embedding`.
3. Author `MISSION.md`: "Run the full test suite nightly on the main branch. For each failure, classify as regression/flaky/known. Gather the stack trace and last 50 log lines. Post each failure as a separate report. Do not fix. Check Brain for known-failure patterns first."
4. Add a nightly schedule: `cron: "0 2 * * *"`.
5. Curate Brain knowledge: known-flaky tests, known-unfixed issues.
6. Each morning, the team reviews the failure reports the agent posted overnight.

## What this guide is not

It is not a CI/CD replacement — CI runs on every push and gates merges; the agent runs on a schedule or on demand and reports to a channel. It is not a bug-fixing agent — it finds and reports; a human fixes. And it is not a test-writing tool — the agent runs existing tests; it does not generate new ones (though it can suggest areas that lack coverage).

## Next steps

- For git setup, read [Git integration](../git-integration/).
- For the shell tools, read [Code execution](../code-execution/).
- For delegation, read [Delegation patterns](../delegate-patterns/).
- For Brain knowledge (known failures), read [Brain](../brain/) and [Brain review](../brain-review-ops/).
