---
title: Agent Computer Worker
description: How the Bun and TypeScript Worker runs model loops, tools, files, terminal state, and streaming output while the control plane fences each turn.
section: Developer guide
order: 108
---

An Agent Computer Worker is the execution node for an Agent. When a conversation wakes, Actor Runtime gives a fenced turn to a Worker. The Worker runs the model loop, tools, files, and terminal work, then returns the result to the control plane. This page describes the boundary implemented by `app/agent_computer`.

The decisive property, stated up front: the worker owns live execution and rebuildable worker-local state, nothing more. Durable state — the transcript, the fences, the final commit — stays in the control plane. A worker is replaceable, and a late or stray worker write fails the fence and is discarded.

## The ownership boundary

The split is explicit in the worker's own contract. Agent Computer Worker owns live execution and rebuildable worker-local state. The Elixir control plane owns PostgreSQL state, actor and delivery fences, final commit authority, provider outboxes, runtime credentials, and recovery facts. The worker must not invent durable control-plane state.

What this rules out in practice: `DATABASE_URL`, `ANKOLE_AGENT_UID`, `ANKOLE_SESSION_ID`, and `ANKOLE_ACTOR_EPOCH` are not worker inputs. Actor identity arrives in `turn_start`, not in the environment. The worker authenticates to RuntimeFabric with a `WORKER_ID`, a `RUNTIME_FABRIC_URL` carrying the worker auth key, and `ANKOLE_AGENTS_ROOT`. It does not hold a database connection and it does not decide who it is acting for.

## The turn fence

Every turn the worker runs is pinned by an `ActorTurnRef` with three fields — `activation_uid`, `actor_epoch`, and `actor_event_id`. One worker execution handles exactly one `actor_event_id`. The worker keys its in-memory active-turn state on `${activation_uid}:${actor_event_id}`, and every envelope it sends back to the control plane carries the ref.

This is the worker side of the [Actor Runtime](../actor-runtime/) triple fence. The control plane checks each incoming worker write against the activation, the epoch, and the delivery rows; if the worker's ref no longer matches — because the activation was superseded, the lease expired, or the event was retried with a higher epoch — the write is rejected as stale. The worker does not get to commit to a turn it no longer owns.

## The model loop

The agent loop is a worker-driven Responses loop over AIGateway's stateful transport, and it is deliberately small. Four steps:

1. Call the model through a turn-scoped OpenAI Responses adapter.
2. If the response carries function-call items, execute them locally.
3. Record the function-call outputs through AIGateway.
4. Continue from the recorded journal anchor until no function-call items come back.

The worker owns loop termination and its local iteration budget. It does **not** own history expansion, compaction, continuation anchors, or durable response state — those stay in AIGateway. When the loop ends, the outcome is one of two: `loop_finished` (the model returned with no further tool calls) or `iteration_exhausted` (the worker hit its iteration limit, and the model is nudged to synthesize a final answer rather than call more tools). The worker reports the whole-turn outcome to the control plane; the control plane records it.

## Tools: what runs inside the worker

Tools are the local actions the model can drive during a loop. The worker ships them as categories, each backed by real worker code:

- **Computer** — shell commands (under bubblewrap confinement), file read and patch, apply-patch, and the v4a computer-use tool that drives a real browser desktop. This is where terminal state and file edits live.
- **Web** — web search and web fetch, routed through the worker.
- **Brain** — the recall and knowledge tools that reach back into long-term memory.
- **Memory, schedule, todo, clarify** — the smaller structured tools an agent uses to plan, defer, and ask.
- **Codex** — the CodexRunner job tools, for work delegated to a Background Agent Job.
- **Library and mcporter** — access to enabled Skills and invocation-scoped MCP dependency configs.
- **Direct MCP** — release-defined deferred namespace tools, with bounded live catalogs and local artifact handling.
- **Background Agent Job** — the handoff tools that create or continue durable jobs.

Every tool result the worker produces is recorded through AIGateway as a function-call output, not committed directly. The model sees the result; the control plane decides what is durable.

## The filesystem contract

The durable shared writable runtime mount is `/agents`, laid out per actor key:

```text
/agents/<agent-key>/
├── .codex/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── user-files/
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── .ankole/skills/
    └── temp/
```

The model sees the absolute container path. The Worker does not translate paths. `SOUL.md` and `MISSION.md` define Agent behavior and responsibility. `DESIGN.md` is the design system for visual work. The [Agent Library](../agent-library/) manages all three. `installed-skills/`, `sessions/`, and `jobs/` hold Skills, conversation workspaces, and Background Agent Job workspaces. PostgreSQL assigns each Session a stable numeric workspace ID that starts at 10000.

## Streaming and progress

While a turn runs, the worker publishes progress as best-effort, non-overlapping envelopes — a checkpoint every interval, with an activity summary when there is something useful to say. Progress is intentionally not a durability mechanism: a stuck progress send must not pile up timers or block the loop it is describing. The streaming output the model and tools produce flows back through the same RuntimeFabric lanes; what becomes durable is decided by the control plane at commit, not by the worker as it streams.

The worker also publishes a small admission hint — remaining turn capacity from its in-memory state — so the control plane can avoid sending work to a full process. Scheduling stays with the control plane; the hint is just a hint.

## What an Agent Computer Worker is not

It is not a standalone local CLI; it runs inside the Linux worker image, which supplies the native kernel bindings, bubblewrap, Chromium, Python/Jupyter and document tooling, ZeroMQ, and the shared agent filesystem. It is not a place to invent durable state — the worker's job is to execute a fenced turn and report back, and every durable decision is the control plane's. And it is not a second scheduler; the Actor Runtime owns waking, leasing, and retrying. The boundary is clean: the control plane owns the turn's identity and truth, the worker owns the turn's execution.

## Next steps

- For the fence that pins a worker to one activation, read the [Actor Runtime](../actor-runtime/) page.
- For the stateful Responses transport the loop calls, read the [AIGateway API](../ai-gateway/).
- For the skills and documents the worker reads from `/agents`, read the [Agent Library](../agent-library/) page.
