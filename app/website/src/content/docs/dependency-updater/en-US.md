---
title: Dependency updater
description: How to set up an agent that checks for outdated dependencies, updates them, runs tests, and opens a PR — the mechanical work of staying current.
section: Guides
order: 350
---

A dependency updater agent checks for outdated packages, updates them to the latest compatible version, runs the test suite, and opens a PR if the tests pass. This is the mechanical work of staying current — work that is tedious for a human and well-suited to an agent. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **updates and verifies, it does not merge**. It bumps the version, runs the tests, and opens a draft PR. A human reviews the changelog and decides whether to merge. The value is in removing the mechanical barrier — "I should update, but I don't have time" — not in replacing the judgment.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`). See [Git integration](../git-integration/).
- **`primary` and `coding` profiles bound** — the agent reads changelogs and assesses breaking changes.
- **A signal binding** to the channel where update PRs are announced.
- **The repo accessible from the worker**, with a lockfile and a test suite.

## The workflow

1. **A schedule fires** (weekly, or on demand).
2. **The agent checks for outdated deps** — `bun outdated`, `npm outdated`, `pip list --outdated`, `cargo outdated`.
3. **The agent reads the changelogs** — for each outdated package, checks whether the latest version has breaking changes (major version bump, deprecations).
4. **The agent updates** — bumps to the latest compatible version (semver-safe for patch/minor; flags major bumps for human review).
5. **The agent runs the tests** — `bun test`, `pytest`, etc. All must pass.
6. **The agent opens a PR** — with the updated lockfile, the list of changes, and the test result.

## What the persona controls

- **Update policy** — "update patch and minor versions automatically. Flag major version bumps for human review — do not update them."
- **Batching** — "one PR per week with all safe updates batched together" vs "one PR per package."
- **Changelog reading** — "read the changelog for each updated package. If a breaking change is mentioned even in a minor bump, flag it."
- **The proof** — "always run the full test suite. If any test fails, revert that package and report."

## The major-version rule

The most important safety rule: **do not auto-update major versions**. A major version bump (1.x → 2.x) can break the build in ways the test suite does not catch (API removals, behavior changes). The agent updates patch and minor versions (semver-safe); for major versions, it reports "package X has a new major version available — review manually" and does not touch the lockfile.

## A worked example

Set up a weekly dependency updater for a Bun repo:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`/`coding`.
3. Author `MISSION.md`: "Every Monday, check for outdated dependencies. Update patch and minor versions. Read changelogs for breaking changes. Run `bun test`. If tests pass, open a PR with the updated lockfile. Flag major version bumps for manual review — do not update them. One PR per week, all safe updates batched."
4. Add a weekly schedule: `cron: "0 7 * * 1"`.
5. The agent checks, reads, updates, tests, and opens the PR.

## What this guide is not

It is not a breaking-change migration tool — the agent updates to compatible versions; migrating to a new major version is a human task. It is not a security patcher — for vulnerability-driven updates, use the [security audit agent](../security-audit-agent/). And it is not a substitute for reviewing the changelog — the agent reads it and flags risks; the human makes the call.

## Next steps

- For git setup, read [Git integration](../git-integration/).
- For the shell tools (`bun outdated`, `bun test`), read [Code execution](../code-execution/).
- For the security audit pattern (vulnerability-driven updates), read [Security audit agent](../security-audit-agent/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).
