defmodule Ankole.Pod.JobsBoardTest do
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query
  import AnkoleWeb.PodAPI

  alias Ankole.{AutomationJobs, BackgroundAgentJobs, Repo, Schedule, Workflow}
  alias Ankole.BackgroundAgentJobs.Schemas.Job, as: AgentJob
  alias Ankole.BackgroundAgentJobs.Schemas.{Turn, TurnItem}
  alias Ankole.Conversations.Conversation
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.Signals.Signal
  alias Ankole.Workflow.Schemas.Run, as: WorkflowRun

  @moduletag host: :pod

  setup %{conn: conn} do
    {conn, uid} = console_conn_with_principal(conn)
    agent = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: uid}).principal
    Ankole.ConversationsFixtures.grant_chat(uid, agent.uid)
    %{conn: conn, uid: uid, agent: agent}
  end

  test "standalone one-off jobs run without creating chat rooms, steer, respawn as one folded chain card, and exclude reflection jobs",
       ctx do
    room_count_before = Repo.aggregate(Conversation, :count)

    created =
      api_response(
        api_post(ctx.conn, "/api/v2/pod/jobs", %{
          requestID: Ecto.UUID.generate(),
          mode: "one_off",
          agentUID: ctx.agent.uid,
          title: "Audit quarterly billing CSVs",
          task: "Reconcile invoice totals and save a report page."
        }),
        200
      )

    assert created["cardType"] == "one_off"
    assert created["kind"] == "background_agent_job"
    assert created["column"] == "scheduled"
    assert created["status"] == "queued"
    assert created["title"] == "Audit quarterly billing CSVs"
    assert is_nil(created["conversationID"])
    assert created["chainLength"] == 1
    assert Repo.aggregate(Conversation, :count) == room_count_before

    job_id = String.to_integer(created["rawID"])
    job = BackgroundAgentJobs.get_job(job_id)
    assert String.starts_with?(job.owner_session_id, "pod_job:")
    assert job.reply_route == %{}

    summary1 = api_response(api_get(ctx.conn, "/api/v2/pod/jobs/summary"), 200)
    assert summary1 == %{"scheduledCount" => 1, "runningCount" => 0, "attentionCount" => 0}

    # Internal skill-lesson reflection jobs never leak onto the user's Jobs board or summary.
    assert {:ok, %{job: _reflection}} =
             Ankole.SessionsCase.create_job_with_stub_driver(%{
               "source_signal_id" => Ankole.WorkFixtures.service_source(ctx.agent.uid).id,
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => "pod_job:#{Ecto.UUID.generate()}",
               "source_tool_call_id" => "reflection-1",
               "title" => "Internal reflection",
               "task" => "Reflect on skill lessons.",
               "metadata" => %{"skill_lesson_reflection" => true}
             })

    assert api_response(api_get(ctx.conn, "/api/v2/pod/jobs/summary"), 200) == %{
             "scheduledCount" => 1,
             "runningCount" => 0,
             "attentionCount" => 0
           }

    claim_and_start_standalone_job!(job, ctx.agent.uid)

    board_running = api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)
    assert [running_card] = board_running["items"]
    assert running_card["id"] == created["id"]
    assert running_card["column"] == "running"
    assert running_card["status"] == "running"
    assert running_card["attention"] == false

    assert api_response(api_get(ctx.conn, "/api/v2/pod/jobs/summary"), 200) == %{
             "scheduledCount" => 0,
             "runningCount" => 1,
             "attentionCount" => 0
           }

    # Waiting on user pins the card as attention in the running column.
    record_waiting_turn!(job, "standalone-thread")

    assert {:ok, _} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, ctx.agent.uid, %{
               "status" => "waiting_on_user",
               "runtime_thread_id" => "standalone-thread",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    board_waiting = api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)
    assert [waiting_card] = board_waiting["items"]
    assert waiting_card["column"] == "running"
    assert waiting_card["attention"] == true
    assert waiting_card["attentionReason"] == "waiting_on_user"

    assert api_response(api_get(ctx.conn, "/api/v2/pod/jobs/summary"), 200) == %{
             "scheduledCount" => 0,
             "runningCount" => 1,
             "attentionCount" => 1
           }

    # Steer the job directly through the /jobs execution endpoint without any chat room.
    steered =
      api_response(
        api_post(
          ctx.conn,
          "/api/v2/pod/jobs/executions/#{job.id}/messages",
          %{requestID: Ecto.UUID.generate(), text: "Use USD for converted totals."}
        ),
        200
      )

    assert steered == %{
             "runID" => to_string(job.id),
             "status" => "waiting_on_user",
             "respawned" => false
           }

    # Stop the job directly from /jobs; it auto-lands in Completed.
    stopped =
      api_response(
        api_post(
          ctx.conn,
          "/api/v2/pod/jobs/executions/background_agent_job/#{job.id}/stop",
          %{}
        ),
        200
      )

    assert stopped == %{"runID" => to_string(job.id), "status" => "stopped"}

    board_completed = api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)
    assert [completed_card] = board_completed["items"]
    assert completed_card["column"] == "completed"
    assert completed_card["status"] == "stopped"
    assert completed_card["canMessage"] == true

    # Respawn a follow-up from the completed standalone job; the continuation chain folds into 1 card!
    respawned =
      api_response(
        api_post(
          ctx.conn,
          "/api/v2/pod/jobs/executions/#{job.id}/messages",
          %{requestID: Ecto.UUID.generate(), text: "Now export the reconciliation summary."}
        ),
        200
      )

    assert respawned["respawned"] == true
    followup_id = respawned["runID"]
    refute followup_id == to_string(job.id)

    board_folded = api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)
    assert [folded_card] = board_folded["items"]
    assert folded_card["rawID"] == followup_id
    assert folded_card["chainLength"] == 2
    assert folded_card["column"] == "scheduled"

    detail =
      api_response(
        api_get(ctx.conn, "/api/v2/pod/jobs/executions/background_agent_job/#{followup_id}"),
        200
      )

    assert detail["continuedFromJobID"] == to_string(job.id)
    assert Repo.aggregate(Conversation, :count) == room_count_before
  end

  test "room-linked one-off jobs carry conversation context and cron schedules flow as a single living routine card",
       ctx do
    room = create_room!(ctx.uid, ctx.agent.uid)

    linked =
      api_response(
        api_post(ctx.conn, "/api/v2/pod/jobs", %{
          requestID: Ecto.UUID.generate(),
          mode: "one_off",
          agentUID: ctx.agent.uid,
          conversationID: room.conversation.id,
          title: "Draft weekly digest",
          task: "Summarize room highlights."
        }),
        200
      )

    assert linked["conversationID"] == room.conversation.id

    # Creating a Cron schedule without explicit conversationID reuses the colleague's canonical DM
    # without posting messages, and stays a single Living Routine card across triggers.
    cron_card =
      api_response(
        api_post(ctx.conn, "/api/v2/pod/jobs", %{
          requestID: Ecto.UUID.generate(),
          mode: "cron",
          agentUID: ctx.agent.uid,
          title: "Morning competitor scan",
          task: "Check competitor changelogs and flag breaking updates.",
          repeat: %{expression: "0 9 * * 1-5", timezone: "Asia/Shanghai"}
        }),
        200
      )

    cron_id = cron_card["rawID"]
    assert cron_card["id"] == "cron:#{cron_id}"
    assert cron_card["cardType"] == "routine"
    assert cron_card["kind"] == "cron"
    assert cron_card["column"] == "scheduled"
    assert cron_card["status"] == "active"
    assert cron_card["triggerSummary"] == "0 9 * * 1-5"
    assert is_binary(cron_card["conversationID"])

    dm_detail =
      api_response(
        api_get(ctx.conn, "/api/v2/pod/conversations/#{cron_card["conversationID"]}"),
        200
      )

    assert dm_detail["messages"] == []

    # Pause & Resume keep the single routine card in Scheduled.
    assert %{"action" => "pause"} =
             api_response(
               api_patch(ctx.conn, "/api/v2/pod/jobs/routines/cron/#{cron_id}", %{
                 action: "pause"
               }),
               200
             )

    paused_detail =
      api_response(api_get(ctx.conn, "/api/v2/pod/jobs/routines/cron/#{cron_id}"), 200)

    assert paused_detail["item"]["column"] == "scheduled"
    assert paused_detail["item"]["status"] == "paused"

    assert paused_detail["instructions"] ==
             "Check competitor changelogs and flag breaking updates."

    assert %{"action" => "resume"} =
             api_response(
               api_patch(ctx.conn, "/api/v2/pod/jobs/routines/cron/#{cron_id}", %{
                 action: "resume"
               }),
               200
             )

    # Triggering "run" creates a pending cron_fire event, sliding the SAME single card to Running!
    assert %{"action" => "run"} =
             api_response(
               api_patch(ctx.conn, "/api/v2/pod/jobs/routines/cron/#{cron_id}", %{action: "run"}),
               200
             )

    board_during_fire = api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)["items"]
    cron_cards = Enum.filter(board_during_fire, &(&1["kind"] == "cron"))
    assert [running_cron] = cron_cards
    assert running_cron["id"] == "cron:#{cron_id}"
    assert running_cron["column"] == "running"
    assert running_cron["attention"] == false

    # Mark the fire event fired and spawn a child BackgroundAgentJob on `cron:<cron_id>`:
    # child job rolls into the Cron routine card rather than spawning a second board card!
    [fire_event] =
      Repo.all(
        from e in ScheduledEvent,
          where: e.cron_schedule_id == ^cron_id and e.kind == "cron_fire"
      )

    now = DateTime.utc_now(:microsecond)

    Repo.update_all(
      from(e in ScheduledEvent, where: e.id == ^fire_event.id),
      set: [status: :fired, fired_at: now]
    )

    assert {:ok, %{job: child_job}} =
             Ankole.SessionsCase.create_job_with_stub_driver(%{
               "source_signal_id" => Ankole.WorkFixtures.service_source(ctx.agent.uid).id,
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => Schedule.Cron.execution_session_id(cron_id),
               "source_tool_call_id" => "cron-child-1",
               "title" => "Scan run #1",
               "task" => "Execute scan.",
               "reply_route" => %{"conversation_id" => cron_card["conversationID"]}
             })

    claim_and_start_standalone_job!(child_job, ctx.agent.uid, "cron-child-thread")
    record_waiting_turn!(child_job, "cron-child-thread")

    assert {:ok, _} =
             BackgroundAgentJobs.commit_status_with_wakeup(child_job.id, ctx.agent.uid, %{
               "status" => "waiting_on_user",
               "runtime_thread_id" => "cron-child-thread",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    board_with_child = api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)["items"]
    refute Enum.any?(board_with_child, &(&1["id"] == "job:#{child_job.id}"))
    cron_waiting = Enum.find(board_with_child, &(&1["id"] == "cron:#{cron_id}"))
    assert cron_waiting["column"] == "running"
    assert cron_waiting["attention"] == true
    assert cron_waiting["attentionReason"] == "waiting_on_user"
    assert cron_waiting["activeExecutionID"] == to_string(child_job.id)

    routine_detail =
      api_response(api_get(ctx.conn, "/api/v2/pod/jobs/routines/cron/#{cron_id}"), 200)

    assert length(routine_detail["runs"]) == 1
    assert [child_exec] = routine_detail["childExecutions"]
    assert child_exec["id"] == to_string(child_job.id)

    # Once the child job succeeds and the Cron session finishes processing its wakeup,
    # the SAME Cron card slides back to Scheduled (never Completed!).
    cron_session_id = Schedule.Cron.execution_session_id(cron_id)

    assert {:ok, _} =
             BackgroundAgentJobs.request_complete(child_job.id, %{
               "agent_uid" => ctx.agent.uid,
               "result_summary" => "All clean."
             })

    # While the wakeup signal on `cron:<id>` is still queued, the Cron card remains Running.
    assert (api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)["items"]
            |> Enum.find(&(&1["id"] == "cron:#{cron_id}")))["column"] == "running"

    Repo.update_all(
      from(s in Signal, where: s.session_id == ^cron_session_id),
      set: [status: :completed, completed_at: DateTime.utc_now(:microsecond)]
    )

    board_after_child = api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)["items"]
    cron_back = Enum.find(board_after_child, &(&1["id"] == "cron:#{cron_id}"))
    assert cron_back["column"] == "scheduled"
    assert cron_back["attention"] == false

    # Removing the Cron schedule removes its card from the board.
    assert %{"action" => "remove"} =
             api_response(
               api_patch(ctx.conn, "/api/v2/pod/jobs/routines/cron/#{cron_id}", %{
                 action: "remove"
               }),
               200
             )

    board_after_remove = api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)["items"]
    refute Enum.any?(board_after_remove, &(&1["id"] == "cron:#{cron_id}"))
  end

  test "workflows, checkbacks, and page automation jobs project accurately and enforce member isolation",
       ctx do
    room = create_room!(ctx.uid, ctx.agent.uid)
    source = Repo.get_by!(Signal, message_id: hd(room.messages).id)

    # 1. Workflow run: running -> fresh failed (pinned attention in running) -> aged failed (completed)
    assert {:ok, %{run: wf}} =
             Workflow.create_with_dispatch(%{
               "source_signal_id" => source.id,
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => source.session_id,
               "source_tool_call_id" => "wf-board-1",
               "reply_route" => %{"conversation_id" => room.conversation.id},
               "title" => "Parallel contract review",
               "script" => "return null;",
               "concurrency" => 2,
               "max_agent_calls" => 4
             })

    Ankole.SessionsCase.stub_workflow_drivers(wf)

    items1 = api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)["items"]
    wf_card = Enum.find(items1, &(&1["id"] == "workflow:#{wf.id}"))
    assert wf_card["column"] == "running"
    assert wf_card["stoppable"] == true

    wf_exec =
      api_response(
        api_get(ctx.conn, "/api/v2/pod/jobs/executions/workflow/#{wf.id}"),
        200
      )

    assert wf_exec["title"] == "Parallel contract review"

    # Fresh failure stays in running with attention: true; older than 48h lands in completed.
    now = DateTime.utc_now(:microsecond)

    Repo.update_all(
      from(w in WorkflowRun, where: w.id == ^wf.id),
      set: [status: :failed, error: %{"message" => "Step timeout"}, completed_at: now]
    )

    wf_failed_fresh =
      api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)["items"]
      |> Enum.find(&(&1["id"] == "workflow:#{wf.id}"))

    assert wf_failed_fresh["column"] == "running"
    assert wf_failed_fresh["attention"] == true

    three_days_ago = DateTime.add(now, -72 * 3_600, :second)

    Repo.update_all(
      from(w in WorkflowRun, where: w.id == ^wf.id),
      set: [completed_at: three_days_ago, updated_at: three_days_ago]
    )

    wf_failed_old =
      api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)["items"]
      |> Enum.find(&(&1["id"] == "workflow:#{wf.id}"))

    assert wf_failed_old["column"] == "completed"
    assert wf_failed_old["attention"] == false

    # 2. Checkback routine card: shows reason title in Scheduled and supports cancel.
    due_iso = DateTime.add(now, 3_600, :second) |> DateTime.to_iso8601()

    assert {:ok, %{scheduled_event: checkback}} =
             Schedule.create_check_back_later(%{
               "source_signal_id" => source.id,
               "agent_uid" => ctx.agent.uid,
               "session_id" => source.session_id,
               "conversation_id" => room.conversation.id,
               "tool_call_id" => "cb-1",
               "idempotency_key" => "cb-key-1",
               "reason" => "Verify vendor webhook delivery",
               "check" => "Confirm 200 OK in delivery logs.",
               "schedule" => %{"kind" => "at", "at" => due_iso, "timezone" => "UTC"}
             })

    cb_card =
      api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)["items"]
      |> Enum.find(&(&1["id"] == "checkback:#{checkback.id}"))

    assert cb_card["column"] == "scheduled"
    assert cb_card["title"] == "Verify vendor webhook delivery"
    assert cb_card["manageable"] == true

    cb_detail =
      api_response(
        api_get(ctx.conn, "/api/v2/pod/jobs/routines/checkback/#{checkback.id}"),
        200
      )

    assert cb_detail["instructions"] == "Confirm 200 OK in delivery logs."

    assert %{"action" => "cancel"} =
             api_response(
               api_patch(ctx.conn, "/api/v2/pod/jobs/routines/checkback/#{checkback.id}", %{
                 action: "cancel"
               }),
               200
             )

    refute api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)["items"]
           |> Enum.any?(&(&1["id"] == "checkback:#{checkback.id}"))

    # 3. Page AutomationJob living card: scheduled -> running (live run) -> attention (failed run).
    auto_job =
      Ankole.WorkFixtures.applet_job(ctx.uid, %{
        label: "Sync CRM leads",
        authorization_kind: "human"
      })

    auto_card_idle =
      api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)["items"]
      |> Enum.find(&(&1["id"] == "automation:#{auto_job.id}"))

    assert auto_card_idle["column"] == "scheduled"
    assert auto_card_idle["title"] == "Sync CRM leads"
    assert auto_card_idle["pageID"] == auto_job.page_id

    assert {:ok, %{automation_job_run: auto_run}} =
             Repo.transact_top_level(fn ->
               Ankole.WorkFixtures.dispatch_job_in_tx(auto_job, %{
                 "id" => "webhook-1",
                 "type" => "manual",
                 "data" => %{}
               })
             end)

    auto_card_live =
      api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)["items"]
      |> Enum.find(&(&1["id"] == "automation:#{auto_job.id}"))

    assert auto_card_live["column"] == "running"
    assert auto_card_live["attention"] == false

    assert {:ok, %{run: started_run}} = AutomationJobs.start_applet_attempt(auto_run.id, 0)

    assert {:ok, _} =
             AutomationJobs.finish_attempt(started_run.id, started_run.attempt_id, %{
               status: "failed",
               error: "Upstream CRM 502"
             })

    auto_card_failed =
      api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)["items"]
      |> Enum.find(&(&1["id"] == "automation:#{auto_job.id}"))

    assert auto_card_failed["column"] == "running"
    assert auto_card_failed["attention"] == true
    assert auto_card_failed["attentionReason"] == "failed"

    auto_detail =
      api_response(
        api_get(ctx.conn, "/api/v2/pod/jobs/routines/automation_job/#{auto_job.id}"),
        200
      )

    assert [run_row] = auto_detail["runs"]
    assert run_row["status"] == "failed"
    assert run_row["error"] =~ "Upstream CRM 502"

    # 4. Cross-user isolation: an uninvited member sees zero items and cannot read or control any of them.
    outsider = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Outsider"}).principal
    outsider_conn = pod_conn_for_uid(pod_conn(build_conn(), ctx.tenant), outsider.uid)

    outsider_board = api_response(api_get(outsider_conn, "/api/v2/pod/jobs"), 200)
    assert outsider_board["items"] == []

    assert api_response(api_get(outsider_conn, "/api/v2/pod/jobs/summary"), 200) == %{
             "scheduledCount" => 0,
             "runningCount" => 0,
             "attentionCount" => 0
           }

    assert api_error(
             api_get(outsider_conn, "/api/v2/pod/jobs/executions/workflow/#{wf.id}"),
             404
           )["code"] == "execution_not_found"

    assert api_error(
             api_get(
               outsider_conn,
               "/api/v2/pod/jobs/routines/automation_job/#{auto_job.id}"
             ),
             404
           )["code"] == "job_not_found"
  end

  test "completed limit applies per member visibility after folding continuations and cron runs, without evicting fresh failures",
       ctx do
    t0 = DateTime.add(DateTime.utc_now(:microsecond), -600, :second)

    # Member A creates a fresh failed job (< 48h -> Running + attention), a succeeded job (Completed),
    # and a Cron schedule with a completed child execution.
    failed_card =
      api_response(
        api_post(ctx.conn, "/api/v2/pod/jobs", %{
          requestID: Ecto.UUID.generate(),
          mode: "one_off",
          agentUID: ctx.agent.uid,
          title: "Member A fresh failure",
          task: "Run brittle import."
        }),
        200
      )

    {failed_job_id, ""} = Integer.parse(failed_card["rawID"])

    Repo.update_all(
      from(j in AgentJob, where: j.id == ^failed_job_id),
      set: [
        status: :failed,
        error: %{"summary" => "Import schema mismatch"},
        completed_at: t0,
        updated_at: t0
      ]
    )

    done_card =
      api_response(
        api_post(ctx.conn, "/api/v2/pod/jobs", %{
          requestID: Ecto.UUID.generate(),
          mode: "one_off",
          agentUID: ctx.agent.uid,
          title: "Member A completed job",
          task: "Generate monthly rollup."
        }),
        200
      )

    {done_job_id, ""} = Integer.parse(done_card["rawID"])

    Repo.update_all(
      from(j in AgentJob, where: j.id == ^done_job_id),
      set: [
        status: :succeeded,
        result: %{"summary" => "Rollup ready"},
        completed_at: t0,
        updated_at: t0
      ]
    )

    cron_card =
      api_response(
        api_post(ctx.conn, "/api/v2/pod/jobs", %{
          requestID: Ecto.UUID.generate(),
          mode: "cron",
          agentUID: ctx.agent.uid,
          title: "Member A hourly pulse",
          task: "Check queue lag.",
          repeat: %{expression: "0 * * * *", timezone: "UTC"}
        }),
        200
      )

    cron_id = cron_card["rawID"]

    assert {:ok, %{job: cron_child}} =
             Ankole.SessionsCase.create_job_with_stub_driver(%{
               "source_signal_id" => Ankole.WorkFixtures.service_source(ctx.agent.uid).id,
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => Schedule.Cron.execution_session_id(cron_id),
               "source_tool_call_id" => "member-a-cron-child",
               "title" => "Pulse run",
               "task" => "Check queue lag.",
               "reply_route" => %{"conversation_id" => cron_card["conversationID"]}
             })

    Repo.update_all(
      from(j in AgentJob, where: j.id == ^cron_child.id),
      set: [
        status: :succeeded,
        result: %{"summary" => "Lag normal"},
        completed_at: t0,
        updated_at: t0
      ]
    )

    # Noisy neighbor finishes 250 terminal jobs and 130 terminal workflows AFTER Member A's runs,
    # plus 1 fresh failure of their own before those 380 completions.
    neighbor =
      Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Noisy Neighbor"}).principal

    neighbor_conn = pod_conn_for_uid(pod_conn(build_conn(), ctx.tenant), neighbor.uid)
    neighbor_room = create_room!(neighbor.uid, ctx.agent.uid)
    neighbor_source = Repo.get_by!(Signal, message_id: hd(neighbor_room.messages).id)

    neighbor_failed_at = DateTime.add(t0, 1, :second)

    neighbor_failed_card =
      api_response(
        api_post(neighbor_conn, "/api/v2/pod/jobs", %{
          requestID: Ecto.UUID.generate(),
          mode: "one_off",
          agentUID: ctx.agent.uid,
          conversationID: neighbor_room.conversation.id,
          title: "Neighbor fresh failure",
          task: "Fail first"
        }),
        200
      )

    {neighbor_failed_id, ""} = Integer.parse(neighbor_failed_card["rawID"])

    Repo.update_all(
      from(j in AgentJob, where: j.id == ^neighbor_failed_id),
      set: [
        status: :failed,
        error: %{"summary" => "Neighbor failure"},
        completed_at: neighbor_failed_at,
        updated_at: neighbor_failed_at
      ]
    )

    seed_job = BackgroundAgentJobs.get_job(neighbor_failed_id)

    job_rows =
      for idx <- 1..250 do
        ts = DateTime.add(t0, 10 + idx, :second)
        row_id = seed_job.id + 10_000 + idx

        %{
          id: row_id,
          tenant_id: seed_job.tenant_id,
          authorization_kind: seed_job.authorization_kind,
          human_uid: seed_job.human_uid,
          human_access_version: seed_job.human_access_version,
          agent_uid: seed_job.agent_uid,
          owner_session_id: neighbor_source.session_id,
          source_signal_id: neighbor_source.id,
          source_tool_call_id: "neighbor-job-#{idx}",
          workspace_owner_job_id: row_id,
          title: "Neighbor job #{idx}",
          task: "Batch #{idx}",
          reply_route: %{"conversation_id" => neighbor_room.conversation.id},
          model_profile: "heavy",
          status: :succeeded,
          attempts: 1,
          execution_failures: 0,
          queued_at: ts,
          started_at: ts,
          completed_at: ts,
          result: %{"summary" => "Done #{idx}"},
          error: %{},
          metadata: %{},
          inserted_at: ts,
          updated_at: ts
        }
      end

    {250, _} = Repo.insert_all(AgentJob, job_rows)

    wf_rows =
      for idx <- 1..130 do
        ts = DateTime.add(t0, 300 + idx, :second)
        row_id = seed_job.id + 20_000 + idx

        %{
          id: row_id,
          tenant_id: seed_job.tenant_id,
          authorization_kind: seed_job.authorization_kind,
          human_uid: seed_job.human_uid,
          human_access_version: seed_job.human_access_version,
          agent_uid: seed_job.agent_uid,
          owner_session_id: neighbor_source.session_id,
          source_signal_id: neighbor_source.id,
          source_tool_call_id: "neighbor-wf-#{idx}",
          reply_route: %{"conversation_id" => neighbor_room.conversation.id},
          title: "Neighbor wf #{idx}",
          script: "return null;",
          args: %{},
          concurrency: 1,
          max_agent_calls: 1,
          memo_bytes: 0,
          status: :completed,
          result_text: "OK #{idx}",
          error: %{},
          completed_at: ts,
          inserted_at: ts,
          updated_at: ts
        }
      end

    {130, _} = Repo.insert_all(WorkflowRun, wf_rows)

    # Member A's board is completely unaffected by Neighbor's 380 newer terminal runs,
    # and matches Member A's sidebar summary counts 100%.
    member_a_items = api_response(api_get(ctx.conn, "/api/v2/pod/jobs"), 200)["items"]
    member_a_summary = api_response(api_get(ctx.conn, "/api/v2/pod/jobs/summary"), 200)

    assert Enum.any?(
             member_a_items,
             &(&1["id"] == "job:#{failed_job_id}" and &1["column"] == "running" and
                 &1["attention"] == true)
           )

    assert Enum.any?(
             member_a_items,
             &(&1["id"] == "job:#{done_job_id}" and &1["column"] == "completed")
           )

    projected_cron = Enum.find(member_a_items, &(&1["id"] == "cron:#{cron_id}"))
    assert projected_cron["column"] == "scheduled"
    assert projected_cron["activeExecutionID"] == to_string(cron_child.id)

    assert member_a_summary == %{
             "scheduledCount" => Enum.count(member_a_items, &(&1["column"] == "scheduled")),
             "runningCount" => Enum.count(member_a_items, &(&1["column"] == "running")),
             "attentionCount" => Enum.count(member_a_items, & &1["attention"])
           }

    # Neighbor's own Completed column is capped at 120, while Neighbor's older fresh failure stays in Running!
    neighbor_items = api_response(api_get(neighbor_conn, "/api/v2/pod/jobs"), 200)["items"]
    neighbor_summary = api_response(api_get(neighbor_conn, "/api/v2/pod/jobs/summary"), 200)

    assert Enum.count(neighbor_items, &(&1["column"] == "completed")) == 120

    assert Enum.any?(
             neighbor_items,
             &(&1["id"] == "job:#{neighbor_failed_id}" and &1["column"] == "running" and
                 &1["attention"] == true)
           )

    assert neighbor_summary == %{
             "scheduledCount" => Enum.count(neighbor_items, &(&1["column"] == "scheduled")),
             "runningCount" => Enum.count(neighbor_items, &(&1["column"] == "running")),
             "attentionCount" => Enum.count(neighbor_items, & &1["attention"])
           }
  end

  defp claim_and_start_standalone_job!(
         %AgentJob{} = job,
         agent_uid,
         thread_id \\ "standalone-thread"
       ) do
    spec = %{model_ref: %{"provider_id" => "test"}, request_context: %{}}

    assert {:ok, _} =
             Repo.transact_top_level(fn ->
               BackgroundAgentJobs.Lifecycle.claim_attempt_in_tx(
                 job.id,
                 agent_uid,
                 1,
                 spec,
                 10
               )
             end)

    assert {:ok, _} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent_uid, %{
               "status" => "running",
               "runtime_thread_id" => thread_id
             })
  end

  defp record_waiting_turn!(%AgentJob{} = job, thread_id) do
    now = DateTime.utc_now(:microsecond)

    {:ok, turn} =
      Repo.transact(fn _ ->
        Ankole.Ash.create(Turn, :record, %{
          job_id: job.id,
          attempt: 1,
          runtime_thread_id: thread_id,
          runtime_turn_id: "turn-#{Ecto.UUID.generate()}",
          kind: "agent",
          status: "interrupted",
          revision: 1,
          trajectory: %{"format" => "ankole_chatml", "version" => 1},
          progress: %{
            "completed_items" => 0,
            "tool_calls" => 1,
            "tools_used" => [%{"name" => "request_user_input", "calls" => 1}],
            "files_changed" => []
          },
          usage: nil,
          error: %{"code" => "request_user_input"},
          started_at: now,
          completed_at: now
        })
      end)

    {:ok, _} =
      Repo.transact(fn _ ->
        Ankole.Ash.create(TurnItem, :append, %{
          turn_id: turn.id,
          position: 0,
          revision: 1,
          item_key: "request-user-input",
          item: %{
            "type" => "dynamicToolCall",
            "id" => "request-user-input",
            "tool" => "request_user_input",
            "status" => "inProgress",
            "arguments" => ~s({"questions":[]})
          }
        })
      end)
  end

  defp create_room!(uid, agent_uid) do
    assert {:ok, room} =
             Ankole.ConversationsFixtures.create(uid, %{
               room_mode: :group,
               conversation_id: Ecto.UUID.generate(),
               message_id: Ecto.UUID.generate(),
               agent_uid: agent_uid,
               text: "Kick off work"
             })

    room
  end

  defp pod_conn_for_uid(base_conn, uid) do
    base_conn
    |> Plug.Test.init_test_session(%{})
    |> AnkoleWeb.Session.put_tenant_session(%{
      principal_uid: uid,
      provider_id: "lark-main",
      external_id: "external-#{uid}"
    })
    |> with_console_csrf()
    |> get(~p"/api/v2/browser/session")
    |> recycle_api()
  end
end
