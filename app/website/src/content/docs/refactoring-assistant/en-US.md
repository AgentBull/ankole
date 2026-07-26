---
title: Refactoring assistant
description: How to set up an agent that helps with code refactoring — identifies opportunities, proposes changes, runs tests, and opens a draft PR for human review.
section: Guides
order: 348
---

A refactoring assistant reads a codebase, identifies refactoring opportunities (duplicated logic, dead code, overly complex functions), proposes changes, runs the tests to verify nothing breaks, and opens a draft PR for a human to review. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **proposes and verifies, it does not merge**. It identifies what to change, writes the refactored code, and proves the tests still pass. A human reviews the diff and decides whether to merge. The value is in the mechanical work — finding the duplication, applying the pattern, running the tests — not in the architectural judgment.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`). See [Git integration](../git-integration/).
- **`primary` and `coding` profiles bound** — refactoring requires both reading complex code and writing correct replacements.
- **A signal binding** to the channel where proposals post.
- **The repo accessible from the worker**, with a test suite the agent can run.

## The workflow

1. **A refactoring task arrives** — "refactor the payments module to reduce duplication," or the agent scans for opportunities on a schedule.
2. **The agent reads the code** — identifies the pattern: duplicated logic, a function that does too much, dead code, or a missed abstraction.
3. **The agent proposes a change** — writes the refactored version, keeping the public interface unchanged.
4. **The agent runs the tests** — `bun test`, `pytest`, `mix test`, or whatever the repo declares. Tests must pass before the proposal is posted.
5. **The agent opens a draft PR** — or posts the diff for review, with a summary of what changed and why.

## What the persona controls

- **What to refactor** — "target functions longer than 50 lines, duplicated blocks appearing 3+ times, and dead code identified by unused exports."
- **What not to touch** — "do not refactor public API signatures. Do not change test assertions. Do not rename exported identifiers."
- **The proof** — "always run the full test suite before proposing. If any test fails, revert and report."
- **The style** — "match the existing code style. Use the project's ESLint/Prettier config."

## The safety boundary

A refactoring agent is powerful and potentially destructive. The persona must enforce:

- **Tests are the gate** — no proposal goes out without tests passing. If the test suite is incomplete (no coverage for the refactored code), the agent should say so and propose adding tests first.
- **Public interfaces are stable** — the refactoring changes the implementation, not the contract. If the agent needs to change a public API, it escalates to a human instead.
- **Small, reviewable diffs** — "one refactoring per PR. Do not batch unrelated changes."

## A worked example

Set up a refactoring assistant for a TypeScript repo:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`/`heavy`/`coding`.
3. Author `MISSION.md`: "Refactor the codebase for clarity and reduced duplication. Target: functions >50 lines, duplicated blocks appearing 3+ times. Keep public interfaces unchanged. Run `bun test` before proposing. One refactoring per PR. Match existing style. If tests fail, revert and report."
4. In the channel: "Refactor the `refund` function in `src/payments/` — it's 80 lines and has duplicated validation logic."
5. The agent reads, refactors, runs tests, opens a draft PR with the diff.

## Delegate large refactors

For a large refactoring that touches many files, delegate the mechanical work to a background job (see [Delegation patterns](../delegate-patterns/)). The job applies the pattern across files; the agent reviews the result, runs the tests, and opens the PR when the job completes.

## What this guide is not

It is not an auto-merger — the agent proposes and verifies; a human reviews and merges. It is not an architect — the agent applies known patterns to existing code; architectural decisions (new abstractions, module splits) are the human's. And it is not a substitute for code review — the diff is a proposal; the reviewer checks it against the codebase's intent.

## Next steps

- For git setup, read [Git integration](../git-integration/).
- For the shell tools, read [Code execution](../code-execution/).
- For the coding profile, read [Providers and models](../providers-and-models/).
- For delegation, read [Delegation patterns](../delegate-patterns/).
