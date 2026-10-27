# Skill Lessons

Skill lessons are dated field notes that one Agent accumulates on its own
Skills: short, evidence-backed observations from finished work that ship with
the Skill text on later runs. Each lesson is stored as an individual leased row
that Dreaming maintains and that an operator can audit or revoke.

The Elixir control plane owns lesson state and every admission gate:
`Ankole.Brain.SkillLessons` runs the reflection and review rounds,
`Ankole.BackgroundAgentJobs` provides the evidence read contract, and
`Ankole.AIAgent.Library` handles lesson storage and delivery. Workers receive
only the rendered field notes embedded alongside the Skill content.

## Data Model

`agent_skill_lessons` stores one lesson per row:

| Field | Meaning |
| --- | --- |
| `agent_uid`, `skill_name` | The owning Agent and Skill |
| `content` | The note text |
| `author_kind` | `dreaming` or `human` |
| `author` | The typed actor reference, for human lessons |
| `evidence_job_ids` | The finished Jobs that ground the note |
| `checked_release`, `checked_skill_hash` | The environment fingerprint at the last review |
| `review_after` | Lease end; `NULL` for human lessons |
| `retired_at`, `retire_reason` | Terminal state: `obsolete`, `lapsed`, or `human_revoked` |

The `AgentSkillLesson` resource exposes four actions: `teach_human`,
`teach_dreaming`, `renew`, and `retire`. Lesson `content` is immutable, and
native PostgreSQL constraints enforce the lease and retirement invariants.
Before writing review verdicts, Ankole locks all candidate rows in ID order, and
human retirement locks the target row the same way; as a result, a concurrent or
stale action cannot renew an already retired row or overwrite its retirement
reason. Enum attributes use atoms in memory and text in PostgreSQL and JSON
responses.

Every top-level lesson write—`apply_adds` for reflection additions, `teach` for
operator-authored lessons, `apply_reviews` for review verdicts, and `revoke` for
human retirement—runs inside `Repo.transact_top_level/2`, while Console
`/api/v2` routes expose generic actions on `AgentSkillLesson`. Both `apply_adds`
and `teach` synchronize the Skill catalog within the same transaction.
`Ankole.AIAgent` is the Ash domain that owns the library resources, and other
domains read lesson rows through its domain functions.

Stored lessons persist even if their Skill is disabled or removed, so historical
rows remain visible in listings.

## Production: Evidence and Reflection

Completed Jobs accumulate as candidate evidence. `BackgroundAgentJobs.evidence_signals`
and `BackgroundAgentJobs.evidence_sections` project the persisted item stream
through the Jobs-owned `TurnItemProjection`, so Brain never decodes raw Worker
items directly. A finished Job qualifies as a learning signal when that
projection contains mid-run human input, a shell command with a nonzero exit
code, or a local dynamic tool call with `success: false` (collaboration, MCP,
and provider-hosted tool calls do not count as failures here).

Once an Agent accumulates at least `brain.skill_learning_reflection_threshold`
unconsumed signal Jobs (minimum 2, default 10), the Dreaming `skill_lessons`
phase launches one reflection Job for that Agent. Brain records the Agent itself
as the trusted creation source: reflection runs as independent service work, so
human input inside the evidence Jobs does not make the reflection Job
human-owned. Because reflection Jobs run with an empty reply route and an
Agent-owned execution Session, Agents that operate exclusively through Pod can
also produce lessons. When the reflection Job commits its terminal result, the
same transaction queues lesson application without posting a conversation
notification.

Each reflection Job runs in the background with the `skill_lesson_reflection`
metadata flag, which excludes it from all user-facing Job listings and budgets.
Its prompt includes the Agent's enabled Skills, active field notes,
human-revoked lessons, and the evidence bundle. When the Job finishes,
`Library.apply_skill_lesson_adds` validates the proposed notes against four
mechanical gates:

- **Volume caps:** at most 2 accepted additions per Skill per round, and at most
  10 active lessons per Skill overall.
- **Content hygiene:** non-blank text, no URLs, at most 100 estimated tokens,
  and zero hits from the prompt-injection scanner. The scanner rejects explicit
  bypass phrases—such as `do anything now` and `developer mode enable` or
  `enabled`—without flagging a bare `DAN` token or the name `Dan`, while all
  other content rules still apply.
- **Evidence grounding:** citations to at least two bundle Jobs, or to one
  bundle Job that included mid-run human input, where every cited Job ID belongs
  to the current round's bundle.
- **Deduplication and immunity:** normalized text must neither duplicate an
  active lesson nor match a human-revoked lesson.

Each accepted dreaming lesson receives a 7-day lease alongside the release
identifier and Skill content hash against which Ankole validated it. Rejected
proposals are reported with rejection reasons rather than stored.

## Review

A dreaming lesson enters the review docket when its lease approaches expiration
within the review horizon or when its stored `checked_release` or
`checked_skill_hash` differs from the current environment. For each lesson, the
review Job returns one verdict:

- `renew` — extends the lease and updates the environment fingerprint; valid
  only for lessons inside the docket.
- `lapse` — retires a docketed lesson that does not merit renewal; valid only
  for lessons inside the docket.
- `obsolete` — retires any active dreaming lesson immediately and requires an
  explanatory note.

Human-authored lessons carry no lease and are never reviewed or retired by
Dreaming. Whenever an operator retires any lesson—whether authored by Dreaming
or a human—that retirement is permanent: the row enters the immunity list so
Dreaming never re-introduces equivalent content.

## Delivery

For each enabled Skill, `Library.skill_view` embeds active lessons under the
heading `Field notes (dated; verify against the current environment):`,
rendering human lessons first, dating every bullet, and marking human-authored
bullets explicitly. When a lesson is retired, Ankole stops delivering it at
once; however, an unretired dreaming lesson continues to appear for a 7-day
grace period after `review_after` passes so that a delayed review Job does not
drop a note mid-conversation.

When `brain.skill_learning_enabled = false`, every Skill renders without field
notes, Dreaming skips the `skill_lessons` phase, and the Console hides stored
lessons while leaving existing database rows untouched.

## Console

In the Console, `GET /api/v2/agents/:agent_uid/skill-lessons` invokes the
`console_list` read action on `AgentSkillLesson` to list all lessons for an
Agent together with their evidence Job IDs, lease timestamps, and retirement
status. Operators add human lessons to enabled Skills via `console_teach`
(recording the Console Principal as `author`) and retire any lesson via
`revoke`; updating a note's wording requires retiring the old lesson and
creating a new row rather than editing in place. Requests referencing an unknown
Skill or lesson return `404`.
