---
title: Browser automation
description: How an Ankole agent drives a real browser session — the browser skill, when to use it instead of web_search/web_fetch, how to enable it, and why the agent must use the preconfigured ankole-browser CLI instead of launching Chromium itself.
section: Guides
order: 305
---

The `browser` Skill lets an Agent drive a real browser session—opening pages, clicking, typing, reading rendered state, taking screenshots, and running reproducible Playwright scripts against a live session. Shipped as a [Skill](../agent-library/) rather than a built-in foreground tool, it executes inside a [Background Agent Job](../background-jobs/). This page explains what the Skill is, when to enable it, and what an Agent may and may not do with the browser.

Each Agent session has a single browser owner: the Worker runtime, never the Agent itself. The Agent drives Chromium exclusively through the preconfigured `ankole-browser` CLI that the Worker image injects, and must never launch Chromium directly or call `chromium.connectOverCDP`—doing either creates a competing owner and breaks session recovery.

## What browser automation is

Browser automation in Ankole is packaged as the `browser` Skill at `app/library/skills/browser/SKILL.md`. It ships as a `builtin` Skill (`default_enabled: true`) scoped to the background-job runtime (`ankole-runtime: background_job`). When an Agent invokes it, execution runs inside a Background Agent Job isolated from the foreground turn, driving a real Chromium session owned by the Worker runtime.

The Skill's description sets the contract that the model reads when choosing tools: use `browser` when the task depends on rendered DOM state, interactive clicks or form fills, screenshots, persistent login sessions, or a repeatable Playwright script; prefer [web_search](../web-tools/) or [web_fetch](../web-tools/) for ordinary discovery and text extraction.

## When to use the browser

Driving a full browser is heavyweight—reserve it for work where an HTTP fetch falls short:

- **Rendered interaction** — the page reveals the target data only after client-side JavaScript executes or after clicking, scrolling, or filling inputs.
- **Persistent login state** — the task relies on an authenticated browser session that the runtime maintains and that a stateless HTTP fetch cannot reproduce.
- **Screenshots** — the task requires visual output or human inspection of the rendered page.
- **A reproducible Playwright workflow** — the same multi-step browser routine needs to run reliably more than once.

Whenever you only need to locate a public page or extract its readable text, prefer `web_search` or `web_fetch`. As the `browser` Skill itself instructs the model, fetching is faster, cheaper, and avoids occupying a live browser session when rendered interaction, login state, screenshots, or client-side scripts are unnecessary.

## How to enable it

Because `browser` is a Skill rather than a standalone tool flag, you manage it through the [Agent Library](../agent-library/). With `default_enabled: true`, newly created Agents can use it out of the box unless you restrict it at one of two layers:

1. **Tenant default** — `browser` defaults to `default_enabled: true` in the tenant's Agent Library catalog; keep it enabled to make browser automation available across the tenant.
2. **Per-Agent override** — disable `browser` for specific Agents that must never run Chromium, or enable it selectively when the tenant default is turned off.

Operators configure both layers through the Console's library-capability endpoints (see the [Console API reference](../console-api/)). Fetching an Agent's `library-capabilities` triggers an immediate skill sync so the response always reflects the current filesystem and catalog state.

## What the runtime injects

Agents never configure browser connection parameters themselves. Before a browser job starts, the Worker runtime injects opaque handles for everything that the job needs:

- an **opaque route** into the runtime-owned browser session
- the **final browser material** (the prepared session that the Agent drives)
- a **daemon socket** that the CLI communicates over
- an **artifact root** for screenshots and other captured outputs

Inside `app/agent_computer/src/browser-runtime/index.ts`, `BrowserRuntime` owns the session materializer, daemon supervisor, and `web_fetch` rendered fallback, managing the entire browser lifecycle while the Agent simply calls `ankole-browser`.

## The constraint: one browser owner

Every Agent must obey one strict ownership rule—the Worker runtime is the sole browser owner:

- **Use the preconfigured `ankole-browser` CLI** for every operation: `open`, `snapshot`, `click`, `fill`, `screenshot`, `batch`, and `run` for Playwright scripts.
- **Never launch Chromium directly.**
- **Never call `chromium.connectOverCDP`** or probe for profile names, credentials, provider configs, raw CDP endpoints, or control-plane identifiers.

This rule protects crash and session recovery. `BrowserRuntime` supervises the daemon, materializes profiles, and recovers interrupted sessions; if an Agent spawns its own Chromium binary or opens a raw CDP socket, that side channel sits outside `BrowserRuntime`. When the runtime checkpoints, recovers, or tears down the session, it cannot see or clean up the unmanaged connection, leaving the browser in an inconsistent state. Keeping `ankole-browser` as the single entry point preserves clean lifecycle control.

## How the agent drives the browser

`ankole-browser` exposes three execution modes matched to the complexity of the step:

- **Short CLI commands** for page exploration and one or two discrete actions: `open`, `snapshot -i`, `click @e2`, `fill @e4 "value"`, `screenshot`.
- **`batch`** for a known short sequence, accepting quoted commands or a JSON array of argv arrays on stdin and parsing them identically to single commands.
- **`run`** for an ESM JavaScript file whenever the task requires loops, conditionals, multi-page extraction, popup or download handling, fine-grained waits, or in-memory state. `run` attaches native Playwright objects directly to the same browser session that CLI commands use, so scripted steps and single CLI calls share one live session.

Crucially, `ankole-browser run` never spawns a second browser—it attaches to the runtime-owned session, upholding the single-owner rule even inside full Playwright scripts.

## What the operator does not touch

The Worker image sets internal browser environment variables—including `ANKOLE_BROWSER_CHROMIUM_EXECUTABLE`, `ANKOLE_BROWSER_DAEMON_SOCKET`, `ANKOLE_BROWSER_DAEMON_ENTRY`, and `ANKOLE_BROWSER_RUNNER`—and Ankole blocks overriding those names under **Console → Environment variables**. Edit the Skill itself if you need custom browser behavior.

## Next steps

- For the skill and enablement model that turns the browser on, read [Agent Library](../agent-library/).
- For the lighter alternative — search and text fetch without a browser — read [Web tools](../web-tools/).
- For the Job that runs the browser, read [Background Agent Jobs](../background-jobs/).
