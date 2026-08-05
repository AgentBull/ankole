# Web Reading

Search, scrape, crawl, and schema-shaped extraction. Every example is one common shape, not a procedure. Compose calls freely inside the selected tool schema, and use the mcporter call format in `SKILL.md`.

## Pick the Cheapest Shape

| Question | Tool | Cost |
| --- | --- | --- |
| Which pages discuss this? | `web-search` | 1 credit for each result |
| What does this page say? | `web-scrape-markdown` | 1 credit |
| What markup does this page carry? | `web-scrape-html` | 1 credit |
| Which images are on this page? | `web-scrape-images` | 1, 2, or 5 credits |
| Which URLs does this site have? | `web-scrape-sitemap` | 1 credit |
| What do these linked pages say? | `web-crawl` | 1 credit for each page |
| What are the values of these fields? | `web-extract` | 10 credits |
| What do these file bytes say? | `parse-document` | 1 credit, 5 when OCR adds text |

A sitemap first, then a small set of `web-scrape-markdown` calls, is often cheaper and more exact than a crawl. Use `web-extract` when the answer has named fields; use `web-crawl` when you must read prose.

## Shared Rendering Axes

`web-scrape-markdown`, `web-scrape-html`, `web-crawl`, and `web-extract` share these controls:

- `useMainContentOnly`: remove navigation, header, footer, and sidebar. Set it when you want the article.
- `includeSelectors` and `excludeSelectors`: up to 50 CSS selectors each. Exclusion wins over inclusion.
- `includeLinks` (on by default for Markdown), `includeImages` (off by default), `shortenBase64Images`.
- `pdf`: `shouldParse`, an inclusive 1-based `start` and `end` page range, and `ocr` for images inside those pages.
- `includeFrames`: render iframe content.
- `maxAgeMs`: reuse a cached scrape this many milliseconds old. Default 1 day, maximum 30 days, `0` forces a fresh read.
- `waitForMs`: 0–30000 ms of extra render time. `settleAnimations` waits for CSS transitions to stop.
- `headers`: forwarded to the target site. Any header bypasses the cache.
- `country`: a two-letter code that selects the exit country.
- `timeoutMS`: 1000–300000 ms.

`actions` runs up to five ordered steps after load and before capture, either `{"do": "wait", "timeMs": 2000}` or `{"do": "perform", "action": "<instruction under 500 characters>"}`. It needs a paid plan, it raises the call to 2 credits, and it bypasses the cache. Use it for a cookie wall, a "load more" button, or a tab that hides the content.

## web-search

`query` accepts natural language and Google operators. `numResults` is 10–100 and defaults to 10. Narrow the result set with `includeDomains`, `excludeDomains`, and `freshness` (`last_24_hours`, `last_week`, `last_month`, `last_year`). `queryFanout` expands one query into parallel variants for wider recall.

`markdownOptions` is off by default. When you set `enabled: true`, each result is scraped in the same call and carries the shared rendering axes. Read `markdown.code` on every result before you read `markdown.markdown`: only `SUCCESS` promises text, while `NOT_REQUESTED`, `TIMEOUT`, `WEBSITE_ACCESS_ERROR`, and `ERROR` mean there is none.

Each result carries `url`, `title`, `description`, and `relevance` of `high`, `medium`, or `low`.

```json
{
  "query": "postgres logical replication conflict handling",
  "numResults": 10,
  "includeDomains": ["postgresql.org"],
  "markdownOptions": { "enabled": true, "useMainContentOnly": true }
}
```

Scraping every result multiplies the cost by the result count. Search first, choose the pages, then scrape those pages.

## web-scrape-markdown and web-scrape-html

`url` must carry the protocol. Markdown returns `{ success, markdown, url }`; HTML returns `{ success, html, url }`.

```json
{
  "url": "https://example.com/pricing",
  "useMainContentOnly": true,
  "excludeSelectors": ["nav", "footer"],
  "maxAgeMs": 0
}
```

A page that fails renders as `400 WEBSITE_ACCESS_ERROR`. Retry once with a longer `waitForMs`, then report the page as unreadable.

## web-scrape-images

Returns every image source it finds: `img` elements, responsive sources, CSS backgrounds, inline SVG, video posters, and data URIs. Each entry carries `src`, `element`, `type`, and `alt`.

`enrichment` adds `resolution`, `hostedUrl`, and `classification`, with `maxTimePerMs` for each image. Any one of these flags raises the whole call to 5 credits, so request only the ones you will read. `dedupe` keeps the highest-resolution copy of each visually equal group.

## web-scrape-sitemap

`domain` is a bare domain. `maxLinks` defaults to 10,000 and reaches 100,000. `urlRegex` is an RE2 pattern of at most 256 characters, and it filters before `maxLinks` counts. `sitemapUrl` reads exactly one sitemap instead of discovering them.

```json
{ "domain": "example.com", "urlRegex": "^https://example\\.com/docs/", "maxLinks": 500 }
```

The response carries `urls` and a `meta` block with the sitemaps found, fetched, and skipped, plus errors. Read `meta` before you treat a short list as the whole site.

## web-crawl

`url` is the seed. `maxPages` defaults to 100 and stops at 500. `maxDepth` counts links from the seed, where `0` is the seed alone. `urlRegex` limits which links are followed. `followSubdomains` is off by default. `stopAfterMs` is a soft budget of 10000–110000 ms that returns partial results early, while `timeoutMS` is the hard stop.

Each result carries `markdown` and a `metadata` block with `url`, `title`, `crawlDepth`, `statusCode`, and `success`. The top-level `metadata` carries `numUrls`, `maxCrawlDepth`, `numSucceeded`, `numFailed`, and `numSkipped`. A failed page appears with empty `markdown` and `success: false`; a skipped URL is counted and omitted.

```json
{
  "url": "https://example.com/docs/",
  "maxPages": 25,
  "maxDepth": 2,
  "urlRegex": "^https://example\\.com/docs/",
  "useMainContentOnly": true
}
```

You pay for each page the crawl reads, so set `maxPages` to the number you will use.

## web-extract

`url` and `schema` are required. `schema` is a JSON Schema object that defines the shape of `data`. `instructions` of up to 2000 characters says which facts matter. `maxPages` is 1–50 and defaults to 5; `maxDepth`, `followSubdomains`, and `stopAfterMs` bound the crawl the same way as `web-crawl`.

`factCheck` is off by default, which lets the model infer and derive. Set `factCheck: true` when every returned value must come from text on the page; unsupported fields then return null or empty.

```json
{
  "url": "https://example.com",
  "schema": {
    "type": "object",
    "properties": {
      "plans": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "name": { "type": "string" },
            "monthly_price_usd": { "type": "number" }
          }
        }
      }
    }
  },
  "instructions": "Read the pricing page only. Use list prices, not promotions.",
  "factCheck": true,
  "maxPages": 5
}
```

The response carries `data`, `urls_analyzed`, and `metadata`. Check `urls_analyzed` before you trust a null field: the crawl may never have reached the page that holds it.

## parse-document

`fileBase64` holds the file bytes, and the decoded file must be 25 MiB or smaller; a larger body returns `413`. `extension` is a hint such as `pdf`, `docx`, `xlsx`, `pptx`, `html`, `csv`, or `png`. `pdf.start` and `pdf.end` bound an inclusive 1-based page range, and `ocr: true` reads images inside those pages. `ocr: false` also turns off the automatic fallback for a scanned PDF. The call costs 1 credit, and 5 when OCR contributes text.

Encode the bytes into the argument file, and delete that file after the call. Ankole reads PDF, image, DOCX, PPTX, and XLSX files locally through its own Skills and spends no credit, so this tool earns its cost on a format they do not read, such as `.doc`, `.rtf`, `.srt`, or `.xlsb`.
