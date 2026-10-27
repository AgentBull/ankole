---
title: Automation Jobs
description: Let a deterministic script consume Cron, Checkback, and Webhook triggers. Mechanical checks finish silently, and the Agent wakes only for judgment.
section: User guide
order: 22
---

By default, all three triggers—Cron schedules, Checkbacks, and webhook endpoints—wake an Agent conversation directly. An Automation Job provides a second consumer option: a deterministic script that the Agent writes and stores in its Files drive. When you bind a trigger to an Automation Job, Ankole executes that script at fire time instead of opening an Agent turn.

Inside the run, the script decides whether anything warrants attention: it can finish silently, or call `emitEvent` to send an event back to the owner conversation so the Agent wakes with the exact context that the script prepared. Code handles the mechanical watch, while the model runs only when judgment is needed.

## When it fits

Delegate trigger handling to an Automation Job whenever the check is a deterministic fetch, comparison, parse, or predetermined action—for example, polling a ticker every 5 minutes, exiting silently while the price stays above a threshold, and emitting the quote only when it drops so the Agent wakes, verifies, and alerts you. Each routine check costs a lightweight script run rather than a full model turn.

Keep a direct Agent wakeup whenever every trigger fire requires memory, open-ended judgment, or conversation. Neither choice is permanent: you can start with direct Agent wakeups, extract the check into an Automation Job once it proves purely mechanical, or switch back at any time.

## Ask the Agent to create one

You do not need to open the Console to set up an Automation Job. Simply describe what to watch, the trigger condition, and when to alert you in chat:

```text
Watch the price of 7709 for me: check every 5 minutes and alert me
only when it drops below 3.5. Stay silent otherwise. After market
close, report once whether the day's checks ran normally.
```

In response, the Agent writes the script in its workspace, tests it by hand, registers it as an Automation Job, binds a Cron schedule to it, and schedules a market-close reconciliation Checkback. Registration copies the script folder into the Agent's Files drive; on every fire, Ankole copies the current contents of that drive folder into a fresh run directory, so any file that the script writes alongside itself disappears when the run ends. To update the logic later, the Agent overwrites the files in that same drive folder—no new registration is required.

## Run history and failures

Every execution writes a run record with its start and end timestamps, status, exit code, error message, and bounded logs. Both the Agent in chat and operators on **Console → Automation Jobs** can inspect this read-only history:

- By default, Ankole records a failed script run without waking the conversation.
- If you ask the Agent to enable `wake_on_failure` at creation, every failed run wakes the owner conversation immediately.
- For long-running watches, pair the job with a periodic reconciliation Checkback so the Agent wakes on schedule, inspects run history, and flags silent breakdowns such as “checks have been failing since 14:00.”

If the script throws an error, exits non-zero, or times out, Ankole records that failure as the script's final outcome without retrying—the next scheduled trigger will run normally on cadence. If the Worker itself crashes mid-run, however, Ankole redispatches the execution, meaning runs can overlap and emitted events can repeat; Agents write scripts to be idempotent so a replay stays harmless.

## Data discipline

Any payload that a script sends through `emitEvent` arrives in the Agent's turn as untrusted input, governed by the same rule as an external webhook receipt: the Agent verifies consequential facts against an authoritative source before acting or reporting on them.

## Teardown

To retire a watch cleanly, cancel the Cron schedule, Checkback, or webhook endpoint pointing at the script first, and then cancel the Automation Job—if an active trigger fires into an already cancelled job, Ankole records a failed run. Leaving an unreferenced Automation Job in place costs nothing at runtime and occupies only a single list row.

Read [Schedules](../schedules/) and [Webhook delegations](../webhook-delegations/) for the triggers, [Automation blueprints](../automation-blueprints/) for common patterns, and [Worker CLI capabilities](../cli-capabilities/) for the full script, SDK, and CLI contract.
