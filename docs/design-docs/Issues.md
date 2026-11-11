# Issues

An Issue is background work that a person hands to an Agent, follows, and
accepts. It gives a [Background Agent Job](BackgroundAgentJob.md) or
[Workflow](Workflow.md) the parts that a person needs around it: a person can
create the work without a chat turn, keep it waiting, repeat it on a schedule,
break it into sub-Issues, sort it with labels, see where it stands beside all
other work, and accept its result.

`Ankole.Issues` owns one small record per Issue. The Issue's title, its
discussion, and the Agent's Session belong to one native conversation, the
Issue's room, which [Conversations](Conversations.md) owns. The Agent works in
that room as it works in any chat: Ankole accepts the request as a message, the
Agent's replies become the room's messages, and a Background Agent Job or
Workflow that the Agent starts there records the room's Session as its owner.
The owner Session therefore links every run to its Issue, and the run records
carry no Issue reference of their own.

## Owners and stored facts

| Owner | Contract |
| --- | --- |
| `Ankole.Issues` | Issue rows, the rules that start and reopen an Issue, and the public form of a work item |
| `Ankole.Conversations` | The room: title, participants, access, messages, and the Agent's Session |
| `Ankole.Signals` and `Ankole.Sessions` | The request message's input, its queue order, admission, and recovery |
| `Ankole.BackgroundAgentJobs`, `Ankole.Workflow`, `Ankole.Schedule` | The runs and schedules whose owner Session is the room, including the cron rule that repeats an Issue |

`issues` is a tenant-scoped table keyed by the room ID. Each row stores a
`status`, the `description`, the `agent_uid` of the Agent that does the work,
up to ten `labels`, the `parent_id` of the Issue that it is part of, and the
`squad_uids` of the AI colleagues among whom a personal assistant shares the
work. The status records only what a person decides:

- `todo`: the Agent has not received the request.
- `started`: the Agent has received the request.
- `done`: a person accepted the result.

The Agent references a Principal, so a Principal rename follows through the
foreign key, and deleting the Agent clears the reference. Deleting the room
deletes its Issue, and deleting a parent's room clears the parent link of its
sub-Issues. A Squad is an array of Principal UIDs that no foreign key can
follow, so `Principals.Rename.References` rewrites `squad_uids` when a member
is renamed, and a work item names only the Squad members that are still
active.

## Rooms and access

`Conversations.ensure_issue_room_in_tx/2` creates the room with the creator
and the Agent as its participants and with the Issue's title as its custom
title, and posts no message. The room is a `dm`, so every message that the
creator writes there addresses the Agent and requires its answer. The room
carries no colleague-DM identity, so an AI colleague's Issues stay apart from
its direct-message room. Creating an Issue requires the `chat` permission on
the Agent, as starting a conversation with that Agent does.

Access to an Issue is access to its room. The people who take part in the room
see the Issue, and inviting a person to the room shares the Issue with that
person. The invitation turns an AI colleague's room into a `group`, where a
message names its Agents. The room's detail therefore carries the Issue's Agent
as `issueAgentUID`, and the composer of a group room selects that Agent as the
recipient until the person picks another one. A message in a shared Issue thus
still addresses the Issue's Agent by default, and a person who picks the Agents
allowed to join in writes to the teammates and leaves the answer to the Agent's
judgment. A personal assistant's room stays private to its owner.

## Start, accept, and reopen

Starting an Issue posts the request to the room as a message from the person
who starts it, addressed to the Issue's Agent. The message's text is the title,
followed by the description when the Issue has one. Ankole posts it through
`Conversations.post_in_tx/3`, so the Agent receives a
`conversation.message.addressed` input with that person's work authorization,
and the queue, steering, retry, and recovery rules of an ordinary message apply.
In the same transaction the Issue becomes `started`.

A new Issue starts at once unless its creator passes `start: false`, which
leaves it in `todo` with nothing sent. While an Issue is in `todo`, a person
can change its description; after the start, the request is the room's first
message, and a person adds to it by writing in the room. A person changes an
Issue's labels at any time.

A person accepts the result by setting the Issue to `done`, and reopens an
accepted Issue by setting it to `started`, which posts nothing. The reopened
Issue is `started` when its room holds a message, and returns to `todo` with
its request when the room holds none, so a person can still start an Issue that
was closed before it began. Starting a `started` Issue again also posts
nothing. Every change reads the Issue's row under a lock before it takes the
room's Session lock, so two people who start the same Issue at once send one
request. After a change commits, `Ankole.Issues` publishes the room's message
and status events, which refresh the room and the Work page in every open tab.

A Background Agent Job that an Agent's turn creates, a Job that continues a
finished one, and a Workflow run each call
`Issues.ensure_for_task_room_in_tx/2` in the creating transaction. A successor
Job that a steer message seeds leaves the Issue as it is.

- When the owner room has an Issue in `done`, the Issue becomes `started`. A
  run in the room of an accepted Issue therefore reopens it, and the run's
  result waits for review.
- An Issue in `todo` stays in `todo`, because its request has not been sent.
  Its work item shows the run while the run is live.
- When the owner room is a native room with `participants` access and has no
  Issue, the room receives an Issue in `started` with the run's Agent as its
  Agent. Such a room is a personal assistant's task room, a direct conversation
  with an AI colleague, or a group, so the long work that starts in any
  conversation of the Chat list appears in Work without the person creating
  anything, and stays there until a person accepts it. A conversation in which
  no such run starts stays a chat and has no Issue.
- When the owner Session is the execution Session of a cron rule whose owner
  room has an Issue, the run belongs to that Issue and reopens it as a fire
  does.

## Repeat on a schedule

A person makes an Issue repeat by creating it with `repeat`, a five-field cron
expression and the person's time zone. `Ankole.Issues` creates the Issue in
`todo` without a request message, and then creates a cron rule in
`Ankole.Schedule` with the Issue's Agent, the room's Session as the rule's
owner Session, the Issue's title as its name, the room ID as its idempotency
key, the room as its only delivery target, and the request as its task. The
rule runs on the creator's work authorization. Schedule takes its own locks
before a room's, so the rule commits in a second transaction; if it fails, the
Issue stays an ordinary Issue that waits.

Each fire runs the request in the rule's execution Session, which sees the task
but not the room's transcript, and the Agent's reply arrives in the room as a
native Agent message. In the fire's transaction, `Schedule.Fire` calls
`Issues.track_fire_in_tx/1`: the room's Issue becomes `started`, which starts
an Issue that waits and reopens an accepted one, so every run's result waits
for review. A start of a repeating Issue arms one manual run of its rule
instead of posting a message, and the pending run shows the Issue as working
until it fires; a second start finds that run and arms nothing. While a
repeating Issue is in `todo`, changing its description also changes the rule's
task.

The Human whose authority a rule runs on pauses, resumes, runs now, or removes
it with `PATCH /issues/scheduled/:id`. The Agent in the room manages the same
rule with its schedule tools, because the room's Session is the rule's owner
Session. Removing the rule leaves an ordinary Issue.

## Sub-Issues

A person creates a sub-Issue from an Issue that the person can open. The
sub-Issue has its own room with the person and its Agent, and records the
parent in `parent_id`; the parent's work item counts its sub-Issues and how
many are `done`, and a sub-Issue names its parent while the person can open the
parent's room. When a person accepts a sub-Issue whose parent is `started`,
Ankole posts a message from that person in the parent's room, addressed to the
parent's Agent, that names the sub-Issue and quotes the sub-Issue Agent's
latest reply, up to 4,000 characters. The parent's Agent thus continues with
the result. The report is a second transaction after the acceptance commits,
so the acceptance stands when the person cannot write in the parent's room.

## Squads

A Squad is the set of AI colleagues among whom a personal assistant shares an
Issue's work. Only a personal assistant hands work to colleagues, so `squad_uids`
requires the creator's personal assistant as the Issue's Agent, and each member
is an AI colleague with which the creator may chat. Starting the Issue posts
the request with an Agent mention of each member. In a personal assistant's
task room a mention is an instruction for the assistant, which delegates to the
named colleagues through its peer exchanges; a delegated colleague's work shows
the Issue as working.

## Work items and their status

A work item is the browser's view of background work. Work covers the rooms of
a Human's Chat list: the native rooms with `participants` access in which the
Human takes part. `Issues.list/1` gives the Human one work item for each such
room that either has an Issue or has a live Background Agent Job or Workflow. A
room without an Issue appears only while such a run is live, which happens for
a run that started before the room could receive an Issue. The list holds
every Issue that is not `done`, the 100 most recently accepted ones, and those
live rooms, with the latest activity first. A Page's comment thread, which is a
room with `anchor_page` access, and a conversation on an external messaging
platform are outside Work, so their runs and schedules appear only in those
conversations.

The status of a work item follows the room's real work before it follows the
Issue:

| Status | Condition |
| --- | --- |
| `waiting` | The room has a pending Clarify question or a prepared Action Card, or one of its Background Agent Jobs waits on the user |
| `working` | The Agent's Session has queued or running input, a delegated colleague is working, a Background Agent Job or Workflow of the room or of its cron rules is live, a cron rule of the room runs, or a run that a person asked of such a rule waits to fire |
| `todo` | Neither of the above holds, and the Issue is `todo` |
| `review` | Neither of the above holds, and the Issue is `started` |
| `done` | Neither of the above holds, and the Issue is `done` |

`Issues.Queries` reads the room state through `Conversations.list_rooms/2`,
which is the reader that the Chat sidebar uses, so a work item and its
conversation row never disagree. Each work item carries its live runs in the
shape of a room's linked runs (`Pod.Chat.Presentation.run_summaries/2`), with
the run's status, step count, plan progress, and whether it can be stopped. A
cron rule's run belongs to the room that owns the rule, and the rule's Session
status reaches open tabs through the same `conversations_changed` event as a
room's.

## Browser API and the Work page

The Pod JSON:API serves work items to the current Human under
`/api/v2/pod/issues`:

- `GET /issues` lists the work items. Each has the room ID as its `id`, the
  room's title, the status, `tracked` (whether the room has an Issue), the
  Agent, the live `runs`, the description while the Issue is in `todo`, its
  `labels`, its `parent`, its `children` counts, its `squad`, and `repeat`,
  the rule that repeats it with that rule's status, expression, time zone, next
  run, and whether the Human manages it.
- `POST /issues` creates an Issue from `title`, `description`, `agentUID`,
  `start`, and optionally `labels`, `parentID`, `squadUIDs`, and `repeat`.
- `GET /issues/:id` reads one Issue.
- `PATCH /issues/:id` changes the `description` of an Issue in `todo` and the
  `labels` of any Issue, and moves an Issue with `status`: `started` starts or
  reopens it, and `done` accepts its result.
- `GET /issues/scheduled` lists the Agents' recurring rules and pending
  checkbacks in the rooms of the Human's Chat list. Each row names the room
  that manages the schedule, or else a room that receives its reports, and
  carries the rule's name, timing, Agent, and `manageable`, which tells that
  the rule runs on the Human's authority. An Applet's Job schedules stay with
  their Applet.
- `PATCH /issues/scheduled/:id` pauses, resumes, runs now, or removes a cron
  rule that runs on the Human's authority.

The Home tab of the Pod sidebar links to the Work page with a row titled
Background Agent tasks, directly above Shared with me. The row shows while
at least one work item is in To do or In progress, and while the Work page is
open. The Work page shows the work items as a board with the columns To do, In
progress, Needs you, In review, and Done, and shows the schedules below it.
The columns share the page's width and wrap onto another row when all five do
not fit, so the board never scrolls sideways. Issues reach the board from the
conversations of the Chat list in which a Background Agent Job or Workflow
starts, and from callers of `POST /issues`. Those callers also give an Issue
its labels, its parent, its Squad, and its repeating rule; `PATCH /issues/:id`
replaces the labels, and `PATCH /issues/scheduled/:id` changes a schedule. The
board is built from the UIKit `Board` components. Each column is a quiet
surface headed by the status's icon in its hue, the status, and the card
count. A card has three rows: what its latest live run has done (the plan or
Workflow progress, else the step count, else the run's kind, with the number
of other live runs) and how that run stands, then the title, then the Agent
and when the work last moved. A card's Stop action shows while the card is
hovered or holds focus. The page header names the Agents whose runs are
running, and its Filter menu limits the cards to the chosen Agents, which the
`agent` search parameters keep. Only the moves that a person decides are
available by dragging: a `todo` card to In progress starts the Issue, a `todo`
or `review` card to Done accepts it, and a `done` card to In review or To do
reopens it.

Selecting a work item opens it beside the board in the room layout of Chat:
the board keeps a 300 px column, and the panel takes the rest of the page with
the open and close motion of a conversation's side panel. On a phone, the panel
opens as a sheet. The panel is the execution inspector that a conversation
opens for a run, with the run's plan, steps, and result, its Stop action, and,
for a Background Agent Job, the message box that answers or steers it. It shows
the card's latest live run, else the room's latest run from the conversation
detail, and the `issue` and `run` search parameters name the open item and run,
including a predecessor or successor Job that the person opens from the
inspector. The inspector's header adds the one Issue step that applies (Start,
Mark done, or Reopen) and a link to the room. For an Issue in `todo`, the panel
shows the title, the Agent, and the request for editing, because the room has
received nothing yet. A schedule row opens the room that manages the schedule.
The Work queries refresh on the Pod's `conversations_changed` event, which
follows every committed message, run status, and Issue change.

## Tests required for changes

`test/ankole/issues_test.exs` covers the request message that starts an Issue,
a later message in the room, the default recipient of an Issue shared with a
teammate, an Issue that waits, an Issue closed before it started, a run in the
room of an Issue that waits, review and acceptance, the events that follow a
change, the status that follows a Background Agent Job, the reopening of an
accepted Issue by a Job, a continued Job, and a Workflow, the personal
assistant's task room, a conversation with an AI colleague, labels, the report
of an accepted sub-Issue, a Squad, a repeating Issue and its rule (including
Squad delegation in scheduled runs), and the scheduled list with a room that a
person cannot open. A change to room creation, to the start
of an Issue, or to the owner-Session link must keep those cases passing against
the real Conversations, Signals, and Sessions owners.
`integration/pod-browser/work.spec.ts` covers the board in the browser.
