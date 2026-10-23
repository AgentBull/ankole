defmodule AnkoleWeb.AgentControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin reads, sets, resets, and clears an agent token quota", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    conn = get(conn, ~p"/api/v1/agents/#{agent.uid}/token-quota")
    assert %{"token_quota" => nil, "usage" => nil} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/token-quota", %{
        "period_days" => 7,
        "period_start_at" => "2026-09-09T00:00:00Z",
        "limit_tokens" => 1_000_000
      })

    assert %{
             "token_quota" => %{
               "period_days" => 7,
               "period_start_at" => "2026-09-09T00:00:00Z",
               "limit_tokens" => 1_000_000
             },
             "usage" => %{
               "window_started_at" => window_started_at,
               "window_ends_at" => window_ends_at,
               "used_tokens" => 0,
               "exceeded" => false
             }
           } = json_response(conn, 200)

    assert {:ok, window_started_at, _offset} = DateTime.from_iso8601(window_started_at)
    assert {:ok, window_ends_at, _offset} = DateTime.from_iso8601(window_ends_at)
    assert DateTime.diff(window_ends_at, window_started_at, :second) == 7 * 86_400

    record_agent_usage(agent.uid, 900_000, 200_000)

    conn = conn |> recycle_api() |> get(~p"/api/v1/agents/#{agent.uid}/token-quota")

    assert %{"usage" => %{"used_tokens" => 1_100_000, "exceeded" => true}} =
             json_response(conn, 200)

    conn =
      conn |> recycle_api() |> post(~p"/api/v1/agents/#{agent.uid}/token-quota/reset")

    assert %{
             "token_quota" => %{
               "period_days" => 7,
               "period_start_at" => reset_start_at,
               "limit_tokens" => 1_000_000
             },
             "usage" => %{"used_tokens" => 0, "exceeded" => false}
           } = json_response(conn, 200)

    refute reset_start_at == "2026-09-09T00:00:00Z"

    conn = conn |> recycle_api() |> delete(~p"/api/v1/agents/#{agent.uid}/token-quota")
    assert %{"token_quota" => nil, "usage" => nil} = json_response(conn, 200)

    # A reset keeps the ledger, so the removed limit does not delete audit rows.
    assert Repo.aggregate(UsageRecord, :count) == 1
  end

  test "an invalid token quota is rejected", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    conn =
      put(conn, ~p"/api/v1/agents/#{agent.uid}/token-quota", %{
        "period_days" => 0,
        "period_start_at" => "2026-09-09T00:00:00Z",
        "limit_tokens" => 1_000
      })

    assert %{"error" => _error} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/token-quota", %{
        "period_days" => 7,
        "period_start_at" => "not-an-instant",
        "limit_tokens" => 1_000
      })

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn =
      conn |> recycle_api() |> post(~p"/api/v1/agents/#{agent.uid}/token-quota/reset")

    assert %{"error" => %{"code" => "token_quota_not_configured"}} = json_response(conn, 422)
  end

  defp record_agent_usage(agent_uid, input_tokens, output_tokens) do
    assert {:ok, _record} =
             Ankole.Ash.create(UsageRecord, :record_round, %{
               subject_uid: agent_uid,
               origin: :agent,
               model: "test-provider/test-model",
               input_tokens: input_tokens,
               output_tokens: output_tokens
             })
  end
end
