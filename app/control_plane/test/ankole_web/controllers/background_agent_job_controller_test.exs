defmodule AnkoleWeb.BackgroundAgentJobControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias OpenApiSpex, as: OpenAPISpex

  import Ecto.Query, warn: false
  import Ankole.PrincipalsFixtures
  import OpenAPISpex.TestAssertions

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = SetupConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin lists with filters and cursor, reads the timeline, and cancels", %{conn: conn} do
    agent = agent_fixture().principal
    other_agent = agent_fixture().principal
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

    detail_response =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/background-agent-jobs/#{middle.id}")
      |> json_response(200)

    assert_schema(detail_response, "BackgroundAgentJobResponse", api_spec)
    detail = Map.fetch!(detail_response, "job")

    assert detail["title"] == middle.title
    assert detail["agent_plugin_ids"] == []
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

  test "missing bearer token is rejected", %{conn: conn} do
    assert conn |> get(~p"/api/v1/background-agent-jobs") |> json_response(401)
  end

  test "Deep Research detail exposes the same semantic Turn trajectory without raw protocol frames",
       %{
         conn: conn
       } do
    agent = agent_fixture().principal

    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "owner_session_id" => "console-parent-research",
               "source_tool_call_id" => "console-tool-research",
               "agent_plugin_ids" => ["deep-research"],
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

    assert detail["agent_plugin_ids"] == ["deep-research"]
    refute Map.has_key?(detail, "plugin_options")

    refute Map.has_key?(detail, "runtime")
    refute Map.has_key?(detail, "mode")
    assert [%{"trajectory" => trajectory}] = detail["turns"]

    assert trajectory["messages"] == [
             %{"content" => "Finished semantic report.", "role" => "assistant"}
           ]

    refute Map.has_key?(detail, "trajectory_archive")
    refute inspect(detail) =~ "json_rpc"
  end

  defp create_job!(agent_uid, suffix) do
    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent_uid,
               "owner_session_id" => "console-parent-#{suffix}",
               "source_tool_call_id" => "console-tool-#{suffix}",
               "title" => "Console job #{suffix}",
               "task" => "Complete console job #{suffix}.",
               "background" => "Console test context.",
               "notes" => "Keep the result concise.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "signal_channel_id" => "console-chat-#{suffix}"
               }
             })

    job
  end

  defp insert_turn!(job, runtime_thread_id, runtime_turn_id) do
    now = DateTime.utc_now(:microsecond)

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
        "version" => 1,
        "messages" => [%{"role" => "assistant", "content" => "Finished semantic report."}]
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
  end

  defp set_queued_at(job, queued_at) do
    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [queued_at: queued_at])
  end

  defp bearer_conn(conn) do
    conn
    |> active_admin_conn()
    |> post(~p"/.internal-apis/oauth/token", %{
      "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
    })
    |> json_response(200)
    |> Map.fetch!("access_token")
    |> then(fn access_token ->
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> put_req_header("content-type", "application/json")
    end)
  end

  defp recycle_bearer(conn) do
    authorization = get_req_header(conn, "authorization") |> List.first()

    conn
    |> recycle()
    |> put_req_header("authorization", authorization)
    |> put_req_header("content-type", "application/json")
  end

  defp active_admin_conn(conn) do
    {:ok, true} = SetupConfig.put_completed(true)
    human = human_fixture(%{uid: unique_uid("job-console-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn
    |> init_test_session(%{})
    |> WebSession.put_admin_session(%{
      principal_uid: human.principal.uid,
      provider_id: "lark-main",
      external_id: "external-1"
    })
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
