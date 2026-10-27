---
title: Cost management
description: The configuration levers that control Ankole token and tool spend across model profiles, reasoning effort, web tools, turn budgets, Workflow fanout, background-job caps, and per-Agent token quotas.
section: Guides
order: 314
---

Model tokens account for most of Ankole's operational cost, so control-plane settings give you direct control over which models run, how many iterations a turn executes, and how much background fanout or retry work can occur. Every lever on this page maps to a concrete control-plane setting.

## Lever 1: model-profile tiers

Each Agent exposes eight built-in profiles that govern separate paid paths: five select language models, while the other three bind web search, web fetch, and image generation.

| Slot | When it runs | Cost impact |
|---|---|---|
| `primary` | Main reasoning model for most turns | Largest single cost driver |
| `light` | High-volume, low-complexity paths | Keep bound to a low-cost model |
| `heavy` | Complex synthesis | High cost per call; used sparingly when `primary` fits normal work |
| Background Agent Jobs (`coding` internally) | Every Background Agent Job | Selects the provider and model for durable background work |
| `vision_fallback` | When `primary` cannot process an image | Bind only when the Agent receives images |
| `web_search`, `web_fetch` | Web tools | See Lever 3 |
| `image_generate` | Image generation | High cost per call; bind only when needed |

Subsystem model calls draw on an owning Agent's model profiles, quota, and usage attribution:

- **`brain.maintainer_agent_uid`**: Selects the active Brain maintainer Agent for the tenant. Brain executes all of its model calls as this Agent and attributes usage to it (`light` extracts conversations and Sources, `heavy` runs Dreaming and Skill lesson review, and `web_fetch` reads URL Sources), while reading the site embedding model and tenant rerank model from `AppConfigure`. If you disable the maintainer Agent, Ankole pauses Brain model calls and URL Source fetching until you re-enable or replace that Agent. **Brain → Health** reports the selected Agent and profile status; see [Brain](../brain/).
- **Pod Applet `ctx.ai`**: Runs as the active Agent that created the Applet, drawing from that Agent's model profiles and quota and attributing token usage to it.

Two profile adjustments save the most spend:

- **Bind `light` to a low-cost model.** Because `light` handles high-volume paths, binding it to a model priced near `primary` eliminates that savings tier.
- **Size `primary` for normal turns.** Start with a smaller model for `primary` and move up to a larger tier only when task quality demands it.

Unbind any slots that an Agent does not need so unused paths like `vision_fallback` cannot incur calls. Even if you leave `image_generate` empty, the Agent can still generate images natively whenever its main provider declares that capability. Similarly, when the dedicated Background Agent Job profile is unset, Jobs fall back to the Agent's `heavy` profile through AIGateway; configure the Background Agent Job profile whenever Jobs need a separate provider or model.

## Lever 2: reasoning effort

For providers that support Codex reasoning effort, `model_reasoning_effort` offers seven levels: `minimal | low | medium | high | xhigh | max | ultra` (defaulting to `high`). Lower effort reduces both latency and token spend, whereas higher effort improves difficult synthesis at higher token cost.

Before moving an Agent's `primary` profile to a larger model, try tuning `model_reasoning_effort` first, reserving `high` and above for Agents that tackle complex synthesis rather than routine operational turns.

## Lever 3: web tools

`web_search` and `web_fetch` are independent profiles that bill per call:

- **Unbind unused web slots.** Leave `web_search` unbound on internal-only Agents so the model cannot invoke external search.
- **Prefer `web_fetch` over `web_search` when you already know the URL.** Fetching a known URL takes a single call, whereas searching incurs a search call plus follow-up fetches.

The `worker.rendered_fetch_idle_ttl_ms` [AppConfigure](../app-configuration/) key sets the idle timeout before the Worker releases an idle browser-sidecar route used for rendered `web_fetch` calls. Adjusting this key controls how long the Worker retains browser memory rather than caching URL responses.

## Lever 4: agent-loop budgets

Three tenant-scoped (`scope: :tenant`) [AppConfigure](../app-configuration/) keys cap per-turn spend:

| Key | What it caps |
|---|---|
| `ai_agent.max_iterations` | Agent-loop model iterations per turn |
| `ai_agent.max_output_tokens` | Output token cap per turn |
| `ai_agent.inactivity_timeout_ms` | Maximum idle time before an inactive turn is reaped |

`ai_agent.max_iterations` bounds multi-step tool loops, while `ai_agent.max_output_tokens` bounds the length of each model response. Both `ai_agent.*` keys inherit the site default whenever a tenant has no override. Size them for normal turns in each tenant: when a complex turn reaches `max_iterations`, the loop prompts the Agent to synthesize a final answer from the results collected so far.

## Lever 5: Workflow fanout and task attempts

Each Workflow `agent()` attempt runs a complete model turn. Because a single `agent()` call can make up to three attempts, a Workflow run with wide fanout can multiply model and web-tool usage from one conversation request.

| AppConfigure key | Default | Maximum | What it controls |
|---|---:|---:|---|
| `workflow.max_concurrency_per_run` | 8 | 32 | Tasks from one run that can execute concurrently |
| `workflow.max_running_per_agent` | 8 | 64 | Running Workflow tasks across all runs of one Agent |
| `workflow.max_agent_calls_per_run` | 32 | 1,024 | Total subagent calls that one run can create |

Increasing concurrency shortens wall-clock time without reducing total model calls, so size `max_agent_calls` from the finite input collection and request only the concurrency you need. A Workflow program can request lower `concurrency` and `max_agent_calls` values for a run, whereas `workflow.max_running_per_agent` is operator-only and no run can exceed an `AppConfigure` limit.

Because Workflow enforces per-turn iteration, output-token, and inactivity limits on each task rather than a batch-wide token budget, keep task prompts narrow, return compact structured results, handle `null` failures explicitly, and split large collections across runs when needed. See [Workflows](../workflows/).

## Lever 6: background-job retry and slot caps

Background Agent Jobs consume tokens across execution attempts and concurrent slots:

| Cap | Value | Effect |
|---|---|---|
| `max_execution_attempts` | 5 | Maximum execution attempts before a job transitions to `failed` |
| `max_consecutive_turn_failures` | 5 | Consecutive turn failures before a job stops |
| `max_running_per_agent` | 3 (default) | Concurrent running jobs per Agent, configurable per tenant via `agent_computer.background_agent_job.max_running_per_agent` (`1..64`) |
| retry delay | ~30s | Minimum delay between retry attempts |

If a job hits transient failures, Ankole retries it up to five times—consuming tokens on each attempt—whereas configuration errors fail immediately without retrying. Lower `agent_computer.background_agent_job.max_running_per_agent` (or instruct the Agent in its persona to run one job at a time) whenever a tenant does not need three concurrent background model loops per Agent.

## Lever 7: per-Agent token quota

While the six levers above bound per-turn and per-job behavior, the per-Agent token quota caps cumulative token consumption over a repeating period: once an Agent reaches its limit, AIGateway rejects further model calls for that Agent until the period ends.

Configure the period length (in days), period start time, and token limit on the Agent page. When a conversation hits that limit, Ankole replies with the tokens used, the configured limit, and the period end time; Background Agent Jobs at the limit fail immediately. During an authorized traffic spike, click **Reset period** to start a fresh quota period right away. See [Agents](../agents/#set-a-token-quota).

## Inspect where spend occurs

Before changing models or concurrency, check which Agent, conversation, Workflow, or Background Agent Job actually generated the calls:

- `GET /api/v2/ai-gateway/conversations` lists recent model calls, resolved profiles, call counts, and providers so you can distinguish high-volume `primary` traffic, expensive `heavy` calls, and frequent `web_search` calls.
- Ask the main Agent to inspect its Workflow run directly; task counts show total fanout and failed attempts (Ankole does not expose a separate Workflow Console page or per-run currency total).
- `GET /api/v2/background-agent-jobs` reports job `attempts` so you can spot jobs that burned multiple retry runs.
- Structured control-plane logs emit provider call events tagged with Agent and provider fields for aggregation in your log store.

## Worked example

Suppose a tenant's weekly token spend doubles while `primary` call volume stays flat, and `/api/v2/ai-gateway/conversations` reveals a tenfold jump in `web_search` calls from a channel assistant configured with `may_intervene`. Tightening the Agent's persona instructions ("run `web_search` only when a participant asks an explicit factual question") or narrowing its Signal Binding policy eliminates the extra spend at its source without throttling normal turns.

## Scope of cost controls

Ankole governs model selection, reasoning effort, tool availability, loop iterations, concurrency, and token quotas; it does not display a real-time currency billing dashboard because actual currency spend depends on your upstream provider's pricing tiers. Inspect conversation and job logs first, then tune the specific lever driving the usage.

## Next steps

- For Agent model profiles and quotas, read [Agents](../agents/#configure-models).
- For `ai_agent.*`, `brain.*`, `pod.applet.*`, and `agent_computer.*` runtime settings, read [AppConfigure](../app-configuration/).
- For conversation and Background Agent Job endpoints, read [Console API reference](../console-api/).
- For bounded subagent fanout, read [Workflows](../workflows/).
- For Background Agent Job execution limits, read [Background Agent Jobs](../background-jobs/).
