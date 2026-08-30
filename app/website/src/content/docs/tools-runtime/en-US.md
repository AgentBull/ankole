---
title: Tools runtime
description: How the Worker schemas and dispatches per-turn tools, including main-turn Workflow tools and the restricted Workflow task catalog.
section: Developer guide
order: 120
---

During a turn, the worker assembles the set of tools the model can call, converts each tool's schema to JSON Schema the model sees, and dispatches each function call the model makes back to the tool's `execute` function. This page documents that runtime: the `WorkerAgentTool` contract, how the per-turn tool set is assembled, how schemas are collected, and how the loop dispatches a call. It builds on [The agent loop](../agent-loop/) and [Agent Computer Worker](../agent-computer-worker/).

The decisive property, stated up front: tools are **assembled per turn**. Each turn builds its final tool set from computer, web, schedule, background jobs, and other current sources. There is no Agent-owned global tool set. MCP-backed Skills use the computer command tool and mcporter.

## The WorkerAgentTool contract

Every Worker-authored tool is a `WorkerAgentTool` constructed with `defineWorkerTool`. The fields the runtime cares about:

| Field | Type | What it does |
|---|---|---|
| `name` | string | the tool name the model sees and calls |
| `description` | string | what the tool does — the model reads this to decide whether to call |
| `schema` | Zod schema | the input parameters, validated before `execute` runs |
| `jsonSchema` | JSON Schema (optional) | a raw schema used instead of a generated Zod schema |
| `strict` | boolean (optional) | asks the Provider to enforce strict function-tool arguments |
| `namespace` / `namespaceDescription` | string (optional) | groups related external tools under one provider namespace |
| `deferLoading` | boolean (optional) | keeps a child schema behind Tool Search until selected |
| `executionMode` | `'parallel' \| 'sequential'` | whether the tool can run alongside others in the same response |
| `isReadOnly` / `isDestructive` | boolean | metadata for activity reporting and safety checks |
| `describeActivity` | function | builds a short human-readable label from validated params (for progress) |
| `describeCompletedActivity` | function (optional) | replaces the label with a result summary when the tool finishes |
| `execute` | function | runs the tool; returns content, details, optional presentation events, and can terminate the turn |

The `execute` function is the tool's actual work. It receives the validated params (the schema has already parsed and checked them), an abort signal, and returns an `AgentToolResult` — the content the model sees, structured details for logging, optional reply presentation events, and optional flags to complete actor events or terminate the turn.

## How the tool set is assembled per turn

`text_turn_tools.ts` builds the main text-turn tool set, composing tools from category creators:

```typescript
tools = [
  createTodoTool(...),
  ...createComputerTools({...}),
  ...webTools,
  ...scheduleTools,
  ...backgroundAgentJobTools,
  ...workflowTools,
  ...
]
```

Each category creator is a function that returns one or more `WorkerAgentTool` objects, configured with the turn's context (the worker environment, the agent's home, the RPC client, the abort signal). The assembly is explicit and ordered — there is no reflection, no auto-discovery, no decorator scanning. If a tool is in the array, it is available; if it is not, it is not.

The per-turn assembly is what makes the tool set dynamic:

- **Skill knowledge** is projected from the Agent's current enabled Skills. An MCP-backed Skill selects a domain tool and uses the existing computer command tool to call mcporter.
- **Web tools** are created from the worker's `web_search`/`web_fetch` provider availability — if the profiles are unbound, the tools are absent.
- **Background job tools** are created from the turn's context — only available when the turn supports spawning jobs.
- **Workflow tools** add the four main-turn operations: start, show, list, and cancel. They are not included in Workflow task turns.

The final tool set is still a per-turn result, not an Agent capability database or a ready connection pool.

### Workflow task tools

`workflow_task_turn.ts` builds a separate, fixed catalog for each isolated Workflow task. It contains available Web tools, the read-only Brain tools `recall` and `get_page` when Brain is enabled, and the task-specific `submit_result` tool. It does not reuse the main text-turn catalog, so a task does not receive computer, file, shell, MCP, Skill, schedule, Workflow, or Background Agent Job tools.

The task must finish through `submit_result`. Its accepted result ends the turn. A schema rejection keeps the turn active so the model can correct the value. If the model returns prose without submitting, the loop gives one bounded repair instruction before it reports a task failure. See [Workflows](../workflows/) for the user-visible retry and isolation contract.

## Schema collection

The model needs JSON Schema, not Zod. `tool-schema.ts` converts each tool's Zod schema:

```typescript
export function zodToJSONSchema(schema: z.ZodType): JSONObject {
  const jsonSchema = z.toJSONSchema(schema) as JSONObject
  if (jsonSchema.type !== 'object') {
    throw new Error('function tool parameters must use a root object schema')
  }
  return jsonSchema
}
```

The collected schemas — one per tool, plus the tool name and description — are sent to the model in the Responses request. When a tool owner supplies `jsonSchema`, Ankole sends that schema at its boundary instead of generating one from Zod; constraints such as `minimum` and `maximum` remain intact there. A separate native runtime owns any later projection. Deferred children remain behind Tool Search until selected.

`strict: true` is also copied to the Provider tool definition. Workflow creates `submit_result` with a raw schema that wraps the task's result schema, and sends it in strict mode. Provider validation is only the first gate: the control plane validates the submitted value against the persisted schema again before it commits the result.

When the model returns a function call, its arguments arrive as a JSON string. `validateToolArguments` parses the string against the tool's Zod schema, with a bounded repair ladder for malformed arguments (truncated JSON, code-fenced JSON, unbalanced objects). A tool's `execute` never receives raw model output — it receives schema-validated params.

## How the loop dispatches a call

When the model's response contains function-call items, the agent loop:

1. **Builds a tool map** — `agentToolMap(tools)` turns the array into a `Map<string, AgentTool>` keyed by tool name.
2. **Validates arguments** — each call's arguments string is parsed and validated against the tool's schema, with repair if needed.
3. **Executes** — the tool's `execute` function runs with the validated params and an abort signal. Tools with `executionMode: 'parallel'` may run concurrently; sequential tools run in order.
4. **Records the result** — the `AgentToolResult` is sent to AIGateway as a function-call-output message, which the model sees on its next iteration.

The loop owns the iteration — it calls the model, executes the tools, records the results, and repeats until the model returns no more function calls. The tools do not decide when to run; the loop decides, based on what the model requested.

## What this guide is not

It is not a tool-authoring tutorial — a new tool uses `defineWorkerTool` to create a `WorkerAgentTool`, and the existing categories (`tools/computer/`, `tools/web/`) are the reference. It is not a model-behavior guide — which tools the model calls is the persona's concern, not the runtime's. And it is not a substitute for the agent-loop page; the dispatch path is part of the loop, and the loop page is the context.

## Next steps

- For the loop that dispatches tool calls, read [The agent loop](../agent-loop/).
- For the Agent Computer Worker that runs the tools, read [Agent Computer Worker](../agent-computer-worker/).
- For the main-turn and task-turn Workflow contract, read [Workflows](../workflows/).
- For MCP execution dependencies behind Skills, read the [MCP server reference](../mcp/).
- For the skills that carry MCP dependencies, read [Writing a skill](../writing-a-skill/).
