---
title: Code lint runner
description: How to set up an agent that runs the project's linter, reads the output, classifies findings, and proposes fixes for the easy ones — with human review for the rest.
section: Guides
order: 358
---

A code lint runner agent runs the project's linter, reads the findings, classifies them (auto-fixable, needs human judgment, false positive), proposes fixes for the auto-fixable ones, and reports the rest for human review. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **fixes the mechanical, reports the judgmental**. A lint finding like "unused import" is mechanical — the agent removes it. A finding like "function has too many parameters" is judgmental — the agent reports it and lets a human decide. The value is in clearing the mechanical noise so the human's review time goes to findings that need thought.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`). See [Git integration](../git-integration/).
- **`primary` and `coding` profiles bound** — reading lint output and classifying findings requires code comprehension.
- **A signal binding** to the channel where lint reports post.
- **The project's linter installed in the worker image** — ESLint, oxlint, RuboCop, Dialyzer, or whatever the repo declares.

## The workflow

1. **A lint task arrives** — scheduled, or after a PR.
2. **The agent runs the linter** — `bun run lint`, `npx eslint .`, `rubocop`, or the repo's lint command.
3. **The agent reads the output** — parses each finding: file, line, rule, severity, and the message.
4. **The agent classifies** — auto-fixable (the linter has a `--fix` for it, or the fix is trivial like removing an unused import), needs judgment (a design concern the linter flags), or false positive (the linter is wrong in this context).
5. **The agent fixes the auto-fixable** — either runs the linter's `--fix`, or applies the fix through `patch`/`apply-patch`.
6. **The agent reports** — the fixed count, and the findings that need human judgment, with file/line/rule/message for each.

## What the persona controls

- **Auto-fix policy** — "auto-fix only what the linter's `--fix` handles. Do not hand-write fixes for lint findings."
- **Judgmental findings** — "report but do not fix: complexity warnings, naming convention violations, and any finding the linter itself does not auto-fix."
- **False positives** — "if a finding is clearly a false positive (the linter's rule does not apply in this context), suppress it with the project's suppression comment and note why."
- **The proof** — "after auto-fixing, run the linter again. All auto-fixed findings must be resolved. Report any that remain."

## The linter's --fix

Most modern linters have a `--fix` mode that handles a large class of findings mechanically:

```bash
npx eslint . --fix        # ESLint
bunx oxlint . --fix       # oxlint
rubocop -A                # RuboCop (auto-correct all)
```

The agent runs the linter with `--fix`, then runs it again without `--fix` to see what remains. What remains is either judgmental or a false positive.

## A worked example

Set up a lint runner for a TypeScript repo:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`/`coding`.
3. Author `MISSION.md`: "Run `bun run lint` on the repo. Auto-fix what the linter's fix mode handles. Run again to confirm fixes. Report remaining findings: file, line, rule, message, and whether it needs human judgment or is a likely false positive. Do not hand-write fixes for judgmental findings."
4. Add a schedule: `cron: "0 6 * * 1-5"` (6 AM weekdays, before the team starts).
5. The agent lints, fixes, re-lints, and posts the report.

## What this guide is not

It is not a style enforcer — the linter enforces style; the agent runs it. It is not a code reviewer — lint findings are mechanical; code review is semantic. And it is not a replacement for the project's lint CI gate — CI blocks on lint; the agent fixes and reports. Use both.

## Next steps

- For git setup, read [Git integration](../git-integration/).
- For the shell tools, read [Code execution](../code-execution/).
- For the code review pattern (semantic, not mechanical), read [Code review workflow](../code-review-workflow/).
- For the refactoring pattern (structural changes), read [Refactoring assistant](../refactoring-assistant/).
