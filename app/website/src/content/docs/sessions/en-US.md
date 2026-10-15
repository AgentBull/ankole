---
title: Sessions
description: Agent execution, shared history reads, writer fences, and recovery.
section: Developer guide
order: 103
---

A Session is one Agent's unit of execution. Its key is `{agent_uid, session_id}`. An Agent can run multiple Sessions concurrently. Each Session advances through one Driver in `Ankole.Sessions`.

A Conversation stores shared statements. Each participating Agent has a separate Session for that Conversation. AIGateway stores the model history used by the Session. A generic Signal can target a Session without a Conversation.

## One writer

A DynamicSupervisor starts temporary `:gen_statem` Drivers. `:global` gives each Session key one name across the Erlang cluster. The persistent workspace epoch is the write fence. Admission advances it, and Driver transactions check it under a row lock. A stale Driver cannot commit after a network partition.

## Durable inputs and model history

Signals are the durable inbox. AIGateway's Response chain records model output and tool results. A control-plane tool commits its effect and receipt together. The Driver commits the round into the chain and deletes its receipts in one transaction. A replacement Driver reconstructs progress from these facts.

At a model request boundary, Sessions reads current Conversation Messages. The read watermark belongs to the actual request metadata. The current main and steer Messages are excluded from the background slice. Shared history supplies context; it does not supply permission to act for a past author. Admission checks the current requester.

Signal completion and final reply intent commit together. Internal revisions preserve the reply owner. Tool results remain available after withdrawal or retry. A command such as `/compress` completes with its feedback and checkpoint; it does not need a normal final model Response.

## Worker and operation identity

The Agent's Worker is requested when an environment tool or Codex needs its computer. Environment work uses `RunRef`, scoped to the Agent, Session and Signal. Codex uses `JobTurnRef`, which also identifies the Job and attempt. An operation has its own identity, so a replacement Driver can adopt work already in progress.

RuntimeFabric uses one Phoenix Channel per Worker. Phoenix Tracker locates it across nodes. The Worker generation and incarnation reject stale routes. Each Worker remains bound to one Agent.

## Recovery

Signals inserts a durable Oban wakeup in its admission transaction. The wakeup commits with the caller's domain writes. A Reconciler scans due open inputs, including attempts already started. It wakes the existing Driver or ensures a new one. It also asks the Workflow owner to repair missing RunServers and cleanup. Stored `last_attempt_at` and failure budgets control repeated attempts.

Native chats, external chats, scheduled work, and business events use these execution rules. Read [Signals](../signals/), [Agent loop](../agent-loop/), and [Agent Computer Worker](../agent-computer-worker/) for their adjacent owners.
