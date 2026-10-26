---
title: Cost management
description: The configuration levers that control Ankole token and tool spend across model profiles, reasoning effort, web tools, turn budgets, Workflow fanout, background-job caps, and per-Agent token quotas.
section: Guides
order: 314
---

Model tokens account for most of Ankole's operational cost. Control-plane settings govern which model runs, how many iterations a turn executes, and how much background fanout or retry work can occur. Every lever on this page maps to a concrete control-plane setting.

## Lever 1: model-profile tiers

Eight built-in Agent profiles control separate paid paths. Five select language models, and three bind web-search, web-fetch, and image-generation capabilities.

| Slot | When it runs | Cost impact |
|---|---|---|
| `primary` | Main reasoning model for most turns | Largest single cost driver |
| `light` | High-volume, low-complexity paths | Keep bound to a low-cost model |
| `heavy` | Complex synthesis | High cost per call; used sparingly when `primary` fits normal work |
| Background Agent Jobs (`coding` internally) | Every Background Agent Job | Selects the provider and model for durable background work |
| `vision_fallback` | When `primary` cannot process an image | Bind only when the Agent receives images |
| `web_search`, `web_fetch` | Web tools | See Lever 3 |
| `image_generate` | Image generation | High cost per call; bind only when needed |

Two tenant-scoped [AppConfigure](../app-configuration/) keys attribute subsystem model calls to designated Agents:

- **`brain.maintainer_agent_uid`**: Selects the active Brain maintainer Agent for the tenant. All Brain model calls run as this Agent and attribute usage to it (`light` extracts conversations and Sources, `heavy` runs Dreaming and Skill lesson review, and `web_fetch` reads URL Sources). Brain also reads the site embedding model and tenant rerank model from `AppConfigure`. Disabling the maintainer Agent stops Brain model calls and URL Source fetching until the Agent is enabled or replaced. **Brain → Health** reports the selected Agent and profile status; see [Brain](../brain/).
- **`pod.applet.ai_agent_uid`**: Selects the active Agent for Pod Applet `ctx.ai` model calls in the tenant and attributes those calls and token usage to that Agent.

Two profile adjustments save the most spend:

- **Bind `light` to a low-cost model.** `light` serves high-volume paths; binding it to a model priced near `primary` removes that savings tier.
- **Size `primary` for normal turns.** Start with a smaller model for `primary` and move to a larger tier only when task quality requires it.

Unbind slots that an Agent does not use so `vision_fallback` cannot incur calls. An empty `image_generate` profile can still use native image generation when the main provider declares that capability. Background Agent Jobs fall back to the Agent's `heavy` profile through AIGateway when their dedicated profile is unset; configure the Background Agent Job profile when Jobs require a separate provider or model.

## Lever 2: reasoning effort

For providers that support Codex reasoning effort, `model_reasoning_effort` offers seven levels: `minimal | low | medium | high | xhigh | max | ultra`. Lower effort reduces latency and token cost; higher effort improves hard synthesis at higher token cost. The default is `high`.

Adjust `model_reasoning_effort` on an Agent's `primary` profile before switching to a larger model. Reserve `high` and above for Agents that perform difficult synthesis rather than routine operational turns.

## Lever 3: web tools

`web_search` and `web_fetch` are independent profiles that bill per call:

- **Unbind unused web slots.** Internal-only Agents should leave `web_search` unbound so the model cannot invoke external search.
- **Prefer `web_fetch` over `web_search` when the URL is known.** Fetching a known URL takes one call, whereas searching adds a search call plus follow-up fetches.

The `worker.rendered_fetch_idle_ttl_ms` [AppConfigure](../app-configuration/) key sets the idle timeout before an unused rendered `web_fetch` browser sidecar route is released. It controls Worker browser memory retention rather than caching URL responses.

## Lever 4: agent-loop budgets

Three tenant-scoped (`scope: :tenant`) [AppConfigure](../app-configuration/) keys cap per-turn spend:

| Key | What it caps |
|---|---|
| `ai_agent.max_iterations` | Agent-loop model iterations per turn |
| `ai_agent.max_output_tokens` | Output token cap per turn |
| `ai_agent.inactivity_timeout_ms` | Maximum idle time before an inactive turn is reaped |

`ai_agent.max_iterations` bounds multi-step tool loops, and `ai_agent.max_output_tokens` bounds the size of each model response. Both `ai_agent.*` keys are tenant-scoped defaults (inheriting the site default when a tenant has no override). Size them for normal turns in each tenant; when a complex turn reaches `max_iterations`, the loop forces the Agent to synthesize a final answer from the results collected so far.

## Lever 5: Workflow fanout and task attempts

Each Workflow `agent()` attempt runs a complete model turn. One call can make up to three attempts, so a Workflow run with wide fanout multiplies model and web-tool usage from a single conversation request.

| AppConfigure key | Default | Maximum | What it controls |
|---|---:|---:|---|
| `workflow.max_concurrency_per_run` | 8 | 32 | Tasks from one run that can execute concurrently |
| `workflow.max_running_per_agent` | 8 | 64 | Running Workflow tasks across all runs of one Agent |
| `workflow.max_agent_calls_per_run` | 32 | 1,024 | Total subagent calls one run can create |

Concurrency changes elapsed wall-clock time; it does not reduce total model calls. Set `max_agent_calls` from the finite input size, and request only the concurrency required. A run can request lower `concurrency` and `max_agent_calls` values, but it cannot change `workflow.max_running_per_agent` or exceed an `AppConfigure` limit.

Workflow enforces per-turn iteration, output-token, and inactivity limits on each task rather than a batch-wide token budget. Keep task prompts narrow, return compact structured results, handle `null` failures explicitly, and split large collections across runs when needed. See [Workflows](../workflows/).

## Lever 6: background-job retry and slot caps

Background Agent Jobs consume tokens across execution attempts and concurrent slots:

| Cap | Value | Effect |
|---|---|---|
| `max_execution_attempts` | 5 | Maximum execution attempts before a job transitions to `failed` |
| `max_consecutive_turn_failures` | 5 | Consecutive turn failures before a job stops |
| `max_running_per_agent` | 3 (default) | Concurrent running jobs per Agent, configurable per tenant via `agent_computer.background_agent_job.max_running_per_agent` (`1..64`) |
| retry delay | ~30s | Minimum delay between retry attempts |

A job that hits transient failures five times consumes five runs of tokens, whereas configuration errors fail fast. Lower `agent_computer.background_agent_job.max_running_per_agent` (or instruct the Agent in its persona to run one job at a time) when a tenant does not need three concurrent background model loops per Agent.

## Lever 7: per-Agent token quota

The six levers above bound per-turn and per-job behavior. The per-Agent token quota caps total token consumption over a repeating period: when an Agent reaches its limit, AIGateway rejects further model calls for that Agent until the period ends.

Configure the period length (in days), period start time, and token limit on the Agent page. Conversations that hit the limit receive a reply with the used tokens, limit, and period end time; Background Agent Jobs at the limit fail immediately. Use **Reset period** to start a new period immediately during an authorized traffic spike. See [Agents](../agents/#set-a-token-quota).

## Inspect where spend occurs

Before changing models or concurrency, inspect the Agent, conversation, Workflow, or Background Agent Job that generated the calls:

- `GET /api/v2/ai-gateway/conversations` lists recent model calls, resolved profiles, call counts, and providers so you can distinguish high-volume `primary` traffic, expensive `heavy` calls, and frequent `web_search` calls.
- Ask the main Agent to inspect its Workflow run. Task counts show total fanout and failed attempts (Ankole does not expose a separate Workflow Console page or per-run currency total).
- `GET /api/v2/background-agent-jobs` reports job `attempts` so you can spot jobs that consumed multiple retry runs.
- Structured control-plane logs emit provider call events with Agent and provider fields for aggregation in your log store.

## Worked example

Suppose a tenant's weekly token spend doubles while `primary` call volume stays flat, and `/api/v2/ai-gateway/conversations` shows a tenfold jump in `web_search` calls from a channel assistant configured with `may_intervene`. Updating the Agent's persona instructions ("run `web_search` only when a participant asks an explicit factual question") or narrowing its Signal Binding policy resolves the spend at its source without throttling normal turns.

## Scope of cost controls

Ankole controls model selection, reasoning effort, tool availability, loop iterations, concurrency, and token quotas; it does not emit a real-time currency billing dashboard, because currency cost depends on your upstream provider's pricing tiers. Inspect conversation and job logs first, then adjust the specific lever responsible for the usage.

## Next steps

- For Agent model profiles and quotas, read [Agents](../agents/#configure-models).
- For `ai_agent.*`, `brain.*`, `pod.applet.*`, and `agent_computer.*` runtime settings, read [AppConfigure](../app-configuration/).
- For conversation and Background Agent Job endpoints, read [Console API reference](../console-api/).
- For bounded subagent fanout, read [Workflows](../workflows/).
- For Background Agent Job execution limits, read [Background Agent Jobs](../background-jobs/).
