defmodule Ankole.Sessions.ScheduleToolTest do
  use Ankole.SessionsCase
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Context
  alias Ankole.Sessions.ToolCatalog
  alias Ankole.Sessions.Tools
  alias Ankole.Schedule
  alias Ankole.Schedule.Schemas.ScheduledEvent

  setup do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    {:ok, %{signal: event}} =
      emit_entry(agent.uid, "bot", group_entry(%{text: "Arrange follow-up work", explicit: true}),
        now: @base_time
      )

    {:ok, run} = Admission.admit(event, event)
    {:ok, context} = Context.resolve(run.agent_uid, run.session_id)
    {tools, _} = ToolCatalog.for_run(%{run | context: context})

    {:ok, response} =
      start_response_run(%{subject_uid: run.agent_uid, conversation_id: run.conversation.id})

    %{run: %{run | context: context, tools: tools, model_response: response}}
  end

  test "minimal create keeps defaults, normalization and parameter idempotency", %{run: run} do
    args = checkback_args("  Review progress  ", "  Check the report  ")
    first = invoke(run, "check_back_later", args, "first")
    assert first.details["status"] == "scheduled"

    event =
      Repo.one!(from(e in ScheduledEvent, where: e.source_signal_id == ^run.signal_id))

    assert event.wake_payload["quiet_success"] == false
    assert event.wake_payload["context_summary"] == nil
    assert event.wake_payload["reason"] == "Review progress"
    assert event.wake_payload["check"] == "Check the report"
    repeated = invoke(run, "check_back_later", args, "second")
    assert repeated.details["status"] == "already_scheduled"
    assert Repo.aggregate(ScheduledEvent, :count) == 1

    spaced =
      invoke(
        run,
        "check_back_later",
        Map.put(checkback_args("r", "c"), "context_summary", "   "),
        "spaced"
      )

    refute spaced.is_error

    event =
      Repo.one!(
        from(e in ScheduledEvent,
          where: e.source_signal_id == ^run.signal_id and e.id != ^event.id
        )
      )

    assert event.wake_payload["context_summary"] == nil
  end

  test "list defaults to ten and get, update, cancel preserve the same checkback", %{run: run} do
    for index <- 1..12 do
      refute invoke(run, "check_back_later", checkback_args("r#{index}", "c"), "create-#{index}").is_error
    end

    listed = invoke(run, "check_back_later", %{"action" => "list"}, "list")
    assert length(listed.details["checkbacks"]) == 10

    assert length(
             invoke(run, "check_back_later", %{"action" => "list", "limit" => 3}, "short").details[
               "checkbacks"
             ]
           ) == 3

    id = hd(listed.details["checkbacks"])["checkback_id"]

    assert invoke(run, "check_back_later", %{"action" => "get", "checkback_id" => id}, "get").details[
             "checkback"
           ]["checkback_id"] == id

    updated =
      invoke(
        run,
        "check_back_later",
        %{"action" => "update", "checkback_id" => id, "reason" => "  Changed  "},
        "update"
      )

    assert updated.details["checkback"]["checkback_id"] == id
    assert updated.details["checkback"]["reason"] == "Changed"

    cancelled =
      invoke(run, "check_back_later", %{"action" => "cancel", "checkback_id" => id}, "cancel")

    assert cancelled.details["checkback"]["checkback_id"] == id
    assert cancelled.details["checkback"]["status"] == "cancelled"
    event = Repo.get!(ScheduledEvent, id)
    Repo.update!(Ecto.Changeset.change(event, session_id: "other-session"))

    rejected =
      invoke(run, "check_back_later", %{"action" => "get", "checkback_id" => id}, "foreign")

    assert rejected.is_error
    assert rejected.output =~ "No checkback with this checkback_id belongs to this conversation."
  end

  test "cron names resolve with whitespace and runs use default and explicit limits", %{run: run} do
    created = invoke(run, "cron", cron_args("daily"), "cron-add")
    assert created.details["status"] == "created"
    {:ok, rule} = Schedule.get_cron_schedule_by_name(run.agent_uid, run.session_id, "daily")

    for _ <- 1..28 do
      {:ok, current} = Schedule.get_cron_schedule(rule.id)

      assert {:ok, _} = Ankole.Schedule.fire_cron(rule.id, now: current.next_fire_at)
    end

    assert length(
             invoke(run, "cron", %{"action" => "runs", "name" => "  daily  "}, "runs").details[
               "runs"
             ]
           ) == 25

    assert length(
             invoke(
               run,
               "cron",
               %{"action" => "runs", "name" => " daily ", "limit" => 3},
               "few-runs"
             ).details["runs"]
           ) == 3

    for action <- ["get", "update", "pause", "resume", "run", "remove"] do
      args = %{"action" => action, "name" => "  daily  "}

      args =
        if action == "update",
          do: Map.put(args, "payload", %{"task" => "Updated instruction"}),
          else: args

      result = invoke(run, "cron", args, "#{action}-cron")
      refute result.is_error, inspect(result)
    end
  end

  test "automation cron add accepts absent payload and cron-origin get accepts absent name", %{
    run: run
  } do
    automation = Ankole.WorkFixtures.applet_job(run.agent_uid)

    args =
      cron_args("action") |> Map.delete("payload") |> Map.put("automation_job_id", automation.id)

    created = invoke(run, "cron", args, "action-cron")
    refute created.is_error, inspect(created)

    assert {:ok, rule} =
             Schedule.get_cron_schedule_by_name(run.agent_uid, run.session_id, "action")

    id = rule.id
    assert rule.payload == %{}
    origin = %{run | session_id: Schedule.cron_execution_session_id(id)}

    assert invoke(origin, "cron", %{"action" => "get"}, "origin-get").details["schedule"][
             "name"
           ] == "action"
  end

  test "check_back_later can deliver its default subscription to an Applet Action", %{run: run} do
    job = Ankole.WorkFixtures.applet_job(run.agent_uid)
    count = Repo.aggregate(Ankole.Signals.Signal, :count)

    args =
      checkback_args("Refresh data", "Run the deterministic refresh")
      |> Map.put("automation_job_id", job.id)

    response = invoke(run, "check_back_later", args, "applet-checkback")
    refute response.is_error, inspect(response)
    event = Repo.one!(from e in ScheduledEvent, where: e.source_signal_id == ^run.signal_id)

    assert {:ok, %{automation_job_run: action, signals: []}} =
             Schedule.fire_due_event(event.id, now: event.due_at)

    assert action.automation_job_id == job.id
    assert Repo.aggregate(Ankole.Signals.Signal, :count) == count

    assert :ok =
             Ankole.AutomationJobs.Jobs.ExecuteRun.run(%Oban.Job{
               args: %{"automation_job_run_id" => action.id},
               attempt: 1,
               max_attempts: 5
             })

    assert Ankole.AutomationJobs.get_run_record(action.id).status == :succeeded
  end

  test "an ordinary turn declares finish_scheduled but rejects the call without ending the turn",
       %{run: run} do
    assert run.kind == :main
    assert Enum.any?(run.tools, &(&1.name == "finish_scheduled"))

    result =
      invoke(run, "finish_scheduled", %{"outcome" => "reply", "reply" => "Done."}, "ordinary")

    assert result.is_error
    assert result.output =~ "finish_scheduled ends only a scheduled turn."
    refute Ankole.Sessions.ToolResult.ends_turn?(result)
  end

  test "an unknown checkback id or cron name names the lookup that finds it", %{run: run} do
    missing =
      invoke(
        run,
        "check_back_later",
        %{"action" => "get", "checkback_id" => 9_999_999},
        "missing-checkback"
      )

    assert missing.is_error
    assert missing.output =~ "No checkback with this checkback_id belongs to this conversation."

    unknown =
      invoke(run, "cron", %{"action" => "get", "name" => "no-such-schedule"}, "missing-cron")

    assert unknown.is_error
    assert unknown.output =~ "No cron schedule with this name belongs to this conversation."
  end

  defp invoke(run, name, args, id) do
    call = %{
      "type" => "function_call",
      "name" => name,
      "call_id" => id,
      "arguments" => Ankole.JSON.encode!(args)
    }

    assert {:ok, tool, normalized} = Tools.prepare(run, call)
    Tools.execute(run, call, tool, normalized)
  end

  defp checkback_args(reason, check),
    do: %{
      "action" => "create",
      "reason" => reason,
      "check" => check,
      "schedule" => %{"after" => %{"value" => 5, "unit" => "minute"}}
    }

  defp cron_args(name),
    do: %{
      "action" => "add",
      "name" => name,
      "schedule" => %{
        "kind" => "every",
        "every_ms" => 60_000,
        "anchor_at" => DateTime.to_iso8601(@base_time)
      },
      "payload" => %{"task" => "Review progress"}
    }
end
