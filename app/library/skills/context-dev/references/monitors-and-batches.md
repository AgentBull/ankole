# Monitors and Batches

Two kinds of durable object in the operator's Context account. A monitor repeats on a schedule; a batch runs once and is large. Both return an ID that you must report, because the ID is the only way back to the work.

## Monitors

A monitor watches one target, runs on an interval, and records a change when it finds one. `create-monitor` runs an immediate baseline and returns the monitor. Every later run spends credits, so a monitor that nobody removes keeps spending.

### create-monitor

`name` and `target` are required.

`target` is one of three shapes:

- `{"type": "page", "url": "..."}` watches one page. `instructions` of up to 2000 characters states which changes matter, and it implies semantic detection when `change_detection` is absent. `normalize_whitespace` compares text after whitespace is normalized.
- `{"type": "sitemap", "url": "..."}` watches a sitemap for added and removed URLs. `include` and `exclude` hold up to 50 path patterns each, and `max_urls` bounds the set.
- `{"type": "extract", "url": "...", "instructions": "..."}` watches the relevant pages of a site. Its optional `schema` chooses which pages are tracked, tells the judge which changes matter, and shapes the baseline `data` snapshot on `get-monitor`. It never shapes a change event: change payloads always carry diffs, summaries, and evidence.

`change_detection` is `{"type": "exact"}` for a visible-text diff, or `{"type": "semantic", "confidence_threshold": ...}` for a judged diff. Use `exact` for a price or a version string, and `semantic` for prose that gets reworded.

`schedule` is `{"type": "interval", "frequency": <n>, "unit": "minutes"|"hours"|"days"}`. The product of frequency and unit must be at least 10 minutes and at most 1 year.

`webhook` takes `url`, an optional `secret`, and `events` of `change.detected`, `run.completed`, or both. `change.detected` fires only on a change; `run.completed` fires on every finished run and embeds the change when there is one. The default is `change.detected` alone.

```json
{
  "name": "Example pricing page",
  "target": {
    "type": "page",
    "url": "https://example.com/pricing",
    "instructions": "Report a plan price change or a new plan. Ignore copy edits."
  },
  "change_detection": { "type": "semantic" },
  "schedule": { "type": "interval", "frequency": 12, "unit": "hours" },
  "tags": ["competitor"]
}
```

Pick the longest interval that still meets the need. An hourly monitor spends 24 times what a daily one spends.

### Reading a monitor

- `list-monitors` finds an ID. Filter with `q`, `status`, `target_type`, `change_detection_type`, and `tag`, then follow `cursor`.
- `get-monitor` returns the configuration, the schedule, and the current baseline. It returns no run history.
- `list-monitor-runs` and `get-monitor-run` return execution facts: status, timing, credits, and the change when there is one.
- `list-monitor-changes` returns the changes of one monitor, filtered by `tag`, `since`, and `until`. `list-changes` does the same across the whole account.
- `get-change` returns the full evidence for one change: text diffs, added and removed URLs, semantic evidence, confidence, importance, and the current snapshot.
- `list-account-runs` gives an account-wide activity feed, and `list-monitor-credit-usage` ranks monitors by the credits they spent between `since` and `until`.

List first and read `get-change` only for the changes that matter. A change payload carries diffs and evidence, so it is much larger than its list entry.

### Changing a monitor

`update-monitor` applies to later runs. A new target or a new change-detection definition creates a new baseline, which discards the comparison history. Call `get-monitor` first when the current configuration must survive the edit.

`run-monitor-now` queues one run outside the schedule and returns the queued run. Follow it with `get-monitor-run`.

`delete-monitor` stops all future runs and cannot be undone.

## Batches

A batch scrapes up to 25,000 supplied URLs, or crawls a large site, as an asynchronous job. Use it when a synchronous `web-scrape-markdown` or `web-crawl` would be too large.

### submit-batch

`input` is one of two modes, and each carries a `format` of `markdown` or `html`:

- `{"mode": "scrape", "data": {"format": "markdown", "urls": [...]}}`. Each URL entry takes `url`, an optional `itemId` that comes back with the result, and optional `meta` JSON that returns unchanged. The same URL can appear under different IDs.
- `{"mode": "crawl", "data": {"format": "markdown", "source": {...}}}`. The source describes the site to crawl.

`data.options` carries the same rendering axes as a single scrape. `webhookUrl` receives the completion event, and `tags` label the usage.

`Idempotency-Key` is any string unique to the submission. A retry with the same key returns the original batch instead of starting a second one. Set it before the first attempt, not after a timeout.

```json
{
  "Idempotency-Key": "docs-refresh-2026-08-06",
  "input": {
    "mode": "scrape",
    "data": {
      "format": "markdown",
      "urls": [
        { "url": "https://example.com/a", "itemId": "a" },
        { "url": "https://example.com/b", "itemId": "b" }
      ],
      "options": { "useMainContentOnly": true }
    }
  }
}
```

The call returns a batch ID, not pages.

### Following a batch

`get-batch` returns status, progress, timing, credit accounting, errors, and download links once the batch is complete. Poll it, and wait for a settled status before you read results.

`get-batch-results` pages through the successful and failed URL results. `limit` is 1–100 and defaults to 25, but a page can close early to stay under about 8 MB, so follow `next_cursor` instead of counting records. Write each page to a file, because a full page of Markdown will not survive a pipe.

`list-batches` finds an ID from newest to oldest, filtered by `status`, `q`, and `tags`.

`cancel-batch` stops a queued or running batch from starting more pages. Work in flight finishes, and unused reserved credits return after settlement. It keeps the stored results.

`delete-batch` removes a settled batch and its results, and cannot be undone. An active batch must be cancelled and allowed to settle first.
