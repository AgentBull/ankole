---
title: The agent loop
description: The boundary between the control-plane turn lifecycle and the worker-side agent loop — what each side owns, how they communicate, and where the iteration budget and retry live.
section: Developer guide
order: 117
---

A turn is a unit of work that spans two runtimes: the Elixir control plane schedules and fences it, and the Bun worker runs the agent loop inside it. This page documents the boundary between the two — what the control-plane `TurnLifecycle` owns, what the worker's `runAgentLoop` owns, and how they communicate across RuntimeFabric. It builds on the [Actor Runtime](../actor-runtime/) and [Agent Computer Worker](../agent-computer-worker/) pages; this is the turn-level detail between them.

The decisive property, stated up front: the control plane owns the turn's *identity and commit*; the worker owns the turn's *execution*. The worker decides when the loop ends; the control plane decides whether the turn's result is durable. A turn that the worker reports as finished is not durable until the control plane commits it.

## The control-plane side: TurnLifecycle

`Ankole.SignalsGateway.ActorRuntime.TurnLifecycle` owns what happens around the loop, not inside it. Its responsibilities:

| Responsibility | What it does |
|---|---|
| **Lease management** | an activation holds a lease (`activation_progress_lease_seconds` = 2100s, with a 120s grace); the watchdog fails an expired activation so its event can be retried |
| **Turn start** | creates the `ActorSessionActivation` with a fresh epoch, assigns the worker, delivers the turn envelope over RuntimeFabric |
| **Turn error handling** | `handle_turn_error/2` receives the worker's error report, classifies it, and decides retry vs dead-letter |
| **Turn commit** | records the turn's outcome as durable truth when the worker reports success |
| **Activation expiry** | `fail_activation_if_expired/2` catches a stuck or crashed turn whose lease ran out |

The turn error retry budget lives here, not in the worker: at most 5 attempts (`@worker_turn_error_dead_letter_attempts`), with exponential backoff between 5 and 120 seconds (`@worker_turn_error_retry_base_seconds` and `@max`). Each failed attempt bumps the epoch, so a late reply from the failed attempt cannot match a later retry.

The control plane does **not** decide what the model says, what tools the agent calls, or how many iterations the loop runs. Those are the worker's.

## The worker side: runAgentLoop

`runAgentLoop` in `app/agent_computer/src/core/agent-loop.ts` is the four-step loop the worker runs inside a turn:

1. **Call the model** through a turn-scoped OpenAI Responses adapter (AIGateway's stateful transport).
2. **Execute function calls locally** — if the response carries function-call items, the worker runs the tools.
3. **Record the outputs** through AIGateway, which stores them as function-call-output messages.
4. **Continue from the journal anchor** until the response returns no more function-call items.

The worker owns **loop termination and its local iteration budget**. Two outcomes:

- **`loop_finished`** — the model returned with no further tool calls. The turn ends naturally.
- **`iteration_exhausted`** — the worker hit its iteration limit. The model is nudged to synthesize a final response rather than call more tools (`MODEL_ITERATION_LIMIT_SYNTHESIS_TEXT`), and the turn ends with that synthesis.

The worker also owns three recovery nudges: an empty-after-tools nudge (the model executed tools but returned an empty response), a tool-error recovery hint, and the iteration-limit synthesis. These are worker-side because they are about what the model does next, not about whether the turn is durable.

## What the worker does NOT own

The agent-loop moduledoc is explicit: the worker does **not** own history expansion, compaction, continuation anchors, or durable response state. Those remain in AIGateway. The worker:

- does not decide how much history the model sees (AIGateway's stateful Responses owns that, including compaction);
- does not store the conversation (AIGateway does);
- does not decide whether the turn's side effects are committed (the control plane does).

This is the split that makes a worker replaceable: the worker runs the loop, AIGateway owns the transcript, the control plane owns the commit.

## How they communicate

| Direction | What crosses the boundary |
|---|---|
| Control plane → worker | a `TurnStart` envelope (actor identity, turn ref, the event to process) |
| Worker → control plane | progress envelopes (checkpoints, activity summaries), a `TurnError` if the turn fails, or the turn's natural completion |
| Worker → AIGateway | model calls, function-call outputs (these do not go through the control plane) |

Every worker message carries the `ActorTurnRef` (`activation_uid`, `actor_epoch`, `actor_event_id`). The control plane checks it against the current activation; a message whose ref no longer matches is rejected as stale. This is the [Actor Runtime](../actor-runtime/) triple fence, seen from the turn level.

## The retry boundary

When a turn fails, the control plane decides retry, not the worker. The worker reports the error; `handle_turn_error` classifies it:

- **Retryable** (worker transport failure, timeout) — the event stays `open`, the epoch bumps, the runtime re-delivers after the backoff delay.
- **Dead-letter** — after 5 attempts (or 5 consecutive turn failures), the event moves to `dead_letter` and the turn stops retrying. An operator inspects and resolves it.

The worker does not retry on its own. It reports the error and the control plane owns the retry decision, because the control plane is what can re-establish the activation fence.

## What this guide is not

It is not a model-prompting guide — the loop's shape is mechanical (call, execute, record, continue), and the model's behavior within it is the persona's concern. It is not a transport guide — RuntimeFabric carries the envelopes, and that is the [Kernel](../kernel/) page's scope. And it is not a substitute for the [Actor Runtime](../actor-runtime/) page; the activation fence is the context the turn lifecycle operates inside.

## Next steps

- For the activation fence and the actor model, read [Actor Runtime](../actor-runtime/).
- For the worker that runs the loop, read [Agent Computer Worker](../agent-computer-worker/).
- For the stateful Responses transport the loop calls, read [AIGateway](../ai-gateway/).
- For compaction (which the worker does not own), read [Context compression](../context-compression-and-caching/).
