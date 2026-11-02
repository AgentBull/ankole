---
title: Prompt assembly
section: Developer guide
order: 118
description: How the control plane renders main Agent instructions and separates Codex Job context.
---

The Elixir control plane assembles the system instructions for every main Agent run: `Ankole.Sessions.Context.resolve/2` loads the current domain facts, `Ankole.Sessions.Prompt.system/1` renders the prompt, and `Ankole.Sessions.Driver` dispatches the request through AIGateway. Meanwhile, the Agent Computer Worker receives only environment tool calls and Codex Jobs. See [The agent loop](../agent-loop/).

## Current context

Each run resolves the Agent identity, enabled capabilities, originating conversation, and timezone. Ankole reads the whole effective `AGENTS.md` from `/AnkoleBrain/AGENTS.md` and the Agent’s append or override page. The `DESIGN.md` contract uses the same hierarchy and is available as a complete runtime file.

`Ankole.Sessions.Prompt.system/1` renders the complete AGENTS contract, completion and authority rules, Job and Workflow policies, memory guidance, environment and tool instructions, the Skill catalog, and the runtime context. Templates live in `app/control_plane/priv/sessions/prompts/`.

The Skill catalog lists descriptions of enabled Skills visible to the current conversation. `skill_view` reads the selected Skill and permitted supplements when needed. The runtime suffix records the Agent, `/workspace`, Session workspace, timezone, conversation start time, and channel. Lark and Feishu share one adapter whose configured domain selects the upstream API.

## Settings and history

At the start of a run, `AgentConfig` resolves tenant-level turn bounds—`ai_agent.max_iterations` (`90`), `ai_agent.max_output_tokens` (unbounded by default), and `ai_agent.inactivity_timeout_ms` (`30` minutes)—which govern the control-plane loop.

AIGateway owns the durable model transcript and records every model request for audit. Rather than interpolating live inputs into the system prompt, `Prompt.Input` formats the triggering input and channel observations as user messages, while the control plane re-renders the system instructions from fresh domain state on each run.

## Codex Jobs and Workflow tasks

Codex Jobs use the Worker execution path. At every turn start and resume, the Worker fetches current contracts and atomically refreshes `$CODEX_HOME/AGENTS.md`, `~/AGENTS.md`, and `~/DESIGN.md`. Native Codex combines global Agent instructions with the project’s own instruction files. See [Background Agent Jobs](../background-agent-jobs/).

Workflow subagent tasks render their own prompt through `Prompt.workflow_system/1`—covering Agent identity, task IDs, the persisted result JSON Schema, `submit_result` rules, and Job delegation and `sleep` policies—while ambient group-intervention checks use a dedicated routing prompt so each execution mode receives only the contract that applies to it.
