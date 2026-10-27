---
title: Workflows
description: Split bounded work across parallel subagents and collect one structured result in the original conversation.
section: User guide
order: 19
---

A Workflow lets the Main Agent execute a fixed, bounded orchestration program that fans out independent tasks across parallel subagents—ideal for evaluating dozens of candidates, extracting structured fields from a finite set of sources, comparing independent assessments, or running a verification pass before final synthesis.

When launched from a chat conversation, the Workflow returns a `run_id` immediately so the conversation remains responsive while subagent tasks execute in the background. Once the Workflow finishes or fails, Ankole wakes the originating conversation so the Main Agent can inspect the aggregate output and reply.

## Choose the right execution shape

| Need | Use | Why |
|---|---|---|
| A short task tied to the current conversation | Main Agent turn | Keeps full conversation context and the complete main-turn tool set. |
| A finite batch of independent checks or fixed multi-stage synthesis | Workflow | Runs bounded subagent calls in parallel and returns one structured aggregate result. |
| A long, stateful task needing files, a workspace, steering messages, or mid-run user input | [Background Agent Job](../background-jobs/) | Owns a durable Codex thread that can pause, accept steering, and resume. |
| A scheduled or webhook-triggered deterministic check | [Automation Job](../automation-jobs/) | Runs deterministic TypeScript without a model turn whenever open-ended judgment is unnecessary. |

A Workflow is neither a general-purpose DAG engine, a cron scheduler, nor an event bus: it cannot block on external webhooks or prompt you mid-run. Whenever a task needs to adapt its plan interactively after starting, use a Background Agent Job instead.

## Ask the Agent to start a Workflow

In chat, specify the finite input set, the per-item check, the completion rule, and the output structure—for example:

```text
Run this as a Workflow. Review these 40 proposals in parallel against the five
criteria below. Return one JSON result with every verdict, the failed reviews,
and a final shortlist. Do not expand beyond these 40 proposals.
```

The Main Agent authors and launches the orchestration program automatically—you never have to write JavaScript or call an API directly. When starting the run, the Agent can specify a per-run concurrency cap, a maximum subagent call count, and any model profile available to it (defaulting to `primary`).

Starting a Workflow returns the `run_id` and initial `running` state immediately. Rather than polling in a loop, the Main Agent yields so you can keep chatting in the same thread and check progress whenever you want.

## How the orchestration runs

Each orchestration program receives immutable JSON `args` and invokes subagents via `agent(prompt, options)`. Wrapping calls in `Promise.all` executes them concurrently, and standard JavaScript conditionals can run a follow-up verification or synthesis stage once earlier calls settle—provided every collection and loop has an explicit finite bound.

For example, this program reviews up to 20 items in parallel, filters out any failed (`null`) items, and synthesizes the surviving reviews:

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

Once a run starts, both the program source and `args` are immutable. For each orchestration step, the control plane posts the program and memoized history to `POST /v1/program/run` on the stateless `ankole-function-runtime` service, where it executes inside an ephemeral worker with network, filesystem, environment, child-process, and FFI access denied and deterministic `Math.random()` and `Date.now()` values—no worker process stays resident while subagent tasks run.

If the control plane restarts mid-run, Ankole replays the fixed program against persisted task results within a `6 MiB` durable memo budget: already-completed tasks return their stored results immediately without re-executing, whereas any divergence in replayed `agent()` call order or arguments fails the Workflow run. Because an in-flight task interrupted by a restart may be retried, design task prompts for at-least-once execution.

## What each subagent can access

Every `agent()` call runs in its own isolated control-plane conversation (`wf_task:<call_id>`) without occupying an Agent Worker slot. Each subagent receives the Agent's identity and `MISSION.md` plus its task prompt, and never sees the parent chat transcript or sibling task outputs unless the orchestration script passes them explicitly in a downstream prompt.

Subagents can invoke Web tools and—when Brain is enabled—the read-only `recall` and `get_page` tools. They have no direct shell, file, MCP, Skill, Brain-write, or schedule tools, and cannot launch nested Workflows (orchestration depth is strictly `1`).

When a subagent needs workspace execution or multi-hour work, it can delegate [Background Agent Jobs](../background-jobs/) (`create_background_job`, `show_background_job_details`, `send_message_to_background_job`, `stop_background_job`) and call `sleep` (for `1` minute up to `48` hours, up to `16` sleeps per subagent call) to hibernate without holding a concurrency slot until a delegated Job lifecycle event, an owner message, or its sleep deadline wakes it. Passing `attention: true` to `sleep` notifies the Main Agent so it can read the task's sleep `note` and reply. Once its work is complete, the subagent finishes by calling `submit_result`.

Within each wake segment, Ankole allows up to three task attempts: a successful submission resolves `agent()` to the submitted value, whereas exhausting all three attempts resolves `agent()` to `null` so the orchestration script can either continue with partial results or explain why the output is incomplete. A single failed subagent call never aborts the entire Workflow automatically.

## Require structured results

Any `agent()` call can pass a JSON `schema` option. Ankole exposes the generated `submit_result` tool with provider strict mode enabled and re-validates the submitted payload in the control plane; if validation fails, Ankole keeps the task active so the subagent can fix and resubmit its output.

Workflow schemas support a closed subset of OpenAPI 3 JSON Schema: each result must have a single non-null root type (`object`, `array`, `string`, `number`, `integer`, or `boolean`), and every `object`—including nested objects—must declare `properties`, list every key in `required`, and set `additionalProperties: false`. Optional properties, nullable types, unions, `$ref`, and `oneOf` / `anyOf` / `allOf` are rejected.

When you omit `schema`, the subagent submits a plain string. At the end of the script, the orchestrator's `return` value becomes the Workflow output—strings are stored directly as text, and any other JSON value is serialized as JSON text.

## Read, message, list, or cancel runs

Ask the Main Agent to manage Workflows through its built-in tools:

- `show_workflow` returns the run status, task counters, up to `32` live tasks (with sleep `note`, `attention`, and wake deadlines), up to `10` failure summaries, and any terminal run error, reading completed output from byte offset `0` in `8,000`-byte UTF-8 chunks.
- `send_message_to_workflow_task` appends an asynchronous message (`run_id`, `call_seq`) to wake or guide a live subagent—for instance, answering a subagent that called `sleep` with `attention: true`.
- `list_workflows` lists up to `32` live or finished (`completed`, `failed`, or `cancelled`) runs belonging to the Agent.
- `cancel_workflow` idempotently marks the run cancelled, blocks new task launches or late submissions from reviving it, and signals active subagent turns and delegated Background Agent Jobs to stop (in-flight model requests may take a moment to unwind).

While `completed` and `failed` Workflows automatically wake the originating conversation, `cancel_workflow` does not emit a completion wakeup—ask the Agent to confirm the cancelled status if needed.

In the Console, the Home background-activity panel provides a read-only view of Workflow runs (live calls, status counts, sleep notes, wake deadlines, attention flags, and bounded error summaries under `site_console:agent:<agent_uid>:workflow`), while starting, messaging, reading full outputs, and cancelling runs all happen through the Main Agent's Workflow tools.

## Control cost and capacity

Because every subagent attempt executes a full language-model turn—and may invoke paid Web search or fetch providers—higher concurrency shortens wall-clock duration without reducing total token or API spend. Size your call cap to match your finite input list, and keep per-task prompts and return schemas concise.

| Boundary | Default | Hard limit |
|---|---:|---:|
| Concurrent tasks in one run | `8` | `32` |
| Running Workflow tasks for one Agent | `8` | `64` |
| Subagent calls in one run | `32` | `1,024` |
| Attempts per wake segment | up to `3` | `3` |
| Sleeps for one subagent call | — | `16` |
| One sleep duration | — | `1` minute to `48` hours |
| Stored program | — | `256 KiB` |
| Stored `args` | — | `64 KiB` |
| One call argument object | — | `8 KiB` |
| One owner task message | — | `8 KiB` |
| One submitted result value | — | `24 KiB` |
| Durable memo budget | — | `6 MiB` |
| Final aggregate result | — | `1 MiB` |

Administrators can adjust the first three concurrency and call defaults in [AppConfigure](../app-configuration/) within their hard ceilings, and per-run options can only lower—never exceed—those instance limits. Workflows enforce no single batch-wide token or currency cap; instead, each subagent turn obeys the Agent's standard iteration, output-token, and inactivity limits (see [Cost management](../cost-management/)).

If a Workflow hits a payload or memo size cap, lower the fanout, return tighter per-task summaries, or partition the input across multiple Workflows. Because program code and `args` are immutable once started, launch a fresh Workflow run whenever you need to revise the script or inputs.
