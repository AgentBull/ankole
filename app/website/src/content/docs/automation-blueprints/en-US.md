---
title: Automation blueprints
description: Combine triggers with Agent sessions, automation jobs, background jobs, and signal routing rules.
section: Guides
order: 309
---

Automation in Ankole combines one of three triggers with one of two consumers. An Agent session handles work that needs judgment, memory, or conversation. An automation job runs a deterministic script for mechanical handling. This page gives ready-to-use blueprints for the common shapes.

Ankole does not add a workflow language or a step graph. An automation job is an ordinary Bun `main.ts` inside the Agent Home. The trigger owner keeps time or ingress, and the selected consumer handles the unchanged event. The Agent returns only when the script emits an event or the failure policy wakes it.

## The three triggers

Every blueprint uses one of three triggers. Know which one you need before you pick a blueprint.

| Trigger | How it fires | Carrier | Built with |
|---|---|---|---|
| **Schedule** | on a cron cadence (hourly, daily, weekly) | a `task` on a cron schedule | [Schedules](../schedules/) |
| **Self-deferred (checkback)** | the Agent sets a delayed trigger during a turn | the Agent's `check_back_later` tool | [Schedules](../schedules/) |
| **Event-driven (webhook)** | an external system POSTs to a capability URL | a `webhook.received` event | [Webhook delegations](../webhook-delegations/) |

All three produce the same CloudEvents envelope whether they wake the Agent or run a script. The consumer choice changes the recipient, not the trigger fact. A direct wake and an event emitted by a script both return through the owner session's routing rule.

## Choose the consumer

| Consumer | Use it when | Trigger result |
|---|---|---|
| **Agent session** | Each delivery needs judgment, memory, tools chosen at run time, or a user-facing response. | The trigger appends an ActorEvent and wakes the conversation. |
| **Automation job** | Handling is a deterministic fetch, comparison, parse, or predetermined action. | The trigger creates a durable script run. The script can finish silently or emit an event to the owner session. |

Start with a direct Agent wake while the handling is unclear. Move only the proven mechanical part into an automation job. This keeps the script small and keeps the model out of an idle polling loop.

## Blueprint: daily digest (schedule)

A schedule wakes the Agent once a day. The Agent collects and summarizes the requested information, then posts the result to the bound chat channel. Create and test it with [Schedules](../schedules/) before you set the daily cron expression.

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/sessions/<session_id>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "binding_name": "main",
    "name": "daily-digest",
    "schedule": { "cron": "0 9 * * *", "kind": "cron" },
    "timezone": "Asia/Shanghai",
    "payload": { "task": "Produce today'\''s digest of the topics in your mission." }
  }'
```

Tunable parts: the cron expression (cadence), the `timezone` (when "9 AM" is), the `task` (what to do), and the persona (how to do it). Verify with a manual run before relying on the schedule.

## Blueprint: deterministic sentinel (schedule + automation job)

Use an automation job when a schedule fires often but the check is mechanical and usually has no result. The Agent writes and registers the script, then binds the cron schedule to its `automation_job_id`.

```json
{ "cron": "0 * * * *", "kind": "cron" }
```

The script reads the source and finishes without `emitEvent` when the condition is false. When the condition is true, it emits the bounded source facts to the owner session, where the Agent verifies and decides what to do. Test non-SDK branches by hand before registration, then use a real test trigger for every branch that calls `context()` or `emitEvent`.

Keep the direct Agent schedule when every run needs semantic judgment. Read [Worker CLI capabilities](../cli-capabilities/) for the Automation Job contract.

## Blueprint: deferred follow-up (checkback)

The agent is asked something in a turn, and decides to come back to it later. Instead of a fixed cron, the agent itself sets a one-shot wakeup with `check_back_later`. The shape from the agent's side is "look again in an hour" — the agent calls the tool; the operator surface is read-only.

This fits work that is not on a cadence: "check whether the deploy finished in an hour," "re-read this thread after the standup." The agent owns the timing; you see the pending checkback through `GET /agents/:agent_uid/sessions/:session_id/checkbacks` and can cancel one with `DELETE`.

## Blueprint: research-and-report (schedule + background job)

A schedule starts a turn. When the work needs long search and cross-checking, the Agent delegates it to a [Deep Research Background Agent Job](../deep-research-job/) instead of holding the turn open.

1. The cron schedule fires its `task`.
2. The agent decides the work is long and calls `create_background_job`.
3. The schedule's turn ends; the job runs on its own.
4. The job posts `background_agent_job.completed` back to the owning session, which the binding delivers.

This is how you get a "weekly deep research" without the schedule's turn running for an hour. The schedule kicks; the job does the work.

## Blueprint: event-driven (webhook)

An external system, such as a source repository or CI provider, calls a short-lived Ankole capability URL. The endpoint accepts the delivery and commits the selected consumer record before it returns success.

Use the default direct consumer when the Agent must inspect the current external object and judge the event. Bind the endpoint to an automation job when a deterministic script can filter or reconcile the receipt first. The receipt is untrusted in both paths, and consequential facts still come from the authoritative external source. Read [Webhook delegations](../webhook-delegations/) for capability security and lifecycle rules.

## Blueprint: observe-and-escalate (binding policy + schedule)

A team assistant watches a channel, and a schedule produces a periodic summary of what it observed. The binding policy (`may_intervene` or `record_only`) decides what the agent sees in real time; the schedule decides when it synthesizes.

- Binding: `unaddressed_group_message_policy: record_only` — the agent sees everything, speaks on nothing, builds context.
- Schedule: a daily or weekly digest of "what happened in this channel."
- The agent posts the summary through the binding, drawing on the session's recent context.

This separates observation (continuous, quiet) from synthesis (scheduled, loud). It fits a channel where real-time replies would be noise, but a periodic digest is valuable.

## Choosing a blueprint

- **Want it to run on a clock?** Schedule. Pick the digest or sentinel shape by whether it should post every time or only when something matters.
- **Want it to come back to something mid-flight?** Checkback. The agent owns the timing.
- **Want long work kicked by a clock?** Schedule + background job.
- **Want a frequent mechanical check without a model turn?** Schedule or Checkback + automation job.
- **Want an external system to continue the work?** Webhook delegation, with a direct Agent or automation job consumer.
- **Want quiet observation plus periodic synthesis?** Binding policy + schedule.

## What automation in Ankole is not

It is not a workflow language. There is no YAML step list, platform DAG, hidden cursor, or general event bus. An automation job can run a small script, but the script owns its state and repeat safety. Delivery still uses the owner session's routing rule, and automation cannot bypass permissions. Use the Agent for judgment and use a script only for the mechanical part.

## Next steps

- For the schedule surface, read [Schedules](../schedules/).
- For deterministic script consumers, read [Automation Jobs](../automation-jobs/).
- For background execution and collaboration choices, read [Background Agent Jobs](../background-jobs/).
- For an external event capability, read [Webhook delegations](../webhook-delegations/).
