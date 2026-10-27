---
title: Skill lessons
description: Give each Agent short process cautions without changing the shared Skill.
section: User guide
order: 34
---

Skill lessons attach short, dated process cautions when an Agent loads a Skill—helping that Agent avoid recurring tool failures, environment pitfalls, and procedural mistakes while leaving the shared `SKILL.md` file untouched.

Inspired by GBrain's experiments in Skill optimization, Skill lessons capture dated operational notes accumulated as an Agent exercises a Skill. Ankole restricts machine-written lessons to leased, per-Agent process cautions and never rewrites the shared Skill body itself.

Each lesson belongs to a single Agent and a single Skill. Whenever a rule should apply to every Agent across the deployment, add it directly to the Skill's `SKILL.md` source instead.

## What can become a lesson

Ankole records two kinds of reusable process guidance:

- A tool failure or environment quirk encountered across multiple Background Agent Jobs.
- A reusable procedural correction given by a human while a Background Agent Job is running.

A lesson can specify when to stop, what precondition to verify, or how to invoke a tool—never how thorough, polished, or well-written a final deliverable should be, and Ankole does not score task outputs to evaluate whether a lesson helped.

One-off task instructions—such as a single report's scope, formatting, or terminology—stay inside that task rather than becoming a lesson, so most reflection batches produce zero new lessons.

## What evidence is required

Ankole examines completed Background Agent Jobs from the past 30 days that recorded either a failed command/tool call or a mid-run human steering message.

Once an Agent accumulates enough unprocessed qualifying Jobs (`10` by default), Dreaming launches a reflection Job covering up to the `30` most recent qualifying Jobs.

A machine-written lesson normally requires corroborating evidence across at least two distinct Jobs; a single Job suffices only when a human explicitly stated the reusable procedural rule during that Job.

Inside its reflection Job, the Agent can run read-only checks against its local Worker environment, but it cannot modify files, access the network, or attempt repairs, and it treats all captured error logs and tool outputs as untrusted data.

## What the Agent receives

When the Agent loads a Skill, active lessons are appended beneath the main `SKILL.md` body under `Agent-specific additions`, each stamped with its date and ordered with human-authored lessons ahead of Dreaming lessons.

Ankole omits retired lessons as well as Dreaming lessons whose review grace period has expired. Disabling a Skill also suppresses its lessons from entering the Agent's prompt, while preserving the full lesson history in the Console for operator inspection.

## Keep machine lessons current

Every Dreaming lesson starts with a seven-day lease, and scheduled Dreaming re-evaluates it whenever its lease comes due, the Ankole release version changes, or the underlying `SKILL.md` body changes.

Each review produces one of three outcomes:

- **Renew** extends the lease when the underlying environment condition still holds or no contradicting evidence has appeared.
- **Obsolete** retires the lesson once the environment issue has been resolved or the shared `SKILL.md` body covers it directly.
- **Lapse** retires an expired lesson when recent runs neither re-confirm the condition nor prove it obsolete.

If a due lesson goes unreviewed past a seven-day grace window, Ankole stops delivering it to the Agent while keeping the row in history so operators can see what happened.

Human-authored lessons carry no expiration lease, and Dreaming never alters or retires them.

## Add or retire a lesson

1. Open **Agent Library** in the Console.
2. Switch the scope from **Global defaults** to the target Agent.
3. Locate the Skill under an Agent Plugin or under **Skills**.
4. Select **Add lesson**, stating the triggering condition first and the required action second.
5. Select **Retire** whenever an existing lesson is inaccurate, obsolete, or unneeded.

You can add a human lesson only while the Skill is enabled for that Agent. Human lessons have no machine token cap, though they cannot contain URLs. Because lesson text is immutable once saved, fix a typo or update wording by retiring the existing lesson and adding a replacement.

For every lesson, the Console displays its author, creation timestamp, last review date, verified release version, supporting evidence Jobs, and retirement reason. Retiring a lesson also places it on Dreaming's never-relearn list so Dreaming will not recreate an equivalent caution later, and the Agent stops receiving the retired lesson starting on its next turn.

## Configure and observe learning

Four `brain.*` settings in AppConfigure govern Skill lessons:

| Setting | Default | Effect |
|---|---|---|
| `brain.skill_learning_enabled` | `true` | Enables reflection, lease review, and lesson delivery; setting it to `false` hides stored human and Dreaming lessons without deleting them. |
| `brain.skill_learning_reflection_threshold` | `10` | Unprocessed qualifying Jobs required before Dreaming starts a reflection Job (minimum `2`). |
| `brain.maintainer_agent_uid` | Not set | Selects the Agent whose `heavy` model profile reviews leased lessons; without a usable `heavy` profile, Ankole skips model-based review. |
| `brain.dreaming_task_cron` | `0 5 * * *` | Cron schedule on which Dreaming checks reflection thresholds and reviews due leases. |

Open **Brain → Health** in the Console to check whether Skill learning is active, inspect active lesson counts per Agent, view lessons added and retired over the past seven days, and check the age of the oldest active Dreaming lesson.

## Limits and safety

- Each machine-written lesson is capped at one to three short English sentences and at most `100` tokens—structured around a condition, an action, and an optional verification check.
- A single reflection Job can add at most two lessons to any one Skill, and Dreaming stops proposing new lessons for a Skill once it reaches `10` active lessons.
- Machine-written lessons cannot include URLs or text matching Ankole's prompt-injection guards.
- Lessons remain strictly per-Agent; Ankole never shares lessons across different Agents.
- Because Ankole cannot prove that a lesson holds universally without re-executing tasks, lessons are phrased as dated, conditional checks instructing the Agent to verify the live environment before acting.
