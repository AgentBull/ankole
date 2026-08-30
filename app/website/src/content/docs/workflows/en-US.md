---
title: Workflows
description: Split bounded work across parallel subagents and collect one structured result in the original conversation.
section: User guide
order: 19
---

A Workflow lets the main Agent run a fixed, bounded program that delegates independent tasks to subagents. Use it to review many candidates, extract the same fields from a finite set of sources, compare independent judgments, or run a verification stage before synthesis.

The Workflow starts from the current conversation and immediately returns a `run_id`. The conversation remains available while the tasks run. When the Workflow completes or fails, Ankole wakes the original conversation so the main Agent can read the result and continue.

## Choose the right execution shape

| Need | Use | Why |
|---|---|---|
| One short task that needs the current conversation | Main Agent turn | It keeps the current context and complete main-turn tool set. |
| A finite set of independent checks or fixed analysis stages | Workflow | It runs bounded subagent tasks in parallel and returns one aggregate result. |
| One long, stateful task that needs files, a workspace, later messages, or user input | [Background Agent Job](../background-jobs/) | It owns a durable Codex thread that can pause and resume. |
| A scheduled or webhook-triggered mechanical script | [Automation Job](../automation-jobs/) | The trigger runs deterministic handling without a model turn when judgment is not needed. |

A Workflow is not a general DAG engine, scheduler, or event bus. It cannot wait for an external event or for a decision from you. Use a Background Agent Job when the work must change direction after it starts.

## Ask the Agent to start a Workflow

Describe the finite input set, the independent task, the completion rule, and the final format. For example:

```text
Run this as a Workflow. Review these 40 proposals in parallel against the five
criteria below. Return one JSON result with every verdict, the failed reviews,
and a final shortlist. Do not expand beyond these 40 proposals.
```

The main Agent writes the orchestration program and starts it. You do not need to write JavaScript or call an API. The Agent can set a per-run concurrency limit, a maximum number of subagent calls, and a custom model profile that is available to it. If it does not select a profile, Workflow tasks use `primary`.

The start operation returns the run ID and current `running` status. The main Agent must not poll the run. You can keep talking in the same conversation and ask for the state later.

## How the orchestration runs

The program receives fixed JSON `args` and can call `agent(prompt, options)`. Calls inside `Promise.all` run in parallel. Normal JavaScript conditions can select a later verification or synthesis stage after earlier calls finish. Every collection and loop must have a visible finite bound.

This simplified program reviews at most 20 items, keeps failed calls as `null`, and then synthesizes the successful results:

```js
const items = args.items.slice(0, 20)
const reviews = await Promise.all(
  items.map(item =>
    agent(`Review this item: ${JSON.stringify(item)}`, {
      label: `review-${item.id}`,
      schema: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          verdict: { type: 'string', enum: ['accept', 'reject'] },
          reason: { type: 'string' }
        },
        required: ['id', 'verdict', 'reason'],
        additionalProperties: false
      }
    })
  )
)

const successful = reviews.filter(review => review !== null)
const summary = await agent(`Summarize these reviews: ${JSON.stringify(successful)}`, {
  label: 'summary'
})

return { reviews, summary }
```

The program and its `args` do not change after the run starts. A control-plane restart replays the fixed program from persisted task results. A successful task that is already stored is not created again, but an interrupted task can be retried. Do not treat task execution as exactly once.

## What each subagent can access

Each `agent()` call runs in an independent, short-lived conversation. It receives the Agent identity and mission plus the task prompt. It does not receive the original conversation transcript or the result of another task unless the program includes that result in a later prompt.

A Workflow task can use Web tools and, when Brain is enabled, the read-only `recall` and `get_page` tools. Its only durable write is `submit_result`. It does not receive shell, file, MCP, Skill, schedule, Workflow, or Background Agent Job tools, and it cannot create nested work.

Each call can make at most three complete task attempts. A successful call resolves to the submitted value. A call that exhausts its attempts resolves to `null`; the program can record the failure and continue, or make the final result explain why the run is incomplete. One failed task does not automatically make the whole Workflow fail.

## Require structured results

An `agent()` call can declare a result schema. Ankole sends the generated `submit_result` tool with provider strict mode and validates the submitted value again in the control plane. A schema rejection leaves the task active so the subagent can correct its value.

The schema is a closed subset of OpenAPI 3 JSON Schema, not the complete specification. A result has one non-null type: `object`, `array`, `string`, `number`, `integer`, or `boolean`. Every object, including a nested object, must declare `properties`, list every property in `required`, and set `additionalProperties: false`. Optional object fields, nullable values, unions, `$ref`, and `oneOf`/`anyOf`/`allOf` are not supported.

If no schema is supplied, the task returns a string. The program must return its aggregate result. A string becomes the final text; another JSON value becomes JSON text.

## Read, list, or cancel runs

Ask the main Agent to use these operations:

- `show_workflow` reports the status, task counts, up to ten failure summaries, and any terminal error. A completed result is read from byte offset `0` in segments of at most 8,000 UTF-8 bytes.
- `list_workflows` lists this Agent's live or finished runs, up to 32 at a time. Finished runs include `completed`, `failed`, and `cancelled`.
- `cancel_workflow` is idempotent. It prevents new tasks and late results from reviving the run, then asks running task turns to stop. A model call can take a short time to stop.

Completed and failed runs wake the original conversation. A cancelled run does not send that completion event, so ask the Agent to confirm its state if you need confirmation.

There is no Workflow page in the Console in the current version. The main Agent's Workflow tools are the supported user surface.

## Control cost and capacity

Every task attempt is a complete model turn and can also make paid Web calls. Concurrency changes elapsed time, not the total number of calls. Set the call limit from the finite input size, and keep each task prompt and result narrow.

| Boundary | Default | Hard limit |
|---|---:|---:|
| Concurrent tasks in one run | 8 | 32 |
| Running Workflow tasks for one Agent | 8 | 64 |
| Subagent calls in one run | 256 | 1,024 |
| Attempts for one subagent call | up to 3 | 3 |
| Stored program | — | 256 KiB |
| Stored `args` | — | 64 KiB |
| One call argument object | — | 8 KiB |
| One submitted result value | — | 24 KiB |
| Final aggregate result | — | 1 MiB |

An administrator can set the first three instance limits in [AppConfigure](../app-configuration/) within their hard ranges. A run request cannot raise the deployment limits. Workflow has no batch-wide token or currency budget; every task still uses the ordinary per-turn iteration, output-token, and inactivity limits. See [Cost management](../cost-management/) for the related controls.

If a run exceeds a size boundary, reduce the fanout, return shorter task summaries, or split the input into separate Workflows. Create a new run when the program or input must change; a failed run cannot be edited or resumed with different code.
