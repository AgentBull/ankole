defmodule AnkoleWeb.AgentControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions

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

  test "admin creates, lists, updates, disables, re-enables, and deletes an agent", %{conn: conn} do
    %{principal: owner} = human_fixture(%{uid: unique_uid("agent-owner")})
    provider = worker_provider_fixture()
    conn = console_conn(conn)

    conn =
      post(conn, ~p"/api/v1/agents", %{
        "worker_provider_id" => provider.provider_id,
        "handle" => "Console-Agent",
        "display_name" => "Console Agent",
        "role" => "Research Operator",
        "owner_principal_uid" => owner.uid,
        "options" => %{"ai_agent" => %{"temperature" => 0.2}}
      })

    owner_uid = owner.uid

    assert %{
             "agent" => %{
               "uid" => agent_uid,
               "handle" => "console-agent",
               "display_name" => "Console Agent",
               "role" => "Research Operator",
               "status" => "active",
               "type" => "ai_colleague",
               "options" => %{"ai_agent" => %{"temperature" => 0.2}},
               "owner_principal_uid" => ^owner_uid,
               "group_memory_disclosure_mode" => "strict",
               "created_by" => creator
             }
           } = json_response(conn, 200)

    assert_schema(json_response(conn, 200), "AgentResponse", AnkoleWeb.APISpec.spec())

    assert creator == %{
             "tenant_id" => conn.assigns.current_principal.tenant_id,
             "uid" => conn.assigns.current_principal_uid
           }

    assert {:ok, _} = Ecto.UUID.cast(agent_uid)
    assert agent_uid != "console-agent"

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/agents")

    assert %{"agents" => agents} = json_response(conn, 200)
    assert Enum.any?(agents, &(&1["uid"] == agent_uid))

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/agents/#{agent_uid}", %{
        "display_name" => "Console Agent Updated",
        "role" => "Customer Success Operator",
        "options" => %{"ai_agent" => %{"temperature" => 0.1}}
      })

    assert %{
             "agent" => %{
               "uid" => ^agent_uid,
               "display_name" => "Console Agent Updated",
               "role" => "Customer Success Operator",
               "options" => %{"ai_agent" => %{"temperature" => 0.1}}
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/agents/#{agent_uid}")

    assert %{"agent" => %{"display_name" => "Console Agent Updated"}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/agents/#{agent_uid}")

    assert %{"agent" => %{"uid" => ^agent_uid, "status" => "disabled"}} =
             json_response(conn, 200)

    # A disabled agent stays listed so the operator can re-enable or delete it.
    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/agents")

    assert %{"agents" => agents} = json_response(conn, 200)
    assert Enum.any?(agents, &(&1["uid"] == agent_uid and &1["status"] == "disabled"))

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/agents/#{agent_uid}/enable")

    assert %{"agent" => %{"uid" => ^agent_uid, "status" => "active"}} =
             json_response(conn, 200)

    # Deleting requires disabling first; the second delete removes the row.
    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/agents/#{agent_uid}")

    assert %{"agent" => %{"status" => "disabled"}} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/agents/#{agent_uid}")

    assert %{"agent" => %{"uid" => ^agent_uid}} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/agents")

    assert %{"agents" => agents} = json_response(conn, 200)
    refute Enum.any?(agents, &(&1["uid"] == agent_uid))
  end

  test "agent delete does not disable a human principal with the same path shape", %{conn: conn} do
    %{principal: human} = human_fixture(%{uid: unique_uid("not-agent")})

    conn =
      conn
      |> console_conn()
      |> delete(~p"/api/v1/agents/#{human.uid}")

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "agent creation requires a nonblank display name", %{conn: conn} do
    %{principal: owner} = human_fixture(%{uid: unique_uid("agent-owner")})
    conn = console_conn(conn)

    conn =
      post(conn, ~p"/api/v1/agents", %{
        "handle" => unique_uid("missing-display-name"),
        "role" => "Research Analyst",
        "owner_principal_uid" => owner.uid
      })

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/agents", %{
        "handle" => unique_uid("blank-display-name"),
        "display_name" => "   ",
        "role" => "Research Analyst",
        "owner_principal_uid" => owner.uid
      })

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "display_name is required"
             }
           } = json_response(conn, 422)
  end

  test "agent creation refuses a token quota in its options", %{conn: conn} do
    %{principal: owner} = human_fixture()
    provider = worker_provider_fixture()

    conn =
      conn
      |> console_conn()
      |> post(~p"/api/v1/agents", %{
        "worker_provider_id" => provider.provider_id,
        "handle" => unique_uid("quota-at-creation"),
        "display_name" => "Quota At Creation",
        "role" => "Research Analyst",
        "owner_principal_uid" => owner.uid,
        "options" => %{"ai_agent" => %{"token_quota" => %{"period_days" => 0}}}
      })

    assert %{"error" => %{"code" => "validation_failed", "message" => message}} =
             json_response(conn, 422)

    assert message =~ "token quota route"
  end

  test "the generic agent update keeps the ai_agent options and refuses to write them",
       %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    conn =
      put(conn, ~p"/api/v1/agents/#{agent.uid}/token-quota", %{
        "period_days" => 7,
        "period_start_at" => "2026-09-09T00:00:00Z",
        "limit_tokens" => 1_000
      })

    assert %{"token_quota" => %{"period_days" => 7}} = json_response(conn, 200)

    conn = conn |> recycle_api() |> patch(~p"/api/v1/agents/#{agent.uid}", %{"options" => %{}})

    assert %{"agent" => %{"options" => %{"ai_agent" => %{"token_quota" => _}}}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/agents/#{agent.uid}", %{
        "options" => %{"ai_agent" => %{"token_quota" => %{"period_days" => 0}}}
      })

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn = conn |> recycle_api() |> get(~p"/api/v1/agents/#{agent.uid}/token-quota")

    assert %{"token_quota" => %{"period_days" => 7, "limit_tokens" => 1_000}} =
             json_response(conn, 200)
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
