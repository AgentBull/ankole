---
title: Conversation history
description: How to read what an agent said and did — the conversations list, the messages per conversation, and how compaction changes what is visible.
section: User guide
order: 58
---

AIGateway stores every conversation's transcript — the messages, the model calls, the tool results — as durable PostgreSQL rows. This page is the operator's view of that history: how to list conversations, read their messages, and understand what compaction does to the visible record.

The decisive property, stated up front: the conversation transcript is **AIGateway-owned durable truth**, and a compaction changes what the model sees but does not delete the audit record. The messages before a compaction are summarized; the summary is the new anchor; the original messages are gone from the model's context but the compaction artifact remains.

## List conversations

```bash
curl https://ankole.example.com/api/v1/ai-gateway/conversations \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /ai-gateway/conversations` lists conversations. Each carries a conversation id, the subject (Principal) it belongs to, and metadata. Filter by agent or by recency to find the conversation you need.

## Read messages

```bash
curl https://ankole.example.com/api/v1/ai-gateway/conversations/<conversation_id> \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

curl https://ankole.example.com/api/v1/ai-gateway/conversations/<conversation_id>/messages \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET .../conversations/:id` reads one conversation's metadata. `GET .../conversations/:id/messages` reads its messages — the assistant turns, the user messages, the tool-call outputs, in the order they happened. Each message carries its type, role, status, content, and metadata (which includes the model, provider, and token usage for model responses).

This is the surface for "what did the agent actually do on this turn?" — the fastest tell when debugging a misbehavior.

## How compaction changes the visible record

A conversation that ran long has been compacted (see [Context compression](../context-compression-and-caching/)). After a compaction:

- **Old messages are summarized.** A compaction message replaces the older turns as the conversation's anchor. The model sees the summary, not the original turns.
- **Recent turns stay verbatim.** The last few turns (`tail_rows`, default 2) remain in full.
- **User originals are retained.** Within a token budget, verbatim user messages from the compacted span are replayed alongside the summary.
- **The compaction artifact is durable.** The artifact records what was compacted and when. It is an audit fact, not a deleted message.

This means the message history you read through the Console is the current state of the conversation — what the model sees now. If you need the pre-compaction detail, it was summarized; the summary is the record of what was there.

## What the messages tell you

Each message's `metadata` field carries facts AIGateway owns:

- **Model and provider** — which model served the response, through which provider.
- **Token usage** — the cumulative usage snapshot at the time of the response.
- **Provider raw id** — the upstream provider's response id, for cross-referencing with the provider's own logs.

These are the facts that tell you whether a slow or wrong response was the model's fault, the provider's fault, or a configuration problem. See [Provider routing](../provider-routing/) for how to trace a message back to its provider.

## What this guide is not

It is not the AIGateway concept page — for the full API surface, read [AIGateway](../ai-gateway/). It is not a compaction internals guide — for the trigger, the summarizer, and the retention model, read [Context compression](../context-compression-and-caching/). And it is not the trajectory-format reference — for how messages are stored and projected, read [Trajectory format](../trajectory-format/).

## Next steps

- For the AIGateway API, read [AIGateway](../ai-gateway/).
- For compaction, read [Context compression](../context-compression-and-caching/).
- For the message storage format, read [Trajectory format](../trajectory-format/).
- For the Console routes, read the [Console API reference](../console-api/).
