---
title: Signals
description: Durable events, routing rules, shared conversation facts, and external delivery.
section: Developer guide
order: 102
---

A Signal is a durable event that asks an Agent Session to perform work—whether triggered by a chat message, a scheduled wakeup, an automation result, or an external business event. While chat Signals reference a Conversation and Message, a generic business Signal can target a Session directly without either one.

Three control-plane domains divide this pipeline cleanly: `Ankole.Signals` owns event admission and Signal Routing Rules, `Ankole.Conversations` owns shared message history, external channel observation, and outbound delivery, and `Ankole.Sessions` owns Agent execution. Keeping these three domains distinct separates the recorded channel fact, the execution stimulus, and the Session runtime state.

## Conversations and Messages

Every Conversation—whether in native Pod Chat or an external chat platform—stores shared history using the same Message schema, recording the author, content, and sequence number within the Conversation, while `ExternalMessageRef` links external Messages to their upstream provider IDs and raw payloads.

Within a tenant, each external Conversation is uniquely identified by its `provider_conversation_id`. Multiple Agents can participate in the same Conversation, sharing its recorded Messages while maintaining independent Sessions and model histories; removing an Agent or disabling a routing rule leaves the Conversation's external message history intact.

On the inbound path, `Conversations.Observe` accepts normalized provider events and `Conversations.External` persists Messages and external references. When a provider delivers an edit or duplicate event, Ankole updates the existing Message record; when a user adds a reaction, Ankole updates the Message record without starting a model turn; and when a message is deleted upstream, Ankole removes the Message through its owner and updates dependent execution records in the same transaction.

## From a message to a Signal

When a chat webhook or stream frame arrives, the channel adapter verifies the provider's credentials and normalizes the message, reaction, deletion, or interactive action. `Conversations.Observe` then resolves the matching Signal Routing Rule, applies its filter and group-message policy, and runs identity admission when needed.

Once accepted, the inbound message is written as a Message, and if it calls for Agent work, `Ankole.Signals` admits a Signal for that Agent's Session inside the same PostgreSQL transaction. Messages excluded by a filter return a clean no-op, and reactions never wake the Agent.

For unaddressed group chatter under an `addressed_only` rule, Ankole skips signal admission and message recording while retaining referenced context IDs—so if a later @-mention replies to an earlier unrecorded message, Ankole can promote that referenced source Message into context. See [Ambient intervention](../ambient-intervention/) for how Agents evaluate unaddressed group conversations in other modes.

## CloudEvents and routing

Each Signal Routing Rule is stored as a Binding specifying the target Agent, adapter, configuration reference, filters, and session target. Operators manage these rules in the Console; disabling a rule halts new signal admission without deleting recorded Conversation facts.

External systems can also post structured CloudEvents JSON to:

```text
POST /signals/v1/cloudevents/:token
```

Each CloudEvent carries `specversion`, `id`, `source`, and `type`, plus optional `subject`, `time`, `data`, and extension attributes. Routing rules can direct matching events into a fixed Conversation or Session, group them by `source` and `subject`, or open a dedicated Session per event. Because Ankole deduplicates by event identity, redelivering the same CloudEvent is idempotent and never triggers a second Agent run.

Ankole treats external event `type` and `data` payloads strictly as untrusted input—callers cannot spoof internal control commands or system producer identities, which carry private kernel provenance stamped by their owning Elixir modules. Operators create, configure, and revoke CloudEvents endpoints in the Console.

## Provider webhooks and callback capabilities

Channel and integration webhooks enter through:

```text
POST /webhooks/v1/:handler_id/:instance_id/:kind
```

The webhook controller looks up the registered handler under the `signals.webhook_handler` contract, enforces its declared event kinds, and delegates signature or token verification to that handler, while full signal adapters register under `signals.adapter`.

By contrast, Agent-created raw callbacks use `/webhooks/v1/event-callbacks/wh_<token>`. Possessing that capability URL authorizes waking the recorded callback route, not trusting the HTTP body. `Ankole.Signals` stores only a SHA-256 token digest and commits the endpoint state change atomically alongside either a `webhook.received` Signal or the bound Automation Job run; see [Webhook delegations](../webhook-delegations/) for the full lifecycle and Worker bridge.

## Delivery

On the outbound path, `Conversations.Delivery` persists the send intent before invoking the adapter's `deliver` callback, resolving the upstream provider Conversation and reply-target Message IDs first. Once the upstream platform confirms delivery, Ankole records each resulting Message and `ExternalMessageRef` in the same database commit as the delivery status update.

Each outbound delivery tracks one of five states: `pending`, `sent`, `failed`, `expired`, or `unknown`. If a transport drop leaves delivery unconfirmed, Ankole marks the record `unknown` rather than blindly resending and duplicating messages in chat, preserving the durable intent and diagnostics for operator or adapter reconciliation.

Read [Sessions](../sessions/) for turn execution and crash recovery, [Quick start](../quickstart/) for channel setup, and [Conversations, Signals, and Sessions](../conversations-signals-sessions/) for how the three models fit together.
