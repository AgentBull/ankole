---
title: Prompt assembly
section: Developer guide
order: 118
description: How the control plane renders main Agent instructions and separates Codex Job context.
---

The control plane assembles the main Agent's model instructions. `Ankole.Sessions.Context.resolve/2` reads the current domain facts; `Ankole.Sessions.Prompt.system/1` renders them; `Ankole.Sessions.Driver` sends the result through AIGateway. The Worker receives environment work and Codex Jobs, rather than rendering the main Agent prompt. See [The agent loop](../agent-loop/).

## Current context

The context contains Agent identity and documents, effective Skills and plugins, conversation origin, and timezone. `SOUL.md` supplies behavior and judgment; `MISSION.md` supplies responsibilities. The domain owns these documents in PostgreSQL. Environment tools receive materialized runtime files through the workspace contract.

The main prompt starts with identity, SOUL, and MISSION, followed by completion and authority instructions, available Job and Workflow policies, memory guidance, environment and tool guidance, the Skill catalog, and runtime context. The templates are in `app/control_plane/priv/sessions/prompts/`; the renderer is `app/control_plane/lib/ankole/sessions/prompt.ex`.

The Skill catalog omits `brain-recall-only: true` entries. They remain in the effective set and can be discovered through Brain and loaded through `skill_view`. The runtime suffix names the Agent, `/workspace`, the current Session workspace, timezone, conversation start, and origin channel. The Lark adapter represents both Lark and Feishu; its domain selects the upstream API.

## Settings and history

`AgentConfig` resolves tenant settings for `ai_agent.max_iterations` (90), `ai_agent.max_output_tokens` (no explicit cap), and `ai_agent.inactivity_timeout_ms` (30 minutes). These bound the control-plane turn. They are not a Worker-owned main loop configuration.

AIGateway owns transcript history and stores model requests for audit. The current input and provider observations become user messages through `Prompt.Input`; they are not copied into the system instructions. The control plane renders instructions from current context for each run.

## Codex Jobs and Workflow tasks

Codex Jobs have a separate Worker path. The runner resolves frozen Job execution choices, gets current domain context through RPC, and prepares the Job project and its `AGENTS.md`. Native Codex owns that Job's model loop. See [Background Agent Jobs](../background-agent-jobs/).

Workflow tasks use `Prompt.workflow_system/1`: identity, task IDs, the persisted result schema, submission rules, and delegation and sleep rules. Ambient routing uses its own prompt. These paths retain their own execution contracts instead of using a Worker copy of the main prompt renderer.
