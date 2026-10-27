---
title: Sessions
description: Agent execution, shared history reads, writer fences, and recovery.
section: Developer guide
order: 103
---

A Session is a single Agent's unit of execution, keyed by `{agent_uid, session_id}`. An Agent can run multiple Sessions concurrently, and each Session advances through a dedicated Driver process in `Ankole.Sessions`.

While a Conversation stores the shared message stream visible to participants, each Agent in that Conversation owns its own separate Session, and AIGateway stores the model transcript used by that Session. Generic business Signals can also target a Session directly without any backing Conversation.

## One writer

Under `Ankole.Sessions`, a `DynamicSupervisor` starts temporary `:gen_statem` Driver processes, and `:global` registers at most one active Driver name per `{agent_uid, session_id}` across the Erlang cluster. To guard against split-brain writes, Ankole uses a persistent workspace epoch as a write fence: signal admission increments the epoch, and every Driver transaction verifies that epoch under a row lock so a stale Driver isolated by a network partition cannot commit.

## Durable inputs and model history

Signals serve as the Session's durable inbox, while AIGateway's Response chain records model outputs and tool results. When a control-plane tool executes, Ankole commits its domain side effect and a receipt atomically; once the tool round finishes, the Driver appends the completed round to the AIGateway chain and deletes those receipts in a single transaction. If a Driver crashes, its replacement reconstructs the exact in-flight state from these persisted records.

At each model request boundary, `Ankole.Sessions` reads new Conversation Messages using a read watermark stored in the request metadata, excluding the current main and steering Messages from the background context slice. Although shared Conversation history supplies conversational context, it never grants the Agent authority to act on behalf of an earlier speaker—admission always evaluates the Principal of the current requester.

When a turn finishes, the Driver commits Signal completion and the final outbound reply intent together, preserving the original reply owner across internal revisions and keeping completed tool results available across withdrawals or retries. Slash commands such as `/compress` commit their user feedback and compaction checkpoint directly without requiring a final language-model Response.

## Worker and operation identity

`Ankole.Sessions` provisions or wakes the Agent's Worker only when an environment tool or Codex Job requires a computer. Environment operations carry a `RunRef` scoped to the Agent, Session, and Signal, whereas Codex turns carry a `JobTurnRef` that additionally identifies the Job and attempt. Because each operation has its own stable identity, a replacement Driver can adopt Worker operations that are already running rather than duplicating them.

RuntimeFabric maintains one Phoenix Channel per Worker and locates active sockets across cluster nodes via Phoenix Tracker. On every message, RuntimeFabric checks the Worker's generation and incarnation numbers to reject stale routes, ensuring each Worker remains exclusively bound to a single Agent.

## Recovery

During signal admission, `Ankole.Signals` inserts a durable Oban wakeup job inside the same PostgreSQL transaction as the caller's domain writes. Periodically, a Reconciler scans due open Signals—including attempts that have already started—and either nudges the live Driver or starts a fresh one; it also asks the Workflow subsystem to recover missing `RunServers` and run pending cleanups. Persisted `last_attempt_at` timestamps and failure budgets bound repeated retry attempts.

Native Pod chats, external chat channels, scheduled runs, and business events all share this Session execution model. Read [Signals](../signals/), [Agent loop](../agent-loop/), and [Agent Computer Worker](../agent-computer-worker/) for the adjacent subsystems.
