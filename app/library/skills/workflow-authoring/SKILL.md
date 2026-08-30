---
name: workflow-authoring
description: Author bounded JavaScript Workflow scripts when one main Agent must fan out independent subagent tasks and combine structured results without a model turn between stages.
default_enabled: true
category: productivity
tags: [Workflow, Subagents, Parallelism, Orchestration]
version: 1.0.0
ankole-runtime: main
---

# Author Workflow scripts

Use the `workflow` tool for a bounded program that needs parallel subagent
tasks, deterministic stages, or both. Use a Background Agent Job for one long
task that needs a persistent Codex thread, workspace work, or later human
messages. Do not use a Workflow when the main Agent must judge each step before
the next step starts.

The `workflow` tool returns a `run_id` immediately. Do not poll it. The run
wakes the owner Session when it completes or fails. Use `show_workflow` after
that event, or when the human explicitly asks for current status.

## Write the program body

The script is the body of an async function. It receives:

- `args`, the JSON object supplied to the `workflow` tool
- `agent(prompt, opts)`, which starts one independent subagent task

The script must return its final value. A returned string becomes result text.
Another JSON value becomes JSON text.

`agent()` accepts these options:

- `label`: a short stable name for status and failure reports
- `model_profile`: a custom profile when one task needs it
- `schema`: the non-null result schema for that task

Use labels that describe roles or partitions, such as `collect:security`,
`verify:pricing`, or `round:2:pair:3`. Do not put the complete prompt in the
label.

A successful call returns its submitted value. A call that exhausts its retry
budget returns `null`. A valid success result cannot be `null`, so check for
`null` before a later stage uses the value.

Use an explicit top-level schema type: `object`, `array`, `string`, `number`,
`integer`, or `boolean`. Prefer a small object with only the fields that the next
stage needs. The control plane rejects unsupported schema forms such as `$ref`
and nullable results.

For every object schema, including a nested object, write `properties`,
`required`, and `additionalProperties: false`. Put every property name in
`required` exactly once, and do not put another name there. Do not use
`minProperties` or `maxProperties`. Array item bounds, string bounds and
patterns, numeric ranges, integer `multipleOf`, and enums remain available.

## Keep cost visible

Set `concurrency` and `max_agent_calls` from the work you can count. Each call
attempt is one full model turn, and one call can use as many as three attempts.
Ask a task for a decision, compact facts, or a summary instead of source dumps.

Batch wide fanout. Give one task one group of items with an array schema, not
one task per item: twenty tasks that each research ten stocks cost one tenth of
two hundred single-stock tasks and lose nothing.

Every loop must have a visible finite bound. Do not derive an unbounded loop
from subagent output. A run supports at most 1,024 calls, but the deployment
default is 32. One result value is at most 24 KiB, and the complete durable
memo is at most 6 MiB.

A Workflow task cannot start another Workflow. A Workflow has depth one.

## Delegate heavy work from a task

A task can create Background Agent Jobs, then call `sleep` to hibernate until a
job lifecycle event, an owner message, or its deadline wakes it in the same
conversation. This makes an `agent()` call the right unit for deep work: the
task does its own triage, writes the job brief from what it found, waits
without holding a worker slot, then shapes the job outcome into its result
schema.

Write the prompt of a delegating task so it states the deliverable of the job
it must create and the schema-shaped summary it must submit afterwards. A
delegated job cannot ask a human; a task that needs an owner decision sleeps
with `attention` and a note that states the exact question, and the owner
answers with `send_message_to_workflow_task`.

From the script's view nothing changes: the `agent()` promise just resolves
after hours instead of minutes. Keep delegating stages behind cheap triage
stages so only work that deserves a job gets one.

## Map and reduce

Start independent calls together. Filter failed values before reduction.

```js
const rows = await Promise.all(
  args.items.map((item, index) =>
    agent(`Analyze this item and return one finding: ${JSON.stringify(item)}`, {
      label: `analyze:${index}`,
      schema: {
        type: "object",
        properties: {
          finding: { type: "string" },
          confidence: { type: "number", minimum: 0, maximum: 1 }
        },
        required: ["finding", "confidence"],
        additionalProperties: false
      }
    })
  )
);
const findings = rows.filter((row) => row !== null);
return { findings };
```

## Run stages

Wait for one batch, then use its compact output in the next batch. Keep the
second-stage prompt bounded.

```js
const collected = await Promise.all(
  args.sources.map((source, index) =>
    agent(`Extract up to three claims from ${source}.`, {
      label: `collect:${index}`,
      schema: { type: "array", items: { type: "string" }, maxItems: 3 }
    })
  )
);
const claims = collected.filter((value) => value !== null).flat();
if (claims.length === 0) return { claims: [], verdicts: [] };
const verdicts = await Promise.all(
  claims.map((claim, index) =>
    agent(`Verify this claim and return a short verdict: ${claim}`, {
      label: `verify:${index}`,
      schema: { type: "string", maxLength: 1000 }
    })
  )
);
return { claims, verdicts };
```

## Use a verification panel

Give the same candidate to independent reviewers. Let the script preserve
disagreement for the main Agent.

```js
const reviews = await Promise.all(
  ["evidence", "logic", "risk"].map((role) =>
    agent(`Review the candidate for ${role}: ${args.candidate}`, {
      label: `panel:${role}`,
      schema: {
        type: "object",
        properties: {
          pass: { type: "boolean" },
          reason: { type: "string", maxLength: 1200 }
        },
        required: ["pass", "reason"],
        additionalProperties: false
      }
    })
  )
);
return { reviews };
```

## Run a tournament

Reduce a finite candidate set in pairs. A failed comparison keeps the first
candidate, so one failed task does not erase the bracket.

```js
let round = args.candidates.slice(0, 32);
for (let roundIndex = 0; round.length > 1 && roundIndex < 5; roundIndex += 1) {
  const next = [];
  for (let index = 0; index < round.length; index += 2) {
    if (index + 1 >= round.length) {
      next.push(round[index]);
      continue;
    }
    const winner = await agent(
      `Choose the stronger candidate and return it exactly: ${JSON.stringify([round[index], round[index + 1]])}`,
      { label: `round:${roundIndex}:pair:${index / 2}`, schema: { type: "string" } }
    );
    next.push(winner === null ? round[index] : winner);
  }
  round = next;
}
return { winner: round[0] ?? null };
```

The final `null` in this example is a Workflow result field, not an `agent()`
success value. Do not use a nullable task schema.

## Loop until dry

Use a small fixed round limit. Stop early when one round finds no new work.

```js
let frontier = args.seeds.slice(0, 20);
const seen = new Set(frontier);
for (let round = 0; round < 4 && frontier.length > 0; round += 1) {
  const expansions = await Promise.all(
    frontier.map((item, index) =>
      agent(`Find up to three new related items for: ${item}`, {
        label: `expand:${round}:${index}`,
        schema: { type: "array", items: { type: "string" }, maxItems: 3 }
      })
    )
  );
  frontier = expansions
    .filter((value) => value !== null)
    .flat()
    .filter((item) => !seen.has(item))
    .slice(0, 20);
  frontier.forEach((item) => seen.add(item));
}
return { items: [...seen] };
```

## Preserve replay identity

Workflow uses replay with a durable memo. It matches each `agent()` call by its
position and complete arguments. Calls after the longest completed prefix are
the live suffix.

Do not change a running script, reorder calls, or build call arguments from an
external clock, network response, or file. The runtime gives `Date.now()` and
`Math.random()` deterministic values, but the clearest script derives calls
only from fixed `args` and earlier task results.

When a run fails, use its failure summaries to distinguish a task failure from
script divergence or a size limit. Start a new run with a corrected script;
v1 cannot edit and resume the old script.
