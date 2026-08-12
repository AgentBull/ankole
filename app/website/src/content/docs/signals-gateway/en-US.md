---
title: SignalsGateway
description: The shared-work ingress layer — how chats, webhooks, and provider events become actor events without turning source facts into execution state.
section: Developer guide
order: 102
---

SignalsGateway is the entry surface for shared work. A chat message, a webhook, a provider event, or a scheduled reminder comes in on one side; a normalized, durable actor event comes out the other side, ready to wake a session. The gateway's job is to turn the messy variety of providers into one shape, and to keep the original provider facts separate from the execution that follows.

This page maps the real ingress path, the Signal Binding model behind user-facing routing rules, and the boundary between mirroring and waking. The source of truth is the `Ankole.SignalsGateway` module and its `Ingress`, `Projection`, and `Bindings` submodules.

## The contract it keeps

Two properties hold across every provider, and they are the reason the gateway exists as a distinct layer:

- **Source facts stay facts.** A mirrored entry records what the provider currently looks like — who said what, in which channel, at what time. It is not execution state. The agent's turn runs against a projection of these facts, not against the facts themselves.
- **Waking is conditional.** Not every accepted fact wakes an actor. A filtered signal is a successful no-op (`status: :filtered`), and the actor runtime is started only when an accepted fact actually produced a new actor event.

The separation matters because providers behave differently, retry, redeliver, and send events the agent should see but not act on. The gateway absorbs that variance so the actor runtime sees one clean input stream.

## The ingress pipeline

Every inbound fact walks the same fixed pipeline, regardless of provider:

1. **Resolve the routing rule.** The gateway looks up the internal Signal Binding by `agent_uid` and `binding_name`. No rule means no route, so the fact is rejected.
2. **Construct the fact.** The provider-native payload is normalized into a typed fact through `FactNormalizer` — entry, reaction, action, or lifecycle. Provider-specific names like "delete" or "recall" collapse into one actor-facing kind.
3. **Apply the routing filter.** The rule's filter decides whether this fact is in scope. A non-match returns `{:ok, %{status: :filtered}}`, which is a success, not an error.
4. **Accept and mirror.** The accepted fact upserts the channel mirror and writes the entry projection. This is where provider facts become durable rows.
5. **Hand off the actor event, when warranted.** If the accepted fact should wake an actor, an `ActorEvent` row is appended to the session queue. Reactions are the exception: they only update the mirror and never create an actor event.

The lock order through acceptance is fixed — channel, then session, then actor event — so concurrent facts on the same channel resolve deterministically.

## Kinds of inbound fact

The gateway accepts four concrete kinds through `Ingress`, and each maps to a normalized actor-facing contract:

- **Entry** — a message or post arriving in a channel. The primary wake path. The IM entry policy decides whether an unaddressed group message produces a `may_intervene` event (the agent is allowed to speak up) or an `addressed` event (the agent was called directly). For how the intervention judgment behaves, reply attribution, and channel standing orders, see [Ambient intervention](../ambient-intervention/).
- **Entry removed** — a provider delete or recall. The actor-facing contract is always `signal.entry.removed`; the provider-native lifecycle name is kept only for diagnostics.
- **Reaction** — an emoji or vote change on an existing entry. Updates the mirror only; never wakes an actor. A reaction on an entry the gateway never mirrored is ignored (`:ignored_unknown_entry`), not treated as an error.
- **Action** — a provider-raised interaction such as a card button click. Goes through reply-interaction de-duplication: a duplicate click returns `:duplicate_action`, a stale one returns `:stale_action`, and an accepted one becomes a `signal.action.invoked` event.

## Channels, entries, and reply modes

A **channel** is the provider-side container an entry lives in: an IM direct message or group, a webhook endpoint, an issue, an alert stream. The channel row is a pure external-fact mirror, keyed by the provider-native channel id, so writes upsert rather than insert per event. It records `reply_mode` — `:none`, `:channel`, or `:entry` — which the outbox reads to decide whether a reply goes out as a new channel post or as a threaded reply to a specific entry.

An **entry** is one unit of content in a channel: one message, one post, one event. The entry projection is what the agent turn reads; it is not the actor event, and it is not the source payload verbatim.

## The routing-rule model

A signal routing rule, stored as a Signal Binding, connects one provider adapter to one Agent under a name that the operator chooses. Rules belong to the Agent and are managed through Console-scoped routes:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/signal-adapters` | List the adapters this deployment instance declared |
| `GET` | `/signal-bindings` | List routing rules; `?agent=` filters to one Agent |
| `PUT` | `/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | Create or replace a routing rule |
| `PATCH` | `/agents/:agent_uid/signal-bindings/:binding_name` | Update a routing rule |
| `DELETE` | `/agents/:agent_uid/signal-bindings/:binding_name` | Remove a routing rule |

A rule carries the adapter it uses, a configuration reference, filter rules, a group-message policy, an `enabled` flag, and a `confidential_memory` flag. Disabling a rule stops new facts from waking its Actor without deleting the rule. An unavailable rule records `unavailable_reason` so the operator can see why it stopped.

Adapters are not hard-coded. They are resolved at boot from the plugin registry under the `signals_gateway.adapter` contract, so the set of available providers is whatever this deployment instance's plugins declare. A request against an adapter id that no declaration provides returns `signal_adapter_not_found`.

## Provider webhook ingress

Providers that push events reach the gateway through one front door:

```text
POST /webhooks/v1/:handler_id/:instance_id/:kind
```

This route sits deliberately outside every auth pipeline: no session, no CSRF, no bearer token, no Accept negotiation, because providers send whatever headers they send. Authenticating the provider is the declared handler's job — a Bot Framework JWT, a Graph `clientState`, or whatever the provider signs with.

The controller only routes. It resolves the declared `signals_gateway.webhook_handler` plugin, enforces the handler's declared `kind` whitelist, and renders the handler's response instruction. An unknown handler or an undeclared kind returns `404` without echoing the payload back; a handler that fails returns `500` with a generic message. The handler itself is what calls into `Ingress` with a normalized fact.

## Agent-created webhook delegations

Agent-created callback capabilities use a separate ingress:

```text
POST /webhooks/v1/event-callbacks/wh_<token>
```

This path does not use a provider handler. The URL itself authorizes one wake-up path to the Agent session that created it. It does not authenticate the facts in the body.

SignalsGateway stores only the token digest. It locks the endpoint, applies one-shot or standing delivery semantics, and appends `webhook.received` in the same PostgreSQL transaction. The Worker then projects a bounded set of headers and body data inside an untrusted-data boundary. The Agent reads the current external system before a consequential action.

Endpoint creation, list, and cancel commands use a turn-local Worker bridge. The Console can list and cancel endpoints, but it cannot create them or reveal their callback URL. Read [Webhook delegations](../webhook-delegations/) for the user flow, GitHub lifecycle, delivery contract, and operational limits.

## The outbox: replies going back out

Inbound is half the gateway. The other half is the outbox, which turns an agent's reply into provider-side sends. The outbox reads the channel's `reply_mode` to choose the send operation — a channel post or a threaded entry reply — and goes through the same adapter contract that ingress uses. Side effects the agent commits during a turn are delivered through this path, and their durable record lives with the actor event that produced them, not in the live worker.

## What SignalsGateway is not

It is not a provider client. It does not hold open connections to every chat platform; that is the adapters' and their long-connection workers' concern. It is not a queue for arbitrary work — only for actor-facing events on sessions. And it is not where agent execution lives; once an actor event is appended, waking and running the turn is the Actor Runtime's job. The gateway's boundary is the conversion from provider fact to durable actor input, and back from actor reply to provider send.

## Next steps

- For how a woken actor event gets run, read the [AIGateway API](../ai-gateway/) and the [architecture overview](../architecture/).
- For configuring a Channel Provider and routing rule, read [Quick start](../quickstart/).
