---
title: Web research
description: How to set up an agent that researches the web — the web_search and web_fetch tools, the model profiles, and a worked multi-source research example.
section: Guides
order: 326
---

Web research is one of the most common agent jobs — search for current information, fetch sources, synthesize findings. Ankole's web tools (`web_search` and `web_fetch`) make this possible, and the model profiles control which providers serve it. This guide is the practical shape of a web-research agent, from setup to a worked multi-source example.

The decisive property, stated up front: web research goes through **AIGateway's web tools, not through the browser**. `web_search` finds sources; `web_fetch` reads them. The browser skill is for interactive work (login, screenshots, rendered pages); research is for discovery and text extraction. Use the right tool.

## What you need

- **`web_search` profile bound** — to a provider that serves web search (Jina Search, Bright Data SERP, Parallel, or Agent Bull Cloud). Without it, the agent cannot search.
- **`web_fetch` profile bound** — to a provider that serves web fetch (Jina Reader). Without it, the agent cannot read a fetched page's content.
- **`primary` model profile** — for the synthesis step, where the agent reads what it found and writes the summary.

See [Providers and models](../providers-and-models/) for how to bind these.

## The two tools

| Tool | What it does | When to use |
|---|---|---|
| `web_search` | searches the web for a query, returns results with titles, URLs, and snippets | discovery — "what's out there on X" |
| `web_fetch` | fetches one to five public HTTPS URLs, returns their text content | reading — "read what this source says" |

The agent calls `web_search` to find sources, then `web_fetch` to read the most relevant ones. For a simple question, one search and one fetch is enough; for a deep dive, multiple rounds of search-fetch-synthesize.

## When to use the browser instead

Use the browser skill (see [Browser automation](../browser-automation/)) when:

- the source requires login or interaction to reach the content
- you need a screenshot or rendered page state
- the content is behind JavaScript rendering that `web_fetch` cannot parse

For ordinary discovery and text extraction, `web_search` and `web_fetch` are faster and cheaper.

## A worked example

Set up a research agent that monitors a competitor:

1. Bind `web_search` (to Jina Search) and `web_fetch` (to Jina Reader).
2. Create the agent, author a `MISSION.md`: "Track Acme Corp's product changes. Search for their blog and changelog weekly. Summarize what changed with links."
3. Add a [schedule](../cron-schedules-ops/) that fires weekly.
4. On each fire, the agent searches, fetches the top results, synthesizes a summary, and posts it to the bound channel.

## What this guide is not

It is not a web-scraping tutorial — `web_fetch` reads public HTTPS pages; it does not bypass authentication or rate limits. It is not a browser guide — for interactive work, read [Browser automation](../browser-automation/). And it is not a search-engine reference — the search results depend on the provider you bind.

## Next steps

- For the web tools, read [Web tools](../web-tools/).
- For binding profiles, read [Providers and models](../providers-and-models/).
- For the browser alternative, read [Browser automation](../browser-automation/).
- For scheduling the research, read [Cron schedules](../cron-schedules-ops/).
