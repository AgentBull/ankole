defmodule AnkoleWeb.BackgroundActivityControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import Ecto.Query
  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures
  alias Ankole.{AutomationJobs, BackgroundAgentJobs, Repo, Workflow}
  alias Ankole.Workflow.Schemas.{AgentCall, Run}

  setup do
    Ankole.AppConfigure.Registry.clear_for_test()
    Ankole.AppConfigure.Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = Ankole.Setup.Config.delete_bootstrap_activation_code()
    :ok
  end

  test "actual cancelled definitions and revoked parents retain independently running children",
       %{conn: conn, tenant: tenant} do
    %{principal: human} = human_fixture()

    %{principal: agent} =
      Ankole.AIGatewayCase.background_agent_fixture(%{owner_principal_uid: human.uid})

    source = Ankole.WorkFixtures.service_source(agent.uid)
    {job, run} = automation_run(agent.uid, source)

    assert {:ok, _worker} =
             Ankole.SessionsCase.admit_worker("automation-test-#{agent.uid}", %{
               worker_id: agent.uid
             })

    assert {:ok, %{run: attempt}} = AutomationJobs.start_attempt(run.id)

    assert {:ok, %{status: :cancelled}} =
             AutomationJobs.cancel_job(agent.uid, source.session_id, job.id)

    assert {:ok, native} =
             Ankole.ConversationsFixtures.create(human.uid, %{
               conversation_id: Ecto.UUID.generate(),
               message_id: Ecto.UUID.generate(),
               agent_uid: agent.uid,
               text: "Start a workflow"
             })

    human_source = Repo.get_by!(Ankole.Signals.Signal, message_id: hd(native.messages).id)
    revoked = workflow(agent.uid, human_source, "Admitted before revocation")
    admitted = claimed_call(revoked)

    assert {:ok, _} =
             Repo.transact(fn ->
               Workflow.Lifecycle.stop_human_work_in_tx(
                 human.uid,
                 human.access_version + 1,
                 DateTime.utc_now(:microsecond)
               )

               {:ok, :revoked}
             end)

    assert Repo.get!(Run, revoked.id).status == :cancelled
    assert Repo.get!(AgentCall, admitted.id).status == :running

    sleeping_run = workflow(agent.uid, source, "Waiting for evidence")
    sleeping = claimed_call(sleeping_run)

    assert {:ok, %{job: delegated}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "source_signal_id" => source.id,
               "agent_uid" => agent.uid,
               "owner_session_id" => Workflow.task_session_id(sleeping.id),
               "source_tool_call_id" => "delegated-activity",
               "title" => "Gather evidence",
               "task" => "Check evidence",
               "reply_route" => %{"binding_name" => "bot"}
             })

    assert {:ok, %{call: sleeping}} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.sleep_task_in_tx(
                 sleeping.id,
                 agent.uid,
                 Workflow.task_session_id(sleeping.id),
                 %{
                   wake_after_ms: 3_600_000,
                   note: "Waiting for background job #{delegated.id}",
                   attention: true
                 }
               )
             end)

    cleanup = workflow(agent.uid, source, "Cleanup after cancellation")

    assert {:ok, %{run: %{cleanup_completed_at: nil}}} =
             Repo.transact(fn -> Workflow.Lifecycle.cancel_in_tx(cleanup.id, agent.uid) end)

    capacity_run = workflow(agent.uid, source, "Waiting for Agent capacity")
    capacity_call = queued_call(capacity_run)

    dispatch =
      Repo.get_by!(Ankole.Signals.Signal,
        source_event_id: "workflow:call:#{capacity_call.id}:dispatch"
      )

    capacity_retry_at = DateTime.add(DateTime.utc_now(:microsecond), 30, :second)
    assert {:ok, _} = Workflow.defer_task_event(dispatch, capacity_retry_at, :agent_capacity)

    idle = workflow(agent.uid, source, "Replay has no live calls")
    signal_count = Repo.aggregate(Ankole.Signals.Signal, :count)
    task_count = Repo.aggregate(Oban.Job, :count)
    conn = console_conn(conn)

    automation =
      conn |> api_get(activity_path(agent.uid, "automation-runs")) |> json_response(200)

    assert [visible] = automation["runs"]
    assert visible["id"] == run.id
    assert visible["automation_job_id"] == job.id
    assert visible["definition_status"] == "cancelled"
    assert visible["status"] == "running"
    assert visible["attempt_id"] == attempt.attempt_id
    refute Map.has_key?(visible, "stdout")
    refute Map.has_key?(visible, "event")

    workflow_page =
      conn |> recycle_api() |> api_get(activity_path(agent.uid, "workflow")) |> json_response(200)

    visible_admitted = Enum.find(workflow_page["live_calls"], &(&1["id"] == admitted.id))
    assert visible_admitted["status"] == "running"
    assert visible_admitted["run_status"] == "cancelled"
    assert visible_admitted["run_error_code"] == "human_access_revoked"
    assert visible_admitted["wake_kind"] == nil
    visible_sleep = Enum.find(workflow_page["live_calls"], &(&1["id"] == sleeping.id))
    assert visible_sleep["status"] == "sleeping"
    assert visible_sleep["attention"]
    assert visible_sleep["sleep_note"] == sleeping.sleep_note
    assert visible_sleep["wake_kind"] == "sleep"
    assert visible_sleep["wake_at"] == DateTime.to_iso8601(sleeping.wake_at)
    assert visible_sleep["run_counts"]["sleeping"] == 1
    assert visible_sleep["task_session_id"] == delegated.owner_session_id
    visible_capacity = Enum.find(workflow_page["live_calls"], &(&1["id"] == capacity_call.id))
    assert visible_capacity["status"] == "queued"
    assert visible_capacity["wake_kind"] == "agent_capacity"
    assert visible_capacity["wake_at"] == DateTime.to_iso8601(capacity_retry_at)
    assert Enum.find(workflow_page["runs"], &(&1["id"] == cleanup.id))["cleanup_pending"]
    assert Enum.find(workflow_page["runs"], &(&1["id"] == idle.id))["counts"]["total"] == 0
    refute Enum.any?(workflow_page["runs"], &(&1["id"] in [revoked.id, sleeping_run.id]))
    refute Enum.any?(workflow_page["runs"], &Map.has_key?(&1, "script"))

    jobs =
      conn
      |> recycle_api()
      |> api_get(activity_path(agent.uid, "background-jobs"))
      |> json_response(200)

    assert [visible_job] = jobs["jobs"]
    assert visible_job["id"] == delegated.id
    assert visible_job["owner_session_id"] == Workflow.task_session_id(sleeping.id)
    refute Map.has_key?(visible_job, "task")
    refute Map.has_key?(visible_job, "result")
    Repo.put_tenant_id(tenant.id)
    assert Repo.aggregate(Ankole.Signals.Signal, :count) == signal_count
    assert Repo.aggregate(Oban.Job, :count) == task_count
    assert Repo.get!(AgentCall, admitted.id).status == :running
    assert Repo.get!(Ankole.AutomationJobs.Schemas.Run, run.id).attempt_id == attempt.attempt_id
  end

  test "activity filters precede independent pagination and retain tenant and Agent scope", %{
    conn: conn,
    tenant: tenant
  } do
    %{principal: agent} = agent_fixture()
    %{principal: other} = agent_fixture()
    source = Ankole.WorkFixtures.service_source(agent.uid)
    {_, first} = automation_run(agent.uid, source)
    {_, second} = automation_run(agent.uid, source)
    {_, terminal} = automation_run(agent.uid, source)

    assert {:ok, _worker} =
             Ankole.SessionsCase.admit_worker("automation-test-#{agent.uid}", %{
               worker_id: agent.uid
             })

    {:ok, %{run: attempt}} = AutomationJobs.start_attempt(terminal.id)

    {:ok, _} =
      AutomationJobs.finish_attempt(terminal.id, attempt.attempt_id, %{
        status: "succeeded",
        exit_code: 0
      })

    automation_run(other.uid, Ankole.WorkFixtures.service_source(other.uid))
    conn = console_conn(conn)

    one =
      conn
      |> api_get(activity_path(agent.uid, "automation-runs") <> "?limit=1")
      |> json_response(200)

    assert Enum.map(one["runs"], & &1["id"]) == [second.id]
    assert is_binary(one["next_cursor"])

    two =
      conn
      |> recycle_api()
      |> api_get(
        activity_path(agent.uid, "automation-runs") <> "?limit=1&cursor=#{one["next_cursor"]}"
      )
      |> json_response(200)

    assert Enum.map(two["runs"], & &1["id"]) == [first.id]
    assert is_nil(two["next_cursor"])

    Repo.put_tenant_id(tenant.id)
    for _ <- 1..2, do: workflow(agent.uid, source, "No calls")
    run = workflow(agent.uid, source, "Two live calls")

    {:ok, %{new_calls: calls}} =
      Workflow.Replay.commit_replay_pending(
        run.id,
        for(
          n <- 1..2,
          do: %{namespace: nil, name: "agent", arguments: %{"prompt" => "Question #{n}"}}
        ),
        0
      )

    for call <- calls,
        do:
          Ankole.SessionsCase.stub_driver(%{
            agent_uid: agent.uid,
            session_id: Workflow.task_session_id(call.id)
          })

    page =
      conn
      |> recycle_api()
      |> api_get(activity_path(agent.uid, "workflow") <> "?limit=1")
      |> json_response(200)

    assert length(page["live_calls"]) == 1
    assert is_binary(page["calls_next_cursor"])
    assert length(page["runs"]) == 1
    assert is_binary(page["runs_next_cursor"])

    next =
      conn
      |> recycle_api()
      |> api_get(
        activity_path(agent.uid, "workflow") <>
          "?limit=1&calls_cursor=#{page["calls_next_cursor"]}&runs_cursor=#{page["runs_next_cursor"]}"
      )
      |> json_response(200)

    assert MapSet.new(page["live_calls"] ++ next["live_calls"], & &1["id"]) ==
             MapSet.new(calls, & &1.id)

    assert is_nil(next["calls_next_cursor"])
    assert is_nil(next["runs_next_cursor"])

    other_tenant = Ankole.DataCase.create_tenant()

    Repo.with_tenant(other_tenant.id, fn ->
      assert %{runs: []} = Ankole.AutomationJobs.ConsoleQueries.activity(agent.uid, nil, 25)

      assert %{runs: [], live_calls: []} =
               Ankole.Workflow.ConsoleQueries.activity(agent.uid, nil, nil, 25)

      assert {:ok, %{jobs: []}} = Ankole.BackgroundAgentJobs.Queries.list_activity(agent.uid)
    end)
  end

  test "each group requires its own resource permission and missing sessions fail closed", %{
    conn: conn,
    tenant: tenant
  } do
    %{principal: agent} = agent_fixture()

    for group <- ["background-jobs", "workflow", "automation-runs"] do
      assert conn |> api_get(activity_path(agent.uid, group)) |> json_response(401)
    end

    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    Repo.delete_all(from(grant in Ankole.AuthZ.Grant, where: grant.resource_pattern == "**"))

    assert {:ok, _} =
             Ankole.AuthZ.create_permission_grant(%{
               principal_uid: uid,
               resource_pattern: "agent:#{agent.uid}:automation_jobs",
               action: "read",
               condition: "true",
               metadata: %{}
             })

    assert conn
           |> recycle_api()
           |> api_get(activity_path(agent.uid, "automation-runs"))
           |> json_response(200)

    assert conn
           |> recycle_api()
           |> api_get(activity_path(agent.uid, "workflow"))
           |> json_response(403)

    assert conn
           |> recycle_api()
           |> api_get(activity_path(agent.uid, "background-jobs"))
           |> json_response(403)

    Repo.put_tenant_id(tenant.id)

    assert {:ok, _} =
             Ankole.AuthZ.create_permission_grant(%{
               principal_uid: uid,
               resource_pattern: "agent:#{agent.uid}:workflow",
               action: "read",
               condition: "true",
               metadata: %{}
             })

    assert conn
           |> recycle_api()
           |> api_get(activity_path(agent.uid, "workflow"))
           |> json_response(200)

    assert conn
           |> recycle_api()
           |> api_get(activity_path(agent.uid, "workflow") <> "?calls_cursor=bad")
           |> json_response(422)
  end

  test "automation execution inspection uses one bounded join and a real query plan" do
    %{principal: agent} = agent_fixture()
    source = Ankole.WorkFixtures.service_source(agent.uid)
    for _ <- 1..4, do: automation_run(agent.uid, source)
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        &__MODULE__.capture_query/4,
        {self(), handler}
      )

    try do
      assert %{runs: [_, _], next_cursor: cursor} =
               Ankole.AutomationJobs.ConsoleQueries.activity(agent.uid, nil, 2)

      assert is_binary(cursor)
    after
      :telemetry.detach(handler)
    end

    assert_receive {^handler, sql, params}
    refute_receive {^handler, _, _}
    assert sql =~ "LIMIT"
    assert sql =~ "JOIN"
    plan = Ecto.Adapters.SQL.query!(Repo, "EXPLAIN " <> sql, params)
    assert length(plan.rows) > 0
    assert inspect(plan.rows) =~ "automation_job_runs"
  end

  def capture_query(_, _, metadata, {owner, handler}) do
    if self() == owner, do: send(owner, {handler, metadata.query, metadata.params})
  end

  defp activity_path(agent, group), do: "/api/v2/agents/#{agent}/background-activities/#{group}"

  defp automation_run(agent_uid, source) do
    suffix = Ecto.UUID.generate()
    drive_file_fixture(agent_uid, "automation/#{suffix}/main.ts")

    {:ok, job} =
      AutomationJobs.create_job(%{
        agent_uid: agent_uid,
        owner_session_id: source.session_id,
        source_signal_id: source.id,
        reply_route: %{"binding_name" => "bot"},
        drive_prefix: "automation/#{suffix}",
        label: "Diagnostics #{suffix}"
      })

    {:ok, %{automation_job_run: run}} =
      Repo.transact(fn ->
        AutomationJobs.enqueue_run_in_tx(job.id, agent_uid, %{
          "specversion" => "1.0",
          "source" => "test://activity",
          "id" => suffix,
          "type" => "test.trigger",
          "data" => %{"scheduled_event_id" => "42"}
        })
      end)

    {job, run}
  end

  defp workflow(agent_uid, source, title) do
    {:ok, %{run: run}} =
      Workflow.create_with_dispatch(%{
        "source_signal_id" => source.id,
        "agent_uid" => agent_uid,
        "owner_session_id" => source.session_id,
        "source_tool_call_id" => Ecto.UUID.generate(),
        "title" => title,
        "reply_route" => %{"binding_name" => "bot"},
        "script" => "return await agent('Inspect evidence');",
        "args" => %{},
        "concurrency" => 8,
        "max_agent_calls" => 10
      })

    run
  end

  defp claimed_call(run) do
    call = queued_call(run)

    {:ok, %{call: call}} =
      Repo.transact(fn -> Workflow.TaskLifecycle.claim_task_in_tx(call.id, run.agent_uid, 8) end)

    call
  end

  defp queued_call(run) do
    {:ok, %{new_calls: [call]}} =
      Workflow.Replay.commit_replay_pending(
        run.id,
        [%{namespace: nil, name: "agent", arguments: %{"prompt" => "Inspect evidence"}}],
        0
      )

    Ankole.SessionsCase.stub_driver(%{
      agent_uid: run.agent_uid,
      session_id: Workflow.task_session_id(call.id)
    })

    call
  end

  defp api_request(conn, method, path, body \\ nil) do
    if String.starts_with?(path, "/api/v2/") do
      body =
        case body do
          nil ->
            nil

          value when is_binary(value) ->
            value

          value ->
            Jason.encode!(
              if Map.has_key?(value, :data) or Map.has_key?(value, "data"),
                do: value,
                else: %{data: value}
            )
        end

      conn
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> dispatch(@endpoint, method, path, body)
    else
      conn |> dispatch(@endpoint, method, path, body)
    end
  end

  defp api_get(conn, path), do: api_request(conn, :get, path)
end
