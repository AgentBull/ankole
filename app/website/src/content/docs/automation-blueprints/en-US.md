---
title: Automation blueprints
description: Combine triggers with Agent sessions, automation jobs, background jobs, and signal routing rules, and distinguish them from Workflows.
section: Guides
order: 309
---

Automation in Ankole pairs one of three triggers with one of two consumers: an Agent session handles work that needs judgment, memory, or conversation, while an automation job runs a deterministic script for mechanical checks. This page provides ready-to-use blueprints for the most common shapes.

An Automation Job is neither a workflow DSL nor a step graph—it is an ordinary Bun `main.ts` stored in a folder on the Agent's Files drive. The trigger owner manages scheduling or HTTP ingress and delivers the unmodified event to the chosen consumer; when bound to an Automation Job, Ankole wakes the Agent only when the script emits an event or the failure policy wakes it.

A [Workflow](../workflows/) serves a different execution pattern: during a turn, the main Agent starts one fixed, bounded subagent fanout in parallel. Because a Workflow never subscribes to schedules or webhooks and never polls external state, use it when a single turn needs a finite set of independent judgments combined into one result.

## The three triggers

Every blueprint starts from one of three triggers—pick the trigger before choosing a blueprint:

| Trigger | How it fires | Carrier | Built with |
|---|---|---|---|
| **Schedule** | on a cron cadence (hourly, daily, weekly) | a `task` on a cron schedule | [Schedules](../schedules/) |
| **Self-deferred (checkback)** | the Agent sets a delayed trigger during a turn | the Agent's `check_back_later` tool | [Schedules](../schedules/) |
| **Event-driven (webhook)** | an external system POSTs to a capability URL | a `webhook.received` event | [Webhook delegations](../webhook-delegations/) |

All three triggers emit the same CloudEvents envelope regardless of whether they wake the Agent directly or invoke a script. Choosing a consumer changes only the recipient, and both a direct Agent wakeup and an event emitted by a script deliver replies through the owner session's signal routing rule.

## Choose the consumer

| Consumer | Use it when | Trigger result |
|---|---|---|
| **Agent session** | Each delivery needs judgment, memory, tools chosen at run time, or a user-facing response. | The trigger appends a Signal and wakes the conversation. |
| **Automation job** | Handling is a deterministic fetch, comparison, parse, or predetermined action. | The trigger creates a durable script run. The script can finish silently or emit an event to the owner session. |

Start with a direct Agent wakeup while the handling rules are still evolving, then move only the proven mechanical check into an automation job. That keeps scripts small and keeps the model out of repetitive polling loops.

## Blueprint: daily digest (schedule)

A cron schedule wakes the Agent once a day so it can gather and summarize the requested updates and post the result to the bound chat channel. Create and test the schedule with [Schedules](../schedules/) before enabling the daily cron cadence.

Copy a valid session cookie and `x-csrf-token` value from a signed-in browser before running this Console API request:

```bash
curl -X POST https://ankole.example.com/api/v2/agents/<agent_uid>/cron-schedules \
  -H "Cookie: $CONSOLE_COOKIE" \
  -H "x-csrf-token: $CSRF_TOKEN" \
  -H "Content-Type: application/vnd.api+json" \
  -d '{
    "data": {
      "owner_session_id": "<session_id>",
      "binding_name": "main",
      "name": "daily-digest",
      "idempotency_key": "daily-digest-1",
      "schedule": { "kind": "cron", "expression": "0 9 * * *" },
      "timezone": "Asia/Shanghai",
      "delivery": { "targets": [{ "binding_name": "main", "conversation_id": "<conversation_uuid>" }] },
      "payload": { "task": "Produce today'\''s digest of the topics in your mission." }
    }
  }'
```

You can tune the cron `expression` (cadence), `timezone` (when 9 AM occurs), `task` prompt (what to summarize), and Agent persona (how to present it). Trigger a manual test run before relying on the recurring schedule.

## Blueprint: deterministic sentinel (schedule + automation job)

Use an automation job when a schedule fires frequently for a mechanical check that usually finds nothing actionable. The Agent writes and registers the script, then binds the cron schedule to its `automation_job_id`:

```json
{ "kind": "cron", "expression": "0 * * * *" }
```

On each run, the script inspects the upstream source and exits quietly without calling `emitEvent` whenever the condition is false. When the condition holds, the script emits bounded source facts to the owner session so the Agent can verify them and decide how to respond. Test pure logic branches manually before registration, then fire a real test trigger to exercise every branch that calls `context()` or `emitEvent`.

Keep a direct Agent schedule whenever every run requires semantic judgment. Read [Worker CLI capabilities](../cli-capabilities/) for the full Automation Job contract.

## Blueprint: deferred follow-up (checkback)

When an Agent is asked something mid-turn and decides to check back later rather than creating a recurring cron job, it schedules a one-shot wakeup by calling `check_back_later`—effectively telling itself to look again in an hour.

This blueprint fits ad-hoc follow-ups that do not belong on a fixed clock, such as “check whether the deploy finished in an hour” or “re-read this thread after standup.” Because the Agent sets the timing dynamically, the operator surface is read-only: inspect pending checkbacks via `GET /api/v2/checkbacks?agent=<agent_uid>`, and cancel one with `DELETE /api/v2/agents/:agent_uid/checkbacks/:scheduled_event_id`.

## Blueprint: research-and-report (schedule + background job)

When a scheduled task requires extended search and cross-checking, the Agent starts from a cron wakeup and delegates the heavy work to a [Deep Research Background Agent Job](../deep-research-job/) instead of holding the foreground turn open:

1. The cron schedule fires its `task`.
2. Recognizing long-running work, the Agent calls `create_background_job`.
3. The scheduled turn ends promptly while the job executes independently.
4. When finished, the job appends `background_agent_job.completed` to the owning session, which delivers the report through its signal routing rule.

This handoff gives you a weekly deep-research report without holding a scheduled session turn open for an hour: the schedule triggers the run, and the background job performs the research.

## Blueprint: event-driven (webhook)

When an external system such as a source repository or CI pipeline POSTs to a short-lived Ankole capability URL, the endpoint validates and commits the selected consumer record before returning success.

Keep the default direct-Agent consumer when the Agent should inspect the live external object and judge the event directly, or bind the endpoint to an automation job when a deterministic script should filter or reconcile payloads first. In both paths, treat the incoming webhook payload as untrusted and verify consequential facts against the authoritative external source. Read [Webhook delegations](../webhook-delegations/) for capability security and lifecycle rules.

## Blueprint: observe-and-escalate (binding policy + schedule)

When a team assistant monitors an active group channel and posts a periodic summary, combine a quiet group-binding policy (`may_intervene` or `record_only`) for real-time observation with a cron schedule for periodic synthesis:

- Binding: `unaddressed_group_message_policy: record_only` — the Agent observes every message, stays quiet in real time, and accumulates context.
- Schedule: a daily or weekly digest summarizing what happened in the channel.
- Delivery: the Agent posts the digest back through the binding, drawing on the session's recent context.

Separating continuous, quiet observation from scheduled synthesis works well in busy channels where real-time bot replies would be noisy, while a daily or weekly recap adds clear value.

## Choosing a blueprint

- **Want it to run on a clock?** Use a **Schedule**, choosing the digest shape to post every time or the sentinel shape to post only when something changes.
- **Want it to revisit something mid-flight?** Use a **Checkback** so the Agent controls the followup timing.
- **Want long research kicked off on a clock?** Combine **Schedule + Background Agent Job**.
- **Want frequent mechanical checks without spending model turns?** Combine **Schedule or Checkback + Automation Job**.
- **Want bounded parallel judgments inside a single Agent turn?** Use a **Workflow**, which returns one aggregated result to the turn that started it.
- **Want an external system to push events in?** Use a **Webhook delegation**, routed to either the Agent or an Automation Job.
- **Want quiet observation paired with periodic recaps?** Combine **Binding policy + Schedule**.

## What automation in Ankole is not

Triggered automation in Ankole is not a declarative workflow engine: there is no YAML step list, platform DAG, hidden polling cursor, or general-purpose event bus. When an Automation Job runs a script, that script owns its own state and replay safety, outbound delivery still flows through the owner session's routing rule, and automation never bypasses AuthZ permissions.

Likewise, [Workflows](../workflows/) do not add trigger subscriptions or multi-hour waits—they execute fixed JavaScript for a single bounded subagent fanout inside an active turn. Use the Agent for open-ended judgment, an Automation Job for mechanical trigger handling, and a Workflow for bounded parallel judgment.

## Next steps

- For the schedule surface, read [Schedules](../schedules/).
- For deterministic script consumers, read [Automation Jobs](../automation-jobs/).
- For bounded subagent orchestration, read [Workflows](../workflows/).
- For background execution and collaboration choices, read [Background Agent Jobs](../background-jobs/).
- For an external event capability, read [Webhook delegations](../webhook-delegations/).
