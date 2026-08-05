---
name: context-dev
description: "Get web data from Context.dev; when a site must be inventoried, crawled, or collected in a large asynchronous batch; when a site must return JSON in a supplied schema; when a company profile such as logos, colors, socials, industry, address, or stock ticker must be resolved from a domain, company name, work email, ticker, card descriptor, or one page URL; or when a page must be watched on a schedule for changes."
default_enabled: false
category: data
tags:
  - web-data
  - scraping
  - brand
  - extraction
  - mcp
---

# Context.dev

Context.dev turns a URL, a domain, or file bytes into typed JSON. Every call spends credits from the operator's Context.dev account, so select the narrowest tool that answers the question, and keep a result instead of asking for it a second time.

## Select the Owner First

Ankole already owns most of this work. Use the built-in owner when it applies:

| Work | Owner |
| --- | --- |
| Find a page, or read the text of a page that a plain fetch reaches | `web_search`, `web_fetch` |
| Read a PDF or an image that is already in the workspace | `pdf` Skill, `ocr` Skill |
| Click, sign in, or drive one rendered browser session | `browser` Skill |

Route to Context.dev for the work those owners do not cover:

- A page that refuses an ordinary fetch, or that shows its content only after a wait or a click.
- A site inventory, a whole-site crawl, or an asynchronous batch of up to 25,000 URLs.
- A page or site that must answer in a caller-defined JSON Schema.
- A company profile, design system, font list, page screenshot, or NAICS or SIC code.
- A page, sitemap, or extraction that must be watched on a schedule.

## MCP Entry Point

The configured mcporter server is `context-dev`. Use **Tool Selection** below to choose one exact tool before you inspect or call the server.

When the arguments are not already fixed by this Skill and its references, inspect only the selected tool:

```bash
mcporter list 'context-dev.<tool-name>' --schema --json --timeout 360000
```

Write the argument object as JSON to a temporary file, then call the tool without shell interpolation. Send the result to an absolute file path and read that file:

```bash
mcporter call 'context-dev.<tool-name>' --json - --output json --timeout 360000 \
  < /absolute/path/to/arguments.json > /absolute/path/to/result.json
```

Read `result.json`, or reduce it first with `jq` or `python3` when it is large. Remove the argument file and the result file after each call.

mcporter loses most of its own output when stdout is a pipe, and the command tool captures stdout through a pipe. Page Markdown, crawl results, sitemaps, and batch pages are large enough to be cut in the middle of a token with exit code 0 and no error on stderr. Write to a file, and treat a JSON parse failure on mcporter output as this truncation until you prove otherwise.

In an Automation Job, use `Bun.spawn` with the same argv and JSON on stdin, and write stdout to a file. Check the process exit code and read stderr as a failure diagnostic.

Ankole generates `MCPORTER_CONFIG` for each Main turn, Background Agent Job execution, or Automation attempt from this enabled Skill. The declaration fixes the endpoint and names `CONTEXT_DEV_API_KEY`; the value stays in the execution WorkerEnv. A `401` means that variable is empty or wrong, not that the request was malformed.

## Tool Selection

### Web reading

- `web-search`: Search the live web. 1 credit for each result, and `numResults` starts at 10, so one search costs at least 10 credits. `markdownOptions.enabled: true` also scrapes each hit in the same call.
- `web-scrape-markdown`: Turn one known URL into clean Markdown. 1 credit, or 2 with `actions`. This is the default page reader.
- `web-scrape-html`: Return rendered raw HTML. 1 credit, or 2 with `actions`. Use it only when DOM structure, attributes, or scripts are the answer.
- `web-scrape-images`: List the image assets of one page. 1 credit, 2 with `actions`, 5 when any `enrichment` flag is set.
- `web-scrape-sitemap`: Discover the URLs of a domain. 1 credit. It returns URLs only, never page bodies, so use it before you decide what to read.
- `web-crawl`: Follow internal links from one URL and return Markdown for each page in one synchronous call. 1 credit for each page, `maxPages` at most 500. Set `maxPages` to what you will read.
- `web-extract`: Crawl the relevant pages and return data shaped by a JSON Schema. 10 credits, `maxPages` at most 50.
- `parse-document`: Convert base64 file bytes to Markdown. 1 credit, 5 when OCR adds text, and the decoded file must be 25 MiB or smaller. Ankole reads PDF, image, DOCX, PPTX, and XLSX files locally through its own Skills, so reach for this tool only for a format they do not read, such as `.doc`, `.rtf`, or `.srt`.

Read [references/web-reading.md](references/web-reading.md) before you compose any of these calls.

### Brand intelligence

- `brand-retrieve-unified`: Return a structured company profile. 10 credits. All arguments go inside one `body` object whose `type` selects the lookup.
- `get-brand`: Return the same profile for a bare domain as a visual card. 10 credits. Prefer `brand-retrieve-unified` when you need the fields.

### Design, visual, and classification

- `web-styleguide`: Return colors, typography, spacing, shadows, and paste-ready component CSS. 10 credits.
- `web-fonts`: Return the font families of a site with fallbacks and usage share. 5 credits.
- `web-screenshot`: Return a hosted PNG URL for a rendered page. 5 credits.
- `web-naics`: Return 2022 NAICS codes for a domain or company name. 10 credits.
- `web-sic`: Return SIC codes against `original_sic` or `latest_sec`. 10 credits.

Read [references/brand-and-design.md](references/brand-and-design.md) for the `body` union, the returned brand object, and the `domain`/`directUrl` rule.

### Monitors

`list-monitors`, `create-monitor`, `get-monitor`, `update-monitor`, `delete-monitor`, `run-monitor-now`, `list-monitor-runs`, `get-monitor-run`, `list-monitor-changes`, `list-changes`, `get-change`, `list-account-runs`, `list-monitor-credit-usage`.

A monitor is a recurring check that lives in the Context account and spends credits at each run. Use it for change detection over time, not for one reading.

### Batches

`submit-batch`, `list-batches`, `get-batch`, `get-batch-results`, `cancel-batch`, `delete-batch`.

A batch is an asynchronous job for work that is too large for `web-scrape-markdown` or `web-crawl`. `submit-batch` returns an ID, not pages.

Read [references/monitors-and-batches.md](references/monitors-and-batches.md) for both lifecycles.

## Account Writes

`create-monitor`, `update-monitor`, `delete-monitor`, `run-monitor-now`, `submit-batch`, `cancel-batch`, and `delete-batch` change durable state in the operator's Context account, and a monitor keeps spending credits until somebody removes it. Call them for the request the user made, and report the monitor or batch ID that the call returned so the user can find it again.

Treat a submission as non-idempotent. After a timeout or an unclear error, list monitors or batches and read the current state before you retry. `submit-batch` accepts an `Idempotency-Key`; reuse the same key when you retry the same submission.

## Reading Rules

1. Pass a bare domain, such as `stripe.com`, where the tool asks for `domain`. Pass a full `http` or `https` URL where the tool asks for `url` or `directUrl`.
2. A cached answer returns in under a second. A cold answer takes about 7 seconds at p50 and can reach a minute, so raise `timeoutMS` toward its 300000 ms maximum for a first look at a slow site, and keep the mcporter `--timeout` above it.
3. `[N entries omitted]` or `...[truncated]` means the business result is incomplete. Do not analyze it and do not advance a cursor. Ask again with fewer pages, fewer results, or a narrower range.
4. Follow `next_cursor` while the response says more results exist. A page can close early to stay under its size limit, so trust the cursor instead of counting records.
5. Any field can be absent. Check the fields you need before you build an answer on them.
6. Report the URL or domain you read, the tool you called, and any page that failed or was skipped.

## Errors

| Status | Meaning | Next step |
| --- | --- | --- |
| 400 | Malformed input, `WEBSITE_ACCESS_ERROR` for an unreachable or blocked site, or `NOT_FOUND` for no brand match | Fix the input, or report the site as unreadable. `NOT_FOUND` is free |
| 401 | `CONTEXT_DEV_API_KEY` is missing or wrong | Report the variable name and ask the operator to set it in Console |
| 403 | `FORBIDDEN` for a paid-plan feature, or `USAGE_EXCEEDED` | Report the plan or quota limit. Browser `actions` need a paid plan |
| 408 | Cold answer or `timeoutMS` exceeded | Raise `timeoutMS`, or narrow the request |
| 422 | Free or disposable address on an email lookup | Skip enrichment for that address |
| 429 | Rate limit | Wait, then retry with growing delays |

A tool name that the server rejects means the catalog changed. Inspect the selected tool again and use its current replacement.
