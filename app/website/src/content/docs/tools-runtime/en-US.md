---
title: Tools runtime
description: Control-plane tool declarations, dispatch, and Worker environment execution.
section: Developer guide
order: 120
---

The control plane owns the main Agent's model loop and tool dispatch. `Ankole.Sessions.Driver` calls AIGateway, executes the requested tools, records their results, and continues the turn. Agent Computer executes environment operations and Codex Jobs. See [The agent loop](../agent-loop/) and [Agent Computer Worker](../agent-computer-worker/).

## Build the current tool set

`Ankole.Sessions.ToolCatalog.for_run/1` combines the current domain declarations with the exported Worker declarations in `worker_tools.json`. The result depends on the run kind, model capabilities, selected Skills and plugins, and ambient authority. It is built for the run, rather than stored as an Agent's global tool set.

`Ankole.Sessions.Tool` records the model-visible schema, executor, execution mode, allowed callers, and read, destructive, and retry metadata. `Ankole.Sessions.Tools.prepare/2` checks the caller, parses the arguments, normalizes them through the owning tool, and validates the JSON Schema before execution.

## Execute at the owner

- Session planning, schedules, Background Agent Jobs, Workflows, Skill reads, and domain web operations use their control-plane owners.
- Computer operations are delegated through RuntimeFabric to the Agent's Worker. The first environment operation opens the Session workspace. The Worker owns its slot and process state; the control plane owns durable results.
- MCP-backed Skills use the computer command tool and mcporter on the Worker.
- Provider-hosted tools run through AIGateway. The catalog respects the selected model's declared capabilities.

The Driver schedules parallel and sequential calls according to their declarations. Durable effects use `Ankole.Sessions.Receipts` so the domain mutation and its result are committed together. AIGateway stores tool output for the next model iteration. A Worker disconnection leaves the Driver to handle an uncertain environment operation through the declared retry contract.

## Workflow task tools

A Workflow task has a restricted catalog: web operations, the Background Agent Job operations for delegation and inspection, `sleep`, and `submit_result`. Its hosted Brain access is limited to `recall` and `get_page`. It receives no computer, shell, Skill, schedule, or Workflow creation tools.

`submit_result` validates the value against the task's persisted result schema. Rejection permits correction; an accepted result ends the task. A task must settle its live delegated Jobs before it submits. See [Workflows](../workflows/).

## Add a tool

Put a domain tool declaration and implementation in its control-plane owner. Add an environment tool to the Worker catalog and regenerate `worker_tools.json`. `WorkerAgentTool` and Zod remain the Worker implementation contract; they do not own the main model loop. Preserve the schema and the execution boundary together.
