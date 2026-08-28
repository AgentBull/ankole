---
title: Prompt assembly
description: How the system prompt an agent sees each turn is built — the control-plane data providers, the two channels that carry it to the worker, and the worker-side assembly that produces the final prompt.
section: Developer guide
order: 118
---

Every turn, the worker builds the system prompt the model sees. That prompt is assembled from PostgreSQL-backed agent context, resolved at turn time, and rendered on the worker. This page documents how the pieces get from the control plane to the worker, what each piece is, and where the assembly happens. It builds on the [Agent Computer Worker](../agent-computer-worker/) and [AIGateway](../ai-gateway/) pages.

The system prompt is **assembled on the Worker**, not on the control plane. The control plane supplies durable Agent documents, Skills, Agent settings, and chat context through two paths. The Worker renders these facts into the final prompt.

## The two data channels

The worker receives context from the control plane through two paths, each carrying a different class of data:

| Channel | What it carries | When |
|---|---|---|
| `turn_start.request_context` | agent-loop settings (`ai_agent.max_iterations`, `max_output_tokens`, `inactivity_timeout_ms`) and turn-local facts (the signal and the kind of turn) | embedded in the TurnStart envelope, before the loop begins |
| `AgentConversationContextBroker` RPC | durable Agent documents (`SOUL`/`MISSION`/`DESIGN`), enabled skills, conversation origin channel, instance timezone, agent profile | fetched by the worker at loop start, through an RPC over RuntimeFabric |

The split is deliberate: turn-local facts travel on `turn_start` because they change every turn; conversation-scoped context is fetched by the worker through the broker because it is stable across turns within a conversation and the broker caches it. The broker's moduledoc is explicit: "This RPC intentionally does not return transcript messages or turn-local request context. Transcript history is owned by AIGateway; turn-local facts travel on `turn_start`."

## What the control plane provides

### Durable Agent documents

`AgentConversationContextBroker` reads the Agent's durable documents through `Library.list_agent_documents/1`. It returns them as `soul`, `mission`, and `design`. `SOUL.md` defines communication and judgment, `MISSION.md` defines responsibilities, and `DESIGN.md` supplies the design system for visual work.

### Enabled skills

`Library.runtime_skills_for_agent/1` sends the Agent's complete effective Skill set, with descriptions and metadata, to the Worker. The Worker keeps the complete set for `skill_view`. When it builds the model-visible catalog, it omits Skills that declare `brain-recall-only: true`, so Brain can discover them without listing them in every prompt.

### Conversation origin channel

`SignalsGateway.ConversationChannel` projects the provider channel declared by the AIGateway conversation. It reads a group label from the current channel mirror and a DM label from the peer Principal. It reports the `lark` adapter as one Lark / Feishu surface; the adapter domain only selects the API server. The broker sends this projection through `ConversationInfo.origin_channel`, so an internal wakeup does not lose the conversation origin when its ActorEvent payload has no channel object.

### Agent settings (from AppConfigure)

`AgentConfig` resolves the loop-level settings from AppConfigure and snapshots them into `turn_start.request_context.ai_agent`:

- `ai_agent.max_iterations` (default 90) — the agent loop's iteration budget
- `ai_agent.max_output_tokens` (default nil = no explicit cap) — per-response token cap
- `ai_agent.inactivity_timeout_ms` (default 30 minutes) — how long a turn may be inactive

These belong to the actor turn, not to any individual model response, so they ride on `turn_start`.

## The worker-side assembly

`system_prompt.ts` on the worker builds the final prompt. Its moduledoc states the design: "Slow-changing instructions lead; conversation-scoped runtime and skill context form the suffix." The blocks, in order:

1. **Core instructions** — the agent's base behavior contract, assembled from the turn's context.
2. **Durable Agent documents** — `SOUL`, `MISSION`, and `DESIGN`, rendered from the broker's response.
3. **Skills** — the enabled skill descriptions, telling the model what it can reach for.
4. **Channel and runtime context** — the conversation origin channel, the workspace paths, the available tool names.

The worker re-renders the full prompt every turn from current PostgreSQL-backed context — it does not trust a cached version. AIGateway retains prior request instructions for audit, but the turn renders the current state.

## What is NOT in the system prompt

- **Transcript history** — owned by AIGateway's stateful Responses; the system prompt does not repeat it.
- **Turn-local observations** — the signal, the incoming message, the user's current input. These stay in the current user message, not in the system prompt.

This separation keeps the system prompt stable (it changes when persona or skills change, not when the conversation grows) and keeps the per-turn payload small.

## What this guide is not

It is not a prompt-engineering tutorial — the literal strings in `system_prompt.ts` are the contract with the model, and changing them is a behavior change, not a documentation change. It is not a control-plane-side description of prompt assembly — the assembly is on the worker, and the control plane's role is to provide the data. And it is not a substitute for reading `system_prompt.ts`; it is the map to it.

## Next steps

- For the agent loop that uses this prompt, read [The agent loop](../agent-loop/).
- For the Agent Computer Worker that runs the assembly, read [Agent Computer Worker](../agent-computer-worker/).
- For the skills block, read [Agent Library](../agent-library/).
