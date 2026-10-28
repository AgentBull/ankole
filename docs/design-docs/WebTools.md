# Web Tools

Both control-plane conversation tools and Codex Job tools expose two web tools:
`web_search` searches the public web, and `web_fetch` extracts readable text
from web pages.

For interactive clicks, screenshots, or authenticated sessions with saved login
state, Agents use the Browser Skill inside a `BackgroundAgentJob`. The
`ankole-browser` daemon backs both the rendered `web_fetch` fallback and the
interactive Browser Skill.

## Which Component Does What

AIGateway manages provider selection, credentials, and the `/web_search` and
`/web_fetch` HTTP endpoints. Provider credentials never leave AIGateway: Agent
Computer authenticates with an Agent-scoped AIGateway key and requests providers
through the semantic `web_search.default` and `web_fetch.default` selectors.

The Elixir control plane owns foreground tool schemas, provider dispatch,
cancellation, paginated result windows, the run-local page cache, and the
`security.ssrf_filter` and `agent_workers.rendered_fetch_idle_ttl_ms` settings. Agent
Computer owns the rendered `web_fetch` fallback and the web-tool implementations
for Codex Jobs.

On the Worker, `ankole-browser` manages browser sessions and extracts text from
rendered pages, addressing each session by an opaque route ID without any
knowledge of Agents, Jobs, Principals, or control-plane database records. During
execution preparation, Agent Computer binds rendered fetch to the resolved
Worker environment before stripping raw browser configuration variables from
shell command environments. Each rendered fetch allocates a temporary route that
stays separate from a Codex Job's persistent browser route.

For URL safety, the control plane calls the Rust kernel to classify URLs before
provider fetches, while `ankole-browser` validates rendered-fetch URLs inside
its browser runtime.

## `web_search`

Both foreground and Codex Job tool catalogs accept a single nonempty `query`
without advertising a character cap in the model-visible JSON Schema; AIGateway
rejects trimmed queries longer than 500 characters before calling the upstream
provider. Callers can also pass an optional `limit` from `1` through `100`
(default `5`).

When a search provider is configured, `web_search` dispatches the query to the
provider selected by AIGateway and returns result titles, URLs, and short
snippets. If no search provider is configured, the tool returns an explanatory
message stating why search is unavailable.

## `web_fetch`

`web_fetch` accepts between one and five `https://` page URLs and returns
readable text rather than raw binary bytes. It is not intended for PDFs,
archives, images, audio, video, or executables—Agents use the command tool for
explicit file downloads.

Both foreground Sessions and Codex Jobs call AIGateway first with the
`web_fetch.default` selector. If that selector has no configured provider or the
upstream fetch fails, execution falls back to rendered extraction on the Worker
(labeled `rendered_fallback` in the response `source` field). Both paths return
each page's URL, title, extracted text or error message, and `source`, without
exposing browser endpoints, credentials, daemon process details, or local
renderer state to the model.

## Keep Page Text Inside a Fixed Budget

In foreground Sessions, `web_fetch` slices output to fit the byte budget for
control-plane tool results. When a page exceeds that window, the response
includes `next_offset` so the Agent can call `web_fetch` again with the same URL
and `result_offset` to read the next segment. Full page text stays in the run's
in-memory page cache—refetched if recovery restarts the run—so foreground calls
need no workspace file.

Codex Jobs enforce a 40,000-character call budget backed by workspace files.
Because page text is unbounded, untrusted input that replays on every turn
iteration until compaction shrinks it to roughly 2,000 tokens, returning an
unbounded page directly would bill the same text repeatedly before discarding
it.

That 40,000-character budget is shared across the entire `web_fetch` call rather
than fixed per URL: any page that fits within an equal share is returned in
full, and larger pages split whatever budget the smaller pages leave unused. A
single-URL call can therefore use all 40,000 characters, while a five-URL batch
still gives every URL a usable window.

When a page exceeds its share, Agent Computer keeps its head and tail cut cleanly
on line boundaries, writes the complete page (up to 2,000,000 characters) to
`<workspace>/temp/web-fetch/<host>-<hash>.md`, and prepends a header above the
excerpt showing the returned size, total size, file path, and exact `read_file`
call needed to inspect the omitted middle. Placing that note at the top ensures
it survives Codex Job projections, which keep the head of a tool output and
truncate the tail. If writing the workspace file fails, the fetch still returns
bounded text and notes in the header that the full file is unavailable.

The workspace file is the sole owner of the complete page text: tool-result
metadata records only the URL, title, character counts, and file path without
duplicating the body. Because the file is rebuildable worker-local state, no
durable control-plane record depends on it.

## Read a Page in a Browser When Fetch Fails

When `web_fetch` falls back to browser rendering, Agent Computer allocates an
in-memory temporary route and sends a `fetch` command over the Worker's daemon
socket carrying the route, session, resolved backend material, and artifact
root—without writing a material file to disk. Each client request enforces a
300-second deadline and an 8 MiB response cap, closing the socket immediately on
cancellation.

Inside `ankole-browser`, a batch accepts up to five URLs, opens at most two
pages concurrently, and enforces a fixed per-URL timeout. For each page, the
browser waits for the main document navigation to commit—without waiting for
`DOMContentLoaded`—and then waits briefly for visible text to stabilize. Partial
failures do not discard sibling pages, and returned entries preserve the caller's
request order.

If rendered extraction fails, Agent Computer logs the backend kind, failure
stage, error code, retryability flag, failed URL index, URL scheme and host, and
the first error line (truncated to 500 characters with endpoint URLs and common
credential headers redacted), while surfacing the browser's diagnostic message
in the tool result so the Agent can inspect what went wrong.

Once the call finishes—whether by succeeding, failing, or cancelling—the Worker
purges the temporary route and deletes its artifact directory; if cleanup fails,
Agent Computer restarts the browser daemon and retries the purge once. Temporary
routes live strictly in Worker memory with no PostgreSQL footprint, and
`agent_workers.rendered_fetch_idle_ttl_ms` (default 30 minutes, configurable from 5
minutes through 24 hours without changing the model schema) bounds how long an
idle route may linger before automatic eviction.

## Use the Browser Skill for Interactive Work

Every Codex Job receives the built-in Browser capability. Before launching the
Codex app server, Agent Computer provisions a persistent browser route for the
Job, injects only the reserved `ANKOLE_BROWSER_*` variables and a read-only
connection file into the Job sandbox, and strips the raw backend environment
variables. Neither Codex nor user scripts can choose backend credentials or
reassign route ownership; the route record holds only opaque resume tokens and
hashes, while browser profiles and reconnect state stay local to the Worker so
subsequent turns can reuse authenticated sessions.

Through the Browser Skill, both the preconfigured `ankole-browser` CLI and
Playwright scripts attach to the same default browser session:

- `snapshot` returns Playwright's AI accessibility snapshot. Passing `-i`
  extracts interactive controls and pointer-cursor elements from Playwright's
  JSON tree before applying the output budget, so verbose static copy never
  crowds out actionable controls.
- Each snapshot captures element references (`@eN`, or `@f1e3` inside iframes),
  and subsequent commands resolve refs against the latest snapshot; if a ref is
  unknown or its DOM node has detached, the command returns `stale_ref`.
- When given an explicit selector, text and interactive snapshots wait for that
  selector to attach within the remaining command timeout, returning a retryable
  `timeout` if it does not appear in time.

In short, use `web_fetch` to read page text, and use the Browser Skill for UI
interaction, screenshots, persistent login sessions, and repeatable Playwright
scripts.

## Block Unsafe URLs

Model tool schemas accept only `https://` URLs, and the rendered fallback
re-validates every URL before opening it. Across all environments, Ankole
always blocks cloud-metadata hostnames (including trailing-dot variants) and
metadata IP ranges; operators can also set `security.ssrf_filter` to `true`
(default `false` so enterprise intranet pages work out of the box) to block
private and loopback networks as well.

URL parsing, host classification, and SSRF admission live in the Rust kernel—loaded
as a NIF in Elixir and as a Node-API addon in `ankole-browser`—and share the
canonical test suite in
`app/kernel/test/vectors/web_url_host_classification.json`. Callers pass the
allowed schemes and private-network flag; invalid IP literals and empty DNS
responses fail admission. The Lark image resolver reuses the same Rust admission
checks via its Req/Finch adapter, connecting directly to the verified IP while
preserving the original `Host` header and TLS SNI hostname and re-checking every
HTTP redirect.

For local Chromium instances, web TCP connections route through a loopback Rust
SOCKS5 proxy:

- The proxy resolves DNS, validates every returned IPv4 and IPv6 address against
  the SSRF policy, and dials the verified numeric socket address directly so
  Chromium cannot re-resolve the hostname (preventing DNS rebinding across
  navigations, redirects, subresources, iframes, and WebSockets).
- Chromium terminates TLS itself using the original hostname for SNI and
  certificate verification, while QUIC and unproxied WebRTC UDP are disabled and
  caller backend flags cannot override the managed proxy arguments.
- Saved local-browser metadata records both the loopback proxy port and the
  private-network flag. After a daemon restart, the new daemon rebinds that
  exact port before reattaching to a surviving Chromium process (failing
  recovery if the port is taken), and if a surviving browser lacks matching
  proxy or private-network metadata, the daemon closes it over CDP and launches
  a fresh instance against the same profile.

For remote CDP endpoints and cloud-hosted persistent browser contexts, the
external provider owns DNS resolution and SSRF enforcement; Ankole validates URL
syntax and allowed schemes without resolving destination hosts on the Worker.

All provider search results and fetched page text remain untrusted data—reading
a web page never elevates its contents to system instructions or durable Brain
facts—and credentials or decrypted settings must never appear in model outputs,
tool metadata, logs, or workspace files.

## Resolve Web Providers at Call Time

The model-visible web-tool catalog stays fixed across turns. Each `web_search`
or `web_fetch` invocation sends its semantic selector straight to AIGateway,
which resolves the active Agent profile and upstream provider on demand without
a separate availability check or local provider cache. `web_search` requires an
active search provider, whereas `web_fetch` continues to work whenever the
rendered browser fallback is available.

## Repeat Fetches Inside One Session

To avoid redundant downloads within a turn or session, the control-plane Driver
maintains a run-local `web_fetch` cache of up to 96 entries for foreground
calls, and the Codex runner maintains a Job-session cache of up to 100 entries.
In both caches, a clean fetch result satisfies repeat requests for the same URL
for 15 minutes—annotating the output as a cached repeat—while failed or degraded
fetches are never cached. Each cache lives purely in memory for the lifetime of
its owning process and caches page results rather than provider routing.

## Tests

Automated tests verify:

- direct mapping of semantic selectors on AIGateway requests
- rendered-fallback activation and `source` labeling
- call-level character budgets, proportional budget sharing across multi-URL
  calls, and unclipped small pages
- workspace full-text persistence, the 2,000,000-character file cap, and
  continuation `read_file` offsets
- bounded excerpts and explicit missing-file notes when workspace writes fail
- in-memory backend material delivery without writing material files to disk
- per-URL error isolation and preserved request ordering across mixed batches
  (blocked URLs, per-page errors, and batch-level failures)
- extraction deadlines and socket cancellation
- post-commit text extraction while `DOMContentLoaded` is still pending
- `https://` enforcement and Rust SSRF host/IP classification
- route purge, artifact cleanup, and daemon restart recovery
- credential and endpoint redaction in backend failure logs
- browser diagnostic messages surfaced in model-visible tool errors
