---
title: Market research agent
description: How to set up an agent that monitors competitors, tracks market changes, and reports what matters — combining web tools, schedules, Brain memory, and the judgment to stay quiet when nothing changed.
section: Guides
order: 334
---

A market research agent monitors competitors, tracks industry changes, and reports when something matters — not on every scan, only when the signal crosses a threshold the persona defines. This guide is the practical shape of that agent, combining web tools, a schedule, Brain memory, and the discipline to stay quiet.

The decisive property, stated up front: a research agent's value is **signal over noise**. It scans regularly but reports selectively. An agent that posts every scan is noise; one that posts only when a competitor changed their pricing, shipped a feature, or made an announcement is signal. The persona defines the threshold; the web tools gather the raw material; Brain holds what was reported last time so the agent can diff.

## What you need

- **`web_search` and `web_fetch` profiles bound.** The agent searches for competitor activity and reads the sources it finds. See [Web tools](../web-tools/).
- **`primary` profile bound** — for synthesis and the "did anything actually change?" judgment.
- **`embedding` profile bound** — Brain recall compares what it finds this scan to what it found last time.
- **A schedule** that fires daily or weekly. See [Cron schedules](../cron-schedules-ops/).
- **A signal binding** to the channel where reports post.

## The workflow

1. **The schedule fires** — daily for fast-moving markets, weekly for slower ones.
2. **The agent searches** — `web_search` for each tracked competitor or topic ("Acme Corp pricing", "Beta Inc product launch", "industry regulatory change").
3. **The agent fetches** — `web_fetch` on the most relevant results to read the actual content.
4. **The agent compares** — Brain recall surfaces what it reported last time. The agent diffs: is this new, or has it already been reported?
5. **The agent decides** — if nothing material changed, stay quiet (the `[SILENT]` pattern). If something changed, draft a report: what changed, why it matters, with links.
6. **The agent posts (or does not)** — a report to the channel, or silence.

## The silent pattern

This is the most important persona rule for a research agent: **silence is a valid outcome**. If the agent scans and finds nothing new, it should not post "no changes detected" — that is noise. It should stay quiet. Only post when there is something to report.

The persona should name this explicitly: "If nothing material changed since the last scan, do not post. Silence is correct."

## What Brain adds

Brain is what makes a research agent improve over scans:

- **Previous-scan memory** — Brain recall surfaces what the agent reported last time, so it can diff instead of repeating itself.
- **Curated context** — the competitor list, the topics to track, the "what counts as material" thresholds, maintained as knowledge entries.
- **Dreaming proposals** — Brain's dreaming reads the scan history and proposes new tracking topics or thresholds. A human reviews them.

## A worked example

Set up a weekly competitor-tracking agent:

1. Bind `web_search` (Jina Search), `web_fetch` (Jina Reader), `primary`, `embedding`.
2. Create the agent, author `MISSION.md`: "Track Acme Corp and Beta Inc weekly. Check their pricing pages, changelogs, and press releases. Report only when something material changes (pricing, new product, acquisition, major hire). If nothing changed, stay silent. Always include links."
3. Add a weekly schedule: `cron: "0 9 * * 1"` (Monday 9 AM).
4. Curate Brain knowledge: the competitor list, their current pricing (as a baseline), the material-change thresholds.
5. On the first run, the agent reports the baseline. On subsequent runs, it diffs and reports only changes.

## Delegate the heavy scans

For many competitors or deep searches, delegate the scanning to a background job (see [Delegation patterns](../delegate-patterns/)). The job does the search-and-fetch loop; the agent synthesizes the diff when the job completes. This keeps the schedule's turn short.

## What this guide is not

It is not a web scraper — `web_search` and `web_fetch` read public pages; they do not bypass authentication or rate limits. It is not a market-intelligence platform — the agent gathers and synthesizes; it does not predict. And it is not a substitute for human judgment on what matters — the persona encodes the threshold; the human tunes it over time.

## Next steps

- For the web tools, read [Web tools](../web-tools/) and [Web research](../web-research/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).
- For Brain memory, read [Brain](../brain/) and [Brain review](../brain-review-ops/).
- For delegation, read [Delegation patterns](../delegate-patterns/).
