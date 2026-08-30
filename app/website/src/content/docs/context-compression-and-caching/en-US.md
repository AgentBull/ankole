---
title: Context compression and compaction
description: How Ankole keeps long conversations within a model's context — AIGateway automatic history compaction and verbatim user-original retention.
section: Developer guide
order: 116
---

A conversation that runs long eventually exceeds the model's context window. AIGateway compacts the conversation history a turn sees, so the conversation can continue past that limit. This page documents that mechanism, against the real code in `ai_gateway/compaction*.ex`.

The decisive property, stated up front: compaction is *lossy by design, but not silent*. A compaction replaces older turns with a summary, preserves recent turns verbatim, and records itself as a durable artifact the conversation points at. The original turns are gone from the model's context; the summary is the new reference state. A compaction is not a cache you can invalidate back to the originals.

## AIGateway history compaction

AIGateway owns automatic history compaction for its stateful Responses conversations. The trigger, the summary, and what survives are all in `Ankole.AIGateway.Compaction`.

### The trigger

Compaction fires when the conversation's token usage crosses a threshold. The decision uses the **newest provider-returned usage** stored on the visible history — each usage value is a cumulative snapshot, not an amount to add. AIGateway does not estimate token counts from content; it trusts the provider's usage number.

The threshold is configured through the `ai_gateway.compaction` AppConfigure key:

| Setting | Default | Meaning |
|---|---|---|
| `threshold` | 0.50 | the ratio of the model's input context that triggers compaction |
| `max_threshold_tokens` | 120,000 | an absolute cap on the computed trigger, so a very large context does not wait too long |
| `tail_rows` | 2 | how many recent turns stay verbatim alongside the summary |
| `user_message_budget_tokens` | 20,000 | the token budget for replaying verbatim user originals |

The defaults assume a 256k context length. The `max_threshold_tokens` cap exists so a model with a very large context does not accumulate a history so long that compaction itself becomes expensive. A small-context model triggers earlier, through the `small_context_trigger_ratio` (0.85).

### What the summarizer does

When the threshold is crossed, AIGateway calls a summarizer model to produce a structured summary of the older turns. The compaction prompt frames the summary as **reference state, not instructions**: "Do NOT continue the conversation. Do NOT respond to any questions. ONLY output the structured summary." The summary captures intent, decisions, errors and fixes, and preserves verbatim file paths, function names, error messages, command lines, and IDs — because a paraphrased path or error is a broken reference.

The summary is the new oldest item in the conversation. The model sees it as state, not as a turn to continue.

### What survives verbatim

Two things stay alongside the summary:

- **Recent turns** (`tail_rows`, default 2) — the last few turns remain in full, so the model has the immediate context it needs.
- **Verbatim user originals** — `CompactionRetention` selects user messages from the compacted span, within `user_message_budget_tokens`, and replays them verbatim. This is why the model can still see "the user asked for X" even after the assistant's turns have been summarized.

The combination — a summary of old assistant work, verbatim recent turns, verbatim user originals — is what lets the conversation continue without drift.

### The compaction artifact

Each compaction produces a durable `CompactionArtifact`, stored by AIGateway. The conversation's history points at the most recent compaction as its anchor; subsequent turns continue from there.

## Tuning

- **Raise `threshold`** if your agents work with short conversations and compaction fires too eagerly. The default (0.50) is conservative.
- **Raise `tail_rows`** if the model loses immediate context after a compaction — more verbatim recent turns, at the cost of less room for the summary.
- **Raise `user_message_budget_tokens`** if user messages are being dropped from the compacted span and the model loses track of what was asked.

All three are AppConfigure keys, changed through the Console, taking effect on the next compaction — not on the current turn.

## What this guide is not

It is not a prompt-caching guide — AIGateway does not implement provider-side prompt caching here; that is the provider's concern, and the `promptCacheKey` setting on a provider that supports it is the lever. It is not lossless history — compaction is lossy by design, and the original turns are gone from the model's context. And it is not a substitute for shorter conversations; compaction lets a conversation continue past the context limit, but a conversation that compacts every few turns is one that would benefit from splitting into sessions or delegating to background jobs.

## Next steps

- For the AIGateway concept page, read [AIGateway](../ai-gateway/).
