---
title: Prompt assembly
section: Developer guide
order: 118
description: How the control plane renders main Agent instructions and separates Codex Job context.
---

The Elixir control plane assembles the system instructions for every main Agent run: `Ankole.Sessions.Context.resolve/2` loads the current domain facts, `Ankole.Sessions.Prompt.system/1` renders the prompt, and `Ankole.Sessions.Driver` dispatches the request through AIGateway. Meanwhile, the Agent Computer Worker receives only environment tool calls and Codex Jobs. See [The agent loop](../agent-loop/).

## Current context

Each resolved run context brings together the Agent's identity and durable documents, its effective Skills and Agent Plugins, the originating conversation, and the active timezone. Within those documents, `SOUL.md` governs communication style and judgment while `MISSION.md` defines responsibilities. PostgreSQL owns the authoritative copies in the control plane, and Ankole materializes runtime files into the Worker workspace whenever environment tools run.

`Ankole.Sessions.Prompt.system/1` (`app/control_plane/lib/ankole/sessions/prompt.ex`) renders templates from `app/control_plane/priv/sessions/prompts/` in a fixed order: Agent identity, `SOUL.md`, and `MISSION.md` come first, followed by completion and authority rules, Background Agent Job and Workflow policies, Brain memory guidance, environment and tool instructions, the model-visible Skill catalog, and a runtime context suffix.

When building the Skill catalog, Ankole omits Skills marked `brain-recall-only: true`; those Skills remain in the Agent's effective set so the Agent can discover them semantically through Brain and load them on demand via `skill_view`. The trailing runtime suffix records the Agent's name, `/workspace`, the active Session workspace path, the timezone, the conversation start time, and the origin channel. For Lark and Feishu conversations, the shared Lark adapter represents both platforms and selects the upstream API endpoint from its configured domain.

## Settings and history

At the start of a run, `AgentConfig` resolves tenant-level turn bounds—`ai_agent.max_iterations` (`90`), `ai_agent.max_output_tokens` (unbounded by default), and `ai_agent.inactivity_timeout_ms` (`30` minutes)—which govern the control-plane loop.

AIGateway owns the durable model transcript and records every model request for audit. Rather than interpolating live inputs into the system prompt, `Prompt.Input` formats the triggering input and channel observations as user messages, while the control plane re-renders the system instructions from fresh domain state on each run.

## Codex Jobs and Workflow tasks

Codex Jobs follow a separate Worker execution path: the Worker runner reads the execution choices frozen on the Job, fetches current domain context over RuntimeFabric RPC, and materializes the Job workspace along with its `AGENTS.md` before handing the model loop to native Codex. See [Background Agent Jobs](../background-agent-jobs/).

Workflow subagent tasks render their own prompt through `Prompt.workflow_system/1`—covering Agent identity, task IDs, the persisted result JSON Schema, `submit_result` rules, and Job delegation and `sleep` policies—while ambient group-intervention checks use a dedicated routing prompt so each execution mode receives only the contract that applies to it.
