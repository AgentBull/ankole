---
title: Context.dev web data
description: Give an Agent bot-resistant page reading, whole-site crawling, schema-shaped extraction, brand profiles, and scheduled change monitoring through the Context.dev API.
section: Guides
order: 307
---

Ankole searches and reads public web pages with `web_search` and `web_fetch`, and drives interactive Chromium sessions with the `browser` Skill. Some tasks still fall outside all three: reading a page that blocks standard fetches, converting an entire documentation site into clean Markdown, extracting web data directly into a JSON Schema that you define, or monitoring a competitor's pricing page over months. The `context-dev` Skill handles those tasks through the [Context.dev](https://context.dev) API.

Because every call spends credits from your Context.dev account, `context-dev` ships disabled by default and stays off until you store an API key and explicitly enable it.

## What an Agent can do with it

Once enabled, describe the outcome you want and let the Agent pick the right Context.dev tool:

```text
Read every page under example.com/docs and give me the API limits in one table.

This pricing page blocks our fetch. Get its plan names and monthly prices.

Give me the logo, brand colors, and LinkedIn page for the domain in this email signature.

Watch example.com/pricing twice a day and tell me when a plan price changes.

Which NAICS code fits stripe.com?
```

Its capabilities span five areas:

- **Reading the live web** — search, single-page scraping to Markdown or HTML, page image inventories, and domain sitemaps, with automatic bot-detection bypass and proxy escalation so pages that reject plain HTTP fetches usually succeed.
- **Whole-site collection** — synchronous crawls of up to 500 pages, or asynchronous batch jobs of up to 25,000 URLs for jobs too large to block on.
- **Schema-shaped extraction** — supply a JSON Schema and receive data directly in that shape instead of prose that the Agent has to parse a second time.
- **Brand and design** — company profiles (logos, brand colors, social links, industry, address, stock listing) resolved from a domain, company name, work email, ticker, card descriptor, or page URL, plus site design systems, font lists, rendered screenshots, and NAICS or SIC codes.
- **Change monitoring** — scheduled monitors that re-check a page, sitemap, or structured extraction at a fixed interval and record diffs, with optional webhook delivery.

## Set it up

### 1. Get an API key

Sign up at [context.dev](https://context.dev) and generate an API key (prefixed with `ctxt_secret_`). Context.dev's free tier includes 500 credits—plenty to verify your setup and run initial tasks.

### 2. Store the key as an environment variable

Open **Console → Environment variables** and create a variable:

- **Name:** `CONTEXT_DEV_API_KEY`
- **Value:** your `ctxt_secret_...` key
- **Encrypted storage:** on

Use the exact name `CONTEXT_DEV_API_KEY`, which the Skill manifest declares. Set it at site or tenant scope to share across Agents, or attach it to a single Agent under **Console → Agents → the Agent → Environment variables** when only that Agent should spend Context.dev credits; see [Environment variables](../worker-env/) for scope precedence.

### 3. Enable the Skill

Open **Console → Agent Library**, locate `context-dev`, and enable it either as a tenant default or per Agent; see [Agent Library](../skills/) for the default-then-override model.

Enabling `context-dev` takes effect on the Agent's next turn, while disabling it removes the MCP connection from subsequent turns, Background Agent Jobs, and Automation Job attempts.

### 4. Confirm it works

Ask an enabled Agent for a small lookup, such as the brand profile of a domain that you know. If the reply reports a `401` error, the key is missing or invalid: confirm that the variable is named `CONTEXT_DEV_API_KEY`, does not show `Not set`, and is not shadowed by an empty Agent attachment or tenant override.

## How Ankole connects

Context.dev hosts an MCP server at `https://mcp.context.dev/mcp`, which `context-dev` declares as a [Skill-backed MCP dependency](../mcp/) so the connection exists only while an enabled execution runs. For each turn, Background Agent Job, or Automation Job attempt, Ankole writes a single-use `mcporter` configuration containing only the `CONTEXT_DEV_API_KEY` variable name—keeping the secret value inside the process environment and out of config files on disk.

While Context.dev's desktop setup docs use interactive browser OAuth—which a headless Worker cannot complete—Ankole authenticates non-interactively via the `Authorization` header supported by the same MCP endpoint.

Rather than registering Context.dev tools directly in every model prompt, the Agent reads the `context-dev` Skill on demand, selects the appropriate tool, and calls it through `mcporter`; see [Use an MCP-backed Skill](../using-mcp/).

## Credits and cost

Context.dev bills in credits according to the operation:

| Work | Credits |
| --- | --- |
| Scrape one page to Markdown or HTML, one sitemap, one image inventory, one parsed file | 1 |
| Web search | 1 for each result, and the smallest result set is 10 |
| Crawl | 1 for each page |
| Screenshot, font list | 5 |
| Brand profile, design system, structured extraction, NAICS, SIC | 10 |

Two practices keep credit spend predictable. First, crawls and searches bill per page or result, so crawling a large site without a cap burns credits quickly—the Skill instructs Agents to set a concrete page budget matching what they will actually read. Second, a change monitor spends credits on every scheduled check until someone deletes it (an hourly monitor costs 24× a daily monitor). Ask the Agent to report the monitor ID whenever it creates one, and scope `CONTEXT_DEV_API_KEY` to specific Agents if you want strict spend control.

## Limits

- **Credits cost real money.** Any open-web research prompt sent to an enabled Agent can invoke `context-dev`; scope `CONTEXT_DEV_API_KEY` to specific Agents when budget isolation matters.
- **Monitors and async batches live in Context.dev, not Ankole.** They outlive the conversation that created them and do not appear in a Console table—ask the Agent to list or delete them through the Skill.
- **Scraped web pages are untrusted input.** Treat extracted web content as untrusted data rather than instructions, especially before forwarding it downstream.
- **Local workspace files do not need `context-dev`.** To read a PDF or image already in the Agent's workspace, use the built-in [`pdf` and `ocr` Skills](../ocr/) locally at zero Context.dev credit cost.

## Next

- Ordinary search and fetch, which stay the first choice: [Web tools](../web-tools/).
- Rendered sessions, logins, and clicks: [Browser automation](../browser-automation/).
- The declaration contract behind this Skill: [MCP server reference](../mcp/).
