---
title: Signals
description: Durable events, routing rules, shared conversation facts, and external delivery.
section: Developer guide
order: 102
---

A Signal is a durable event that asks an Agent Session to do work. It can describe a message, a scheduled wakeup, an automation result, or a business event. A Signal can refer to a Conversation and Message. A generic business event does not need either one.

`Ankole.Signals` owns event admission and Signal Routing Rules. `Ankole.Conversations` owns shared statements, external observation, and delivery. `Ankole.Sessions` owns execution. These owners keep the source fact, the stimulus, and the execution state separate.

## Conversations and Messages

A Conversation stores shared history. Native chats and external chats use the same Message model. A Message records its author, content, and sequence within the Conversation. `ExternalMessageRef` connects an external Message to its provider identifier and payload.

An external Conversation has one identity within a tenant: its `provider_conversation_id`. Multiple Agents can participate in the same Conversation. They share its Messages and retain separate Sessions and model histories. Removing an Agent or routing rule preserves the external history.

`Conversations.Observe` accepts provider facts. `Conversations.External` writes Messages and external references. Repeated observations update the same fact. Reactions update that fact without starting a model turn. A provider deletion removes the Message through its owner and updates dependent execution facts in the same transaction.

## From a message to a Signal

An adapter verifies the provider request and normalizes its message, reaction, removal, or action. Observe resolves the Signal Routing Rule, applies its filter and message policy, and performs identity admission when required.

An accepted message becomes a Message. If it needs Agent work, Signals accepts a Signal for that Agent's Session in the same transaction. A filtered fact is a successful no-op. A reaction does not wake the Agent.

For an unaddressed group message, `addressed_only` can skip admission and recording. Referenced messages are retained for later resolution. A later explicit reply reference can promote the required source Message. [Ambient intervention](../ambient-intervention/) describes how an Agent evaluates other group activity.

## CloudEvents and routing

A Signal Routing Rule is stored as a Binding. It selects an Agent, adapter, configuration reference, filters, and target. Operators manage these rules in Console. A disabled rule stops new admission; it does not delete recorded conversation facts.

CloudEvents endpoints accept structured JSON through:

```text
POST /signals/v1/cloudevents/:token
```

The event has `specversion`, `id`, `source`, `type`, and optional `subject`, `time`, `data`, and extensions. Matching rules can route it to a fixed Conversation or Session, group events by source and subject, or use a separate Session for each event. Repeated delivery retains the event identity and does not create another stimulus.

An external event's type and data are input facts. They cannot declare an internal control command or a trusted producer. Kernel events use private provenance assigned by their actual owner. Console can create and cancel CloudEvents endpoints and configure their rules.

## Provider webhooks and callback capabilities

Provider handlers use:

```text
POST /webhooks/v1/:handler_id/:instance_id/:kind
```

The declared handler verifies the provider's signature or credential. The controller selects a handler under the `signals.webhook_handler` contract and enforces its declared event kinds. Signal adapters use `signals.adapter`.

An Agent-created raw callback uses `/webhooks/v1/event-callbacks/wh_<token>`. Its capability authorizes the recorded callback route, not the truth of the request body. Signals stores a token digest and commits the endpoint decision with `webhook.received` or the bound automation run. Read [Webhook delegations](../webhook-delegations/) for its lifecycle and Worker bridge.

## Delivery

`Conversations.Delivery` stores external send intent and uses the adapter's `deliver` callback. It resolves the actual provider Conversation and Message identifiers before sending. A confirmed send records each resulting Message and external reference in the same commit as the delivery result.

Delivery states are `pending`, `sent`, `failed`, `expired`, and `unknown`. An unconfirmed result remains visible as `unknown` and is not automatically sent again. The durable intent and diagnostics support reconciliation.

Read [Sessions](../sessions/) for execution and recovery, [Quick start](../quickstart/) for configuration, and [Conversations, Signals, and Sessions](../conversations-signals-sessions/) for the architecture comparison.
