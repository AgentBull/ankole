---
title: Automation Jobs
description: Let a deterministic script consume Cron, Checkback, and Webhook triggers. Mechanical checks finish silently, and the Agent wakes only for judgment.
section: User guide
order: 22
---

The three triggers — Cron, Checkback, and webhook endpoints — wake an Agent conversation by default. An automation job is the second consumer: a deterministic script that the Agent writes and keeps inside its own Agent Home. Bind a trigger to it, and the system runs the script at fire time instead of starting an Agent turn.

The script decides what deserves your attention. It can finish silently, or call `emitEvent` to send an event back to the owner conversation, so the Agent wakes with exactly the context the script prepared. Code keeps the mechanical watch, and the model stays only at the points that need judgment.

## When it fits

Hand the work to an automation job when the handling is a deterministic fetch, comparison, parse, or predetermined action. A typical case: check a price every 5 minutes, finish silently while it stays above the threshold, and emit the current price only when it drops — the Agent then wakes, verifies, and notifies you. Each check costs one script run instead of one model turn.

Keep the direct Agent wake when every fire needs memory, judgment, or conversation. Neither choice is permanent: start with direct wakes, move the handling into a script once it has proven mechanical, or move it back.

## Ask the Agent to create one

You do not need the Console. In chat, state what to check, the condition, and when to wake you:

```text
Watch the price of 7709 for me: check every 5 minutes and alert me
only when it drops below 3.5. Stay silent otherwise. After market
close, report once whether the day's checks ran normally.
```

The Agent writes the script inside its Agent Home, verifies it by hand, registers it as an automation job, creates the Cron bound to it, and sets a market-close reconciliation Checkback. Script edits apply immediately without re-registration: each run executes the current files on disk.

## Run history and failures

Every fire leaves a run record: start and end time, status, exit code, error, and bounded logs. The Agent can read this history in conversation, and the Console **Automation Jobs** page gives the same read-only view.

- By default a failed run is recorded and nothing else happens.
- Ask the Agent to enable `wake_on_failure` at creation, and every failed run wakes the owner conversation.
- For a long watch, pair the job with a reconciliation Checkback: the Agent wakes on schedule, reads the run history, and reports a silent breakdown such as "checks have failed since 14:00" out loud.

A throw, a non-zero exit, or a timeout is the script's own outcome. The system does not retry it; the next fire arrives on its own. A Worker failure instead redispatches the run, so runs can overlap and deliveries can repeat — the Agent writes scripts so a rerun stays harmless.

## Data discipline

A payload the script sends through `emitEvent` reaches the Agent as untrusted input, under the same rule as a webhook receipt: the Agent verifies consequential facts at an authoritative source before it acts or replies on them.

## Teardown

To end a watch, cancel the Cron, Checkback, or webhook endpoint that points at the script first, then cancel the automation job. A trigger firing into a cancelled job records a failed run. A job with no trigger pointing at it costs nothing to keep; it only occupies one list row.

Read [Schedules](../schedules/) and [Webhook delegations](../webhook-delegations/) for the triggers, [Automation blueprints](../automation-blueprints/) for the common shapes, and [Worker CLI capabilities](../cli-capabilities/) for the complete script, SDK, and command contract.
