---
title: Web tools
description: How an Ankole agent searches and fetches the public web — the web_search and web_fetch tools, how their availability depends on model profiles being bound, web_fetch's 1-5 public HTTPS URL limit, rendered-fetch caching, and when to use these tools instead of the browser.
section: User guide
order: 32
---

Web tools are the lightweight way for an agent to reach the public web: search it, and fetch readable text from pages. They are the `web_search` and `web_fetch` tools, defined in `app/agent_computer/src/tools/web/web-tools.ts`, and they run inside the turn through AIGateway rather than driving a browser. This page is the operator view — what the tools do, what must be configured for them to appear, and when to reach for them instead of the [browser](../browser-automation/).

The decisive property, stated up front: these tools exist only when their model profiles are bound. A profile is a selector the control plane resolves to a real provider at call time; the agent never sees the credential. If the `web_search` or `web_fetch` profile is unset, the corresponding tool is simply absent from the turn's tool set.

## What each tool does

- **`web_search`** searches the public web through the configured AIGateway web-search provider. The agent supplies a query, and gets back search results.
- **`web_fetch`** extracts and returns readable text from HTTPS web pages through AIGateway, with an internal rendered-page fallback when the provider is unavailable. The agent passes the URLs it needs, and gets back the page text.

Both tools are read-only — `web_search` is `isReadOnly: true`, and so is `web_fetch`. Neither writes anything to the web. `web_search` runs in parallel with other parallel tools; `web_fetch` is sequential.

## What you must configure

The tools are not unconditional. Their availability depends on the `web_search` and `web_fetch` model profiles being bound to the agent, exactly the slots listed in [Providers and models](../providers-and-models/). Two consequences:

1. **No binding, no tool.** If the `web_search` profile is unset, `web_search` does not appear in the turn's tool set; the same goes for `web_fetch`. This is why a fresh agent that has not been wired to a web provider cannot search — the tool is genuinely not there for the model to call.
2. **The binding is a selector, not a credential.** The profile points at a provider id you configured at `PUT /ai-gateway/providers/<id>`, with credentials stored encrypted in that provider's `options`. The control plane resolves the selector at call time; the agent and the worker never see the credential.

Bind the profiles through the Console, the same `PUT /agents/:agent_uid/model-profiles/<profile>` route used for the reasoning slots. If a turn fails with `422 unknown_model_selector` or `422 model_binding_not_configured` on a web call, the cause is the binding, not a transient fault — confirm the profile points at a provider id that actually exists and has complete options.

## web_fetch: 1 to 5 public HTTPS URLs

`web_fetch` accepts one to five URLs in a single call, and they must be public HTTPS. The one-to-five limit and the HTTPS-only rule are both deliberate: the tool is for reading public web pages, and batching a few URLs into one call keeps the turn efficient. It returns text only — never binary content. Do not use it for PDFs, archives, images, audio, video, executables, or other binary files; for those downloads, the agent uses the command shell to run `aria2c`.

The provider path is preferred when configured, because the gateway can use its own extraction services. When the provider is unavailable, the internal rendered-page fallback keeps rendered pages reachable, so a fetch does not silently fail just because the provider is down.

## Rendered-fetch caching

Fetched results that came through the rendered path are cached so the agent does not re-render the same page twice in a turn. The cache lifetime is controlled by the `worker.rendered_fetch_idle_ttl_ms` AppConfigure key, which sets how long an idle rendered-fetch result stays cached. Tune it through AppConfigure if you find the agent re-fetching pages it already saw, or if you want to shorten the cache to force fresher results. The default is sensible for most work; change it only when the access pattern calls for it.

## When to use web tools instead of the browser

This is the choice the agent makes on every turn. The rule, stated by the [browser skill](../browser-automation/) itself: prefer `web_search` and `web_fetch` when rendered interaction, login state, screenshots, or browser-side code are unnecessary.

Concretely:

- **Use the web tools** to find a page, read its text, or gather several pages' content in a turn. They are cheaper and faster, and they do not consume a browser session.
- **Use the browser** when the page only yields its data after JavaScript runs, after a click or fill, when you need a persistent login session, when you need a screenshot, or when you need a reproducible Playwright workflow.

If you are configuring an agent whose work is mostly reading public pages, make sure the `web_search` and `web_fetch` profiles are bound and leave the browser skill at its default. If the agent needs to interact with logged-in sites, also enable the browser. The two paths coexist; they are not alternatives for the whole agent, they are alternatives per task.

## Next steps

- For the profile slots these tools depend on, read [Providers and models](../providers-and-models/).
- For the heavier path — real browser interaction — read [Browser automation](../browser-automation/).
- For how the turn assembles these tools each turn, read the [Tools runtime](../tools-runtime/) developer page.
- For the routes that bind a profile, read the [Console API reference](../console-api/).
