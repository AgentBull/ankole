---
title: Context.dev web data
description: Give an Agent bot-resistant page reading, whole-site crawling, schema-shaped extraction, brand profiles, and scheduled change monitoring through the Context.dev API.
section: Guides
order: 307
---

Ankole reads the web with `web_search` and `web_fetch`, and drives a real browser with the `browser` Skill. Some work still falls outside all three: a page that refuses an ordinary fetch, a whole documentation site that must become clean Markdown, a site that must answer in a JSON shape you define, or a competitor page that must be watched for months. The `context-dev` Skill covers that work through the [Context.dev](https://context.dev) API.

The Skill is off by default, and it stays off until you add an API key and enable it. Every call spends credits from your Context.dev account, so the setup is deliberate.

## What an Agent can do with it

Once the Skill is enabled, ask for the result and let the Agent select the tool:

```text
Read every page under example.com/docs and give me the API limits in one table.

This pricing page blocks our fetch. Get its plan names and monthly prices.

Give me the logo, brand colors, and LinkedIn page for the domain in this email signature.

Watch example.com/pricing twice a day and tell me when a plan price changes.

Which NAICS code fits stripe.com?
```

The capability surface has five groups:

- **Reading the live web.** Search, one page to Markdown or HTML, an image inventory of a page, and a sitemap of a domain. Bot-detection bypass and proxy escalation are automatic, so pages that refuse a plain fetch usually answer.
- **Whole-site collection.** A synchronous crawl of up to 500 pages, or an asynchronous batch of up to 25,000 URLs for work that is too large to wait on.
- **Schema-shaped extraction.** You supply a JSON Schema and the Agent gets back data in that shape, instead of prose it has to re-read.
- **Brand and design.** A company profile — logos, colors, socials, industry, address, stock listing — from a domain, company name, work email, ticker, card descriptor, or one page URL. Also a site's design system, its fonts, a rendered screenshot, and NAICS or SIC codes.
- **Change monitoring.** A monitor that re-checks a page, a sitemap, or an extraction on an interval and records what changed, with an optional webhook.

## Set it up

### 1. Get an API key

Sign up at [context.dev](https://context.dev) and create an API key. The key begins with `ctxt_secret_`. The free tier includes 500 credits, which is enough to confirm the setup and try a few tasks.

### 2. Store the key as an environment variable

Open **Console → Environment variables** and create a variable:

- **Name:** `CONTEXT_DEV_API_KEY`
- **Value:** your `ctxt_secret_...` key
- **Encrypted storage:** on

The name must match exactly, because the Skill declares that name and nothing else. Set the variable for all Agents, or set it on one Agent under **Console → Agents → the Agent → Environment variables** when only that Agent should spend the credits. See [Environment variables](../worker-env/) for the scope rules.

### 3. Enable the Skill

Open **Console → Agent Library**, find `context-dev`, and enable it — instance-wide, or for the Agents that need it. See [Agent Library](../skills/) for the default-then-override model.

The Skill takes effect on the Agent's next turn. Disabling it removes the connection from the next turn, the next Background Agent Job, and the next Automation Job attempt.

### 4. Confirm it works

Ask an enabled Agent for something small, such as the brand profile of a domain you know. A `401` in the reply means the key is missing or wrong: check that the variable name is exactly `CONTEXT_DEV_API_KEY`, that it is not shown as "Not set", and that no Agent-level value overrides the global one.

## How Ankole connects

Context.dev publishes an MCP server at `https://mcp.context.dev/mcp`. The `context-dev` Skill declares it as a [Skill-backed MCP dependency](../mcp/), so the connection exists only while an enabled execution runs. Ankole writes a private, single-use mcporter configuration for each turn, Background Agent Job execution, or Automation attempt, and puts only the variable name in that file. The key value stays in the execution environment and never enters the configuration.

Context's own desktop instructions use a browser OAuth sign-in, which a headless Worker cannot complete. Ankole uses the API-key path that the same server supports through the `Authorization` header, so no interactive sign-in is needed.

The server is not registered as a native model tool. The Agent reads the Skill, chooses one tool, and calls it through mcporter. [Use an MCP-backed Skill](../using-mcp/) describes that path.

## Credits and cost

Context.dev bills in credits, and the price depends on the tool:

| Work | Credits |
| --- | --- |
| Scrape one page to Markdown or HTML, one sitemap, one image inventory, one parsed file | 1 |
| Web search | 1 for each result, and the smallest result set is 10 |
| Crawl | 1 for each page |
| Screenshot, font list | 5 |
| Brand profile, design system, structured extraction, NAICS, SIC | 10 |

Two habits control the bill. First, a crawl and a search bill per unit, so an unbounded crawl of a large site is the expensive mistake; the Skill tells the Agent to set a page budget it will actually read. Second, a monitor spends credits at every run for as long as it exists — an hourly monitor costs 24 times a daily one, and nothing stops it until somebody deletes it. Ask the Agent for the monitor ID when it creates one, and review **Console → Environment variables** scope if you want only one Agent to be able to spend at all.

## Limits

- **The credits are real money.** Anything you ask an enabled Agent to research on the open web can reach for this Skill. Scope the environment variable to specific Agents if that matters.
- **Monitors and batches outlive the conversation.** They live in your Context.dev account, not in Ankole. Ankole has no page that lists them; the Agent lists them through the Skill.
- **Results are untrusted input.** A scraped page is web content, not instruction. Ankole treats it that way, and so should you when you forward it.
- **Workspace files do not need this Skill.** For a PDF or an image that is already in the Agent's workspace, the [`pdf` and `ocr` Skills](../ocr/) read it locally and for free.

## Next

- Ordinary search and fetch, which stay the first choice: [Web tools](../web-tools/).
- Rendered sessions, logins, and clicks: [Browser automation](../browser-automation/).
- The declaration contract behind this Skill: [MCP server reference](../mcp/).
