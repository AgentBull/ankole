---
title: Prompt assembly
description: How the system prompt an agent sees each turn is built — the control-plane data providers, the two channels that carry it to the worker, and the worker-side assembly that produces the final prompt.
section: Developer guide
order: 118
---

Every turn, the worker builds the system prompt the model sees. That prompt is assembled from PostgreSQL-backed agent context, resolved at turn time, and rendered on the worker. This page documents how the pieces get from the control plane to the worker, what each piece is, and where the assembly happens. It builds on the [Agent Computer Worker](../agent-computer-worker/) and [AIGateway](../ai-gateway/) pages.

The system prompt is **assembled on the Worker**, not on the control plane. The control plane supplies durable Agent documents, Skills, the Brain snapshot, Agent settings, and chat context through two paths. The Worker renders these facts into the final prompt.

## The two data channels

The worker receives context from the control plane through two paths, each carrying a different class of data:

| Channel | What it carries | When |
|---|---|---|
| `turn_start.request_context` | agent-loop settings (`ai_agent.max_iterations`, `max_output_tokens`, `inactivity_timeout_ms`), turn-local facts (the signal, the channel, the kind of turn) | embedded in the TurnStart envelope, before the loop begins |
| `AgentConversationContextBroker` RPC | durable Agent documents (`SOUL`/`MISSION`/`DESIGN`), enabled skills, Brain snapshot (pinned memo + channel entry), instance timezone, agent profile | fetched by the worker at loop start, through an RPC over RuntimeFabric |

The split is deliberate: turn-local facts travel on `turn_start` because they change every turn; conversation-scoped context is fetched by the worker through the broker because it is stable across turns within a conversation and the broker caches it. The broker's moduledoc is explicit: "This RPC intentionally does not return transcript messages or turn-local request context. Transcript history is owned by AIGateway; turn-local facts travel on `turn_start`."

## What the control plane provides

### Durable Agent documents

`AgentConversationContextBroker` reads the Agent's durable documents through `Library.list_agent_documents/1`. It returns them as `soul`, `mission`, and `design`. `SOUL.md` defines communication and judgment, `MISSION.md` defines responsibilities, and `DESIGN.md` supplies the design system for visual work.

### Enabled skills

`Library.skills_for_system_prompt/1` returns the agent's effective skill set — the skills enabled by default-then-override, with their descriptions and metadata. The worker uses these to build the skills block of the system prompt, telling the model which skills it has and what each is for.

### Brain snapshot

`Brain.Snapshot.get_or_create/1` resolves the conversation's Brain scope and returns a snapshot: the agent's pinned memo (`agent_context`) and the channel's durable context (`group_context`). These are saved context entries — durable facts the agent was told to remember — not the full Brain knowledge base. The snapshot is a projection, not a query; recall (the full search) happens through Brain tools during the loop, not through this snapshot.

### Agent settings (from AppConfigure)

`AgentConfig` resolves the loop-level settings from AppConfigure and snapshots them into `turn_start.request_context.ai_agent`:

- `ai_agent.max_iterations` (default 90) — the agent loop's iteration budget
- `ai_agent.max_output_tokens` (default nil = no explicit cap) — per-response token cap
- `ai_agent.inactivity_timeout_ms` (default 30 minutes) — how long a turn may be inactive

These belong to the actor turn, not to any individual model response, so they ride on `turn_start`.

## The worker-side assembly

`system_prompt.ts` on the worker builds the final prompt. Its moduledoc states the design: "Slow-changing instructions lead; conversation-scoped runtime, skill, and Brain snapshots form the suffix." The blocks, in order:

1. **Epoch marker** — `<!-- ankole-system-prompt-epoch:agent-computer-v3 -->`, so prompt-cache-aware providers can identify the prompt version.
2. **Core instructions** — the agent's base behavior contract, assembled from the turn's context.
3. **Durable Agent documents** — `SOUL`, `MISSION`, and `DESIGN`, rendered from the broker's response.
4. **Durable context** — the Brain snapshot's pinned memo and channel entry, rendered with guidance ("Use an item only if it remains valid… otherwise ignore it").
5. **Skills** — the enabled skill descriptions, telling the model what it can reach for.
6. **Channel and runtime context** — the current channel, the workspace paths, the available tool names.

The worker re-renders the full prompt every turn from current PostgreSQL-backed context — it does not trust a cached version. AIGateway retains prior request instructions for audit, but the turn renders the current state.

## What is NOT in the system prompt

- **Transcript history** — owned by AIGateway's stateful Responses; the system prompt does not repeat it.
- **Turn-local observations** — the signal, the incoming message, the user's current input. These stay in the current user message, not in the system prompt.
- **Brain recall results** — recall (the full search) happens through Brain tools during the loop, not as a system-prompt block. The snapshot is the floor; recall is the ceiling.

This separation keeps the system prompt stable (it changes when persona, skills, or memory change, not when the conversation grows) and keeps the per-turn payload small.

## What this guide is not

It is not a prompt-engineering tutorial — the literal strings in `system_prompt.ts` are the contract with the model, and changing them is a behavior change, not a documentation change. It is not a control-plane-side description of prompt assembly — the assembly is on the worker, and the control plane's role is to provide the data. And it is not a substitute for reading `system_prompt.ts`; it is the map to it.

## Next steps

- For the agent loop that uses this prompt, read [The agent loop](../agent-loop/).
- For the Agent Computer Worker that runs the assembly, read [Agent Computer Worker](../agent-computer-worker/).
- For the Brain snapshot that feeds the durable-context block, read [Brain](../brain/).
- For the skills block, read [Agent Library](../agent-library/).
