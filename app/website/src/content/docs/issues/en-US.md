---
title: Issues
description: Follow the background work that Agents do for you on one board, and accept the result.
section: User guide
order: 16
---

An Issue is a piece of background work that you hand to an Agent. It has a title, a description, and one Agent that does the work. Every Issue has its own conversation: the Agent's replies, its questions, and the Background Agent Jobs and Workflows that it starts appear there, as they do in Chat.

## Open the board

While any item is in **To do** or **In progress**, the **Home** tab of the Pod sidebar shows **Background Agent tasks** directly above **Shared with me**. Select it to open the board, with the scheduled tasks below it.

The board covers the conversations in your Chat list. A comment thread on a Page and a conversation in a chat application stay off the board, so you follow their runs and schedules in those conversations.

The board has five columns:

- **To do**: the Agent has not received the request.
- **In progress**: the Agent is working, or one of its background runs is live.
- **Needs you**: the Agent asked a question or waits for your approval.
- **In review**: the Agent has stopped, and the result waits for you.
- **Done**: you accepted the result.

**In progress** and **Needs you** follow what the Agent is really doing, so a card moves between them by itself. A card shows, on its first row, how far its latest live run has come and how that run stands; then the title; then the Agent and when the work last moved. A **+** in the first row counts the card's other live runs. Point at a card to show its **Stop** button. The header above the board names the Agents that are working now, and **Filter** shows only the cards of the Agents that you choose.

## Create an Issue

To hand work to an Agent, ask your personal assistant or an AI colleague for it in Chat. Once the Agent takes it on as a Background Agent Job or Workflow, the conversation becomes an Issue on the board, as **Background work from Chat** below describes.

To create an Issue yourself, for example from a script, send `POST /api/v2/pod/issues` with a `title`, a `description` of what should be done, and the `agentUID` of the Agent that does the work: your personal assistant or an AI colleague. The Agent receives the title and the description as your first message in the Issue's conversation and starts working. With `start: false`, the Issue waits in **To do** instead. You can still edit its description, and it starts when you select **Start** or drag its card to **In progress**.

To sort your Issues, give an Issue up to ten `labels` when you create it, and replace them at any time with `PATCH /api/v2/pod/issues/:id`. `GET /api/v2/pod/issues` lists your Issues with their labels.

## Repeat an Issue on a schedule

To make an Issue repeat, create it with `repeat`: an `expression`, which is a five-field cron expression such as `0 9 * * 1` for every Monday at 9:00, and your `timezone`. Each run sends the Issue's request to the Agent, and the Agent's result arrives in the Issue's conversation, so the Issue moves to **In review** after every run, even after you accepted the previous one. The first run happens at once, unless you create the Issue with `start: false`; then it waits for the first scheduled time.

**Scheduled** below the board shows the Issue's next run. To pause, resume, or remove the schedule, or to run the Issue now, ask the Agent in the Issue's conversation, or send `PATCH /api/v2/pod/issues/scheduled/:id` with `change` set to `pause`, `resume`, `remove`, or `run`. The schedule's ID is the Issue's `repeat.id` in `GET /api/v2/pod/issues`.

## Break an Issue into sub-issues

A sub-issue is an Issue of its own, with its own Agent and conversation, that belongs to a larger Issue. To create one, send `POST /api/v2/pod/issues` with the larger Issue's ID in `parentID`. That ID is the ID of the larger Issue's conversation, and you need to be able to open it. In `GET /api/v2/pod/issues`, a sub-issue names its parent, and the parent counts its sub-issues and how many of them are done. When you accept a sub-issue, the parent's Agent receives the sub-issue's result in the parent's conversation, as a message from you, and continues the parent's work.

## Share the work with a Squad

A Squad is a group of AI colleagues among whom your personal assistant shares an Issue's work. To give an Issue a Squad, create it with your personal assistant as its Agent and list the colleagues' UIDs in `squadUIDs`. The request names them, and your assistant shares the work among them. While a colleague works on its part, the Issue stays in **In progress**. In a conversation with your personal assistant, you hand work to colleagues in the same way: mention them in your message, and your assistant delegates to them.

## Follow and accept the work

Select a card to open it beside the board. A card in **To do** opens the Issue's title, its Agent, and the request, which you can still edit. When you select **Start** or drag the card to **In progress**, the Agent receives the title and the description as your first message in the Issue's conversation. Any other card opens the details of its background run, as a conversation shows them: the plan, the steps, and the result. There you answer the run's question, steer it, or stop it, and **Open in Chat** opens the Issue's conversation.

When the Agent has stopped, the Issue moves to **In review**. Select **Mark done**, or drag the card to **Done**, to accept the result. **Reopen** returns an accepted Issue to **In review**, and an Issue that you closed before it started returns to **To do** with its request. When the Agent starts new background work in the conversation of an accepted Issue, the Issue reopens by itself.

## Who sees an Issue

The people in the Issue's conversation see it. Invite a teammate to the conversation to share the Issue. An Issue for your personal assistant is private to you.

While you are the only person in the conversation, the Agent answers every message that you write there. After a teammate joins, your messages still go to the Issue's Agent unless you choose otherwise. To write to your teammates and leave it to the Agent whether to answer, change the recipient below the message box to **Agents allowed to join in**.

## Background work from Chat

A conversation in your Chat list becomes an Issue when an Agent starts its first Background Agent Job or Workflow there, whether it is a conversation with your personal assistant, a direct conversation with an AI colleague, or a group. That work appears on the board without any step from you and stays there until you accept it. A new Background Agent Job in the same conversation reopens it.

## Scheduled tasks

Below the board, **Scheduled** lists the recurring tasks and pending check-backs that Agents keep in the conversations of your Chat list, with the time of the next run, or **Paused** for a paused task. Select a row to open the conversation that manages it, and ask the Agent there to create or change a schedule. You can also pause, resume, run, or remove a recurring task that runs on your authority, such as an Issue that you made repeat, with `PATCH /api/v2/pod/issues/scheduled/:id`, using the row's ID from `GET /api/v2/pod/issues/scheduled`.
