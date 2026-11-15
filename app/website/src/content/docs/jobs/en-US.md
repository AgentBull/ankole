---
title: Jobs
description: Track, start, and control asynchronous Agent jobs, Workflows, recurring Cron schedules, check-backs, and Page automations on one board.
section: User guide
order: 16
---

While **Chat** hosts interactive conversations with people and Agents, **Jobs** (`/jobs`) brings every asynchronous execution and standing schedule in your Pod onto a single board. One-off Background Agent Jobs, multi-step Workflows, recurring Cron schedules, check-back timers, and Page-owned Applet Automation Jobs appear side by side according to what is scheduled next, what is running or waiting on you right now, and what has finished.

## Open the board

Open the **Home** tab of the Pod sidebar and select **Jobs**, located directly above **Shared with me**, or press `⌘K` (`Ctrl+K` on Windows and Linux) and jump to **Jobs**.

The **Jobs** item in the sidebar displays a live count whenever work is active:

- An amber badge counts items in **Running** that need your attention, such as a job waiting on a question or a recent failure.
- When nothing needs intervention, an info badge counts the active runs currently in progress.

Above the board, the header names the Agents working right now, lets you switch **Board view** between **By status** and **By Agent**, and provides a **Filter** menu to narrow the board by Agent (or **Page automations**) and by item **Type**.

## One-off jobs and living routines

The board organizes asynchronous work into two card behaviors across three columns (**Scheduled**, **Running**, and **Completed**):

- **One-off jobs** (**Agent job** and **Workflow**) start, execute, and move to **Completed** once they finish. When you follow up on a finished Background Agent Job and the Agent continues in a new run, Ankole folds the entire continuation chain onto one card so you track a single work item from start to finish.
- **Living routines** (**Cron**, **Automation**, and **Check back**) represent standing schedules, Applet triggers, and deferred reminders. Each rule corresponds to a single permanent card rather than creating a separate card for every trigger. While a Cron fire or Applet automation is executing, its card moves from **Scheduled** to **Running** (rolling up any child Background Agent Jobs or Workflows launched during that fire); when the run finishes cleanly, the same card returns to **Scheduled** with its updated **Last run** and **Next run** times.

### What each column shows

- **Scheduled**: Queued one-off Agent jobs waiting for a Worker slot, idle active or paused Cron schedules, healthy idle Page automations, and pending **Check back** timers.
- **Running**: Active runs and any item requiring your attention. Pod pins attention cards—such as an Agent job **Needs input** (`waiting_on_user`), a Cron schedule or Workflow whose latest run failed within the past 48 hours, or a Page automation that became **Unavailable**—at the top of **Running**, with healthy active executions listed directly beneath them.
- **Completed**: Finished one-off Agent jobs and Workflows, capped at your 120 most recent terminal runs.

Switch **Board view** to **By Agent** when you want to see each Agent's active, scheduled, and recently completed work grouped under that Agent, alongside a dedicated group for **Page automations**.

## Start a job or recurring Cron schedule

You can ask your personal assistant or an AI colleague to run background work or set up a schedule directly in **Chat**—any Background Agent Job, Workflow, Cron schedule, or check-back timer started from your conversations appears on **Jobs** automatically.

To dispatch work directly from the board without writing a chat prompt first, select **New Job** in the top-right corner (or pick one of the starter templates when the board is empty):

1. **One-off job**: Choose an **Agent** that has background execution enabled, enter a **Title** and **Instructions**, and pick **Result delivery**:
   - **Jobs board only (no chat room)** runs the Background Agent Job directly on the Agent's Worker (`pod_job:<request_id>`) and keeps the entire run inside **Jobs** without opening a conversation in **Chat**.
   - Selecting an existing conversation links the run to that room so the Agent posts its final summary back to the conversation when finished.
2. **Recurring Cron**: Choose an **Agent**, enter a **Title** and **Instructions**, pick a preset schedule (such as **Every weekday at 09:00**) or enter a **Custom Cron expression** (`5` fields) and **Time zone**, and choose a delivery room (or **Agent's direct room**). Keep **Notify only when attention is needed** enabled when routine healthy runs should stay quiet in **Chat** and surface notifications only if the Agent encounters an anomaly or needs a decision. Enable **Trigger first run immediately** to launch the first run right away alongside the recurring schedule.

### Programmatic API

Scripts and tools authenticated as a Pod member can read and manage the board through `/api/v2/pod/jobs` (sending JSON:API action payloads under `{"data": ...}`):

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/v2/pod/jobs/summary` | Read `scheduledCount`, `runningCount`, and `attentionCount` |
| `GET` | `/api/v2/pod/jobs` | List visible board `items` and callable `agents` |
| `POST` | `/api/v2/pod/jobs` | Create a `one_off` job or `cron` schedule (`mode`, `agentUID`, `title`, `task`, `requestID`, optional `conversationID`, `repeat`, `quietSuccess`, `runNow`) |
| `GET` | `/api/v2/pod/jobs/routines/:kind/:raw_id` | Inspect instructions, delegated child executions, and run history for a `cron`, `automation_job`, or `checkback` card |
| `PATCH` | `/api/v2/pod/jobs/routines/:kind/:raw_id` | Control a routine you created (`pause`, `resume`, `run`, or `remove` for `cron`; `cancel` for `checkback`) |
| `GET` | `/api/v2/pod/jobs/executions/:kind/:run_id` | Read the live plan, tool steps, and output log of a `background_agent_job` or `workflow` |
| `POST` | `/api/v2/pod/jobs/executions/:kind/:run_id/stop` | Stop a queued or running `background_agent_job` or `workflow` |
| `POST` | `/api/v2/pod/jobs/executions/background_agent_job/:run_id/messages` | Answer a question, steer a running job, or continue a finished job (`requestID`, `text`) |

## Inspect, steer, and control runs

Select any card to open its inspector panel beside the board (or share its direct `/jobs?item=<id>` link with a teammate who has access to the same room or Page):

- **Agent jobs and Workflows** open the live execution inspector showing the Agent's plan, step-by-step tool calls, and output summary. When a Background Agent Job asks a question (`Needs input`), is actively running, or has finished in a workspace session, type a reply at the bottom of the inspector to answer, steer, or continue the work, or select **Stop** to cancel a live run. If the run belongs to a conversation, **Open in Chat** jumps straight to that room.
- **Cron schedules, Check backs, and Page automations** open the routine inspector with **Next run**, **Last run**, standing **Instructions**, **Delegated executions** (which you can click to inspect full step logs), and **Run history**. For schedules and check-backs that run under your authority, use **Run now**, **Pause**, **Resume**, **Remove**, or **Cancel** directly from the header; for Page automations, select **Open Applet** to open the owning Page.

## Visibility

Every member's **Jobs** board reflects their own permissions in the Pod:

- Standalone jobs (`Jobs board only`) are private to the member who started them.
- Jobs, Workflows, Cron schedules, and check-backs attached to a conversation in your **Chat** list are visible to the members of that conversation; Page comment threads stay on their Page rather than appearing on **Jobs**. Only the member who created a Cron schedule or check-back can pause, resume, trigger, or delete it.
- **Page automations** include active Applet Automation Jobs on Pages you can view, while another member's personal (`human`-authorized) Applet automation stays visible only to its owner.
