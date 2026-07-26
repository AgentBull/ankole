---
title: Changelog generator
description: How to set up an agent that generates a structured changelog from commit history — grouped by change type, filtered for relevance, and ready for the project's CHANGELOG.md.
section: Guides
order: 357
---

A changelog generator agent reads the commit history since the last release, classifies each change by type (feature, fix, breaking, internal), filters out noise (refactors, test-only, CI), and drafts a structured changelog entry ready for the project's `CHANGELOG.md`. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **generates from evidence, it does not invent**. Every entry in the generated changelog traces back to a specific commit. The agent does not add narrative that the commits do not support, and it does not omit a change that materially affects users. The value is in classification and filtering, not in creative writing.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`). See [Git integration](../git-integration/).
- **`primary` profile bound** — classifying commits and filtering noise requires reasoning.
- **A signal binding** to the channel where the changelog draft posts.
- **Knowledge of the project's changelog format** — whether it follows Keep a Changelog, conventional commits, or a custom format.

## The workflow

1. **A changelog request arrives** — "generate the changelog for v2.3.0," or a schedule that fires before each release.
2. **The agent reads the commit history** — `git log v2.2.0..HEAD --format="%h %s%n%b"` to get every commit since the last release, with their full messages.
3. **The agent classifies** — each commit into: feature (new capability), fix (bug fix), breaking (breaking change), internal (refactor, test, CI, docs — not user-facing), or skip (merge commits, version bumps).
4. **The agent filters** — removes internal and skip entries from the user-facing changelog.
5. **The agent drafts** — groups the remaining entries by type, in the project's changelog format, ready to paste into `CHANGELOG.md`.

## The changelog format

If the project follows Keep a Changelog:

```markdown
## [2.3.0] - 2026-07-26

### Added
- Webhook retry with exponential backoff (#142)
- Dark mode for the settings page (#145)

### Fixed
- Payment refund fails on zero-amount orders (#138)
- Session timeout does not clear the auth token (#143)

### Changed
- API rate limit increased from 100 to 200 requests/minute (#147)

### Removed
- Deprecated `/v1/users` endpoint (#140)
```

The persona names the format and the grouping convention.

## What the persona controls

- **Classification rules** — "a commit is a feature if it adds a new endpoint, UI element, or configuration option. A fix if it resolves an issue or bug. Breaking if it removes, renames, or changes a public API."
- **Filtering** — "exclude commits tagged `internal`, `chore`, `ci`, `test`, or `refactor` unless they affect user-visible behavior."
- **Format** — "follow the Keep a Changelog format. Link to PRs, not individual commits."
- **The ask** — "post the draft and ask for review. Do not commit to CHANGELOG.md directly."

## A worked example

Set up a changelog generator for a release-based repo:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`.
3. Author `MISSION.md`: "On request, read commits since the last tag. Classify: Added, Fixed, Changed, Removed, internal (exclude). Filter out internal and merge commits. Draft in Keep a Changelog format with PR links. Post the draft for review. Do not commit to CHANGELOG.md."
4. In the channel: "Generate the changelog for v2.3.0 (since v2.2.0)."
5. The agent reads, classifies, filters, drafts, and posts.

## Relationship to release-notes-agent

The [release notes agent](../release-notes-agent/) drafts customer-facing notes (blog, newsletter) from the same commit history. This agent drafts the developer-facing `CHANGELOG.md` entry. They read the same source material; they produce different artifacts for different audiences.

## What this guide is not

It is not a commit-message enforcer — the agent works with whatever commit messages exist; it does not reject or rewrite them. It is not a version bumper — the agent generates the entry; the human decides the version number. And it is not the project's `CHANGELOG.md` editor — the agent drafts; the human commits.

## Next steps

- For git setup, read [Git integration](../git-integration/).
- For the release-notes pattern (customer-facing), read [Release notes agent](../release-notes-agent/).
- For the shell tools (git log), read [Code execution](../code-execution/).
- For the Ankole changelog rule itself, read [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md).
