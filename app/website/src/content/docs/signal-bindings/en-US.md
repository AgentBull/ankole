---
title: Signal bindings
description: How to connect an agent to a chat platform — create a binding, point it at an adapter, scope it with filters, and choose how it behaves in group chats.
section: User guide
order: 14
---

A signal binding is what makes an agent reachable. It ties one provider adapter — Lark, DingTalk, Slack, Microsoft 365, Google Workspace — to one agent, so messages, webhooks, and events from that provider become actor events the agent wakes on. This page is the operator's path through a binding: pick the adapter, name the binding, scope it, and choose its group-chat behavior.

The decisive property, stated up front: a binding is keyed by `(agent, binding_name)`, and disabling it stops new signals from waking the agent without deleting the binding's configuration. You can quiet an agent without losing its setup.

## What a binding carries

A binding has a small, fixed shape:

| Field | Meaning |
|---|---|
| `adapter` | the provider adapter id — `lark`, `dingtalk`, `slack`, `microsoft365`, `google_workspace`, or whatever this installation's plugins declare |
| `name` | the binding name you choose; unique per agent |
| `config_ref` | a reference to the adapter-specific configuration (app ids, tokens, webhook endpoints) the adapter needs |
| `filters` | rules that decide which incoming facts are in scope |
| `unaddressed_group_message_policy` | how the agent treats group messages where it was not directly addressed |
| `enabled` | whether new signals may wake the agent through this binding |
| `confidential_memory` | whether the agent keeps what it sees through this binding out of shared memory |

The adapter-specific fields behind `config_ref` differ per provider — see the per-adapter pages for the exact prerequisites (app ids, tokens, event subscriptions, webhook URLs).

## List the available adapters

```bash
curl https://ankole.example.com/api/v1/signal-adapters \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

The response is the set of adapter declarations this installation's Control Plane Plugins registered under the `signals_gateway.adapter` contract. If an adapter you expect is missing, the plugin that declares it is not enabled — see [Control Plane Plugins](../control-plane-plugins/).

## Create or replace a binding

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/<adapter_id>/<binding_name> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "...", "filters": { ... }, "unaddressed_group_message_policy": "..." }'
```

The `(adapter_id, binding_name)` pair in the path names the binding; a second `PUT` to the same pair replaces it. List an agent's bindings with `GET /agents/:agent_uid/signal-bindings`.

## Scope with filters

Filters decide which incoming facts the binding accepts. A fact that does not match returns a successful no-op (`status: :filtered`) — the agent is not woken, and no actor event is queued. Use filters to narrow a binding to certain channels, senders, or message kinds, so the agent only wakes on work that is actually meant for it. The exact filter shape is adapter-agnostic; the per-adapter pages call out the fields worth filtering on for that provider.

## Choose group-chat behavior

`unaddressed_group_message_policy` controls what happens when a message arrives in a group chat and the agent was not directly @-mentioned. The policy decides whether that message produces a `may_intervene` event (the agent is allowed to speak up) or an `addressed` event (the agent was called). Set this to match the agent's role: a customer-success agent in a shared support channel may want to observe and intervene; a release-notes bot should probably stay quiet unless addressed.

## Disable without deleting

`DELETE /agents/:agent_uid/signal-bindings/:binding_name` is, despite the HTTP verb, a *disable* operation: it stops new signals from waking the agent but keeps the binding's configuration recoverable. Use `PATCH /agents/:agent_uid/signal-bindings/:binding_name` to reconfigure or move a binding, including flipping `enabled` back on. A binding that is unavailable records an `unavailable_reason` so you can see why it stopped — usually a missing or revoked adapter configuration.

## A binding is one adapter, one agent

A binding connects exactly one adapter to exactly one agent. To let two agents share one channel, give each its own binding; to let one agent answer in two providers, give it two bindings. There is no "many-to-many" binding object — the one-to-one shape is what keeps each agent's identity, memory, and permission scope clean.

## Next steps

- For each provider's prerequisites and Console fields, read the adapter pages under the User guide.
- For the binding model and how a binding becomes an actor event, read the [SignalsGateway](../signals-gateway/) developer page.
- For the routes, read the [Console API reference](../console-api/).
