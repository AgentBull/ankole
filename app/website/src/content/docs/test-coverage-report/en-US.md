---
title: Test coverage report
description: How to set up an agent that runs the test suite with coverage, identifies uncovered code paths, and proposes test cases for the gaps.
section: Guides
order: 359
---

A test coverage report agent runs the test suite with coverage enabled, reads the coverage output, identifies uncovered code paths (branches, functions, lines), and proposes specific test cases that would close the gaps. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **identifies gaps and proposes tests, it does not write them**. It reads the coverage report, finds the uncovered branches, and suggests what test case would cover each. A human writes the test; the agent does the analysis. The value is in finding the gaps fast and proposing targeted cases, not in generating test code.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`). See [Git integration](../git-integration/).
- **`primary` and `coding` profiles bound** — reading coverage reports and proposing test cases requires code comprehension.
- **A signal binding** to the channel where coverage reports post.
- **The project's coverage tool** — `bun test --coverage`, `npx c8`, `pytest --cov`, or whatever the repo declares.

## The workflow

1. **A coverage task arrives** — scheduled, or after a major change.
2. **The agent runs the tests with coverage** — `bun test --coverage`, `pytest --cov=src`, etc.
3. **The agent reads the coverage report** — identifies files and functions below the threshold, and specific uncovered branches within them.
4. **The agent maps to source** — for each uncovered branch, reads the code to understand what condition is not tested.
5. **The agent proposes test cases** — for each gap: what input would trigger the uncovered branch, what the expected behavior is, and which test file it belongs in.

## The coverage report

```text
**Coverage report — <date>**
**Overall**: 78% lines, 65% branches, 82% functions
**Below threshold** (target: 80% lines, 70% branches):

**`src/payments/refund.ts`** — 62% lines, 50% branches
- Uncovered branch (line 45): `if (amount === 0) return early` — no test sends a zero-amount refund.
  Proposed test: `refund with amount=0 should return immediately without calling the provider.`
- Uncovered function (line 82): `calculatePartialRefund()` — never called in any test.
  Proposed test: `partial refund calculates the prorated amount correctly.`

**`src/auth/token.ts`** — 71% lines, 55% branches
- Uncovered branch (line 30): expired-token path — no test uses an expired token.
  Proposed test: `request with expired token returns 401 with token_expired code.`
```

The report is actionable — each gap has a proposed test case with the trigger input and the expected behavior, not just "line 45 is uncovered."

## What the persona controls

- **Thresholds** — "target 80% line coverage and 70% branch coverage. Report files below the target."
- **Scope** — "all source files" vs "only files modified since the last release."
- **Proposal depth** — "one proposed test per uncovered branch" vs "group small gaps into one proposed test."
- **What not to do** — "do not write the test code. Propose the case. Do not modify the source."

## A worked example

Set up a weekly coverage report agent:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`/`coding`.
3. Author `MISSION.md`: "Run `bun test --coverage`. Read the coverage report. Identify files below 80% line / 70% branch coverage. For each uncovered branch, read the source and propose a test case: trigger input, expected behavior, target test file. Post the report. Do not write tests."
4. Add a weekly schedule: `cron: "0 7 * * 1"`.
5. The agent runs, reads, maps, proposes, and posts the report.

## What this guide is not

It is not a test writer — the agent proposes cases; a human writes the code. It is not a coverage gate — it reports; CI decides whether to block. And it is not a code-quality judge — coverage measures whether code was executed, not whether the tests assert the right things. 100% coverage with weak assertions is worse than 70% coverage with strong ones.

## Next steps

- For git setup, read [Git integration](../git-integration/).
- For the shell tools (running coverage), read [Code execution](../code-execution/).
- For the QA test pattern (running tests, not coverage), read [QA test agent](../qa-test-agent/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).
