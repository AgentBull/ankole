# Issues

An Issue is background work that a person hands to an Agent, follows, and
accepts. It gives a [Background Agent Job](BackgroundAgentJob.md) or
[Workflow](Workflow.md) the parts that a person needs around it: a person can
create the work without a chat turn, keep it waiting, see where it stands
beside all other work, and accept its result.

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
| `Ankole.BackgroundAgentJobs`, `Ankole.Workflow`, `Ankole.Schedule` | The runs and schedules whose owner Session is the room |

`issues` is a tenant-scoped table keyed by the room ID. Each row stores a
`status`, the `description`, and the `agent_uid` of the Agent that does the
work. The status records only what a person decides:

- `todo`: the Agent has not received the request.
- `started`: the Agent has received the request.
- `done`: a person accepted the result.

The Agent references a Principal, so a Principal rename follows through the
foreign key, and deleting the Agent clears the reference. Deleting the room
deletes its Issue.

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
message addresses the Agent when it names the Agent. A personal assistant's
room stays private to its owner.

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
message, and a person adds to it by writing in the room.

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
- When the owner room is a personal assistant's task room without an Issue,
  the room receives an Issue in `started` with the assistant as its Agent. The
  assistant's background work thus appears in Work without the person creating
  anything. A conversation in which the assistant starts no such run stays a
  chat and has no Issue.

## Work items and their status

A work item is the browser's view of background work. Work covers the rooms of
a Human's Chat list: the native rooms with `participants` access in which the
Human takes part. `Issues.list/1` gives the Human one work item for each such
room that either has an Issue or has a live Background Agent Job or Workflow. A
room without an Issue appears only while such a run is live. The list holds
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
| `working` | The Agent's Session has queued or running input, a delegated colleague is working, or a Background Agent Job or Workflow of the room is live |
| `todo` | Neither of the above holds, and the Issue is `todo` |
| `review` | Neither of the above holds, and the Issue is `started` |
| `done` | Neither of the above holds, and the Issue is `done` |

`Issues.Queries` reads the room state through `Conversations.list_rooms/2`,
which is the reader that the Chat sidebar uses, so a work item and its
conversation row never disagree. Each work item carries its live runs in the
shape of a room's linked runs (`Pod.Chat.Presentation.run_summaries/2`), with
the run's status, step count, plan progress, and whether it can be stopped.

## Browser API and the Work page

The Pod JSON:API serves work items to the current Human under
`/api/v2/pod/issues`:

- `GET /issues` lists the work items. Each has the room ID as its `id`, the
  room's title, the status, `tracked` (whether the room has an Issue), the
  Agent, the live `runs`, and the description while the Issue is in `todo`.
- `POST /issues` creates an Issue from `title`, `description`, `agentUID`, and
  `start`.
- `GET /issues/:id` reads one Issue.
- `PATCH /issues/:id` changes the `description` of an Issue in `todo`, and
  moves an Issue with `status`: `started` starts or reopens it, and `done`
  accepts its result.
- `GET /issues/scheduled` lists the Agents' recurring rules and pending
  checkbacks in the rooms of the Human's Chat list. Each row names the room
  that manages the schedule, or else a room that receives its reports, and
  carries the rule's name, timing, and Agent. An Applet's Job schedules stay
  with their Applet.

The Pod sidebar has a Work tab beside Home and Chat. The tab lists the open
work items by status with the marks that a conversation row uses in Chat. The
Work page shows the work items as a board with the columns To do, In progress,
Needs you, In review, and Done, or as a list, and shows the schedules below
them. A card shows the room's title, each live run with the mark, status,
progress, and running time that its card shows in the conversation, the Agent,
and a Stop action for a run that can be stopped. Only the moves that a person
decides are available by dragging: a `todo` card to In progress starts the
Issue, a `todo` or `review` card to Done accepts it, and a `done` card to In
review or To do reopens it.

Selecting a work item opens its room beside the board, as the Page Assistant
opens a conversation beside a Page. The panel's header names the status and
offers the one step that applies: Start, Mark done, or Reopen. For an Issue in
`todo`, the panel shows the title, the Agent, and the request for editing in
place of the room, because the room has received nothing yet. The Work queries
refresh on the Pod's `conversations_changed` event, which follows every
committed message, run status, and Issue change.

## Tests required for changes

`test/ankole/issues_test.exs` covers the request message that starts an Issue,
a later message in the room, an Issue that waits, an Issue closed before it
started, a run in the room of an Issue that waits, review and acceptance, the
events that follow a change, the status that follows a Background Agent Job,
the reopening of an accepted Issue by a Job, a continued Job, and a Workflow,
the personal assistant's task room, a room without an Issue, and the scheduled
list with a room that a person can no longer open. A change to room creation,
to the start of an Issue, or to the owner-Session link must keep those cases
passing against the real Conversations, Signals, and Sessions owners.
`integration/pod-browser/work.spec.ts` covers the board in the browser.
