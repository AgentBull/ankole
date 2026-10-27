---
title: The agent loop
description: The control-plane Driver, durable model and tool steps, and the Worker execution boundary.
section: Developer guide
order: 117
---

The main Agent loop runs in `Ankole.Sessions` inside the Elixir control plane, where each Session is driven by a single `:gen_statem` Driver process. Pure Q&A turns and control-plane tools execute directly in Elixir without a Worker, whereas environment tools and Codex Jobs start the Agent's Worker on demand.

## One durable round

Each round of the Agent loop advances through six durable steps:

1. Admit an open Signal and advance the Session epoch in PostgreSQL.
2. Restore the stored Response chain and assemble the next model request.
3. Open a stored Response through AIGateway's in-process Responses API.
4. Dispatch each call to its declared owner: a control-plane tool, the Worker, or a durable wait.
5. Commit all tool results from the round, satisfied input events, and receipt deletions in a single transaction.
6. Either inject newly queued input at the round boundary and continue, or commit the final reply alongside completed inputs.

Within this loop, AIGateway manages the transcript, context compaction, memory injection, and hosted tools, while the Session Driver enforces iteration limits, repairs empty answers, injects hints after repeated tool errors, and applies final-response rules. Every control-plane model loop runs through this Driver; only Codex runs its own internal loop inside the Worker.

## Recovery and side effects

When a replacement Driver starts, it reconstructs progress from open Signals and the stored Response chain. Because control-plane tool effects and their execution receipts commit in the same transaction, the Driver never re-executes calls whose results are already recorded on the chain. On the Worker side, each environment call is keyed by its Response ID and call ID so a replacement Driver can adopt an in-flight call or collect its finished output. If the Worker process itself was lost, the Driver retries only idempotent safe calls and returns `interrupted` for any other unknown calls.

Ordinary user inputs wait in queue until the next round boundary. By contrast, a stop command or a valid retry interrupts current work immediately, whereas an invalid targeted retry is rejected without disturbing the active run. When a user withdraws a message or triggers a bare retry after tool calls have already executed, the Driver preserves those tool records and appends the correction on the same chain.

## Bounded failure

Retries are bounded at two layers: AIGateway handles transport retries within a single model round, while the Session Driver manages retries across turn attempts. If an ordinary input keeps failing, the Driver moves it to dead letter on its sixth admission. During a planned shutdown, the Driver refunds an admitted attempt if its cleanup transaction commits, whereas an unexpected crash consumes the attempt. Background Workflows and Jobs maintain their own independent retry budgets.

See [Sessions](../sessions/) for writer ownership, [Agent Computer Worker](../agent-computer-worker/) for execution and storage, and [AIGateway](../ai-gateway/) for Responses.
