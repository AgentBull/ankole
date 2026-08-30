---
title: Skill lessons
description: Give each Agent short process cautions without changing the shared Skill.
section: User guide
order: 34
---

Skill lessons give an Agent short, dated cautions when it loads a Skill. They help the Agent avoid recurring tool failures, environment traps, and working-method mistakes. The shared `SKILL.md` stays unchanged.

Skill lessons are inspired by GBrain's experiments with Skill optimization. Ankole limits machine-written content to leased, Agent-specific process notes. It does not let an Agent rewrite the Skill body.

One lesson belongs to one Agent and one Skill. Put a rule in the Skill source when it must apply to every Agent.

## What can become a lesson

Ankole can retain two kinds of process guidance:

- A tool problem or environment condition that appears in more than one Background Agent Job.
- A reusable correction about how to work that a person gives while a Job is running.

A lesson can say when to stop, what to check, or how to call a tool. It cannot judge how good, deep, complete, or well-written a result should be. Ankole does not score task results to decide whether a lesson worked.

An instruction for one task is not a lesson. A one-time scope, format, or terminology request stays with that task. Most evidence batches produce no lesson.

## What evidence is required

Ankole looks at finished Background Agent Jobs that contain a failed command or tool call, or a human message after the Job started. It considers only the last 30 days.

Dreaming starts a reflection Job after the Agent has enough unprocessed signal Jobs. The default threshold is 10. The reflection receives up to 30 of the most recent qualifying Jobs.

A machine-written lesson normally needs evidence from at least two different Jobs. One Job is enough only when a human message in that Job states the reusable correction that the lesson summarizes.

The reflection can run read-only checks in its local environment. It cannot change files, use the network, or fix the problem. Error and tool output are treated as untrusted data.

## What the Agent receives

Active lessons appear below the full Skill instructions in an `Agent-specific additions` section. Each item shows its date. Human lessons appear before Dreaming lessons.

Retired lessons and machine lessons outside their review grace period are not delivered. Disabling a Skill also stops its lessons from entering the Agent's context. The stored history remains available to operators.

## Keep machine lessons current

A Dreaming lesson starts with a seven-day lease. Scheduled Dreaming reviews it when the lease is due, when the Ankole release changes, or when the Skill body changes.

The review has three outcomes:

- **Renew** keeps the lesson when its condition still exists or there is no new evidence.
- **Obsolete** retires the lesson when the environment no longer has the condition or the Skill body already covers it.
- **Lapse** retires an expired lesson when recent use does not confirm the condition and the review cannot show that it is obsolete.

An unreviewed lesson stops being delivered after a seven-day grace period. The row remains in the history so an operator can inspect what happened.

Human lessons have no lease. Dreaming does not change or retire them.

## Add or retire a lesson

1. Open **Agent Library** in the Console.
2. Change the scope from **Global defaults** to the target Agent.
3. Find the Skill under an Agent Plugin or under **Skills**.
4. Select **Add lesson**, state the condition first, and then state the action.
5. Select **Retire** when a lesson is wrong, obsolete, or no longer useful.

Only an enabled Skill accepts a new human lesson. A human lesson has no machine length limit, but it cannot contain a URL. To correct a lesson, retire the old item and add a new one; lesson text is immutable.

The Console shows the author, creation time, review date, checked release, evidence Jobs, and retirement reason. Content that an operator retires stays on Dreaming's never-relearn list, so Dreaming does not add an equivalent lesson again. The Agent stops reading a retired lesson on its next turn.

## Configure and observe learning

The following `brain.*` settings control Skill lessons:

| Setting | Default | Effect |
|---|---|---|
| `brain.skill_learning_enabled` | `true` | Enables reflection, review, and lesson delivery. `false` hides stored human and Dreaming lessons without deleting them. |
| `brain.skill_learning_reflection_threshold` | `10` | Sets the number of unprocessed signal Jobs required before one reflection Job starts. The minimum is `2`. |
| `brain.dreaming_model` | Not set | Selects the model that reviews leased lessons. If it is not set, model-based review is skipped. |
| `brain.dreaming_task_cron` | `0 5 * * *` | Sets when Dreaming evaluates reflection triggers and reviews due lessons. |

Open **Brain → Health** to see whether Skill learning is enabled, active lesson counts by Agent, lessons added and retired in the last seven days, and the age of the oldest active Dreaming lesson.

## Limits and safety

- A machine lesson is one to three short English sentences and at most 100 tokens. It uses a condition, an action, and an optional check.
- One reflection can add at most two lessons to one Skill. Dreaming stops adding when that Skill already has 10 active lessons.
- Machine-written lessons cannot contain URLs or content that matches the injection checks.
- Lessons are Agent-specific. Ankole does not share them across Agents.
- Ankole cannot prove a lesson is true or predict its effect without replaying the task. The dated, conditional text tells the Agent to check the current environment before it acts.
