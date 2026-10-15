---
title: The agent loop
description: The control-plane Driver, durable model and tool steps, and the Worker execution boundary.
section: Developer guide
order: 117
---

The main Agent loop runs in `Ankole.Sessions` in the Elixir control plane. Each Session has one `:gen_statem` Driver. Pure questions and control-plane tools work without a Worker; environment tools and Codex start the Agent's Worker when needed.

## One durable round

1. Admit an open Signal and advance the Session epoch in PostgreSQL.
2. Restore the stored Response chain and prepare the next model request.
3. Open a stored Response through AIGateway's in-process Responses API.
4. Dispatch calls to their declared owner: a control-plane tool, the Worker, or a durable wait.
5. Commit the whole round's results, satisfied input events, and receipt deletion in one transaction.
6. Inject queued input at the boundary, or commit the final reply and completed inputs.

AIGateway owns the transcript, compaction, memory injection, and hosted tools. The Driver owns iteration limits, empty-answer repair, repeated-error hints, and final-response rules. All control-plane model loops use this owner; Codex keeps its own loop inside the Worker.

## Recovery and side effects

A new Driver reconstructs progress from Signals and the Response chain. Control-plane tool effects and their receipts commit together. Results already on the chain are not executed again. The Worker identifies an environment call by its Response and call IDs, so a replacement Driver can adopt it. After Worker process loss, a safe call can retry; other unknown calls return `interrupted`.

Ordinary inputs wait for the next boundary. Stop and a valid retry interrupt current work. An invalid targeted retry leaves the run active. Withdrawal or bare retry after tool calls preserves their records and injects the correction on the same chain.

## Bounded failure

AIGateway owns retries inside one model round. The Driver owns retries between attempts. Ordinary inputs enter dead letter on the sixth admission. Planned shutdown refunds an admitted attempt when its transaction succeeds; a crash does not. Workflow and Job owners keep their own budgets.

See [Sessions](../sessions/) for writer ownership, [Agent Computer Worker](../agent-computer-worker/) for execution and storage, and [AIGateway](../ai-gateway/) for Responses.
