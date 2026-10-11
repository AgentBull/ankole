---
title: Actor Runtime
description: Conversation Drivers, durable input and Response logs, writer fences, and recovery.
section: Developer guide
order: 103
---

The actor key is `{agent_uid, session_id}`. An Agent can have concurrent conversations; one conversation advances through one Driver in `Ankole.Conversations`.

## One writer

A DynamicSupervisor starts temporary `:gen_statem` Drivers. `:global` gives each actor key one name across the Erlang cluster. The persistent workspace epoch is the write fence: admission advances it, and Driver transactions check it under a row lock. A stale Driver cannot commit, even after a network partition.

## Facts that survive processes

ActorEvents are the durable inbox. AIGateway's Response chain records model output and tool results. A control-plane tool commits its effect and receipt together; the Driver moves the whole round into the chain and deletes its receipts in one transaction. A replacement Driver reconstructs progress from these facts.

Input completion and the final reply commit together. The last injected input that can receive a reply owns it; internal corrections keep the existing reply owner. Tool results survive withdrawal and retry after an effect.

## Worker identity

An Agent's Worker is requested only for environment tools or Codex. Environment work uses `RunRef`, scoped to the Agent, Session and triggering input. Codex uses `JobTurnRef`, which also names the Job and attempt. Results use their operation identity rather than the Driver epoch, so a new Driver can adopt work already in progress.

RuntimeFabric uses one Phoenix Channel per Worker. Phoenix Tracker finds the channel across nodes, and distributed Erlang delivers to it. The current Worker generation and incarnation reject a stale route. Workers remain bound to their own Agent.

## Recovery

Input owners insert Oban wakeups with their domain writes. A minute Reconciler scans all due open input, including attempts that already started. It wakes an existing Driver or ensures a new one. It also asks the Workflow owner to repair missing RunServers and terminal cleanup. Backoff starts at the stored `last_attempt_at`; failure budgets bound repeated crashes.

The control plane uses the same path in one-node and multi-node deployments. See [Agent loop](../agent-loop/), [SignalsGateway](../signals-gateway/) and [Worker](../agent-computer-worker/).
