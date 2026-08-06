# Web Tools

Agent Computer gives the model two foreground tools. `web_search` searches the
public web. `web_fetch` reads text from a page.

For clicks, screenshots, or a saved login, use the Browser Skill in a
BackgroundAgentJob. The `ankole-browser` process supports both paths.

## Which Component Does What

AIGateway owns provider selection, credentials, and these HTTP endpoints:

- `/web_search`
- `/web_fetch`

Agent Computer owns the model schemas, cancellation, result format, and rendered
`web_fetch` fallback.

`ankole-browser` manages browser sessions and extracts text from rendered pages.
It identifies each session with an opaque route ID. It does not understand
Agents, Jobs, Principals, or control-plane records.

The Rust kernel classifies URLs for worker checks. The browser package implements
the same rules because it cannot load the native module.

The control plane owns `security.ssrf_filter` and
`worker.rendered_fetch_idle_ttl_ms`.

Provider credentials stay in AIGateway. Agent Computer receives an Agent-scoped
AIGateway key and uses the semantic `web_search.default` and
`web_fetch.default` selectors.

## `web_search`

Agent Computer accepts one nonempty query and does not add a length limit to the
model-visible schema. AIGateway rejects a trimmed query longer than 500
characters before provider dispatch.

The optional `limit` accepts values from 1 through 100. Its default is 5.

Agent Computer sends the query to the search provider selected by AIGateway.
The tool returns titles, URLs, and short extracts.

If no provider exists, the tool explains why search is unavailable. The worker
does not keep a second search index.

## `web_fetch`

`web_fetch` accepts from one through five HTTPS page URLs. It returns readable text, not binary file content.

Do not use this tool for PDFs, archives, images, audio, video, or executable files. Use the command tool for explicit downloads.

Agent Computer first calls AIGateway with `web_fetch.default`. If AIGateway
cannot resolve that selector or the provider request fails, Agent Computer opens
the page in a browser.

Both paths return the URL, title, text or error, and source. The rendered path uses the `rendered_fallback` source name.

The model does not receive browser endpoints, credentials, process details, or local renderer state.

## Keep Page Text Inside a Fixed Budget

One `web_fetch` call returns at most 40,000 characters of page text. Page text
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

Agent Computer creates a temporary browser session with an opaque route ID. It
then runs `ankole-browser fetch` with a prepared connection file.

The CLI process receives:

- the daemon socket
- the opaque route and session
- the final material file
- the artifact root
- the packaged Node and runner paths

The process does not receive the original backend settings or profile
credentials.

The CLI has a 300-second process timeout and an 8 MiB output buffer. If the
caller cancels the request, Agent Computer sends `SIGTERM` to the CLI process.

The browser accepts at most five URLs and opens at most two pages at once. Each
URL has a fixed time limit.

The browser waits until the main document commits. It does not wait for
`DOMContentLoaded`. It then waits briefly for the readable text to stop changing.

One failed URL does not remove successful results. The result order matches the request order.

If the rendered fetch fails, Agent Computer logs the backend kind, failure
stage, error code, retryable state, and failed URL index. It does not log the
URL, browser endpoint, connection headers, credentials, or browser error details.
The model continues to receive a neutral rendered-fallback error.

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

Codex cannot select backend credentials or change which Job owns the browser
session. The route record contains only opaque resume data and hashes.

Browser profiles and reconnect data stay on the worker. The Job keeps its route
so later turns can reuse login and browser state.

Use `web_fetch` for text extraction. Use the Browser Skill for interaction, screenshots, login state, and reproducible browser scripts.

## Block Unsafe URLs

The model schema accepts only HTTPS URLs. The rendered fallback checks each URL again before extraction.

The kernel blocks cloud-metadata destinations. It also blocks private destinations when the operator enables `security.ssrf_filter`.

AppConfigure enables the SSRF filter unless the operator explicitly sets it to `false`.

The browser checks every main page URL and every resolved address. It applies
the same metadata and private-address rules.

Rust, Elixir, and Bun use the same URL test vectors from
`app/kernel/test/vectors/web_url_host_classification.json`.

Treat provider responses and page text as untrusted input. Reading a page does
not turn its text into a system instruction or a stored fact.

Credentials and decrypted settings must not appear in model output, result metadata, logs, or Workspace files.

## Resolve Web Providers at Call Time

The model-facing web-tool list is stable. Each call sends its semantic selector
directly to AIGateway, which resolves the current Agent profile and provider.
There is no separate availability lookup or Worker cache.

`web_search` requires a provider. `web_fetch` remains usable when the rendered fallback is available.

## Tests

Tests verify:

- direct semantic-selector request mapping
- fallback activation and source labels
- page-text budget, budget division across URLs, and whole small pages
- full-text storage, stored-size limit, and the `read_file` offset that continues the page
- bounded results and a stated missing full text when storage fails
- route material injection and source-variable removal
- partial URL failure and result order
- bounded extraction and cancellation
- document-commit extraction while `DOMContentLoaded` remains pending
- HTTPS and SSRF checks
- route cleanup and daemon recovery
- redacted backend failure logs
- neutral model-visible errors
