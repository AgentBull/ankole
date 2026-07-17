# Web Tools

The current Agent Computer web surface has two model tools:
provider-backed `web_search` and provider-first `web_fetch`. This document does
not turn the interactive browser into a third foreground web tool. Interactive
work is exposed separately through the long-running Browser Skill inside a
Codex Job, but both paths share the same `ankole-browser` data plane.

## Ownership

- AIGateway owns provider selection, provider credentials, and the
  `/web_tools`, `/web_search`, and `/web_fetch` HTTP contracts.
- Agent Computer owns stable model schemas, lazy availability checks,
  cancellation, result formatting, final browser-material injection, and the
  private rendered-page fallback used by `web_fetch`.
- `ankole-browser` owns only the browser data plane: opaque routes, physical
  sessions, rendered extraction, and generic lifecycle. It has no
  control-plane client or Agent/Job/Principal vocabulary.
- The Rust kernel supplies URL and SSRF facts used by the worker guard. BEAM
  callers apply those facts through the shared `Ankole.Kernel.validate_web_url/3`
  policy helper, keeping only their scheme list and error vocabulary.
- The control plane owns `security.ssrf_filter` and
  `worker.rendered_fetch_idle_ttl_ms` configuration.

Provider credentials stay inside AIGateway. Agent Computer receives only its
agent-scoped AIGateway handle and provider availability/model metadata.

## `web_search`

`web_search` accepts one non-empty query without an Ankole-owned length ceiling
and an optional result limit from 1 to 100, defaulting to 5. The provider may
still enforce its own request boundary. Agent Computer calls the configured
AIGateway search provider and returns a compact numbered list of titles, URLs,
and snippets. If no provider is configured, it fails with the availability
reason; there is no local search-index fallback.

## Hermes Floor And Web Tradeoffs

| Boundary | Previous Ankole | Hermes reference | Current Ankole | Tradeoff |
| --- | --- | --- | --- | --- |
| Search query length | `500` characters | No equivalent Hermes ceiling | No Ankole-owned ceiling; provider limits still apply | Very large requests reach the provider, but Ankole no longer rejects legal research queries earlier. |
| Result count | Maximum `100` | No equivalent boundary | Maximum `100` | Retained as a presentation and provider-cost boundary, not a query-acceptance restriction. |
| Rendered fetch | `45s` subprocess timeout | No equivalent rendered-fetch boundary | `300s` | A broken renderer consumes capacity longer, but complex pages and slow networks get the same five-minute tolerance as control-plane RPC. |

## `web_fetch`

`web_fetch` accepts one to five HTTPS page URLs. It extracts readable page text;
it is not a downloader for PDFs, archives, images, audio, video, or
executables. Binary downloads use the foreground `command` tool and an explicit
downloader such as `aria2c`.

Agent Computer first uses the configured AIGateway fetch provider. If provider
availability resolution fails, no fetch provider is configured, or the
provider request fails, it may use its private rendered-page extractor.

Both paths return the same text-oriented shape: URL, title, extracted text or
error, and a neutral source label. The fallback label is
`rendered_fallback`. Implementation processes, endpoints, credentials, and
rebuildable renderer state never enter the model contract.

One bad URL does not hide successful URLs in the same fallback call. Each URL
gets a normalized result in request order; the renderer uses two bounded
workers and a per-URL budget so a slow page cannot consume the whole batch.
After `domcontentloaded`, body text must remain stable for a bounded quiet
window before it is returned, avoiding a successful `Loading` placeholder
without waiting indefinitely for `networkidle`. Caller cancellation aborts the
whole operation.

## Rendered-Page Fallback

The fallback exists only so JavaScript-rendered text remains readable through
`web_fetch`. Agent Computer materializes an ephemeral opaque route immediately
before invoking `ankole-browser fetch`, injects only the final socket, route,
session, and material paths into that CLI process, and sends an internal purge
in `finally`. If the daemon died during the fetch, Agent Computer first restores
the supervised daemon and retries that purge before discarding the short-lived
material file. Profile or backend source variables are never inherited by the
CLI. The worker-singleton `ankole-browserd` starts with Agent Computer and may
serve other independent physical sessions, but an ephemeral fetch route is not
reused after the call.

Browser route data is worker-local and rebuildable. PostgreSQL stores no
semantic fact that depends on it. `ankole-browser` may persist profile and
remote reconnect bytes under its supplied data root, but it does not know why
the route exists or who owns it.

`worker.rendered_fetch_idle_ttl_ms` bounds live-resource cleanup if explicit
purge cannot complete. It does not add a model capability or change the
`web_fetch` schema.

## Interactive Browser Boundary

Every Codex Job receives the built-in Browser capability. Agent Computer
materializes its persistent opaque route immediately before the Codex app-server
and its `bubblewrap` sandbox are created. The sandbox receives
only reserved `ANKOLE_BROWSER_*` values and read-only binds for the daemon
socket and final material. Backend/profile source variables are removed first.

The Browser Skill then exposes the preconfigured `ankole-browser` CLI. Short
verb-first commands and LLM-authored Playwright scripts both attach to the same
route and injected default session; Codex does not resolve profiles or credentials and cannot create
a second browser owner. Route records contain only opaque identifiers and
hashes needed to resume the same Job route. Browser profiles and reconnect
bytes remain worker-local data-plane state.

This split is intentional: `web_fetch` owns text extraction and uses an
ephemeral route, while the Browser Skill owns visible interaction, screenshots,
persistent login state, and reproducible code workflows. Neither surface gives
`ankole-browser` any Agent, Job, Principal, or control-plane meaning.

## URL and Security Rules

- The model schema accepts HTTPS URLs only.
- The fallback repeats the URL safety guard before extraction.
- When `security.ssrf_filter` is enabled, kernel-backed URL facts reject unsafe
  destinations and redirects at the worker boundary.
- The `ankole-browser` navigation guard applies the same classification to
  every main-frame destination and each DNS-resolved address: cloud metadata
  addresses are always blocked, private addresses only while the filter is on.
  The data plane cannot link the native module, so its TypeScript tables
  mirror the kernel classifier; the shared vectors in
  `app/kernel/test/vectors/web_url_host_classification.json` pin parity across
  the Rust, Elixir, and Bun suites.
- Provider responses and page content are untrusted tool output. They do not
  become system instructions or durable semantic state by being fetched.
- Decrypted settings and credentials stay in memory and must not appear in
  model output, result metadata, logs, or workspace files.

## Availability

The model tool list is stable for one turn. Provider availability is resolved
lazily and memoized within that turn, so Responses tool schemas do not change
between model iterations. `web_search` requires a configured provider;
`web_fetch` may remain available through the rendered-page fallback.

## Validation

Tests cover availability caching, provider request mapping, fallback
activation, pre-CLI material injection, source-environment stripping, per-URL
partial failure, bounded rendered settling, cancellation, HTTPS validation,
SSRF guarding, explicit cleanup, and neutral result metadata.
