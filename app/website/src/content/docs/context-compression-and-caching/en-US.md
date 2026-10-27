---
title: Context compression and compaction
description: How Ankole keeps long conversations within a model's context — AIGateway automatic history compaction and verbatim user-original retention.
section: Developer guide
order: 116
---

Any long-running conversation eventually reaches the model's context window. To let threads continue cleanly past that limit, AIGateway automatically compacts the conversation history that each turn sees, implemented in `ai_gateway/compaction*.ex`.

Compaction is *lossy by design, never silent*: AIGateway replaces older turns with a structured summary, keeps recent turns verbatim, and persists a durable compaction artifact that the conversation points at. Once compacted, the older turns leave the model's active prompt and the summary becomes the new reference state—compaction is a forward checkpoint, not a cache that can be invalidated back to raw turns.

## AIGateway history compaction

`Ankole.AIGateway.Compaction` owns automatic history compaction for stateful Responses conversations, governing when compaction fires, how the summary is generated, and what verbatim items survive alongside it.

### The trigger

AIGateway triggers compaction when a conversation's token usage crosses a configured threshold, reading the **latest provider-reported usage** stored on the visible history. Because each usage record is already a cumulative snapshot of the prompt rather than a delta to sum, AIGateway trusts the provider's reported count directly rather than estimating tokens from text length.

Operators tune the trigger through the `ai_gateway.compaction` AppConfigure key:

| Setting | Default | Meaning |
|---|---|---|
| `threshold` | 0.50 | the ratio of the model's input context that triggers compaction |
| `max_threshold_tokens` | 120,000 | an absolute cap on the computed trigger, so a very large context does not wait too long |
| `tail_rows` | 2 | how many recent turns stay verbatim alongside the summary |
| `user_message_budget_tokens` | 20,000 | the token budget for replaying verbatim user originals |

These defaults assume a 256k context window: `max_threshold_tokens` prevents giant-context models from accumulating histories so long that summarization itself becomes expensive, while smaller-context models trigger later in their window via `small_context_trigger_ratio` (`0.85`).

### What the summarizer does

Once token usage crosses the threshold, AIGateway invokes a summarizer model to condense the older span into a structured summary. The compaction prompt frames that output strictly as **reference state, not instructions**: `"Do NOT continue the conversation. Do NOT respond to any questions. ONLY output the structured summary."` The resulting summary captures user intent, key decisions, errors, and fixes while preserving exact file paths, function names, error strings, command lines, and identifiers—because paraphrasing a path or identifier breaks downstream tool calls.

That summary becomes the oldest item in the compacted chain, presented to the model as prior state rather than an open turn to answer.

### What survives verbatim

Alongside the summary, AIGateway preserves two sets of items verbatim:

- **Recent turns** (`tail_rows`, default `2`) — the newest full turns stay intact so the model retains immediate continuity.
- **Verbatim user originals** — `CompactionRetention` selects original user messages from the compacted span up to `user_message_budget_tokens` and replays them verbatim, ensuring the model can still read what the user originally asked even after older assistant work has been summarized.

Combining a structured summary of older assistant turns with verbatim user requests and verbatim recent turns keeps long conversations coherent without drift.

### The compaction artifact

Each compaction run writes a durable `CompactionArtifact` in AIGateway, anchoring the conversation's visible history so subsequent turns continue forward from that checkpoint.

## Tuning

- **Raise `threshold`** if your Agents mostly handle short threads and the default (`0.50`) compacts earlier than necessary.
- **Raise `tail_rows`** if models lose track of immediate tool context right after compaction, trading summary headroom for more verbatim recent turns.
- **Raise `user_message_budget_tokens`** if long threads drop early user prompts from the compacted span and the model loses sight of original constraints.

All three fields live under `ai_gateway.compaction` in AppConfigure and apply starting with the next compaction rather than retroactively on the active turn.

## What this guide is not

This page does not cover provider-side prompt caching—upstream KV/prefix caching belongs to each provider, configured via `promptCacheKey` on providers that support it. Nor does compaction preserve lossless prompt history, since older assistant turns leave the active context window by design. Finally, compaction is no substitute for clean task boundaries: while it lets a conversation run past a single context window, a thread that compacts every few turns usually belongs in separate Sessions or delegated [Background Agent Jobs](../background-jobs/).

## Next steps

- For the AIGateway concept page, read [AIGateway](../ai-gateway/).
