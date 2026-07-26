---
title: Ambient intervention
description: How an Ankole agent decides whether to speak in a group chat it was not @-mentioned in — the may_intervene policy, the lightweight ambient turn, the contrast with addressed_only, record_only, and ignore, and the durable-context guidance that keeps the agent silent when it should be.
section: User guide
order: 38
---

`may_intervene` is the group-chat policy that lets an agent speak up without being called. Set it on a [signal binding](../signal-bindings/), and a group message that does not @-mention the agent produces a `may_intervene` event. The agent wakes on that event, reads the context, and decides — it does not automatically reply. This page is the operator view: what the policy does, how the agent decides, and how it differs from the alternatives.

The decisive property, stated up front: `may_intervene` gives the agent a choice, not a reflex. It wakes the agent, but the agent is allowed to stay silent. The decision is made by a lightweight turn whose entire job is to weigh whether speaking helps.

## What the policy does

`unaddressed_group_message_policy: may_intervene` on a signal binding changes what a non-mention group message becomes. Instead of being ignored, the message produces a `may_intervene` event. The agent wakes on that event, runs a turn, and either speaks or holds. The handler code lives in `core/turns/ambient_turn.ts` and `core/turns/ambient_recognizer.ts`.

The critical distinction from a normal addressed turn: the agent is not told to reply. It is told to decide whether to reply. An addressed turn assumes the user wants an answer; an ambient turn assumes nothing and earns the right to speak by judging that speaking helps.

## How the agent decides

The ambient turn is lighter than an addressed turn. It reads the context, weighs whether the conversation needs it, and may stay silent. The guidance it runs on is different from an addressed turn's guidance. In `core/turns/durable_context.ts`, the `formatAmbientDurableContext` function shapes the context for the decision:

> Use this saved context only to decide whether to speak. You cannot retrieve memory; stay silent if missing or newer context could change the decision.

Two clauses matter. First, the agent uses the saved context only to decide whether to speak — not to answer the question, not to act. Second, if missing context or newer context could change the decision, the agent stays silent. The bias is toward quiet: when in doubt, the agent does not speak.

## The four policies compared

`unaddressed_group_message_policy` has four values, and they are best understood by what a non-mention group message does under each:

- **`may_intervene`** — produces a `may_intervene` event. The agent wakes and decides whether to speak. This is the only policy where the agent gets a choice to intervene.
- **`addressed_only`** — only @-mentions wake the agent. A non-mention group message does nothing.
- **`record_only`** — the agent mirrors the message into its context but never wakes. It sees the channel; it does not act on it.
- **`ignore`** — the agent sees nothing. The message does not enter the agent's context at all.

Pick the policy to match the agent's role. A customer-success agent in a shared support channel may belong on `may_intervene` — it should be able to spot a question it can answer. A release-notes bot belongs on `addressed_only` — it should speak only when called. A passive observer that builds context belongs on `record_only`. An agent that must not see a channel at all belongs on `ignore`.

## Where the policy lives

The policy is set on the signal binding, alongside the adapter, filters, and the `enabled` flag. It is per-binding, which means one agent can intervene in one channel and stay addressed-only in another. For the binding model, the fields, and how to create or replace a binding, read [Signal bindings](../signal-bindings/). For an agent's role and how that should map onto a policy, read [Agents](../agents/) and the [team assistant](../team-assistant/) pattern.

## What the operator does not touch

The ambient turn's handler, the recognizer that classifies a message as `may_intervene`, and the durable-context formatting are worker internals. If an agent speaks too much under `may_intervene`, the fix is in the agent's persona and the policy choice — see [Agents](../agents/) — not in a worker flag. The durable-context guidance that biases the agent toward silence is part of the runner, not a Console setting.

## Next steps

- For the binding that carries the policy and how to set it, read [Signal bindings](../signal-bindings/).
- For how an agent's role maps onto a group-chat policy, read [Agents](../agents/) and the [team assistant](../team-assistant/) pattern.
- For the worker that runs the ambient turn and shapes its context, read the [Agent Computer](../agent-computer/) developer page.
