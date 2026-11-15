# Jobs Board

Pod separates synchronous interaction from asynchronous execution along two explicit surfaces:

- **Chat (`Conversations`)** hosts interactive conversations and group rooms where Humans and Agents exchange messages in real time.
- **Jobs (`/jobs`)** presents a member-scoped Kanban projection over Ankole's durable background execution and scheduling subsystems (`Ankole.BackgroundAgentJobs`, `Ankole.Workflow`, `Ankole.Schedule`, and `Ankole.AutomationJobs`).

Because each execution and schedule subsystem owns its durable rows in PostgreSQL, the Jobs board introduces zero shadow tracking tables. Instead, `Ankole.Pod.JobsBoard` reads the caller's authorized jobs, workflows, recurring Cron schedules, check-back timers, and Page-owned Applet Automation Jobs directly and projects them into a unified three-column board (`scheduled`, `running`, `completed`).

## Ownership

| Module / Surface | Responsibility |
| --- | --- |
| `Ankole.Pod.JobsBoard` (`lib/ankole/pod/jobs_board.ex`) | Public entry points for summary counts, full board projection, job/schedule creation, routine inspection and control, and standalone execution inspection, steering, and stopping |
| `Ankole.Pod.JobsBoard.Queries` | Read-model projection, authorization filtering, continuation-chain folding, Cron child-execution rollup, column placement, and attention classification |
| `Ankole.Pod.JobsBoard.Operations` | Transactional creation of standalone or room-delivered `BackgroundAgentJob`s and `CronSchedule`s, routine actions (`pause`, `resume`, `run`, `remove`, `cancel`), and execution steering/stopping |
| `Ankole.Pod.JobsBoard.Browser` | Typed Ash JSON:API resource mounting `/api/v2/pod/jobs*` |
| `app/webapps/pod/jobs-page.tsx` | Pod `/jobs` route (`By status` three-column Kanban, `By Agent` view, filters, empty-state starters), `JobCreateDialog`, and `JobsDetailPanel` |

## Card Ontology: One-Off Runs vs. Living Routines

`Ankole.Pod.JobsBoard.Queries` projects every visible item into one of two `cardType` shapes:

1. **One-off cards (`cardType: "one_off"`)** represent bounded asynchronous runs that start, execute, and settle into `completed`:
   - **`BackgroundAgentJob` (`id: "job:<id>"`)**: When a human steers a finished job into a continuation run (`continued_from_job_id`), `Queries` folds the entire continuation chain onto a single card keyed by the latest head job and exposes `chainLength` so the board shows one logical work item rather than fragmented retries. Internal reflection jobs (`metadata["skill_lesson_reflection"] == true`) and jobs owned directly by a `cron:<schedule_id>` session stay off the top-level one-off list.
   - **`Workflow.Run` (`id: "workflow:<id>"`)**: Top-level programmatic workflow runs outside `cron:<schedule_id>` sessions.

2. **Living Routine cards (`cardType: "routine"`)** represent standing rules and timers where one rule always corresponds to strictly one card on the board:
   - **Agent `CronSchedule` (`id: "cron:<id>"`)**: Active and paused Cron schedules (`owner_job_id == nil`). When a Cron fire runs its session turn or delegates child `BackgroundAgentJob`s and `Workflow.Run`s under `owner_session_id = "cron:<id>"`, `Queries` rolls that live state into the parent Cron card, moves the card to `running`, and lists the delegated runs inside the Cron card's inspector (`childExecutions`). Once the fire and any completion wakeup Signal finish cleanly, the same card returns to `scheduled` with updated `lastRunAt` and `nextRunAt` timestamps rather than spawning per-fire cards in `completed`.
   - **Page `AutomationJob` (`id: "automation:<id>"`)**: Active Page-owned Applet Automation Jobs visible to the member through `AutomationJobs.Applet.list/2`, summarizing Job-owned schedules, webhooks, live queued/running attempts, `unavailable_reason`, and recent run status.
   - **Check-back `ScheduledEvent` (`id: "checkback:<id>"`)**: Pending (`scheduled`) or recently failed (`failed` within 48 hours) `check_back_later` timers using `wake_payload["reason"]` as the card title.

## Column Placement and Attention Semantics

Every projected card lands in one of three columns:

- **`scheduled`**: Queued one-off `BackgroundAgentJob`s, idle active or paused `CronSchedule`s, idle healthy `AutomationJob`s, and pending `check_back_later` `ScheduledEvent`s.
- **`running`**: Active executions and any item that requires human attention (`attention == true`). Within the `running` column, Pod pins `attention == true` cards at the top:
  - `BackgroundAgentJob` in `waiting_on_user` or failed within the past 48 hours.
  - `Workflow.Run` failed within the past 48 hours.
  - `CronSchedule` whose delegated child job is `waiting_on_user` or whose latest fire failed.
  - `AutomationJob` carrying a non-nil `unavailable_reason` or whose latest run failed.
  - `ScheduledEvent` (`check_back_later`) in `failed`.
  Active healthy runs (`BackgroundAgentJob` in `running`, `Workflow.Run` in `running`, `CronSchedule` with an active `cron:<id>` session or pending manual fire, and `AutomationJob` with queued or running runs) follow directly below the pinned attention cards.
- **`completed`**: Terminal one-off `BackgroundAgentJob` chains (`succeeded`, `stopped`, or `failed` older than 48 hours) and terminal `Workflow.Run`s, bounded to the 120 most recent items.

## Visibility and Authorization

`Ankole.Pod.JobsBoard` scopes every query and mutation to the authenticated Pod member (`actor.uid`):

- **Personal and standalone work**: A member sees standalone `pod_job:<request_id>` jobs where `requester_uid == actor.uid` (or `metadata["requester_uid"] == actor.uid`), Cron schedules and check-back events where `created_by_uid == actor.uid`, and runs owned by conversations in the member's Pod room list (personal assistant rooms, colleague DMs, and group rooms where the member participates, excluding Page comment threads and internal `agent_peer` sessions).
- **Page Automation Jobs**: `AutomationJobs.Applet.list/2` returns active Applet jobs on Pages the member can view in Pod, hiding another member's personal (`authorization_kind: "human"`) Applet jobs unless `owner_principal_uid == actor.uid`.
- **Management and execution controls**: Only the schedule creator (`created_by_uid == actor.uid`) receives `manageable: true` to pause, resume, run, or remove a `CronSchedule` or cancel a `check_back_later` event. Stopping or steering an execution checks that the execution is visible to the member through `Queries` (either directly on the board or as an ancestor/child execution of a visible chain or Cron routine) before invoking `BackgroundAgentJobs` or `Workflow`.

## Creating Jobs from `/jobs`

`POST /api/v2/pod/jobs` supports two creation modes for any active Agent the member can chat with (`Agents.callable_for_human/2`):

1. **`mode: "one_off"`** (requires `canRunBackgroundJob: true`, meaning the Agent has a configured Worker runtime or eligible personal Runner device):
   - When `conversationID` is omitted, `Operations` allocates a standalone session key `pod_job:<request_id>` (`Ankole.Sessions.Key.pod_job/1`) and calls `BackgroundAgentJobs.create_from_control_plane_in_tx/1` with `reply_route: %{}`. Ankole creates zero chat rooms; the job runs directly on the Agent's Worker and surfaces exclusively on `/jobs`.
   - When the member selects an existing `conversationID` that already includes the target Agent, Ankole links the job to that room's session (`conv:<conversation_id>:<agent_uid>`) with a Pod conversation `reply_route` so completion delivers back into that room.

2. **`mode: "cron"`**:
   - Validates the five-field Cron expression, IANA timezone, title, and standing `task` instructions.
   - Resolves the delivery room: if `conversationID` is provided, Ankole verifies the member's access and the Agent's participation; otherwise `Conversations.ensure_agent_delivery_room_in_tx/2` reuses the canonical colleague DM or a quiet personal-assistant room without posting a chat message.
   - Calls `Schedule.create_cron_schedule_in_tx/3` with `quiet_success` (default `true`, notifying the room only when attention or intervention is needed) and optional `run_now` (`Schedule.run_cron_schedule_now/2`).

## API Surface and Navigation

All Pod Jobs endpoints mount under `/api/v2/pod/jobs`:

- `GET /api/v2/pod/jobs/summary`: Lightweight counts (`scheduledCount`, `runningCount`, `attentionCount`) backing the permanently visible `Jobs` link in the Pod `Home` sidebar tab (directly above `Shared with me`). `runningCount` includes all items in the `running` column, including `waiting_on_user` and fresh-failure attention items.
- `GET /api/v2/pod/jobs`: Returns `{ items, agents }` for the `/jobs` board and the `New Job` dialog.
- `POST /api/v2/pod/jobs`: Creates a one-off `BackgroundAgentJob` or recurring `CronSchedule`.
- `GET /api/v2/pod/jobs/routines/:kind/:raw_id`: Returns full routine detail (`instructions`, `quietSuccess`, `unavailableReason`, `childExecutions`, and `runs`) for `cron`, `automation_job`, and `checkback` cards.
- `PATCH /api/v2/pod/jobs/routines/:kind/:raw_id`: Executes `pause`, `resume`, `run`, or `remove` on `cron` routines and `cancel` on `checkback` timers.
- `GET /api/v2/pod/jobs/executions/:kind/:run_id`, `POST /api/v2/pod/jobs/executions/:kind/:run_id/stop`, and `POST /api/v2/pod/jobs/executions/background_agent_job/:run_id/messages`: Streams cursor-paginated execution logs, stops live runs, and steers or continues `BackgroundAgentJob`s uniformly whether or not the execution belongs to a chat room.

`AnkoleWeb.PodURL` normalizes `/jobs` alongside `/settings`, `/me`, and `/connectors` on both FOSS and SaaS Pod hosts so direct navigation and shared `/jobs?item=…` links load the Pod SPA shell directly.

## Verification

- `app/control_plane/test/ankole/pod/jobs_board_test.exs` verifies standalone one-off jobs without chat rooms, internal reflection filtering, `waiting_on_user` attention pinning and summary counts, steering and respawn chain folding, room-linked jobs, Cron Living Routine lifecycle and child-job rollup, workflow failure aging, check-back cancellation, Page `AutomationJob` visibility, and cross-member isolation.
- `internals/control_plane/test/saas/browser_flow_test.exs` verifies direct SaaS Pod entry on `/jobs?item=…`.
- `app/webapps/pod/jobs-page.test.tsx` and `app/webapps/integration/pod-browser/jobs.spec.ts` verify the sidebar entry, three-column and per-Agent board layouts, `New Job` creation flow, Routine and Execution side-panel inspectors, and live run stopping.
