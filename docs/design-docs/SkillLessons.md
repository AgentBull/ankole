# Skill Lessons

Skill lessons are dated field notes that one Agent accumulates on its own
Skills: short, evidence-backed observations from finished work that ship with
the Skill text on later runs. Each lesson is a leased, per-item row that
Dreaming maintains and an operator can audit and revoke.

The Elixir control plane owns lesson state and every gate.
`Ankole.Brain.SkillLessons` owns the reflection and review rounds,
`Ankole.BackgroundAgentJobs` owns the evidence read contract, and
`Ankole.AIAgent.Library` owns lesson storage and delivery. The worker only
receives the rendered notes with the Skill content.

## Data Model

`agent_skill_lessons` stores one lesson per row:

| Field | Meaning |
| --- | --- |
| `agent_uid`, `skill_name` | The owning Agent and Skill |
| `content` | The note text |
| `author_kind` | `dreaming` or `human` |
| `author` | The typed actor reference, for human lessons |
| `evidence_job_ids` | The finished Jobs the note is grounded in |
| `checked_release`, `checked_skill_hash` | The environment fingerprint at the last review |
| `review_after` | Lease end; `NULL` for human lessons |
| `retired_at`, `retire_reason` | Terminal state: `obsolete`, `lapsed`, or `human_revoked` |

The Lesson resource owns `teach_human`, `teach_dreaming`, `renew`, and
`retire` actions. Content is immutable. Native constraints enforce the
lease and retirement shape. Review locks all candidate rows in ID order before
writing verdicts; Human retirement locks the same row. A stale resource action
cannot renew a retired row or replace its retirement reason. Enum attributes
use atoms in memory and text in PostgreSQL and JSON responses.

Each lesson write (`apply_adds` for reflection adds, `teach` for an operator
lesson, `apply_reviews` for review verdicts, and `revoke` for human retirement)
runs in `Repo.transact_top_level/2`, and the Console `/api/v2` routes expose
generic actions on `Lesson`. `apply_adds` and `teach` synchronize the Skill
catalog in the same transaction. `Ankole.AIAgent` is the Ash domain of the
library resources; other domains read lesson rows through its functions.

A lesson outlives its Skill's enablement: rows stay listed when the Skill is
disabled or removed.

## Production: Evidence and Reflection

Terminal Jobs accumulate as evidence. `BackgroundAgentJobs.evidence_signals`
and `BackgroundAgentJobs.evidence_sections` project the stored item stream
through the Jobs-owned `TurnItemProjection`; Brain does not decode Worker
items. A Job qualifies as a signal when that projection shows mid-run human
input, a shell command with a nonzero exit code, or a local dynamic tool call
with `success: false`. Collaboration, MCP, and provider-hosted calls do not
count as failed calls for this phase.
When an Agent accumulates `brain.skill_learning_reflection_threshold`
unconsumed signal Jobs (minimum 2, default 10), the Dreaming `skill_lessons`
phase starts one reflection Job for that Agent. Brain records the Agent as
the trusted creation source. This is independent service work; the presence of
Human input in the evidence does not make the reflection a Human-owned task.

The reflection Job is a background Job marked with the
`skill_lesson_reflection` metadata flag; every user-facing Job listing and
budget excludes flagged Jobs. Its prompt carries the enabled Skills, the
current field notes, the human-revoked list, and the evidence bundle. Its
output enters `Library.apply_skill_lesson_adds` through mechanical gates:

- At most 2 accepted adds per Skill per round, and at most 10 active lessons
  per Skill.
- Content: non-blank, no URLs, at most 100 estimated tokens, and no
  prompt-injection scanner hit. The scanner checks explicit bypass phrases,
  including `do anything now` and `developer mode enable` or `enabled`; a bare
  `DAN` token or the name `Dan` does not trigger this rule. All other content
  rules apply.
- Evidence: at least two bundle Jobs, or one bundle Job that carried human
  input; every cited id must be inside the round's bundle.
- Dedup against active lessons and immunity against human-revoked lessons,
  both on normalized text.

An accepted dreaming lesson starts a 7-day lease and records the release and
Skill content hash it was validated against. Rejected adds are reported with
reasons, not stored.

## Review

A dreaming lesson enters the review docket when its lease ends within the
horizon or when its recorded release or Skill hash no longer matches the
current environment. The review Job returns one verdict per lesson:

- `renew` — extends the lease and refreshes the fingerprint; valid only
  inside the docket.
- `lapse` — retires the lesson as no longer earning its keep; valid only
  inside the docket.
- `obsolete` — retires any active dreaming lesson, and requires a note.

Human lessons carry no lease and are never reviewed or retired by Dreaming.
A human retirement of any lesson is permanent: the row joins the immunity
list and Dreaming never re-adds equivalent content.

## Delivery

`Library.skill_view` embeds the active lessons for an enabled Skill under the header
`Field notes (dated; verify against the current environment):`. Human
lessons render first, each bullet dated, human bullets marked. A retired
lesson leaves delivery at once; an unretired dreaming lesson keeps
delivering through a 7-day grace period after its lease ends, so a late
review does not silently drop a note mid-conversation.

With `brain.skill_learning_enabled = false` every Skill renders without
notes, the Dreaming phase skips, and the Console hides stored lessons; the
rows stay unchanged.

## Console

The Console lists every lesson of an Agent with its evidence Job ids, lease
state, and retirement (the `console_list` read action of `AgentSkillLesson`,
`GET /api/v2/agents/:agent_uid/skill-lessons`). Operators create human lessons
for enabled Skills (`console_teach`, with the Console Principal as the author)
and retire any lesson (`revoke`); a lesson content change is a retire plus a
new row, never an edit. An unknown Skill or lesson is not found (404).
