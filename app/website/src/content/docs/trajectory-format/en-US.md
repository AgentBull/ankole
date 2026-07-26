---
title: Trajectory and message format
description: How Ankole stores and projects conversation messages and background-job trajectories — the two storage shapes, the ChatML canonical form, and the model-visible projection.
section: Developer guide
order: 121
---

Ankole records what an agent did in two places, for two kinds of work: AIGateway stores conversation messages (the live transcript a stateful Responses conversation produces), and Background Agent Jobs store turn trajectories (the per-turn record of a durable job's execution). This page documents both storage shapes, the canonical ChatML format, and the model-visible projection that strips protocol detail. It builds on [AIGateway](../ai-gateway/) and [Background Agent Jobs](../background-agent-jobs/).

The decisive property, stated up front: the model never sees raw storage rows. Both shapes project to a model-visible form that strips protocol identities and replaces them with turn-local call aliases — the model sees "tool call 1 → tool result 1," not internal UUIDs or wire protocol fields. The stored form is for durability and audit; the projected form is for the model.

## AIGateway conversation messages

AIGateway owns the live conversation transcript. Each message is a row in `ai_gateway_messages`:

| Field | Meaning |
|---|---|
| `subject_uid` | the Principal the conversation belongs to |
| `conversation_id` | the conversation this message is part of |
| `type` | the message type (assistant, tool result, and so on) |
| `role` | the role the message plays in the transcript |
| `status` | lifecycle status |
| `previous_message_id` | a self-reference continuation anchor — renders as `previous_response_id` on the API, so the conversation chains |
| `content` | the message content (a JSON value, not a single string) |
| `metadata` | opaque caller metadata plus AIGateway-owned response facts (model, provider, usage, provider raw ids) |

The `previous_message_id` is the continuation anchor: each message points at its predecessor, producing a linked chain. On the API, this renders as `previous_response_id`, so a caller or a compaction can resume from any anchor. The `metadata` field carries facts AIGateway owns — the model and provider used, the token usage, the provider's raw response id — alongside opaque caller metadata. It must not carry a second item list.

A compaction (see [Context compression](../context-compression-and-caching/)) replaces the old messages with a summary message that becomes the new anchor. The old messages are no longer in the model's visible context; the summary is the new starting point.

## Background Agent Job trajectories

A background job stores its per-turn execution as trajectory groups in `background_agent_job_turn_trajectory_groups`. Each group belongs to a turn, has a position, a revision, an item key, and content:

| Field | Meaning |
|---|---|
| `turn_id` | the job turn this trajectory group belongs to |
| `position` | the group's order within the turn |
| `revision` | bumped on in-place updates (steer, nudge) |
| `item_key` | a stable key for the group |
| `content` | one or more canonical ChatML messages |

The content must be valid canonical ChatML — the schema validates it with `Trajectory.valid_group_content?/1`, rejecting a group that does not contain canonical ChatML messages. The `revision` field lets an in-place steer or nudge update the same group's content without inserting a new row, so the trajectory reflects the latest state of that group.

This is a separate storage shape from the AIGateway conversation messages, because a background job's trajectory belongs to the job, not to a conversation. The job's turns are their own thread; the conversation it reports back to receives the result, not the trajectory.

## The model-visible projection

The model does not see the stored rows. `modelVisibleTrajectory` in the worker projects a trajectory to what the model should see:

- **Strips stored protocol identities** — internal message ids, wire-protocol fields, anything the model should not act on.
- **Replaces tool-call ids with turn-local aliases** — `call_1`, `call_2`, and so on. The model sees which tool result belongs to which tool call (the only useful relationship), without the internal UUIDs that wire them.
- **Preserves content and role** — the actual messages, the tool calls and their results, in the order they happened.

The moduledoc is explicit: "Turn-local call aliases preserve the only useful relationship: which tool result belongs to which tool call." Everything else the storage row carries is for the system, not the model.

## How the two shapes relate

| | AIGateway messages | Background job trajectories |
|---|---|---|
| What it stores | live conversation transcript | per-turn job execution record |
| Who owns it | AIGateway | Background Agent Jobs |
| Canonical format | AIGateway's message schema | ChatML groups |
| Model sees it through | the stateful Responses API | `modelVisibleTrajectory` projection |
| Compaction | AIGateway compaction replaces old messages | not compacted (jobs are bounded by retry budget) |

The two do not mix. A conversation's messages are AIGateway's; a job's trajectory is the job's. The job reports its result back to the owning conversation through a wakeup event (see [Background Agent Jobs](../background-agent-jobs/)), not by writing into the conversation's message store.

## What this guide is not

It is not a ChatML specification — the canonical ChatML format is a standard, and Ankole's validation (`valid_group_content?/1`) checks the shape, not redefines it. It is not a consumer-facing API for reading trajectories — the Console routes (`/ai-gateway/conversations/:id/messages`, `/background-agent-jobs/:id`) are the operator surface, documented in the [Console API reference](../console-api/). And it is not a substitute for the storage pages; this is the format-level view across both.

## Next steps

- For the conversation message store, read [AIGateway](../ai-gateway/).
- For the job trajectory store, read [Background Agent Jobs](../background-agent-jobs/).
- For compaction (which replaces old messages), read [Context compression](../context-compression-and-caching/).
- For the Console routes that read these, read the [Console API reference](../console-api/).
