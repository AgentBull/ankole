---
title: Social media monitor
description: How to set up an agent that monitors social media mentions, classifies sentiment, and escalates when attention is needed — combining web tools, schedules, and Brain memory.
section: Guides
order: 339
---

A social media monitor agent watches for mentions of your brand, product, or keywords across public sources, classifies what it finds, and reports — or stays quiet — based on thresholds the persona defines. This guide is the practical shape of that agent. It is a variant of the [market research agent](../market-research-agent/), focused on social signals rather than competitor strategy.

The decisive property, stated up front: a social monitor is **threshold-driven, not exhaustive**. It scans on a cadence, classifies what it finds, and reports only when a mention crosses a threshold — a spike in volume, a negative-sentiment trend, an influencer mention, or a direct question the team should answer. Everything else is silence.

## What you need

- **`web_search` and `web_fetch` profiles bound.** The agent searches for mentions and reads the posts it finds.
- **`primary` profile bound** — for sentiment classification and threshold judgment.
- **`embedding` profile bound** — Brain recall compares this scan's findings to last scan's, so the agent reports changes, not the full landscape every time.
- **A schedule** — hourly for fast-moving brands, daily for most. See [Cron schedules](../cron-schedules-ops/).

## The workflow

1. **The schedule fires** — the agent runs its search queries.
2. **The agent searches** — `web_search` for the brand name, product names, key hashtags, or competitor comparisons.
3. **The agent fetches** — `web_fetch` on the most relevant results to read the actual posts.
4. **The agent classifies** — sentiment (positive/neutral/negative), volume (is this a spike?), influence (is this from an account that matters?), and actionability (does this need a response?).
5. **The agent decides** — does any mention cross a reporting threshold?
6. **The agent reports or stays silent** — a structured report to the channel, or nothing.

## The thresholds

The persona defines what crosses the threshold:

- **Volume spike** — "if mentions of the brand increased by more than 50% compared to the last scan, report."
- **Negative sentiment** — "if a negative mention is from an account with more than 10k followers, report."
- **Direct question** — "if someone is asking a question about the product that the team should answer, report."
- **Influencer mention** — "if a known influencer or journalist mentions the brand, always report."

Below the threshold, the agent stays silent. This is the same discipline as the [market research agent](../market-research-agent/)'s silent pattern.

## What Brain adds

- **Previous-scan memory** — the agent compares this scan's volume and sentiment to last scan's, so "spike" is relative, not absolute.
- **Influencer list** — a curated knowledge entry of accounts that always warrant a report.
- **Known issues** — if a negative mention matches a known issue in Brain, the agent points to the response rather than escalating blind.

## A worked example

Set up a daily social monitor for a SaaS brand:

1. Bind `web_search`, `web_fetch`, `primary`, `embedding`.
2. Author `MISSION.md`: "Daily, search for 'YourBrand' across social platforms. Classify sentiment, volume, and influence. Report when: volume spiked >50% vs last scan, negative mention from >10k account, direct product question, or influencer mention. Otherwise stay silent. Always include links."
3. Add a daily schedule: `cron: "0 10 * * *"`.
4. Curate Brain knowledge: the influencer list, the known-issues list, the baseline volume from the first scan.

## What this guide is not

It is not a social media management tool — the agent monitors and reports; it does not post, reply, or schedule content. It is not a sentiment API — the agent classifies through its model, not through a dedicated sentiment-analysis service. And it is not a crisis-detection system — it surfaces signals; the team decides whether something is a crisis.

## Next steps

- For the web tools, read [Web tools](../web-tools/) and [Web research](../web-research/).
- For the related market-research pattern, read [Market research agent](../market-research-agent/).
- For Brain memory, read [Brain](../brain/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).
