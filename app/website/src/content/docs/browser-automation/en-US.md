---
title: Browser automation
description: How an Ankole agent drives a real browser session — the browser skill, when to use it instead of web_search/web_fetch, how to enable it, and why the agent must use the preconfigured ankole-browser CLI instead of launching Chromium itself.
section: Guides
order: 305
---

The browser skill is what lets an agent do real browser work — open pages, click, type, read rendered state, take screenshots, and run a reproducible Playwright script against a live session. It is a [skill](../agent-library/), not a built-in tool, and it runs as a [background job](../background-jobs/). This page is the operator view: what the skill is, when to turn it on, and what the agent is and is not allowed to do with the browser.

The decisive property, stated up front: there is one browser owner per agent session, and it is the runtime, not the agent. The agent drives the browser through the preconfigured `ankole-browser` CLI the worker image injects. It must not launch Chromium itself or call `chromium.connectOverCDP` — those create a second owner and bypass session recovery.

## What browser automation is

Browser automation in Ankole is the `browser` skill, shipped at `app/library/skills/browser/SKILL.md`. It is a builtin skill (`default_enabled: true`) tagged for the background-job runtime (`ankole-runtime: background_job`). When an agent invokes it, the work runs inside a background job, isolated from the owning turn, against a real Chromium session that the runtime owns.

The skill's own description is the contract the model reads to decide whether to use it: use the browser when the work depends on rendered page state, interaction, screenshots, persistent login state, or a reproducible Playwright workflow; prefer [web_search](../web-tools/) or [web_fetch](../web-tools/) for ordinary discovery and text extraction.

## When to use the browser

The browser is the heavyweight path. Use it only when a fetch is not enough. Concretely:

- **Rendered interaction** — the page only shows the data you need after JavaScript runs, or after you click, scroll, or fill a field.
- **Persistent login state** — you need a session the runtime has already authenticated, and you cannot reproduce the login with a simple fetch.
- **Screenshots** — the task needs a visual artifact, or a human needs to see the page state.
- **A reproducible Playwright workflow** — the same multi-step browser routine must run more than once.

Use `web_search` or `web_fetch` instead when you only want to find a page or read its text. The browser skill says so itself: those tools are outside this skill, and you should prefer them when rendered interaction, login state, screenshots, or browser-side code are unnecessary. Fetching is cheaper, faster, and does not consume a browser session.

## How to enable it

Browser is a skill, so you turn it on through the [Agent Library](../agent-library/), not through a tool flag. Because `default_enabled` is `true`, a fresh agent already has the browser available unless you narrow it. The two layers:

1. **Instance-wide default** — the skill ships `default_enabled: true`. Leave it alone to keep the browser available to every agent.
2. **Per-agent override** — narrow it for an agent that should not have a browser, or widen it for one you previously narrowed.

Both layers are set through the Console's library-capability routes, covered in the [Console API reference](../console-api/). Reading an agent's `library-capabilities` triggers a skill sync, so what you see is the registry reconciled against the current filesystem, not a stale snapshot.

## What the runtime injects

The agent never selects browser configuration itself. Before the browser job starts, the runtime injects everything the job needs, and the values are opaque to the agent:

- an **opaque route** into the runtime-owned browser session
- the **final browser material** (the prepared session the agent drives)
- a **daemon socket** the CLI talks to
- an **artifact root** for screenshots and other outputs

The agent uses these through the `ankole-browser` CLI. The `BrowserRuntime` class in `app/agent_computer/src/browser-runtime/index.ts` owns the materializer, the daemon supervisor, and the web-fetch adapter, so the lifecycle of the browser session is the runtime's responsibility. The agent's responsibility is to call the CLI.

## The constraint: one browser owner

This is the rule the agent must not break. The runtime is the browser owner. The agent must:

- **Use the preconfigured `ankole-browser` CLI** for everything — open, snapshot, click, fill, screenshot, batch, and `run` for a Playwright script.
- **Not launch Chromium itself.**
- **Not call `chromium.connectOverCDP`** or look for profile names, credentials, provider configuration, CDP endpoints, or control-plane identifiers.

The reason is recovery. The runtime owns the daemon supervisor, the materializer, and the session-recovery path. A second browser owner — a Chromium the agent spawned, or a CDP connection the agent opened — sits outside that path. When the runtime tries to recover, checkpoint, or tear the session down, it cannot see or control the agent's side channel, so the session ends in an inconsistent state. The preconfigured CLI is the single, owned entry point, and it is the only one the agent should touch.

## How the agent drives the browser

The `ankole-browser` CLI gives the agent three execution surfaces, picked by the shape of the work:

- **Short CLI commands** for exploration and one or two deterministic actions — `open`, `snapshot -i`, `click @e2`, `fill @e4 "value"`, `screenshot`.
- **`batch`** for a known short sequence, taking quoted commands or an array of argv arrays on stdin and applying the same parser as individual commands.
- **`run`** for an ESM JavaScript file when the task needs a loop, branch, repeated extraction, popup or download coordination, precise waiting, or several values kept in memory. `run` attaches native Playwright objects to the same physical browser session the CLI commands use, so a script and CLI steps share one session.

That last point matters: `run` does not open a second browser. It reuses the runtime-owned session, so the one-owner rule holds even inside a Playwright script.

## What the operator does not touch

The worker image sets the browser environment variables. They include `ANKOLE_BROWSER_CHROMIUM_EXECUTABLE`, `ANKOLE_BROWSER_CHROMIUM_ARGS_JSON`, `ANKOLE_BROWSER_DAEMON_SOCKET`, `ANKOLE_BROWSER_DAEMON_ENTRY`, `ANKOLE_BROWSER_CLI`, and `ANKOLE_BROWSER_RUNNER`. You cannot override these names in **Environment variables** in the Console. Change the Skill if you need different browser behavior.

## Next steps

- For the skill and enablement model that turns the browser on, read [Agent Library](../agent-library/).
- For the lighter alternative — search and text fetch without a browser — read [Web tools](../web-tools/).
- For the Job that runs the browser, read [Background Agent Jobs](../background-jobs/).
