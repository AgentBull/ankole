---
title: Actor Runtime
description: How a long-running session lives, wakes, fails, and recovers — the actor key, the OTP failure domains, the activation fence, and the RuntimeFabric live path.
section: Concepts
order: 8
---

The Actor Runtime is what makes a session a long-lived thing rather than a request. A signal arrives, a session wakes, a worker runs one turn, the turn commits or fails, and the session goes back to waiting — all while the durable transcript in PostgreSQL stays correct even if processes crash. This page maps that lifecycle against the real code in `Ankole.SignalsGateway.ActorRuntime`.

The central design choice, stated up front: correctness lives in the database, not in processes. The live processes are an optimization for reasoning and throughput; the fences that stop a late or cross-session reply from corrupting state are plain equality checks against rows. Lose every process, and the durable transcript is still intact.

## The actor key

The unit of long-running work is one actor key: `{agent_uid, session_id}`. One agent can hold many sessions; one session belongs to exactly one agent. Everything that follows — the serial controller, the activation, the delivery rows, the worker assignment — is keyed on this pair.

A session is where context, workspace state, steering, cancellation, and recovery meet. It is not a request and not a queue job; it is a stateful work identity that can wake, wait, and resume across hours or days.

## Two layers, two guarantees

The runtime keeps two layers deliberately separate, because they need different guarantees:

- **AI-agent state** — conversations, turns, messages — is *durable truth*. It lives in AIGateway-owned tables and survives any crash.
- **Actor-runtime projections** — activations, deliveries, assignments — are cheaper *runtime hints*. They fence in-flight work and can be rebuilt from the durable layer.

This split is why a worker is replaceable. The worker runs a turn; the fence rows decide whether that turn's reply is still the one that counts. A late reply from a crashed or superseded worker fails the fence and is discarded, harmlessly.

## The serial controller, one per actor

For each actor key, a `SessionController` GenServer is spawned on demand by a dynamic supervisor and registered under a unique name in `ActorDirectory`. One controller serializes scheduling for one actor key, so the common path never has two turns racing for the same session.

This is an optimization for reasoning, not the correctness boundary. If a controller crashes and restarts, no actor state is lost — the durable database fences were the real guard all along. Starting a controller is idempotent: two concurrent wakeups for the same actor race to start it, the loser gets `{:already_started, pid}`, and both callers treat that as success and return the live pid. Callers never coordinate who starts the actor.

## OTP failure domains

The supervision tree is built so one failure does not become everyone's failure:

- **The runtime supervisor** runs `:one_for_one`. Its children — transport, naming, per-actor controllers — are independent concerns. One crashing child does not invalidate the others' state, because durable correctness lives in PostgreSQL, not in these processes.
- **The session supervisor** is a `DynamicSupervisor`, also `:one_for_one`. Each `SessionController` is its own failure unit: one crashing controller, or one misbehaving actor, is isolated and restarted without touching any other actor's controller.

The practical effect is that a single agent hanging, timing out, or crashing gets isolated or restarted on its own branch, instead of turning into a deployment-wide outage. Actors come and go at runtime without a static child list.

## The activation fence

When a session wakes to run a turn, the runtime creates an `ActorSessionActivation`: a live lease projection for that actor session. An activation carries an `actor_epoch` — a monotonic counter for that actor key — a `lease_id` and `lease_expires_at`, a `current_actor_event_id`, and a `revision` bumped on every in-place steer of the live turn.

Activation status moves `starting → active → draining`, with `stopped` and `failed` terminal. Only one live activation may exist per actor key at a time, enforced by a partial unique index. A new activation after a lease failure gets a higher epoch, and that epoch is the cheap fence that makes a late reply from the previous activation fail by simple inequality.

Every worker reply must echo a `turn_ref` whose fields are checked by equality against the database rows — the triple fence of activation, actor epoch, and the delivery rows that name a turn. This makes a late or cross-session worker reply fail harmlessly instead of corrupting the durable transcript, and it needs no in-memory session state to do so. The one intentionally weak spot — a durable started turn whose runtime fences were lost on a restart — is repaired by the exact runtime event handler for the affected message row.

## Delivery rows and the live path

Between a queued actor event and worker acceptance sits an `ActorEventDelivery` row. One worker execution processes exactly one `actor_event_id`. The fence quintet — `activation_uid`, `actor_epoch`, `actor_event_id_fence`, `revision`, and the actor key — is copied from the activation onto each delivery row, so stale-reply checks run as plain equality against the database with no in-memory session state required.

Delivery state moves `created → sent → accepted`, with `send_failed` and `superseded` terminal and ignorable. The live path from the control plane to the worker runs over RuntimeFabric — the ZeroMQ-based live transport — and decoded traffic is routed above the socket-owning broker: worker lifecycle events are serialized, actor events are forwarded to their per-session controller, and independent worker RPC requests run under a task supervisor. No domain callback executes in the transport broker process.

## Lease expiry and recovery

The activation is only valid while `now < lease_expires_at`. A watchdog fails an expired in-flight activation so its actor event can be retried; normally it stops a warm activation whose current event is nil. When a turn errors, the event stays `open` for retry until repeated worker failures cross the overflow threshold, at which point it moves to `dead_letter`. Retries use exponential backoff, bounded between 5 and 120 seconds, and each failed attempt's epoch is bumped so its late replies cannot match a later retry.

This is the recovery story in one sentence: the durable event stays open, the runtime projections are rebuilt, and a fresh activation with a higher epoch picks the event back up. The actor does not lose its place, because its place was never in a process.

## What the Actor Runtime is not

It is not a place to store durable facts — those live in the AI-agent state layer and PostgreSQL. It is not a worker; workers are replaceable Agent Computer processes that run turns. And it is not the entry surface; signals arrive through [SignalsGateway](../signals-gateway/), and once they become actor events, waking and running them is this runtime's job. The boundary is the conversion from a durable queued event into a fenced, recoverable live turn — and back into a durable commit.

## Next steps

- For how signals become actor events, read the [SignalsGateway](../signals-gateway/) page.
- For the model turns a worker runs once awake, read the [AIGateway API](../ai-gateway/).
- For the whole-system view, read the [architecture overview](../architecture/).
