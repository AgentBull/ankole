---
title: Trajectory and message format
description: How Ankole stores and projects conversation messages and background-job trajectories — the two storage shapes, the ChatML canonical form, and the model-visible projection.
section: Developer guide
order: 121
---

Ankole records Agent execution history in two distinct stores tailored to two kinds of work: AIGateway stores conversation messages (the live transcript that a stateful Responses conversation produces), while Background Agent Jobs store turn trajectories (the per-turn execution log of a durable background job). This page explains both storage schemas, canonical ChatML projection, and how Ankole strips wire-protocol internals before showing history to a model, building on [AIGateway](../ai-gateway/) and [Background Agent Jobs](../background-agent-jobs/).

Models never inspect raw database rows directly. Instead, both stores project into a sanitized, model-visible representation that strips internal UUIDs and wire-protocol fields in favor of turn-local call aliases—so the model sees `"call_1 → result of call_1"` while PostgreSQL retains the full audit record.

Note that an AIGateway conversation represents a single Session's model transcript and is distinct from the shared participant Conversation and Messages owned by `Ankole.Conversations`. Shared channel history can supply background context at turn boundaries, but never replaces the Session's AIGateway response chain or tool journal.

## AIGateway conversation messages

AIGateway owns the live model transcript in `ai_gateway_messages`:

| Field | Meaning |
|---|---|
| `subject_uid` | Principal that owns the conversation |
| `conversation_id` | AIGateway conversation that this message belongs to |
| `type` | Message item kind (assistant reply, tool result, compaction checkpoint, and so on) |
| `role` | Role that the message plays in the transcript |
| `status` | Item lifecycle status |
| `previous_message_id` | Self-referencing continuation pointer—exposed on the API as `previous_response_id` to form a linked chain |
| `content` | Structured JSON message payload (not a bare string) |
| `metadata` | Opaque caller metadata alongside AIGateway-owned response facts (resolved model, provider, token usage, upstream response IDs) |

Each row's `previous_message_id` points to its predecessor, forming an append-only chain exposed on the Responses API as `previous_response_id` so callers or compaction checkpoints can resume from any anchor. Meanwhile, `metadata` combines opaque caller tags with facts that AIGateway owns—the provider and model used, token counts, and raw upstream IDs—and must never store a duplicate item list.

When context compaction runs (see [Context compression](../context-compression-and-caching/)), AIGateway appends a summary checkpoint as the new visible anchor: earlier rows stay in PostgreSQL for recovery and audit, while projected model requests start from the summary checkpoint rather than replaying older turns.

## Background Agent Job trajectories

Each Background Agent Job records its per-turn execution as an append-only sequence of sanitized semantic thread items in `background_agent_job_turn_items`:

| Field | Meaning |
|---|---|
| `turn_id` | Job turn that this item belongs to |
| `position` | Zero-based ordering within the turn |
| `revision` | Turn revision under which the item was committed |
| `item_key` | Stable item identifier (`client:` prefixes mark caller-supplied messages) |
| `item` | Typed semantic thread item payload |

Because `background_agent_job_turn_items` is strictly append-only, steering messages and nudges append new rows rather than mutating existing ones. Readers project each semantic item into canonical ChatML messages at read time; items that emit zero ChatML messages remain stored for exact thread replay, and a turn with no items projects an empty trajectory.

On tool-result messages, `metadata.execution_mechanism` records `provider_hosted` when the upstream model Provider executed the tool natively, or `local_dynamic` when Codex invoked a dynamic tool implemented by Ankole—disambiguating tools that share a display name.

Background Agent Job trajectories live separately from `ai_gateway_messages` because a job's multi-turn Codex thread belongs to the job itself: the originating chat conversation receives the job's final report or status wakeup rather than its internal step-by-step trajectory.

## The model-visible projection

When a main Agent inspects a Background Agent Job, the control plane projects stored items through `Ankole.Sessions.Tools.Jobs.visible_trajectory/1`, which:

- **Strips internal protocol identifiers** — removing database UUIDs, upstream wire fields, and metadata that models should not depend on.
- **Replaces tool-call IDs with turn-local aliases** — rewriting raw call identifiers to `call_1`, `call_2`, and so on, preserving the exact pairing between each tool call and its result without leaking internal keys.
- **Preserves roles, content, and chronological order** — keeping assistant messages, tool calls, and tool outputs in the exact sequence in which they occurred.
- **Retains truncation and redaction markers** — keeping trajectory-level `metadata.redacted` and `metadata.content_truncated` flags visible, and setting `content_truncated` whenever the control plane trims message bodies to fit its pagination budget.

## How the two shapes relate

| | AIGateway messages | Background job trajectories |
|---|---|---|
| What it stores | Live Session model transcript | Per-turn Background Agent Job execution log |
| Who owns it | AIGateway | Background Agent Jobs |
| Canonical format | `ai_gateway_messages` schema | Semantic items projected to ChatML |
| Model sees it through | Stateful Responses API | `visible_trajectory/1` projection |
| Compaction | AIGateway appends a summary checkpoint; prior rows remain | Not compacted (bounded by Job turn and retry budgets) |

The two stores never cross-write: conversation turns commit to AIGateway, while Background Agent Jobs commit to `background_agent_job_turn_items` and report outcomes back to the owning conversation via durable wakeup Signals (see [Background Agent Jobs](../background-agent-jobs/)).

## What this guide is not

This page covers how Ankole stores and projects transcripts across its two execution paths, rather than redefining the external ChatML standard itself. Operators and integrations that need to inspect stored messages or job trajectories over HTTP should use the Console JSON:API endpoints (`/api/v2/ai-gateway/conversations/:id/messages` and `/api/v2/background-agent-jobs/:id`), documented in the [Console API reference](../console-api/).

## Next steps

- For the conversation message store, read [AIGateway](../ai-gateway/).
- For the job trajectory store, read [Background Agent Jobs](../background-agent-jobs/).
- For compaction and visible checkpoints, read [Context compression](../context-compression-and-caching/).
- For the Console routes that read these, read the [Console API reference](../console-api/).
