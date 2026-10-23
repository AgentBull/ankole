defmodule AnkoleWeb.BackgroundAgentJobControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.AIGatewayCase, only: [background_agent_fixture: 0]

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Schemas.TurnItem

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "a missing Job has no Turn page", %{conn: conn} do
    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn
             |> console_conn()
             |> api_get("/api/v2/background-agent-jobs/1000000/turns")
             |> json_response(404)
  end

  test "missing browser session is rejected", %{conn: conn} do
    assert conn |> api_get(~p"/api/v2/background-agent-jobs/health") |> json_response(401)
  end

  test "Deep Research detail exposes the same semantic Turn trajectory without raw protocol frames",
       %{
         conn: conn
       } do
    agent = background_agent_fixture().principal

    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "source_signal_id" => Ankole.WorkFixtures.service_source(agent.uid).id,
               "agent_uid" => agent.uid,
               "owner_session_id" => "console-parent-research",
               "source_tool_call_id" => "console-tool-research",
               "workspace_template_id" => "deep-research",
               "title" => "Console research job",
               "task" => "Produce a forecast dossier.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "conversation_id" =>
                   Ankole.ExternalConversationsFixtures.external_conversation_id(
                     "console-chat-research"
                   )
               }
             })

    insert_turn!(job, "thread-research", "turn-research")

    page =
      conn
      |> console_conn()
      |> api_get(~p"/api/v2/background-agent-jobs/#{job.id}/turns")
      |> json_response(200)

    assert [%{"trajectory" => trajectory}] = page["turns"]

    assert trajectory["messages"] == [
             %{
               "id" => "assistant:finished",
               "role" => "assistant",
               "content" => "Finished semantic report.",
               "metadata" => %{"phase" => "assistant"}
             }
           ]

    refute inspect(page) =~ "json_rpc"
  end

  test "Console detail pages the Turn trajectory newest first within one budget", %{conn: conn} do
    agent = background_agent_fixture().principal
    job = create_job!(agent.uid, "paged-turn-detail")
    base = DateTime.add(DateTime.utc_now(:microsecond), -30, :second)
    silent = insert_turn!(job, "thread-page", "turn-page-0", items: 0, started_at: base)

    older =
      insert_turn!(job, "thread-page", "turn-page-1",
        items: 15,
        started_at: DateTime.add(base, 1, :second)
      )

    newer =
      insert_turn!(job, "thread-page", "turn-page-2",
        items: 15,
        started_at: DateTime.add(base, 2, :second)
      )

    conn = console_conn(conn)

    first =
      conn |> api_get(~p"/api/v2/background-agent-jobs/#{job.id}/turns") |> json_response(200)

    assert Enum.map(first["turns"], &{&1["id"], length(&1["trajectory"]["messages"])}) == [
             {older.id, 5},
             {newer.id, 15}
           ]

    assert is_binary(first["next_cursor"])

    second =
      conn
      |> recycle_api()
      |> api_get(~p"/api/v2/background-agent-jobs/#{job.id}/turns?cursor=#{first["next_cursor"]}")
      |> json_response(200)

    assert Enum.map(second["turns"], &{&1["id"], length(&1["trajectory"]["messages"])}) == [
             {silent.id, 0},
             {older.id, 10}
           ]

    assert second["next_cursor"] == nil

    assert %{"errors" => [%{"code" => "invalid_background_agent_job_trajectory_cursor"}]} =
             conn
             |> recycle_api()
             |> api_get(~p"/api/v2/background-agent-jobs/#{job.id}/turns?cursor=not-a-cursor")
             |> json_response(422)
  end

  test "the Agent Session picker exposes durable Job sessions only for this Agent", %{conn: conn} do
    agent = background_agent_fixture().principal
    other = background_agent_fixture().principal
    job = create_job!(agent.uid, "session-picker")
    other_job = create_job!(other.uid, "other-picker")

    %{"sessions" => sessions} =
      conn
      |> console_conn()
      |> api_get("/api/v2/agents/#{agent.uid}/sessions")
      |> json_response(200)

    assert Enum.any?(
             sessions,
             &(&1["session_id"] == BackgroundAgentJobs.job_session_id(job.id) and
                 &1["title"] == job.title)
           )

    refute Enum.any?(
             sessions,
             &(&1["session_id"] == BackgroundAgentJobs.job_session_id(other_job.id))
           )
  end

  defp create_job!(agent_uid, suffix, title \\ nil) do
    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "source_signal_id" => Ankole.WorkFixtures.service_source(agent_uid).id,
               "agent_uid" => agent_uid,
               "owner_session_id" => "console-parent-#{suffix}",
               "source_tool_call_id" => "console-tool-#{suffix}",
               "title" => title || "Console job #{suffix}",
               "task" => "Complete console job #{suffix}. Keep the result concise.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "conversation_id" =>
                   Ankole.ExternalConversationsFixtures.external_conversation_id(
                     "console-chat-#{suffix}"
                   )
               }
             })

    job
  end

  defp insert_turn!(job, runtime_thread_id, runtime_turn_id, opts \\ []) do
    now = Keyword.get(opts, :started_at, DateTime.utc_now(:microsecond))

    turn =
      case Repo.transact(fn _ ->
             Ankole.Ash.create(Turn, :record, %{
               job_id: job.id,
               attempt: max(job.attempts, 1),
               runtime_thread_id: runtime_thread_id,
               runtime_turn_id: runtime_turn_id,
               kind: "agent",
               status: :completed,
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
           end) do
        {:ok, record} -> record
        {:error, error} -> raise Ash.Error.to_error_class(error)
      end

    for position <- 0..(Keyword.get(opts, :items, 1) - 1)//1 do
      case Repo.transact(fn _ ->
             Ankole.Ash.create(TurnItem, :append, %{
               turn_id: turn.id,
               position: position,
               revision: turn.revision,
               item_key: "assistant:finished:#{position}",
               item: %{
                 "type" => "agentMessage",
                 "id" => "assistant:finished",
                 "text" => "Finished semantic report."
               }
             })
           end) do
        {:ok, record} -> record
        {:error, error} -> raise Ash.Error.to_error_class(error)
      end
    end

    turn
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
