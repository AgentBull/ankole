---
title: Automation blueprints
description: End-to-end automation patterns that combine cron schedules, checkbacks, background jobs, and signal routing rules.
section: Guides
order: 309
---

Automation in Ankole is not one tool; it is three triggers combined with the agent's judgment. This page gives ready-to-use blueprints for the common shapes, each built from parts the other guides cover. Copy the shape, swap in your topics and channels, and tune the persona over a few runs.

The decisive property, stated up front: automation here is *agent-driven*. The triggers wake the agent; the agent decides what to do. There is no separate "automation script" language — the prompt the schedule carries, or the event the webhook delivers, is what the agent works from.

## The three triggers

Every blueprint uses one of three triggers. Know which one you need before you pick a blueprint.

| Trigger | How it fires | Carrier | Built with |
|---|---|---|---|
| **Schedule** | on a cron cadence (hourly, daily, weekly) | a `task` on a cron schedule | [Schedules](../schedules/) |
| **Self-deferred (checkback)** | the agent sets a delayed self-wakeup during a turn | the agent's `check_back_later` tool | [Schedules](../schedules/) |
| **Event-driven (webhook)** | an external system POSTs to the webhook front door | a `signals_gateway.webhook_handler` plugin | [SignalsGateway](../signals-gateway/) |

All three deliver through the Agent's routing rules: the rule used by a schedule, or the rule used when an Agent wakes from a Webhook event. There is no separate "automation delivers to channel" setting outside the routing model.

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

## Blueprint: hourly sentinel (schedule, quiet unless triggered)

A schedule that fires often but usually stays quiet — the agent watches a source and only posts when something matters. The secret is the persona's "stay quiet unless" rule, paired with a frequent cron.

```json
{ "cron": "0 * * * *", "kind": "cron" }
```

Pair it with a mission that names the threshold: "Post only if a new critical advisory affects our stack. Otherwise, stay silent." An hourly run that stays quiet most of the time is the point — the sentinel's value is in the rare post, not the frequent one.

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

An external system — a provider webhook, a CI result, a monitoring alert — POSTs to `/webhooks/v1/:handler_id/:instance_id/:kind`, and a declared `signals_gateway.webhook_handler` plugin turns it into an actor event. The agent wakes, reads the event, and decides what to do.

This is the shape behind the Microsoft 365 directory webhook (`entra-id`, kinds `directory`) and any custom webhook handler a plugin declares. The blueprint is: declare the handler in a plugin, point the external system at the webhook URL, and let the agent's persona decide what the event means. The webhook front door authenticates the *provider* (Bot Framework JWT, Graph `clientState`, or whatever the handler signs with), never an admin.

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
- **Want an external system to wake the agent?** Webhook, through a declared handler.
- **Want quiet observation plus periodic synthesis?** Binding policy + schedule.

## What automation in Ankole is not

It is not a script language. There is no YAML step list or "if this then that" graph. Triggers wake the Agent; the persona and model decide the steps. It is not a separate delivery system because delivery always uses a routing rule. It also cannot bypass permissions: an automated Agent acts under the same AuthZ grants as an Agent started by a person. Automation combines triggers, an Agent, and a routing rule; the Agent makes the decisions.

## Next steps

- For the schedule surface, read [Schedules](../schedules/).
- For background execution and collaboration choices, read [Background Agent Jobs](../background-jobs/).
- For the webhook front door, read the [SignalsGateway](../signals-gateway/) developer page.
