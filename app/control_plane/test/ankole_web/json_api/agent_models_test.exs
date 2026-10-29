defmodule AnkoleWeb.JSONAPI.AgentModelsTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.AppConfigure.Registry
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin reads, sets, resets, and clears an agent token quota", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    conn = send_v2(conn, :get, ~p"/api/v2/agents/#{agent.uid}/token-quota")
    assert %{"token_quota" => nil, "usage" => nil} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> send_v2(:put, ~p"/api/v2/agents/#{agent.uid}/token-quota", %{
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

    conn = conn |> recycle_api() |> send_v2(:get, ~p"/api/v2/agents/#{agent.uid}/token-quota")

    assert %{"usage" => %{"used_tokens" => 1_100_000, "exceeded" => true}} =
             json_response(conn, 200)

    conn =
      conn |> recycle_api() |> send_v2(:post, ~p"/api/v2/agents/#{agent.uid}/token-quota/reset")

    assert %{
             "token_quota" => %{
               "period_days" => 7,
               "period_start_at" => reset_start_at,
               "limit_tokens" => 1_000_000
             },
             "usage" => %{"used_tokens" => 0, "exceeded" => false}
           } = json_response(conn, 201)

    refute reset_start_at == "2026-09-09T00:00:00Z"

    conn = conn |> recycle_api() |> send_v2(:delete, ~p"/api/v2/agents/#{agent.uid}/token-quota")
    assert %{"token_quota" => nil, "usage" => nil} = json_response(conn, 200)

    # A reset keeps the ledger, so the removed limit does not delete audit rows.
    assert Repo.aggregate(UsageRecord, :count) == 1
  end

  test "an invalid token quota is rejected", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    conn =
      send_v2(conn, :put, ~p"/api/v2/agents/#{agent.uid}/token-quota", %{
        "period_days" => 0,
        "period_start_at" => "2026-09-09T00:00:00Z",
        "limit_tokens" => 1_000
      })

    assert %{"errors" => [%{"code" => "invalid_period_days"}]} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> send_v2(:put, ~p"/api/v2/agents/#{agent.uid}/token-quota", %{
        "period_days" => 7,
        "period_start_at" => "not-an-instant",
        "limit_tokens" => 1_000
      })

    assert %{"errors" => [%{"code" => "invalid_period_start_at"}]} = json_response(conn, 422)

    conn =
      conn |> recycle_api() |> send_v2(:post, ~p"/api/v2/agents/#{agent.uid}/token-quota/reset")

    assert %{"errors" => [%{"code" => "token_quota_not_configured"}]} = json_response(conn, 422)
  end

  test "capability switches keep the other setting and persist in the profile view", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)
    path = "/api/v2/agents/#{agent.uid}"

    assert %{"provider_hosted" => %{"web_search" => true, "image_generate" => true}} =
             conn |> send_v2(:get, path <> "/model-profiles") |> json_response(200)

    assert %{"provider_hosted" => %{"web_search" => false, "image_generate" => true}} =
             conn
             |> send_v2(:put, path <> "/provider-hosted", %{"web_search" => false})
             |> json_response(200)

    assert %{"provider_hosted" => %{"web_search" => false, "image_generate" => true}} =
             conn |> send_v2(:get, path <> "/model-profiles") |> json_response(200)
  end

  test "an operator cannot read or change an Agent from another tenant", %{conn: conn} do
    other = Ankole.DataCase.create_tenant()
    %{principal: agent} = Repo.with_tenant(other.id, fn -> agent_fixture() end)
    conn = console_conn(conn)
    path = "/api/v2/agents/#{agent.uid}"

    for {method, suffix, params} <- [
          {:get, "/model-profiles", %{}},
          {:put, "/provider-hosted", %{"web_search" => false}},
          {:get, "/token-quota", %{}},
          {:delete, "/token-quota", %{}}
        ] do
      assert %{"errors" => [%{"code" => "not_found"}]} =
               conn |> send_v2(method, path <> suffix, params) |> json_response(404)
    end

    assert {:ok, capabilities} =
             Repo.with_tenant(other.id, fn ->
               Ankole.AIAgent.ModelProfiles.provider_hosted_capabilities(agent.uid)
             end)

    assert capabilities == %{}
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

  defp send_v2(conn, method, path, params \\ %{}) do
    conn =
      conn
      |> recycle_api()
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")

    body = if method in [:get, :delete], do: nil, else: Jason.encode!(%{data: params})
    Phoenix.ConnTest.dispatch(conn, AnkoleWeb.Endpoint, method, path, body)
  end
end
