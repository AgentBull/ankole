---
title: Tools runtime
description: Control-plane tool declarations, dispatch, and Worker environment execution.
section: Developer guide
order: 120
---

The Elixir control plane drives the main Agent's model loop and tool dispatch: `Ankole.Sessions.Driver` calls AIGateway, executes the requested tools, persists their results, and advances the turn, while Agent Computer executes Worker environment operations and Codex Jobs. See [The agent loop](../agent-loop/) and [Agent Computer Worker](../agent-computer-worker/).

## Build the current tool set

At the start of each run, `Ankole.Sessions.ToolCatalog.for_run/1` merges active control-plane domain tools with the exported Worker tool declarations from `worker_tools.json`. Because availability depends on the run kind, selected model capabilities, enabled Skills and Agent Plugins, and ambient turn authority, Ankole computes the catalog fresh for each run rather than storing a static tool list per Agent.

Each `Ankole.Sessions.Tool` struct defines the model-visible JSON Schema, executor, execution mode, permitted callers, and read-only, destructive, and retry flags. Before any tool runs, `Ankole.Sessions.Tools.prepare/2` verifies caller permissions, parses the raw JSON arguments, normalizes them through the tool module, and validates them against the declared JSON Schema.

## Execute at the owner

Each tool executes at the runtime boundary that owns its state:

- **Control-plane domain tools** handle Session planning, schedules, Background Agent Jobs, Workflows, Skill loading, and configured `web_search` / `web_fetch` providers.
- **Worker computer tools** run on the Agent's Worker over RuntimeFabric; the first environment call in a Session opens that Session's workspace, with the Worker managing its concurrency slot and child processes while the control plane commits durable results.
- **MCP-backed Skills** invoke `mcporter` on the Worker through the `command` tool.
- **Provider-hosted tools** execute through AIGateway whenever the selected model declares support for them.

The Driver dispatches calls in parallel or sequentially according to each tool's concurrency metadata. Tools with durable control-plane side effects run through `Ankole.Sessions.Receipts` so the domain write and tool receipt commit together in PostgreSQL, and AIGateway stores the resulting tool output for the next model turn. If a Worker disconnects mid-execution, the Driver resolves the interrupted environment call using the tool's declared retry policy.

## Workflow task tools

Workflow subagents receive a deliberately narrow tool catalog: web tools, the Background Agent Job tools for delegation and inspection, `sleep`, `submit_result`, and—when Brain is enabled—read-only `recall` and `get_page`. They never receive computer, shell, Skill, schedule, or nested Workflow tools.

When a subagent calls `submit_result`, Ankole validates the payload against the task's persisted result schema: if validation fails, the task stays active so the subagent can submit a fixed payload; once validation succeeds, Ankole completes the task. Before submitting, a task must wait for or stop any live Background Agent Jobs that it delegated. See [Workflows](../workflows/).

## Add a tool

Place control-plane domain tools alongside their owning Elixir domain, or implement Worker environment tools with `WorkerAgentTool` and Zod in the Worker catalog and regenerate `worker_tools.json` so the control-plane schema and Worker execution contract stay synchronized.
