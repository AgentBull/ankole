defmodule AnkoleWeb.BackgroundAgentJobControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias OpenApiSpex, as: OpenAPISpex

  import Ecto.Query, warn: false
  import Ankole.AIGatewayCase, only: [background_agent_fixture: 0]
  import OpenAPISpex.TestAssertions

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Schemas.TurnItem

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin lists with filters and cursor, reads the timeline, and cancels", %{conn: conn} do
    agent = background_agent_fixture().principal
    other_agent = background_agent_fixture().principal
    oldest = create_job!(agent.uid, "oldest")
    middle = create_job!(agent.uid, "middle")
    newest = create_job!(other_agent.uid, "newest")

    set_queued_at(oldest, ~U[2026-07-10 01:00:00.000000Z])
    set_queued_at(middle, ~U[2026-07-10 02:00:00.000000Z])
    set_queued_at(newest, ~U[2026-07-10 03:00:00.000000Z])

    turn = insert_turn!(middle, "thread-console", "turn-console")

    api_spec = AnkoleWeb.APISpec.spec()

    conn = bearer_conn(conn)
    first_page = conn |> get(~p"/api/v1/background-agent-jobs?limit=2") |> json_response(200)

    assert_schema(first_page, "BackgroundAgentJobListResponse", api_spec)
    assert Enum.map(first_page["jobs"], & &1["id"]) == [newest.id, middle.id]
    assert is_binary(first_page["next_cursor"])
    refute Map.has_key?(first_page, "calibration_summary")

    # A board row stays at what the board draws. The queued prompt, the result,
    # the error, and the metadata grow with the work the job did, and a list page
    # holds up to 100 rows and reloads on a timer.
    assert %{"jobs" => [listed | _rest]} = first_page

    assert Map.keys(listed) |> Enum.sort() == [
             "agent_uid",
             "attempts",
             "duration_seconds",
             "execution_failures",
             "id",
             "inserted_at",
             "status",
             "title",
             "workspace_template_id"
           ]

    assert listed["title"] == newest.title

    second_page =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/background-agent-jobs?limit=2&cursor=#{first_page["next_cursor"]}")
      |> json_response(200)

    assert Enum.map(second_page["jobs"], & &1["id"]) == [oldest.id]
    assert second_page["next_cursor"] == nil

    filtered =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/background-agent-jobs?agent=#{agent.uid}&status=queued")
      |> json_response(200)

    assert Enum.map(filtered["jobs"], & &1["id"]) == [middle.id, oldest.id]

    name_search =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/background-agent-jobs?agent=#{agent.uid}&q=MIDDLE&limit=1")
      |> json_response(200)

    assert Enum.map(name_search["jobs"], & &1["id"]) == [middle.id]

    id_search =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/background-agent-jobs?q=#{oldest.id}&limit=1")
      |> json_response(200)

    assert Enum.map(id_search["jobs"], & &1["id"]) == [oldest.id]

    detail_response =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/background-agent-jobs/#{middle.id}")
      |> json_response(200)

    assert_schema(detail_response, "BackgroundAgentJobResponse", api_spec)
    detail = Map.fetch!(detail_response, "job")

    assert detail["title"] == middle.title
    assert detail["workspace_template_id"] == nil
    assert detail["model_profile"] == "coding"
    refute Map.has_key?(detail, "runtime")
    refute Map.has_key?(detail, "mode")
    assert [stored_turn] = detail["turns"]
    assert stored_turn["id"] == turn.id
    assert stored_turn["runtime_turn_id"] == "turn-console"
    assert stored_turn["trajectory"]["format"] == "ankole_chatml"

    assert stored_turn["progress"] == %{
             "completed_items" => 2,
             "files_changed" => ["brief.md"],
             "plan" => %{
               "steps" => [%{"status" => "completed", "step" => "Write brief"}]
             },
             "tool_calls" => 1,
             "tools_used" => [%{"calls" => 1, "name" => "shell"}]
           }

    assert stored_turn["usage"]["thread_total"]["total_tokens"] == 21
    refute Map.has_key?(stored_turn, "last_activity_at")

    cancelled_response =
      conn
      |> recycle_bearer()
      |> post(~p"/api/v1/background-agent-jobs/#{middle.id}/cancel")
      |> json_response(200)

    assert_schema(cancelled_response, "BackgroundAgentJobResponse", api_spec)
    cancelled = Map.fetch!(cancelled_response, "job")

    assert cancelled["status"] == "stopped"
    assert cancelled["metadata"]["cancel_requested_by"] =~ "operator:"
  end

  test "external completion reads its result summary from the JSON body", %{conn: conn} do
    agent = background_agent_fixture().principal
    job = create_job!(agent.uid, "external-completion")
    api_spec = AnkoleWeb.APISpec.spec()

    response =
      conn
      |> bearer_conn()
      |> post(~p"/api/v1/background-agent-jobs/#{job.id}/complete", %{
        "result_summary" => "EXTERNALLY-VERIFIED"
      })
      |> json_response(200)

    assert_schema(response, "BackgroundAgentJobResponse", api_spec)
    completed = Map.fetch!(response, "job")

    assert completed["status"] == "succeeded"
    assert completed["result"]["summary"] == "EXTERNALLY-VERIFIED"
  end

  test "title search treats LIKE control characters as ordinary text", %{conn: conn} do
    agent = background_agent_fixture().principal
    percent = create_job!(agent.uid, "literal-percent", "Console percent%marker")
    _percent_wildcard = create_job!(agent.uid, "percent-wildcard", "Console percent-any-marker")
    underscore = create_job!(agent.uid, "literal-underscore", "Console under_marker")
    _underscore_wildcard = create_job!(agent.uid, "underscore-wildcard", "Console underXmarker")
    backslash = create_job!(agent.uid, "literal-backslash", "Console slash\\marker")
    conn = bearer_conn(conn)

    assert search_job_ids(conn, "percent%marker") == [percent.id]
    assert search_job_ids(conn, "under_marker") == [underscore.id]
    assert search_job_ids(conn, "slash\\marker") == [backslash.id]
  end

  test "cursor pagination neither skips nor repeats jobs with the same queued timestamp", %{
    conn: conn
  } do
    agent = background_agent_fixture().principal
    jobs = Enum.map(1..3, &create_job!(agent.uid, "same-time-#{&1}"))
    queued_at = ~U[2026-07-10 04:00:00.000000Z]
    Enum.each(jobs, &set_queued_at(&1, queued_at))

    conn = bearer_conn(conn)
    first = conn |> get(~p"/api/v1/background-agent-jobs?limit=1") |> json_response(200)

    second =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/background-agent-jobs?limit=1&cursor=#{first["next_cursor"]}")
      |> json_response(200)

    third =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/background-agent-jobs?limit=1&cursor=#{second["next_cursor"]}")
      |> json_response(200)

    paged_ids = Enum.map([first, second, third], &get_in(&1, ["jobs", Access.at(0), "id"]))

    assert Enum.all?([first["next_cursor"], second["next_cursor"]], &is_binary/1)
    assert third["next_cursor"] == nil
    assert length(Enum.uniq(paged_ids)) == 3
    assert MapSet.new(paged_ids) == MapSet.new(Enum.map(jobs, & &1.id))
  end

  test "missing bearer token is rejected", %{conn: conn} do
    assert conn |> get(~p"/api/v1/background-agent-jobs") |> json_response(401)
  end

  test "Deep Research detail exposes the same semantic Turn trajectory without raw protocol frames",
       %{
         conn: conn
       } do
    agent = background_agent_fixture().principal

    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "owner_session_id" => "console-parent-research",
               "source_tool_call_id" => "console-tool-research",
               "workspace_template_id" => "deep-research",
               "title" => "Console research job",
               "task" => "Produce a forecast dossier.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "signal_channel_id" => "console-chat-research"
               }
             })

    insert_turn!(job, "thread-research", "turn-research")

    detail =
      conn
      |> bearer_conn()
      |> get(~p"/api/v1/background-agent-jobs/#{job.id}")
      |> json_response(200)
      |> Map.fetch!("job")

    assert detail["workspace_template_id"] == "deep-research"
    assert detail["model_profile"] == "coding"
    refute Map.has_key?(detail, "plugin_options")

    refute Map.has_key?(detail, "runtime")
    refute Map.has_key?(detail, "mode")
    assert [%{"trajectory" => trajectory}] = detail["turns"]

    assert trajectory["messages"] == [
             %{
               "id" => "assistant:finished",
               "role" => "assistant",
               "content" => "Finished semantic report.",
               "metadata" => %{"phase" => "assistant"}
             }
           ]

    refute Map.has_key?(detail, "trajectory_archive")
    refute inspect(detail) =~ "json_rpc"
  end

  test "Console Turn projection loads all item trajectories in one query" do
    agent = background_agent_fixture().principal
    job = create_job!(agent.uid, "batched-turn-projection")
    first = insert_turn!(job, "thread-batch", "turn-batch-1")
    second = insert_turn!(job, "thread-batch", "turn-batch-2")
    turns = BackgroundAgentJobs.list_turns(job.id)

    handler_id = "background-agent-job-turn-query-#{System.unique_integer([:positive])}"
    test_pid = self()
    event = Ankole.Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, pid ->
          cond do
            String.contains?(metadata.query, ~s(FROM "background_agent_job_turn_items")) ->
              send(pid, :turn_item_query)

            String.contains?(
              metadata.query,
              ~s(FROM "background_agent_job_turn_trajectory_groups")
            ) ->
              send(pid, :trajectory_group_query)

            true ->
              :ok
          end
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    projections = BackgroundAgentJobs.console_turn_projections(turns)

    assert Enum.map(projections, & &1.id) == Enum.map(turns, & &1.id)
    assert Enum.find(projections, &(&1.id == first.id)).trajectory["messages"] != []
    assert Enum.find(projections, &(&1.id == second.id)).trajectory["messages"] != []
    assert_receive :turn_item_query
    refute_receive :turn_item_query
    refute_receive :trajectory_group_query
  end

  defp create_job!(agent_uid, suffix, title \\ nil) do
    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent_uid,
               "owner_session_id" => "console-parent-#{suffix}",
               "source_tool_call_id" => "console-tool-#{suffix}",
               "title" => title || "Console job #{suffix}",
               "task" => "Complete console job #{suffix}. Keep the result concise.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "signal_channel_id" => "console-chat-#{suffix}"
               }
             })

    job
  end

  defp search_job_ids(conn, search) do
    query = URI.encode_query(%{"q" => search, "limit" => 100})

    conn
    |> recycle_bearer()
    |> get("/api/v1/background-agent-jobs?#{query}")
    |> json_response(200)
    |> Map.fetch!("jobs")
    |> Enum.map(& &1["id"])
  end

  defp insert_turn!(job, runtime_thread_id, runtime_turn_id) do
    now = DateTime.utc_now(:microsecond)

    turn =
      %Turn{}
      |> Turn.changeset(%{
        job_id: job.id,
        attempt: max(job.attempts, 1),
        runtime_thread_id: runtime_thread_id,
        runtime_turn_id: runtime_turn_id,
        kind: "agent",
        status: "completed",
        revision: 2,
        trajectory: %{
          "format" => "ankole_chatml",
          "version" => 1
        },
        progress: %{
          "completed_items" => 2,
          "tool_calls" => 1,
          "tools_used" => [%{"name" => "shell", "calls" => 1}],
          "files_changed" => ["brief.md"],
          "plan" => %{
            "steps" => [%{"step" => "Write brief", "status" => "completed"}]
          }
        },
        usage: %{
          "thread_total" => %{
            "total_tokens" => 21,
            "input_tokens" => 16,
            "cached_input_tokens" => 2,
            "output_tokens" => 5,
            "reasoning_output_tokens" => 3
          },
          "last_model_call" => %{
            "total_tokens" => 21,
            "input_tokens" => 16,
            "cached_input_tokens" => 2,
            "output_tokens" => 5,
            "reasoning_output_tokens" => 3
          },
          "model_context_window" => 200_000
        },
        error: %{},
        started_at: now,
        completed_at: now
      })
      |> Repo.insert!()

    %TurnItem{}
    |> TurnItem.changeset(%{
      turn_id: turn.id,
      position: 0,
      revision: turn.revision,
      item_key: "assistant:finished",
      item: %{
        "type" => "agentMessage",
        "id" => "assistant:finished",
        "text" => "Finished semantic report."
      }
    })
    |> Repo.insert!()

    turn
  end

  defp set_queued_at(job, queued_at) do
    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [queued_at: queued_at])
  end

  defp recycle_bearer(conn) do
    authorization = get_req_header(conn, "authorization") |> List.first()

    conn
    |> recycle()
    |> put_req_header("authorization", authorization)
    |> put_req_header("content-type", "application/json")
  end
end
