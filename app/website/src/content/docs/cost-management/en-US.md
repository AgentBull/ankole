---
title: Cost management
description: The levers that control what Ankole spends — model-profile tiers, reasoning effort, web-tool gating, agent-loop budgets, and background-job retry and slot caps.
section: Guides
order: 314
---

Most of what Ankole spends is model tokens, and most of *that* is decided by a small set of configuration levers, not by usage you cannot shape. This page names the levers, says what each one costs and saves, and gives the order to pull them when the bill is too high. Every lever here is a real knob in the control plane; none of it is "use the agent less."

The decisive property, stated up front: cost is a function of *which model runs, how many times, and for how long*. The levers map to those three: the model-profile tiers pick the model, the agent-loop budgets cap the iterations, and the job-retry and slot caps bound the runaway cases. Pull the one that matches where the spend is.

## Lever 1: the model-profile tiers

The ten profile slots are the biggest lever. Each one is a model choice, and model choice dominates token cost.

| Slot | When it runs | Cost lever |
|---|---|---|
| `primary` | the main reasoning model — most turns | the single biggest cost line |
| `light` | high-volume, low-stakes paths | should be genuinely cheap |
| `heavy` | hard synthesis | expensive; used rarely if `primary` is well-tuned |
| Background Agent Jobs (`coding` internally) | every Background Agent Job | selects the provider and model for durable background work |
| `vision_fallback` | when `primary` cannot handle an image | only bound if the agent sees images |
| `embedding`, `rerank` | memory and retrieval | priced per-call, usually small |
| `web_search`, `web_fetch` | web tools | see Lever 3 |
| `image_generate` | image generation | expensive per call; only bound if used |

Two moves save the most:

- **Bind `light` to something genuinely cheap.** It exists for the high-volume path; a `light` that is nearly as expensive as `primary` defeats the slot.
- **Turn `primary` down, not up, by default.** An agent that "feels expensive" is often a `primary` bound too heavy for the work it actually does. Move up only when quality demands it.

Unbind a slot the agent does not use. `vision_fallback` then cannot incur calls. An empty `image_generate` profile can still use native image generation when the main provider declares that capability. Background Agent Jobs are different: if their profile is unset, they still run through AIGateway with the Agent's `heavy` profile as the fallback. Configure this profile when Jobs need a different provider or model.

## Lever 2: reasoning effort

For providers that support Codex reasoning effort, `model_reasoning_effort` is a seven-step dial: `minimal | low | medium | high | xhigh | max | ultra`. Lower effort is cheaper and faster; higher effort is better on hard problems and costs more. The default is `high`.

This is a finer-grained lever than swapping the model. An agent whose `primary` is fine at `medium` but configured at `high` spends more for no visible gain. Set it on the `primary` profile to match the agent's actual work; raise it for the one agent that does hard synthesis, not for all of them.

## Lever 3: web tools, on demand

`web_search` and `web_fetch` are independent profiles, and each call costs. Two moves:

- **Unbind them when the agent does not need the web.** An internal-only assistant should not have `web_search` bound; the slot existing is a license to call.
- **Prefer `web_fetch` over `web_search` when you know the URL.** Fetching a known source is one call; searching is one call plus the fetches the agent decides to make.

The `worker.rendered_fetch_idle_ttl_ms` AppConfigure key controls how long a rendered fetch result is cached — a higher TTL saves repeat fetches of the same URL at the cost of staleness.

## Lever 4: agent-loop budgets

Three AppConfigure keys cap the per-turn spend:

| Key | What it caps |
|---|---|
| `ai_agent.max_iterations` | the agent loop's iteration budget per turn |
| `ai_agent.max_output_tokens` | the per-turn output token cap |
| `ai_agent.inactivity_timeout_ms` | how long a turn may be inactive before it is reaped |

`max_iterations` is the one that bounds a chatty agent loop. A loop that calls ten tools where two would do hits the model ten times; a lower cap forces the agent to converge. `max_output_tokens` bounds the size of each response. These are instance-wide defaults — set them to the shape of a normal turn, and accept that a genuinely hard turn may hit the cap and produce a "synthesize what you have" final answer.

## Lever 5: background-job retry and slot caps

Background jobs can spend tokens on retries, and the caps are the lever:

| Cap | Value | Effect |
|---|---|---|
| `max_execution_attempts` | 5 | a job retries up to five times before `failed` |
| `max_consecutive_turn_failures` | 5 | consecutive turn failures before the job gives up |
| `max_running_per_agent` | 3 | at most three running jobs per agent |
| retry delay | ~30s | the floor between retries |
| `agent_computer.background_agent_job.max_turns_per_worker` | configurable | per-worker turn cap for jobs |

A job that fails transiently five times spends five runs' worth of tokens. Most of the time the caps protect you — a configuration error fails fast and stays failed. The lever to watch is the third one: an agent with three concurrent jobs is running three model loops at once. If you do not need that parallelism, the persona ("do one thing at a time") is cheaper than the cap allows.

## Where the spend actually is

Before you change models or concurrency, use the Console to find the Agent, conversation, or Background Agent Job that made the calls:

- `GET /ai-gateway/conversations` shows the model calls recent turns made — which profiles resolved, how many calls, which providers. This is the fastest way to see whether the spend is `primary` (volume), `heavy` (a few expensive calls), or `web_search` (many small calls).
- `GET /background-agent-jobs` shows job `attempts` — a job with `attempts: 5` spent five runs.
- The structured control-plane logs carry the event names and fields for provider calls; your log ingester can aggregate by provider and by agent.

The fix is never "use the agent less." It is "this specific lever is set wrong for this specific agent's work."

## A worked example

A deployment instance's bill doubles in a week. The conversations surface shows `primary` calls are normal, but `web_search` calls are up tenfold — a team-assistant agent with `may_intervene` started searching on every channel message. The fix is the persona ("search only when someone asks a factual question"), not a cost lever. The bill was a symptom of a judgment problem; the persona is where judgment lives.

This is the pattern: cost problems are often behavior problems in disguise, and the behavior lever is the persona or the binding policy, not a token cap.

## What cost management is not

It is not a real-time spend dashboard — Ankole does not emit one. It is not a way to cap spend at a dollar amount; the levers cap *calls and iterations*, and the dollar amount is the provider's rate times those. And it is not a substitute for reading the conversations surface; the levers are only worth pulling once you know which one is set wrong.

## Next steps

- For Agent model profiles, read [Agents](../agents/#wire-up-its-models).
- For the agent-loop knobs and their keys, read [Environment variables](../environment-variables/).
- For the related conversation and Job endpoints, read [Console API reference](../console-api/).
- For the Job caps, read [Background Agent Jobs](../background-jobs/).
