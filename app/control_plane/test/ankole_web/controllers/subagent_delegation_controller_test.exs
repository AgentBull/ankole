defmodule AnkoleWeb.SubagentDelegationControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query, warn: false
  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.SubagentDelegations
  alias Ankole.SubagentDelegations.Schemas.Delegation
  alias Ankole.SubagentDelegations.Schemas.Turn
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

  test "OpenAPI JSON includes the three delegation endpoints", %{conn: conn} do
    paths = conn |> get(~p"/api/v1/openapi.json") |> json_response(200) |> Map.fetch!("paths")

    assert Map.has_key?(paths, "/api/v1/delegations")
    assert Map.has_key?(paths, "/api/v1/delegations/{delegation_id}")
    assert Map.has_key?(paths, "/api/v1/delegations/{delegation_id}/cancel")
  end

  test "admin lists with filters and cursor, reads the timeline, and cancels", %{conn: conn} do
    agent = agent_fixture().principal
    other_agent = agent_fixture().principal
    oldest = create_delegation!(agent.uid, "oldest")
    middle = create_delegation!(agent.uid, "middle")
    newest = create_delegation!(other_agent.uid, "newest")

    set_queued_at(oldest, ~U[2026-07-10 01:00:00.000000Z])
    set_queued_at(middle, ~U[2026-07-10 02:00:00.000000Z])
    set_queued_at(newest, ~U[2026-07-10 03:00:00.000000Z])

    turn = insert_turn!(middle, "thread-console", "turn-console")

    conn = bearer_conn(conn)
    first_page = conn |> get(~p"/api/v1/delegations?limit=2") |> json_response(200)

    assert Enum.map(first_page["delegations"], & &1["id"]) == [newest.id, middle.id]
    assert is_binary(first_page["next_cursor"])

    assert first_page["calibration_summary"] == %{
             "confidence_buckets" => [],
             "forecast_count" => 0,
             "mean_brier_score" => nil,
             "no_edge_count" => 0,
             "no_edge_rate" => nil,
             "resolved_forecast_count" => 0
           }

    second_page =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/delegations?limit=2&cursor=#{first_page["next_cursor"]}")
      |> json_response(200)

    assert Enum.map(second_page["delegations"], & &1["id"]) == [oldest.id]
    assert second_page["next_cursor"] == nil

    filtered =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/delegations?agent=#{agent.uid}&status=queued")
      |> json_response(200)

    assert Enum.map(filtered["delegations"], & &1["id"]) == [middle.id, oldest.id]

    detail =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/delegations/#{middle.id}")
      |> json_response(200)
      |> Map.fetch!("delegation")

    assert detail["title"] == middle.title
    assert detail["runtime"] == "task_worker"
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

    cancelled =
      conn
      |> recycle_bearer()
      |> post(~p"/api/v1/delegations/#{middle.id}/cancel")
      |> json_response(200)
      |> Map.fetch!("delegation")

    assert cancelled["status"] == "stopped"
    assert cancelled["metadata"]["cancel_requested_by"] =~ "operator:"
  end

  test "missing bearer token is rejected", %{conn: conn} do
    assert conn |> get(~p"/api/v1/delegations") |> json_response(401)
  end

  test "Deep Research detail exposes the same semantic Turn trajectory without raw protocol frames",
       %{
         conn: conn
       } do
    agent = agent_fixture().principal

    assert {:ok, %{delegation: delegation}} =
             SubagentDelegations.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "session_id" => "console-parent-research",
               "tool_call_id" => "console-tool-research",
               "runtime" => "deep_research",
               "mode" => "forecast",
               "title" => "Console research delegation",
               "task" => "Produce a forecast dossier.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "signal_channel_id" => "console-chat-research"
               }
             })

    insert_turn!(delegation, "thread-research", "turn-research")

    detail =
      conn
      |> bearer_conn()
      |> get(~p"/api/v1/delegations/#{delegation.id}")
      |> json_response(200)
      |> Map.fetch!("delegation")

    assert detail["runtime"] == "deep_research"
    assert detail["mode"] == "forecast"
    assert [%{"trajectory" => trajectory}] = detail["turns"]

    assert trajectory["messages"] == [
             %{"content" => "Finished semantic report.", "role" => "assistant"}
           ]

    refute Map.has_key?(detail, "trajectory_archive")
    refute inspect(detail) =~ "json_rpc"
  end

  test "Deep Research list computes calibration from resolved source forecasts", %{conn: conn} do
    agent = agent_fixture().principal

    forecast =
      create_research_delegation!(agent.uid, "forecast-calibration", "forecast")
      |> complete_research!(%{
        "conclusion" => %{
          "verdict" => "estimate",
          "outcome_estimate" => %{"probability" => 0.8, "scale" => 0.05},
          "confidence" => 4
        }
      })

    _retrospect =
      create_research_delegation!(agent.uid, "retrospect-calibration", "retrospect", %{
        "source_delegation_id" => forecast.id,
        "actual_outcome" => true
      })
      |> complete_research!(%{
        "conclusion" => %{
          "resolution_status" => "resolved",
          "actual_outcome" => true
        },
        "calibration" => %{"brier_score" => 0.99}
      })

    _no_edge =
      create_research_delegation!(agent.uid, "forecast-no-edge", "forecast")
      |> complete_research!(%{"conclusion" => %{"verdict" => "no_edge", "confidence" => 2}})

    summary =
      conn
      |> bearer_conn()
      |> get(~p"/api/v1/delegations?agent=#{agent.uid}")
      |> json_response(200)
      |> Map.fetch!("calibration_summary")

    assert summary == %{
             "confidence_buckets" => [
               %{"confidence" => 4, "forecasts" => 1, "hit_rate" => 1.0, "hits" => 1}
             ],
             "forecast_count" => 2,
             "mean_brier_score" => 0.04,
             "no_edge_count" => 1,
             "no_edge_rate" => 0.5,
             "resolved_forecast_count" => 1
           }
  end

  defp create_delegation!(agent_uid, suffix) do
    assert {:ok, %{delegation: delegation}} =
             SubagentDelegations.create_with_dispatch(%{
               "agent_uid" => agent_uid,
               "session_id" => "console-parent-#{suffix}",
               "tool_call_id" => "console-tool-#{suffix}",
               "title" => "Console delegation #{suffix}",
               "task" => "Complete console delegation #{suffix}.",
               "background" => "Console test context.",
               "notes" => "Keep the result concise.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "signal_channel_id" => "console-chat-#{suffix}"
               }
             })

    delegation
  end

  defp create_research_delegation!(agent_uid, suffix, mode, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          "agent_uid" => agent_uid,
          "session_id" => "console-research-#{suffix}",
          "tool_call_id" => "console-research-tool-#{suffix}",
          "runtime" => "deep_research",
          "mode" => mode,
          "title" => "Console research #{suffix}",
          "task" => "Complete research #{suffix}.",
          "reply_route" => %{
            "binding_name" => "bot",
            "signal_channel_id" => "console-research-chat-#{suffix}"
          }
        },
        extra
      )

    assert {:ok, %{delegation: delegation}} = SubagentDelegations.create_with_dispatch(attrs)
    delegation
  end

  defp complete_research!(delegation, result) do
    delegation
    |> Delegation.changeset(%{
      status: "succeeded",
      result: result,
      completed_at: DateTime.utc_now(:microsecond)
    })
    |> Repo.update!()
  end

  defp insert_turn!(delegation, runtime_thread_id, runtime_turn_id) do
    now = DateTime.utc_now(:microsecond)

    %Turn{}
    |> Turn.changeset(%{
      delegation_id: delegation.id,
      attempt: max(delegation.attempts, 1),
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

  defp set_queued_at(delegation, queued_at) do
    from(row in Delegation, where: row.id == ^delegation.id)
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
    human = human_fixture(%{uid: unique_uid("delegation-console-admin")})
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
