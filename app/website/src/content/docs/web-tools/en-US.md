---
title: Web tools
description: Configure web search and page reading for an Agent, and know when to use a browser instead.
section: User guide
order: 33
---

Agents use `web_search` to discover public web pages and `web_fetch` to read specific URLs. While `web_search` requires an external Provider, `web_fetch` falls back to the Worker's built-in rendered page reader whenever no `web_fetch` Provider is configured.

## Select the correct tool

| Capability | Use it for | Execution surface |
|---|---|---|
| `web_search` | Finding public pages by query, recency, or domain scope | Main Agent and Background Agent Jobs |
| `web_fetch` | Extracting readable text from one or more known public URLs | Main Agent and Background Agent Jobs |
| [Browser automation](../browser-automation/) | Signing in, clicking, typing, paginating, capturing screenshots, and driving interactive web apps | **Background Agent Jobs only** |

Browser automation is provided by the `browser` Skill (`ankole-runtime: background_job`), so it never appears in the `web_search` or `web_fetch` Provider dropdowns and cannot run inline during a main-Agent chat turn. Whenever a task requires interactive browsing, ask the Main Agent to delegate the work to a Background Agent Job, which runs asynchronously without blocking the chat and reports back with questions, progress, or final results.

## Configure Web tools

### Add Providers

1. Open **Console → LLM Providers**.
2. Choose a Provider kind that supports `web_search`, `web_fetch`, or both.
3. Enter the API key along with any provider-specific fields.
4. Save the Provider and confirm that it is enabled.

You can configure multiple instances of the same Provider kind—for example, two Bright Data SERP instances targeting different countries or serving separate Agents.

### Assign Providers to an Agent

1. Open **Console → Agents** and select the Agent.
2. Under **Model profiles**, locate `web_search` and choose a search-capable Provider.
3. Locate `web_fetch` and choose a fetch-capable Provider (or leave it empty to use the Worker fallback).
4. Save both profiles and start a new conversation.

Because `web_search` and `web_fetch` are Provider-only profiles, you select only a Provider instance—no model name or context window is needed—and the Console automatically filters each dropdown to Providers that declare that capability. If a dropdown is empty, add a compatible Provider under **LLM Providers** first; see [Quick start](../quickstart/#3-add-an-llm-provider-and-create-an-agent).

## Current built-in Providers

Control Plane Plugins can register additional Provider kinds; the following web Providers ship built into Ankole.

### `web_search` Providers

| Provider | Also supports `web_fetch` | Main difference | Use it when |
|---|---|---|---|
| **Parallel** | Yes | Combines search and extraction in one Provider; accepts a research objective, multiple queries, modes, and a character budget | You want a single credential for search and page reading, or run research-heavy queries |
| **Bright Data SERP** | No | Backed by a SERP API; requires a Zone and supports country, language, and Google domain targeting | You need strict control over search geography, language, or localized SERPs |
| **Jina Search** | No | Exposes region, location, language, pagination, cache, and search-engine parameters | You want direct web search with fine-grained region, pagination, or cache controls |
| **AgentBull Cloud** | Yes | Unifies search and page extraction with model capabilities (`llm`, `embedding`, `rerank`, `image_generate`), supporting source scopes, time ranges, and cache bypass | You prefer a single API key across models and web tools, or need source and recency filtering |

You can bind a single **Parallel** or **AgentBull Cloud** Provider instance to both `web_search` and `web_fetch`. By contrast, **Jina Search** and **Jina Reader** are distinct Provider kinds—create one instance of each and bind them to their respective profiles, even when both share the same Jina API key.

### `web_fetch` Providers

| Provider | Also supports `web_search` | Main difference | Use it when |
|---|---|---|---|
| **Parallel** | Yes | Reuses your Parallel Search Provider and API key for page extraction | You already use Parallel Search and want a single Provider entry |
| **AgentBull Cloud** | Yes | Reuses your AgentBull Cloud Provider and API key for public page extraction | You already use AgentBull Cloud for models or search |
| **Jina Reader** | No | Converts public web pages to clean Markdown with link retention, CSS target/wait selectors, caching, engine choice, and token caps | You want clean article Markdown or extraction scoped to specific CSS selectors |

`web_fetch` reads public HTTPS pages as text—it cannot authenticate behind login walls and is not meant for downloading binary files such as PDFs, images, archives, audio, or video.

When `web_fetch` is left unbound, Ankole uses the Worker's built-in rendered fallback (which does not appear in the Console Provider list). That fallback renders the page to extract visible text, but cannot click elements, type into inputs, persist login sessions, or capture screenshots, nor does it grant interactive browser automation to the Main Agent. Similarly, CSS wait and target selectors on a `web_fetch` Provider help capture late-rendered DOM text, not multi-step interaction—use [browser automation](../browser-automation/) in a Background Agent Job whenever a site requires signing in, clicking, or filling forms.

## Ask the Agent to use Web tools

No special slash command is required—simply describe what you want researched or read:

> Find three relevant announcements from this week. Read the original pages, compare the changes, and include source links.

The Agent runs `web_search` first and then calls `web_fetch` on the most relevant URLs; if you already have a URL, paste it directly and ask for a summary or extraction.

Ask the Agent to use browser automation in a Background Agent Job instead whenever:

- the page sits behind a login;
- the Agent must click tabs, paginate, or submit forms before the data appears;
- you need a visual screenshot or layout inspection of the rendered page; or
- content loads only after multi-step client-side interaction.

For straightforward search, public documentation reading, and multi-source synthesis, `web_search` and `web_fetch` are faster and lighter.

## If a Web task does not work

### Search or fetch failed

Verify these points in order:

1. Check that the Agent has the required profiles bound (`web_search` always requires an enabled Provider, whereas `web_fetch` falls back to the Worker reader when unbound).
2. Confirm that the chosen Provider kind supports that capability.
3. Verify that the Provider is enabled and its API key and required settings (such as a Bright Data Zone) are valid.
4. Start a fresh conversation if you updated the Agent's profiles after the current chat began.
5. Confirm that the target URL is a public HTTPS page that does not require authentication.

### Browser automation did not run

Confirm that the `browser` Skill is enabled for the Agent and that the Agent can launch Background Agent Jobs—never try to bind browser automation inside the `web_search` or `web_fetch` profile slots. If the task is already running inside a Background Agent Job, check Worker health under **Console → Workers** and inspect any browser or network error reported in the Job log.
