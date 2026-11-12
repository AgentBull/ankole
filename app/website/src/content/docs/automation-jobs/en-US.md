---
title: Automation Jobs
description: Run published Applet Actions from schedules, callbacks, and external events, and inspect their durable results.
section: User guide
order: 22
---

An Automation Job runs a published Applet Action in Function Runtime. It handles deterministic work without starting an Agent turn. The Job stores configuration and durable state; the Applet's published code defines the handler, concurrency policy, and continuation limits.

## Create and connect a Job

1. Publish an Applet whose server module exports an `actions` table.
2. Open the Applet's **Automation** panel, choose an Action, and create a personal or team Job.
3. Add a schedule, create a callback endpoint, or connect an external event source. Schedules support calendar expressions and fixed intervals. External sources come from the tenant's configured connections.
4. Run a schedule once, or send a test callback, then open the resulting Run to verify its input and result.

The Agent can perform the same operations through `ankole-pod` (`jobs.*`); read `ankole-pod --help` for the current command contract. Applet interfaces can use `useAppletJobs()` and `useJobSources(jobID)` from `@ankole/applet-sdk`.

## Personal and team execution

A personal Job runs for its Human owner; that person or their personal assistant manages its sources. A team Job uses the Applet owner's service authority and requires Page edit access to manage. Moving the Applet to trash prevents new executions. Deleting a Job removes its owned schedules and callback endpoints and detaches its external event bindings; shared external subscriptions remain available to other consumers.

## Action inputs and external tools

The handler receives `ctx.signal` (the CloudEvents input), `ctx.job.config`, and durable `ctx.state`. Use `remainingMs()` and `continueSlice()` for bounded continuations. Call Connector tools through `AnkoleRuntime.mcp`; team execution uses the corresponding `AnkoleRuntime.admin` capabilities. Configure application credentials and personal authorization on the Pod **Connections** page.

Publish updated Applet code to change subsequent executions. Do not rely on local files to preserve business state between runs.

## Inspect and recover

The Automation panel shows Run status, start and finish times, trigger source, result, error, and bounded output logs. Expand the input or logs when diagnosing a failure. A delivery receipt links to its Run and indicates when input was coalesced into another pending execution.

An Action controls its declared concurrency and replay policy. Keep side effects safe for the policy you choose. Missing personal consent returns an authorization link; after reconnecting, retry the intended operation. A partial upstream write can return the completed resource ID so recovery can finish the remaining step without repeating the first write.

See [Schedules](../schedules/), [Webhook delegations](../webhook-delegations/), and [Automation blueprints](../automation-blueprints/).
