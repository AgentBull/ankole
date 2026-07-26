---
title: Web tools
description: Configure web search and page reading for an Agent, and know when to use a browser instead.
section: User guide
order: 33
---

An Agent can use `web_search` to find public pages and `web_fetch` to read selected pages. `web_search` requires a Provider.

`web_fetch` prefers a configured Provider, but it can use the Worker's built-in rendered fallback when the Provider is unavailable.

## Select the correct tool

| Capability | Use it for | Execution surface |
|---|---|---|
| `web_search` | Find public pages by keyword, time, or source scope | Main Agent and Background Agent Jobs |
| `web_fetch` | Read one or more known public URLs as text | Main Agent and Background Agent Jobs |
| [Browser automation](../browser-automation/) | Sign in, click, type, paginate, take screenshots, and read interactive pages | **Background Agent Jobs only** |

Browser automation comes from the `browser` Skill and declares `ankole-runtime: background_job`. It does not appear in the `web_search` or `web_fetch` Provider lists, and it cannot run directly in a normal main-Agent turn.

When a task needs a browser, ask the main Agent to create or use a Background Agent Job. The Job does not block the current conversation and sends questions, state, or results back when needed.

## Configure Web tools

### Add Providers

1. Open **Console → LLM Providers**.
2. Select a Provider kind that supports `web_search`, `web_fetch`, or both.
3. Enter the API key and the required Provider fields.
4. Save it and confirm that the Provider is enabled.

You can create several instances of one Provider kind. For example, two Bright Data SERP instances can use different regions or serve different Agents.

### Assign Providers to an Agent

1. Open **Console → Agents** and select the Agent.
2. In **Model profiles**, find `web_search` and select a Provider that supports search.
3. Find `web_fetch` and select a Provider that supports page reading.
4. Save both profiles and start a new conversation.

These are Provider-only profiles. They do not require a model or a context length. Each Provider kind declares its capabilities, so the list contains only matching instances.

If the list is empty, add a matching Provider first. See [Quick start](../quickstart/#3-add-an-llm-provider-and-create-an-agent) for the first Provider setup.

## Current built-in Providers

A Control Plane Plugin can add more Provider kinds. The following kinds are built into Ankole now.

### `web_search` Providers

| Provider | Also supports `web_fetch` | Main difference | Use it when |
|---|---|---|---|
| **Parallel** | Yes | One Provider supplies search and extraction; supports an objective, several queries, modes, and a total character budget | You want one credential for search and reading, or you have a research-oriented query |
| **Bright Data SERP** | No | Uses a SERP API; requires a Zone and can select country, language, and Google domain | You must control the search region, language, or localized results |
| **Jina Search** | No | Supports region, location, language, page, cache, and search-engine options | You need direct web search with region, pagination, or cache controls |
| **AgentBull Cloud** | No | Aggregates search sources and supports source scope, time range, and cache bypass | You need metasearch or an explicit source and time scope |

One Parallel Provider instance can be assigned to both `web_search` and `web_fetch`.

Jina Search and Jina Reader are different Provider kinds. Add them separately and assign each one to its matching profile, even when they use the same Jina credential.

### `web_fetch` Providers

| Provider | Also supports `web_search` | Main difference | Use it when |
|---|---|---|---|
| **Parallel** | Yes | Uses the same Provider and credential as Parallel Search to extract page text | You already use Parallel Search and want one configuration |
| **Jina Reader** | No | Converts a public page to Markdown; supports retained links, target and wait selectors, cache, engine, and token limits | You need article text or a selected part of a page |

`web_fetch` is for public HTTPS pages. It does not sign in and is not a downloader for PDFs, images, archives, audio, or video.

The Worker's built-in rendered fallback is not a Provider, so it does not appear in the Console Provider list. It only reads rendered page text.

The fallback cannot click, type, reuse login state, or take screenshots. It does not give browser automation to the main Agent.

Selectors and wait options can help a Provider read delayed page text, but they do not provide real interaction. Use browser automation in a Background Agent Job when a task needs login, clicks, or form input.

## Ask the Agent to use Web tools

You do not need a special command. Describe the result that you want. For example:

> Find three relevant announcements from this week. Read the original pages, compare the changes, and include source links.

The Agent searches first and then selects pages to read. If you already know the URL, send it to the Agent and ask it to read and summarize the page.

Explicitly ask for a browser when:

- the page requires a login;
- the Agent must click, type, or change pages before it can see the content;
- the task needs a screenshot or a check of the rendered page;
- the content appears only after complex interaction.

Browser work runs in a Background Agent Job. Use `web_search` and `web_fetch` directly for ordinary search, public page reading, and multi-source comparison.

## If a Web task does not work

### Search or fetch failed

Check these items in order:

1. The current Agent has the profiles that the task needs. `web_search` requires a Provider.
2. If `web_fetch` has no Provider, the Worker supplies the built-in rendered fallback.
3. The selected Provider kind declares the required capability.
4. The Provider is enabled and its credentials and required fields are valid.
5. You started a new conversation after you changed the profiles.
6. The target is a public HTTPS page that does not require a login.

### Browser automation did not run

Confirm that the Agent has the `browser` Skill enabled and can create a Background Agent Job. Do not try to assign browser automation to a `web_search` or `web_fetch` profile.

If the task is already in a Background Agent Job, inspect Worker availability and any browser-session or access problem reported by the Job.
