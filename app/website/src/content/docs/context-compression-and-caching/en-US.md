---
title: Context compression and compaction
description: How Ankole keeps long conversations within a model's context — AIGateway automatic history compaction and verbatim user-original retention.
section: Developer guide
order: 116
---

Any long-running conversation eventually reaches the model's context window. To let threads continue cleanly past that limit, AIGateway automatically compacts the conversation history that each turn sees, implemented in `ai_gateway/compaction*.ex`.

Compaction is *lossy by design, never silent*: AIGateway replaces older turns with a structured summary, keeps recent turns verbatim, and persists a durable compaction artifact that the conversation points at. Once compacted, the older turns leave the model's active prompt and the summary becomes the new reference state—normal continuation uses this checkpoint. Ankole retains predecessor rows so recovery can rebuild a local checkpoint when the provider binding changes or the user invokes `/compress`.

## AIGateway history compaction

`Ankole.AIGateway.Compaction` owns automatic history compaction for stateful Responses conversations, governing when compaction fires, how the summary is generated, and what verbatim items survive alongside it.

The following sections describe local compaction, the default. Setting `ai_gateway.compaction.upstream` to `true` opts into provider-native compaction where supported, with local fallback; see [AIGateway](../ai-gateway/).

### The trigger

AIGateway uses the **latest provider-reported usage** as its context-size anchor, then estimates the additional tokens from new input, tool results, tools, and instructions. It compares that projected total with the configured trigger and applies growth and compression-yield guards to avoid repeated low-yield compactions. Provider usage snapshots are not summed across turns.

Operators tune the trigger through the `ai_gateway.compaction` AppConfigure key:

| Setting | Default | Meaning |
|---|---|---|
| `threshold` | 0.90 | the ratio of the model's input context that triggers compaction |
| `max_threshold_tokens` | 400,000 | an absolute cap on the computed trigger, so a very large context does not wait too long |
| `tail_rows` | 4 | preferred number of recent history rows to retain alongside the summary |
| `user_message_budget_tokens` | 20,000 | the token budget for replaying verbatim user originals |

When model context metadata is unavailable, Ankole uses 256,000 tokens. It subtracts any requested output budget, applies `threshold`, then caps the trigger at `max_threshold_tokens`. If the 64,000-token minimum would reach the effective context limit, it instead triggers at `small_context_trigger_ratio` (`0.85`) of that limit.

Token usage is not the only trigger. Encrypted reasoning and inline images take many bytes per token, so a history can grow large long before it crosses the token threshold. AIGateway also compacts a conversation when its stored history reaches three quarters of what a single tool-using response can carry (1,024 items or 8 MiB). This size trigger has no setting.

### What the summarizer does

When local compaction is selected, AIGateway invokes the `light` model profile (falling back to `primary`) to condense the older span into a structured summary. The compaction prompt frames that output strictly as **reference state, not instructions**: `"Do NOT continue the conversation. Do NOT respond to any questions. ONLY output the structured summary."` The resulting summary captures user intent, key decisions, errors, and fixes while preserving exact file paths, function names, error strings, command lines, and identifiers—because paraphrasing a path or identifier breaks downstream tool calls.

AIGateway replays the summary alongside retained user originals and recent history as prior state rather than an open turn to answer.

### What survives verbatim

Alongside the summary, AIGateway preserves two sets of items verbatim:

- **Recent history rows** (`tail_rows`, default `4`) — a preferred tail size, adjusted to preserve tool call/output pairs and fit the context budget.
- **User originals** — `CompactionRetention` replays user text within `user_message_budget_tokens`; it may truncate text to fit. Compacted image payloads become bounded placeholders, while recent retained images remain intact.

These retained items help the model follow the task, while the summary remains a lossy account of older work.

### The compaction artifact

Each compaction run writes a durable `CompactionArtifact` in AIGateway, anchoring the conversation's visible history so subsequent turns continue forward from that checkpoint.

## Compaction and cold-wake session rotation

`ai_gateway.compaction` and `sessions.wake_recycle` work together across warm and cold traffic:

- **Warm active conversations (`ai_gateway.compaction`):** While turns arrive within the upstream provider's prompt-cache window, Ankole keeps extending the same AIGateway conversation to maximize prefix-cache hit rates, compacting only when cumulative context crosses `threshold` / `max_threshold_tokens` or the stored history reaches the size trigger.
- **Cold resumptions (`sessions.wake_recycle`):** When a Session resumes after sitting idle at least `min_cold_gap_seconds` (default `3,600` seconds) with context at or above `min_context_tokens` (default `128,000` tokens)—or after `im_max_idle_seconds` (default `259,200` seconds / 72 hours) on an external IM channel—`Ankole.Sessions.WakeRecycle` closes the cold AIGateway model conversation instead of replaying the full history, opens a successor branch, and injects a deterministic `<wake-briefing>` capped at `8,000` `o200k_base` tokens; see [Sessions](../sessions/).

## Tuning

- **Raise `threshold`** if your Agents mostly handle short threads and the default (`0.90`) compacts earlier than necessary.
- **Raise `tail_rows`** if models lose track of immediate tool context right after compaction, trading summary headroom for more verbatim recent turns.
- **Raise `user_message_budget_tokens`** if long threads drop early user prompts from the compacted span and the model loses sight of original constraints.

All three fields live under `ai_gateway.compaction` in AppConfigure and apply starting with the next compaction rather than retroactively on the active turn.

## What this guide is not

This page does not cover provider-side prompt caching—upstream KV/prefix caching belongs to each provider, configured via `promptCacheKey` on providers that support it. Nor does compaction preserve lossless prompt history, since older assistant turns leave the active context window by design. Finally, compaction is no substitute for clean task boundaries: while it lets a conversation run past a single context window, a thread that compacts every few turns usually belongs in separate Sessions or delegated [Background Agent Jobs](../background-jobs/).

## Next steps

- For the AIGateway concept page, read [AIGateway](../ai-gateway/).
