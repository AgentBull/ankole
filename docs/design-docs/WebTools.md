# Web Tools

The control-plane conversation tools and Codex Job tools expose two web tools. `web_search` searches the
public web. `web_fetch` reads text from a page.

For clicks, screenshots, or a saved login, use the Browser Skill in a
BackgroundAgentJob. The `ankole-browser` process supports both paths.

## Which Component Does What

AIGateway owns provider selection, credentials, and these HTTP endpoints:

- `/web_search`
- `/web_fetch`

The control plane owns foreground schemas, provider calls, cancellation, result
windows, and the run-local page cache. Agent Computer owns the rendered
`web_fetch` fallback and the Codex Job web tools.

`ankole-browser` manages browser sessions and extracts text from rendered pages.
It identifies each session with an opaque route ID. It does not understand
Agents, Jobs, Principals, or control-plane records.

Execution preparation binds rendered fetch to the resolved Worker environment
before it removes browser source variables from command environments. Each fetch
uses a temporary route, separate from a Codex Job's persistent browser route.

The control plane uses the Rust kernel to classify provider-fetch URLs.
`ankole-browser` checks rendered-fetch URLs in its browser runtime.

The control plane owns `security.ssrf_filter` and
`worker.rendered_fetch_idle_ttl_ms`.

Provider credentials stay in AIGateway. Agent Computer receives an Agent-scoped
AIGateway key and uses the semantic `web_search.default` and
`web_fetch.default` selectors.

## `web_search`

Both tool catalogs accept one nonempty query and do not add a length limit to the
model-visible schema. AIGateway rejects a trimmed query longer than 500
characters before provider dispatch.

The optional `limit` accepts values from 1 through 100. Its default is 5.

The tool sends the query to the search provider selected by AIGateway.
The tool returns titles, URLs, and short extracts.

If no provider exists, the tool explains why search is unavailable.

## `web_fetch`

`web_fetch` accepts from one through five HTTPS page URLs. It returns readable text, not binary file content.

Do not use this tool for PDFs, archives, images, audio, video, or executable files. Use the command tool for explicit downloads.

The main Agent calls AIGateway with `web_fetch.default`. If the selector is
unavailable or the provider request fails, the control plane delegates rendered
extraction to the Worker. Codex Jobs use the same provider and rendered paths.

Both paths return the URL, title, text or error, and source. The rendered path uses the `rendered_fallback` source name.

The model does not receive browser endpoints, credentials, process details, or local renderer state.

## Keep Page Text Inside a Fixed Budget

Foreground results fit the control-plane tool-result byte budget. Longer pages
return `next_offset`; call `web_fetch` with the same URL and `result_offset`
to read the next window. The full text stays in the run's page cache. Recovery
fetches it again. Foreground results do not require a workspace file.

Codex Jobs use the following file-based budget. One `web_fetch` call returns at most 40,000 characters of page text. Page text
is untrusted input of unbounded size, the result is sent again on each model
iteration of the turn, and compaction later reduces it to about 2,000 tokens. An
unbounded page is therefore charged many times and still does not survive.

The budget belongs to the call, not to each URL. Every page that fits inside an
equal share is returned whole, and the larger pages divide what the smaller
pages did not use. One URL can therefore use the whole budget, while five URLs
each keep a useful window.

A page that does not fit keeps its start and its end, cut on line boundaries.
Agent Computer writes the complete text to
`<workspace>/temp/web-fetch/<host>-<hash>.md` and puts a note above the page
text that states the shown and total sizes, the file path, and the `read_file`
call that shows the omitted middle. The note is above the text because the Codex
Job projection keeps the head of a tool result and cuts its tail.

A stored page holds at most 2,000,000 characters. If the workspace cannot be
written, the result stays bounded and the note says that the full text is
missing; the fetch itself still succeeds.

The complete page text has one owner: the workspace file. Result metadata
records the URL, title, sizes, and stored path, and does not repeat the text.
The stored page is rebuildable worker-local state, so nothing durable depends
on it.

## Read a Page in a Browser When Fetch Fails

Agent Computer creates a temporary browser route in memory. In the Worker
process, it sends a `fetch` command to the daemon socket with the route,
session, final material, and artifact root. It does not write a material file.

The client allows 300 seconds and at most 8 MiB of response data. Cancellation
closes the socket immediately. After success, failure, or cancellation, the
Worker purges the temporary route and removes its artifact directory. If purge
fails, it restarts the daemon and retries purge once.

The browser accepts at most five URLs and opens at most two pages at once. Each
URL has a fixed time limit.

The browser waits until the main document commits. It does not wait for
`DOMContentLoaded`. It then waits briefly for the readable text to stop changing.

One failed URL does not remove successful results. The result order matches the request order.

If the rendered fetch fails, Agent Computer logs the backend kind, failure
stage, error code, retryable state, and failed URL index. It does not log the
URL, browser endpoint, connection headers, credentials, or browser error details.
The model receives a neutral rendered-fallback error.

After the call, Agent Computer closes the browser route and removes its files.
It can restart the daemon once if cleanup fails.

The route exists only on the worker and can disappear. PostgreSQL stores no
business record that depends on it.

`worker.rendered_fetch_idle_ttl_ms` sets how long an unused route can remain
before cleanup. Its default is 30 minutes.

The setting accepts values from 5 minutes through 24 hours. It does not change the model schema.

## Use the Browser Skill for Interactive Work

Each Codex Job receives the built-in Browser capability. Agent Computer creates its persistent route before it starts the Codex app server.

The Job sandbox receives only reserved `ANKOLE_BROWSER_*` values and the
read-only connection file. Agent Computer removes the original backend
variables.

The Browser Skill exposes the preconfigured `ankole-browser` CLI. Browser commands and Playwright scripts attach to the same default session.

The `snapshot` command returns Playwright's AI accessibility snapshot. With `-i`,
it selects controls and elements with a pointer cursor from Playwright's JSON
snapshot before it applies the output budget. Static page text cannot use that
budget before the controls. Each command captures one snapshot and retains its
Playwright refs. Commands resolve `@eN` refs from the latest snapshot. A ref in
an iframe uses the form `@f1e3`. A missing ref or a detached element returns
`stale_ref`. Snapshot capture uses the remaining command deadline. An unmatched
selector returns a retryable `timeout` instead of an unbounded Playwright wait.

Codex cannot select backend credentials or change which Job owns the browser
session. The route record contains only opaque resume data and hashes.

Browser profiles and reconnect data stay on the worker. The Job keeps its route
so later turns can reuse login and browser state.

Use `web_fetch` for text extraction. Use the Browser Skill for interaction, screenshots, login state, and reproducible browser scripts.

## Block Unsafe URLs

The model schema accepts only HTTPS URLs. The rendered fallback checks each URL again before extraction.

The control plane blocks cloud-metadata destinations. It also blocks private
destinations when the operator enables `security.ssrf_filter`.

The site setting defaults to `false` to permit enterprise intranet access.
Cloud metadata endpoints remain blocked at either value.

Rust owns URL parsing, host classification, and admission. Elixir loads the NIF;
the browser daemon loads the Node-API build. Callers supply allowed schemes and
the private-network setting. Metadata names, including names with a final dot,
and metadata addresses are always blocked. Invalid addresses and empty DNS
results fail admission. All bindings use the shared URL test vectors in
`app/kernel/test/vectors/web_url_host_classification.json`.

Local Chromium sends web TCP traffic through a loopback Rust SOCKS5 proxy.
The proxy resolves each destination, checks every returned IPv4 and IPv6
address, and connects with a numeric socket address. Chromium cannot resolve
the checked host again for that connection. Redirects, subresources, iframes,
and WebSockets use the same proxy. TLS stays in Chromium, with the original
hostname for SNI and certificate verification. QUIC and non-proxied WebRTC UDP
are disabled. Backend arguments cannot override the managed proxy settings.

The saved local-browser metadata includes the proxy port and private-network
setting. After a daemon crash, the new daemon binds that port before it resumes
the saved browser. If the port is unavailable, recovery fails. A browser
without matching proxy metadata or private-network settings is closed through
CDP and restarted with its profile.

Remote CDP and provider-created persistent contexts own their SSRF policy and
DNS environment. Ankole checks URL syntax and supported protocols for these
backends. It does not resolve or classify their destinations on the Worker.

The Lark image resolver uses the same Rust admission functions with its
Req/Finch adapter. It connects to a checked IP, keeps the original Host and TLS
hostname, and checks each redirect again.

Treat provider responses and page text as untrusted input. Reading a page does
not turn its text into a system instruction or a stored fact.

Credentials and decrypted settings must not appear in model output, result metadata, logs, or Workspace files.

## Resolve Web Providers at Call Time

The model-facing web-tool list is stable. Each call sends its semantic selector
directly to AIGateway, which resolves the current Agent profile and provider.
There is no separate availability lookup or provider-resolution cache.

`web_search` requires a provider. `web_fetch` remains usable when the rendered fallback is available.

## Repeat Fetches Inside One Session

The control-plane Driver keeps a run-local result cache for foreground calls,
with at most 96 entries. The Codex runner keeps a Job-session result cache with
at most 100 entries. In both paths, a clean result for a URL answers a repeat
fetch of the same URL for 15 minutes, marked as a repeat in the output, without
a new download. Failed or degraded results are not cached. Each cache lives
only for its owning process and stores results, not provider resolution.

## Tests

Tests verify:

- direct semantic-selector request mapping
- fallback activation and source labels
- page-text budget, budget division across URLs, and whole small pages
- full-text storage, stored-size limit, and the `read_file` offset that continues the page
- bounded results and a stated missing full text when storage fails
- requests carry final material; rendered fetch does not write a material file
- partial URL failure and result order across one rendered batch call: a
  blocked URL, a returned result that carries an error, and a failed batch each
  keep their request position
- bounded extraction and cancellation
- document-commit extraction while `DOMContentLoaded` remains pending
- HTTPS and SSRF checks
- route cleanup and daemon recovery
- redacted backend failure logs
- neutral model-visible errors
