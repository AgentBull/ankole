---
title: Automation blueprints
description: Combine triggers with Agent sessions, automation jobs, background jobs, and signal routing rules, and distinguish them from Workflows.
section: Guides
order: 309
---

Choose a trigger and a consumer separately. A schedule, Checkback, raw callback endpoint, or Connector event supplies a CloudEvents input. An Agent handles judgment and conversation; an Applet Action handles deterministic work. Bindings can deliver one source to several consumers.

## Common patterns

| Goal | Configuration | Result |
| --- | --- | --- |
| Daily briefing | Agent schedule with a task and delivery destination | The Agent gathers information and sends a summary. |
| Frequent mechanical check | Applet Job with an owned schedule | The Action checks conditions without a model turn and records the result. |
| One-time follow-up | Agent Checkback | The originating conversation resumes at the requested time. |
| External change | Connector subscription or a raw callback endpoint | A binding starts the selected Job or Agent. |
| Extended research | Agent schedule followed by a Background Agent Job | Research runs independently and reports back to the owning conversation. |
| Quiet channel monitoring | A quiet chat binding plus an Agent schedule | Messages accumulate without replies; the schedule produces a recap. |

## Build a deterministic monitor

Publish the checking logic as an Applet Action. Create a Job in the Applet's Automation panel, set its configuration, and add a schedule or external source. Use `ctx.signal.data` for event data and `ctx.state` for durable cursors or the last observed value. Call platform tools through `AnkoleRuntime.mcp` and choose an explicit connection when several exist.

Test a normal condition, a changed condition, and an upstream failure. Inspect actual Run inputs, results, and logs. If a change needs human attention, implement the notification explicitly through the relevant platform tool; a successful silent Run does not send a chat message automatically.

## Choose the right kind of work

Use a direct Agent consumer when every event needs memory, interpretation, or a written response. Use an Applet Job when code can make the decision. A [Workflow](../workflows/) provides bounded parallel subagent judgments inside one Agent turn. A [Background Agent Job](../background-jobs/) handles longer Agent work; it is a separate execution model from an Applet Action.

See [Automation Jobs](../automation-jobs/) for setup and recovery, [Schedules](../schedules/) for timing, and [Webhook delegations](../webhook-delegations/) for callbacks.
