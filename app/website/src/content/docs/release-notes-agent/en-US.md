---
title: Release notes agent
description: How to set up an agent that watches merged PRs, drafts release notes, and posts them for review — combining git, schedules, and the team channel.
section: Guides
order: 331
---

A release notes agent watches what merged, drafts notes from the commit history and PR titles, and posts a draft for the team to review before publishing. This guide is the practical shape of that agent — combining git access, a schedule, and a channel posting.

The decisive property, stated up front: the agent **drafts, it does not publish**. Release notes are a human-facing artifact with tone, framing, and customer-sensitive filtering. The agent gathers the raw material and writes a draft; a human reviews and ships it. Automating the gathering is the win; automating the judgment is not.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`). See [Git integration](../git-integration/).
- **`primary` and `light` profiles bound.** Drafting is a synthesis job — `primary` for quality, `light` if you want a faster, cheaper draft for internal review.
- **A signal binding** to the team channel where drafts post.
- **A schedule** that fires weekly (or per release cadence). See [Cron schedules](../cron-schedules-ops/).

## The workflow

1. **The schedule fires** — weekly, or on your release cadence.
2. **The agent clones or fetches the repo** — `git log --oneline --since="1 week ago"` to list what merged.
3. **The agent reads the PR titles and commit messages** — `git log --format="%s%n%b" --since="1 week ago"` for detail.
4. **The agent drafts release notes** — grouped by category (features, fixes, breaking changes), with links to the PRs.
5. **The agent posts the draft** to the bound channel, asking for review.

The team reviews, edits, and publishes. The agent's draft is the starting point, not the final product.

## What the persona controls

The persona (`MISSION.md`) decides the draft's quality:

- **Categorization** — what counts as a feature vs a fix vs a breaking change in your project.
- **Tone** — technical for an engineering blog, or accessible for a customer newsletter.
- **Filtering** — "exclude internal refactors, test-only changes, and dependency bumps unless they affect behavior."
- **Links** — link to PRs, not to individual commits.
- **The ask** — "post the draft and ask for review; do not publish without a human approval."

## A worked example

Set up a weekly release-notes agent for a GitHub repo:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`/`light`/`heavy`.
3. Author `MISSION.md`: "Every week, fetch the last week's merged PRs from your-repo. Draft release notes grouped by Features, Fixes, Breaking Changes. Exclude refactors and test-only changes. Link to PRs. Post the draft to the channel and ask for review. Do not publish."
4. Add a weekly schedule (Friday afternoon): `cron: "0 17 * * 5"`.
5. The agent fetches, drafts, posts. The team reviews over the weekend, publishes Monday.

## Delegate the git work

For a repo with many merges, the `git log` and PR-detail fetching can be slow. Delegate it to a background job (see [Delegation patterns](../delegate-patterns/)) — the job gathers the raw material, the agent synthesizes the draft when the job completes.

## What this guide is not

It is not a publishing pipeline — the agent drafts; the human publishes, through whatever channel the team uses (GitHub Releases, a blog, a newsletter). It is not a changelog generator — the project's `CHANGELOG.md` is maintained by the contributors; the agent reads it but does not edit it. And it is not a substitute for human judgment on what to highlight — the agent gathers and categorizes; the human decides the narrative.

## Next steps

- For git setup, read [Git integration](../git-integration/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).
- For delegation, read [Delegation patterns](../delegate-patterns/).
- For the daily-briefing pattern (a related scheduled agent), read [A daily briefing bot](../daily-briefing-bot/).
