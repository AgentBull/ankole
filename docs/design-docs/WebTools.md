# Web Tools

This document describes Ankole's model-facing web tools. There are three
families:

- `web_search`: search the public web through the agent's configured
  AIGateway provider profile.
- `web_fetch`: fetch readable content from public HTTPS URLs through the
  agent's configured AIGateway provider profile, with a worker-local browser
  fallback.
- `browser_*`: operate an interactive rendered browser session in Agent
  Computer.

`web_search` is a provider-backed AIGateway tool. `web_fetch` is
provider-backed when `GET /api/v1/ai-gateway/web_tools` reports
`web_fetch.default` as available, and otherwise falls back to the worker-local
browser runtime. Both provider-backed tools use the agent-scoped AIGateway
bearer key; provider credentials never enter Agent Computer.

`browser_*` tools are the rendered browser runtime: the default local
Chromium backend and the operator-controlled remote CDP override used for
Cloudflare Browser Run, Bright Data Browser API, Rayobrowse, CloakBrowser, or
other CDP-compatible services.

The short version: every tool family has a stable model-facing contract.
Provider-backed tools route through AIGateway; browser tools route through the
Agent Computer browser runtime. For each turn, Bun resolves the browser runtime
AppConfigure keys it needs through `app_configure.resolve`. If
`worker.remote_browser_cdp_config` resolves to a remote CDP adapter, the worker
connects to that adapter. If it resolves to `nil`, the main Bun worker lazily
starts one local Chromium sidecar through its in-process `LocalSidecarManager`,
creates a CDP BrowserContext per browser session, and releases the idle sidecar
according to `worker.local_browser_idle_ttl_ms`.

## Provider-Backed Tools

The control plane owns provider configuration and profile routing:

- `web_search.default` resolves through the `web_search` AIGateway capability.
- `web_fetch.default` resolves through the `web_fetch` AIGateway capability.
- Built-in `web_search` providers are `parallel`, `bright_data_serp`, and
  `agentbull_cloud`.
- Built-in `web_fetch` providers are `parallel` and `jina_reader`.

Agent Computer asks AIGateway which provider-backed tools are available before
starting the model loop. If `web_search` is missing, disabled, or points at a
provider without the required capability, that tool is omitted from the model's
tool list. If provider-backed `web_fetch` is missing, Agent Computer still
registers `web_fetch` when the worker-local browser runtime is available.

`web_search` accepts a query and optional limit. AIGateway normalizes provider
responses into a shared result list with fields such as `title`, `url`,
`snippet`, `published_at`, `source`, `sources`, and `score` when available.

`web_fetch` accepts one to five public HTTPS URLs. AIGateway rejects literal
localhost, loopback, private, link-local, and metadata-host URLs before
provider dispatch. Provider responses are normalized into a shared result list
with fields such as `url`, `title`, `text`, `markdown`, `html`, `links`,
`images`, `metadata`, and `error` when available.

Provider-backed `web_search` and `web_fetch` are not rendered browser
automation. The local `web_fetch` fallback uses a rendered CDP browser session,
but exposes only the stable fetch result shape. Use `browser_*` when the task
needs interaction, login/session continuity, screenshots, or element-level
actions.

## Local Web Fetch Fallback

The local `web_fetch` fallback is owned by Agent Computer, not AIGateway.
`GET /api/v1/ai-gateway/web_tools` continues to report only provider-backed
availability. During a text turn, Agent Computer adds `web_fetch` when it has a
local browser scope for the current agent/session.

The fallback:

- accepts the same one-to-five public HTTPS URL input as provider-backed
  `web_fetch`;
- starts or reuses the local Chromium singleton through `LocalSidecarManager`;
- uses its own browser session and Chromium BrowserContext separate from
  interactive `browser_*` sessions;
- navigates each URL through CDP and extracts `document.body.innerText`;
- normalizes results to the same `success` plus `results` body shape used by
  AIGateway providers;
- records `source: "local_browser"` metadata, and records the AIGateway error
  when provider-backed fetch failed before fallback.

The fallback deliberately does not use the operator remote CDP override. It is
the local-browser safety path for missing or failed provider-backed extraction;
operator-selected remote browser behavior remains visible through `browser_*`.

## Browser Runtime

## Architecture

```text
model tool loop
  |
  | browser_navigate / browser_snapshot / browser_find / browser_click / ...
  v
Agent Computer browser tools (Bun)
  |
  | resolves effective browser endpoint for this agent/turn
  v
BrowserEndpointResolver (Bun)
  |
  +-- remote override:
  |     worker.remote_browser_cdp_config from AppConfigure
  |     adapter: cdp_endpoint | cdp_session_request
  |
  +-- local default:
        LocalSidecarManager.ensure(browser.chromium)
        -> chromium --headless=new --remote-debugging-port=<free> ...
        -> Target.createBrowserContext per browser session
  |
  v
CdpBrowserEngine (same implementation for local and remote)
```

The control plane owns configuration. The worker owns browser process/session
state.

- Elixir `AppConfigure` stores `worker.remote_browser_cdp_config` and
  `worker.local_browser_idle_ttl_ms`.
- RuntimeFabric RPC `app_configure.resolve` lets the worker resolve declared
  AppConfigure keys for the current agent. Browser does not own a special
  configuration transport.
- Agent scope overrides global scope; absent config resolves to `nil`.
- Decrypted remote config is not written into `turn_start.request_context`,
  actor events, model messages, or durable browser artifacts.
- Local Chromium is not started at container boot. The main Bun worker starts
  it only when the effective remote config is `nil` and a browser tool needs a
  rendered browser.
- The production browser tools call the Bun CDP engine directly. The
  `ankole-browser` CLI remains a diagnostic/operator entrypoint, not the
  model-facing runtime boundary.
- Browser session metadata lives under
  `/workspace/.sessions/<session>/browser/session.json` and is rebuildable.

The model only sees normal browser tool results.

## Why This Shape

The design deliberately separates the stable product contract from the browser
implementation:

- The model always uses the same `browser_*` tools.
- Local default operation has no external browser service dependency.
- Operators can switch one agent or all agents to a stronger remote browser
  without changing prompts, tools, or actor runtime behavior.
- Remote provider credentials stay in encrypted AppConfigure and ephemeral
  worker memory.
- HTTP fetch fallback is removed; browser-family behavior operates through a
  real CDP browser session. `web_fetch` has an explicit local-browser fallback
  that also uses the CDP engine.
- Chromium provides the default local full-browser compatibility, screenshots,
  and CDP BrowserContext isolation; remote CDP remains available for managed
  browser infrastructure, stronger anti-bot needs, and provider-specific
  browser fleets.

## Default Backend: Lazy Local Chromium

If `worker.remote_browser_cdp_config` is unset or resolves to `nil`, the worker
uses the Chromium binary installed in the Agent Computer image.

The Bun `LocalSidecarManager` launches a local sidecar with:

```bash
chromium --headless=new --renderer-process-limit=4 --no-zygote --no-sandbox \
  --disable-gpu --disable-dev-shm-usage --disable-sync \
  --disable-background-networking --disable-default-apps --disable-translate \
  --disable-popup-blocking --disable-notifications --disable-extensions \
  --user-agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/150.0.4078.48" \
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=<free> \
  --user-data-dir=/workspace/.sessions/_browser/chromium/profile about:blank
```

The Docker image still uses Tini as PID 1 for signal forwarding and zombie
reaping, and starts the worker directly with `bun src/main.ts`. There is no
Python browser daemon, runtime shell wrapper, UDS control protocol, or Rust
browser supervisor in the default design.

The important lifecycle boundary is that Chromium is not a child of a
short-lived bwrap tool command. It is held by the main Bun worker process, whose
lifetime is the Agent Computer worker lifetime. This fixes the failure mode
where a browser launched through the foreground/background command tool died
with the tool command. It does not try to preserve browser sidecars across a Bun
worker crash; if Bun exits, the worker is restarted and browser sessions are
recreated.

Local browser state isolation is keyed by the browser session identifier, which
defaults to the current agent plus execution scope. The sidecar key is global
(`browser.chromium`); isolation lives in Chromium CDP BrowserContext, created by
`Target.createBrowserContext` and disposed by `Target.disposeBrowserContext` on
session release. BrowserContext isolates cookies, localStorage, IndexedDB, and
cache while sharing one Chromium process.

The local adapter tracks the main frame's default Runtime execution context and
waits for navigation primarily through Page lifecycle events instead of repeated
`document.readyState` polling. Browser navigation failure pages, such as
transient TLS or network failures, are returned as browser tool errors rather
than successful snapshots.

Sidecar release is idle-time based. Each browser action touches the sidecar's
`lastUsedAt` timestamp. The TTL comes from scoped AppConfigure key
`worker.local_browser_idle_ttl_ms`, defaults to 30 minutes, and is intentionally
conservative: it prevents leaks in long-lived workers without aggressively
killing useful browser state. When no action has used that sidecar for the
configured idle TTL, Bun sends `SIGTERM`; if the process does not exit within
the grace period, Bun sends `SIGKILL`.

Local Chromium is the right default for:

- normal navigation and rendered text extraction;
- multi-step browser tasks that use `browser_snapshot`, `browser_find`,
  `browser_click`, `browser_type`, and related structured tools;
- screenshots through `Page.captureScreenshot`;
- fast per-session startup through CDP BrowserContext instead of per-session
  browser processes.

Known local Chromium limits:

- headless Chromium still has a detectable browser/runtime fingerprint;
- anti-bot-sensitive flows may need a remote browser provider;
- local sidecar state is worker-local and rebuildable, not durable control-plane
  state.

There is no `ANKOLE_BROWSER_BACKEND=fetch` mode. If Chromium is missing and
no remote CDP config is set, browser tools fail closed.

## Remote CDP Configuration

The only browser override key is:

```text
worker.remote_browser_cdp_config
```

Contract:

- scope: scoped AppConfigure key;
- encrypted: true;
- default: `nil`;
- resolution order: `agent:<uid> -> global -> default`;
- no compatibility alias for misspellings such as `broswer`;
- operator/admin-owned setting, not model-writable state.

When a remote config is present, it is authoritative. The worker does not
silently fall back to local Chromium if the remote endpoint is misconfigured
or unavailable; this makes operator mistakes visible.

### Adapter: Direct CDP Endpoint

Use `cdp_endpoint` when the provider gives you a WebSocket CDP endpoint or an
HTTP(S) CDP server root.

```json
{
  "adapter": "cdp_endpoint",
  "endpoint_url": "wss://...",
  "headers": {
    "Authorization": "Bearer ..."
  },
  "connect_timeout_ms": 30000
}
```

`endpoint_url` may be:

- `ws://...` or `wss://...`: used directly as the CDP WebSocket endpoint;
- `http://...` or `https://...`: the worker requests `/json/version` and reads
  `webSocketDebuggerUrl`.

If a CDP server root returns a loopback WebSocket URL such as
`ws://127.0.0.1:9222/...`, the worker rewrites the host, scheme, and port to
match the configured root URL. This supports LAN proxies and Docker
`host.docker.internal` style endpoints.

`headers` are sent to HTTP discovery requests and WebSocket CDP connections.
This is required by providers such as Cloudflare Browser Run.

### Adapter: Session Request

Use `cdp_session_request` when a provider first creates a browser session via
HTTP and then returns the WebSocket URL.

```json
{
  "adapter": "cdp_session_request",
  "request": {
    "url": "http://rayobrowse.lan:3000/connect?headless=true&os=windows",
    "method": "GET",
    "headers": {},
    "response": {
      "type": "text"
    }
  },
  "headers": {},
  "connect_timeout_ms": 120000
}
```

`request.response` can also extract the WebSocket URL from JSON:

```json
{
  "type": "json",
  "path": ["webSocketDebuggerUrl"]
}
```

`request.headers` authenticate the session-creation HTTP call. Top-level
`headers` authenticate the resulting CDP WebSocket connection.

## Cloudflare Browser Run

Cloudflare Browser Run supports CDP connections from external environments.
The official Playwright example connects to:

```text
wss://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/browser-rendering/devtools/browser?keep_alive=600000
```

and sends:

```text
Authorization: Bearer <API_TOKEN>
```

Cloudflare documents that the API token needs `Browser Rendering - Edit`
permission, and that `keep_alive` is in milliseconds. See the official
[Cloudflare Browser Run Playwright CDP documentation](https://developers.cloudflare.com/browser-run/cdp/playwright/).

Ankole config:

```json
{
  "adapter": "cdp_endpoint",
  "endpoint_url": "wss://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/browser-rendering/devtools/browser?keep_alive=600000",
  "headers": {
    "Authorization": "Bearer <CF_API_TOKEN>"
  },
  "connect_timeout_ms": 30000
}
```

Use Cloudflare when you want managed Chromium-compatible sessions, provider
headers, screenshots/PDFs from a full browser backend, or globally reachable
browser infrastructure without running your own CDP service.

## Bright Data Browser API

Bright Data Browser API exposes a CDP WebSocket endpoint commonly used with
Playwright `chromium.connectOverCDP`:

```text
wss://<AUTH>@brd.superproxy.io:9222
```

where `AUTH` is the Bright Data Browser API zone credential string, for
example `SBR_ZONE_FULL_USERNAME:SBR_ZONE_PASSWORD`. Bright Data also documents
CDP inspection via `Page.inspect`. See the official
[Bright Data Browser API code examples](https://docs.brightdata.com/scraping-automation/scraping-browser/code-examples)
and [configuration documentation](https://docs.brightdata.com/scraping-automation/scraping-browser/configuration).

Ankole config:

```json
{
  "adapter": "cdp_endpoint",
  "endpoint_url": "wss://<SBR_ZONE_FULL_USERNAME>:<SBR_ZONE_PASSWORD>@brd.superproxy.io:9222",
  "connect_timeout_ms": 120000
}
```

Credential-bearing URLs are allowed for providers that require them, but tool
output and status responses must use redacted URLs. URL-encode credential
characters that are not valid in userinfo.

Bright Data is a good fit for high-friction sites, geo/proxy requirements,
CAPTCHA-oriented scraping workflows, and externally inspectable browser
sessions.

## Other Remote Providers

CloakBrowser, Rayobrowse, ShardBrowser, self-hosted Chromium, and similar
systems should integrate through the same two adapters:

- expose a stable `ws(s)://` CDP URL and use `cdp_endpoint`; or
- expose an HTTP session creation endpoint and use `cdp_session_request`.

Do not add provider-specific browser tool names. If a provider requires extra
fields, extend the adapter schema deliberately and keep the model-facing
`browser_*` contract unchanged.

## Security Boundary

Remote browser config may contain bearer tokens, Basic credentials, or signed
session URLs. Treat it as operator secret material:

- store it only in encrypted AppConfigure;
- prefer agent-scoped config for provider experiments;
- use global config only when every agent should share the same browser
  provider;
- do not put remote CDP secrets in prompts, SOUL, MISSION, actor events, or
  workspace files;
- avoid long-lived remote sessions unless the provider requires them;
- rotate provider credentials outside Ankole and update AppConfigure.

The browser itself executes untrusted web content. Keep browser behavior inside
the worker sandbox and expose only structured, redacted tool observations to
the model.

## Operational Checks

Local default:

```bash
docker run --rm ankole-agent-computer:0.1.0 ankole-browser --json doctor
```

Expected backend:

```json
{
  "backend": "chromium",
  "remote_cdp_configured": false
}
```

Remote override:

```bash
ANKOLE_REMOTE_BROWSER_CDP_CONFIG_JSON='{"adapter":"cdp_endpoint","endpoint_url":"wss://..."}' \
  ankole-browser --json doctor
```

Expected backend:

```json
{
  "backend": "remote_cdp",
  "remote_cdp_configured": true
}
```

In production, set `worker.remote_browser_cdp_config` through AppConfigure
instead of process environment variables. The environment variable is only the
local diagnostic path for `ankole-browser`.

Fast no-build package check:

```bash
cd app/agent_computer
bun run test
```

The package test command uses the existing `ankole-agent-computer:0.1.0` image
and bind-mounts local `bin/`, `src/`, and `test/` into the container. Rebuild
the image only after Dockerfile, dependency, kernel output, or image-level tool
changes. Browser runtime fixes in TypeScript can usually be reproduced and
verified through this no-build path first.

## Failure Model

- No remote config: use local Chromium.
- Remote config present but invalid: fail before browser launch.
- Remote endpoint unreachable: fail the browser tool call; do not fall back.
- Backend lacks screenshot support: `browser_screenshot` returns unsupported.
- Stale element ref: action fails and the model must take a fresh snapshot.

This keeps failures explicit and recoverable. Silent fallback would make
operator browser policy and test evidence ambiguous.
