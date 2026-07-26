---
title: Code complexity monitor
description: How to set up an agent that measures code complexity over time, identifies trending hotspots, and proposes simplification targets before they become unmaintainable.
section: Guides
order: 363
---

A code complexity monitor agent runs a complexity analyzer on the codebase, tracks which functions and modules are getting more complex over time, and reports the trending hotspots before they become unmaintainable. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **tracks trends, not snapshots**. A single complexity measurement tells you nothing; a trend tells you "this function was 15 cyclomatic complexity six months ago and is 28 now." The value is in detecting the trajectory — the code that is getting worse, not the code that is already bad.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`). See [Git integration](../git-integration/).
- **`primary` profile bound** — identifying which complexity hotspots matter requires reasoning.
- **A signal binding** to the channel where complexity reports post.
- **A complexity tool** — the language's complexity analyzer (see below).

## The complexity tools

| Language | Tool | What it measures |
|---|---|---|
| TypeScript/JavaScript | `complexity-report`, `typhon-cli` | cyclomatic complexity per function |
| Python | `radon cc`, `mccabe` | cyclomatic complexity per function |
| Elixir | `cyclomatic` hex package | cyclomatic complexity per function |
| Rust | `cargo clippy` warnings | cognitive complexity hints |

The agent runs the tool, reads the output, and compares to the previous run's baseline (stored in Brain or a file).

## The workflow

1. **A complexity check fires** — weekly, or after a major change.
2. **The agent runs the complexity analyzer** — per function: cyclomatic complexity, lines of code, parameter count.
3. **The agent compares to baseline** — which functions increased in complexity since the last check?
4. **The agent identifies trending hotspots** — functions whose complexity increased by more than a threshold.
5. **The agent reports** — the trending hotspots, the delta, and a suggested simplification target.

## The trend report

```text
**Complexity trend — <date>**

**Trending up** (complexity increased since last check):
- `processPayment()` in `src/payments.ts`: 18 → 24 (+6). Suggested: extract the validation block.
- `handleWebhook()` in `src/webhooks.ts`: 12 → 17 (+5). Suggested: split the provider switch.

**High but stable** (complex, not getting worse):
- `generateReport()` in `src/reports.ts`: 31 (stable for 3 checks). Not trending — low priority.

**Improved** (complexity decreased):
- `authenticate()` in `src/auth.ts`: 22 → 16 (-6). The recent refactor helped.
```

The "trending up" section is the actionable part — these are the functions that are getting worse and need attention before they cross the maintainability threshold.

## What the persona controls

- **Thresholds** — "report functions with cyclomatic complexity > 15, or any increase > 3 since the last check."
- **Baseline** — "store the baseline in Brain as a knowledge entry. Compare to the last known baseline, not to a fixed target."
- **Scope** — "all source files" vs "only files modified since the last check."
- **What not to do** — "do not refactor. Report the trend and suggest a target. Do not modify the code."

## A worked example

Set up a weekly complexity monitor for a TypeScript repo:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`/`coding` + `embedding` (for baseline recall).
3. Author `MISSION.md`: "Run complexity analysis with `npx typhon-cli src/`. Compare to last week's baseline (stored in Brain). Report functions trending up (increase > 3). Suggest one simplification target per trending function. Do not refactor. Post the report."
4. Add a weekly schedule: `cron: "0 7 * * 1"`.
5. The agent runs, compares, identifies trends, and posts the report.

## What this guide is not

It is not a refactoring tool — the agent reports trends; a human refactors. For refactoring, read [Refactoring assistant](../refactoring-assistant/). It is not a code-quality score — complexity is one dimension; readability, testability, and correctness matter more. And it is not a gate — it reports; the team decides what to act on.

## Next steps

- For git setup, read [Git integration](../git-integration/).
- For the refactoring pattern (fixing complexity), read [Refactoring assistant](../refactoring-assistant/).
- For the shell tools (running complexity analyzers), read [Code execution](../code-execution/).
- For Brain memory (storing baselines), read [Brain](../brain/).
