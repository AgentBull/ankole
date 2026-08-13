defmodule AnkoleWeb.ConsoleReadinessControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.Binding
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()
    CredentialPool.reset_for_test()

    :ok = SetupConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin sees incomplete deployment instance facts", %{conn: conn} do
    conn = bearer_conn(conn) |> get(~p"/api/v1/console-readiness")

    assert %{
             "ready" => false,
             "completed_core_steps" => 0,
             "total_core_steps" => 5,
             "provider" => %{"complete" => false, "provider_id" => nil},
             "agent" => %{"complete" => false, "uid" => nil, "display_name" => nil},
             "model_profiles" => %{
               "complete" => false,
               "agent_uid" => nil,
               "missing_profiles" => ["primary", "light", "heavy"]
             },
             "worker" => %{"complete" => false, "ready_count" => 0},
             "signal_route" => %{"complete" => false}
           } = json_response(conn, 200)
  end

  test "readiness follows the active owner of a deployment instance signal route", %{conn: conn} do
    provider_id = "readiness-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    %{principal: agent} = agent_fixture(%{display_name: "Ready Agent"})

    for profile <- ~w(primary light heavy) do
      assert {:ok, _result} =
               ModelProfiles.put_model_profile(agent.uid, profile, %{
                 provider_id: provider_id,
                 model: "openai/gpt-5.6-sol"
               })
    end

    insert_ready_worker!()
    %{principal: route_agent} = agent_fixture(%{display_name: "Route Agent"})
    insert_signal_binding!(route_agent.uid)

    conn = bearer_conn(conn)
    agent_uid = agent.uid

    assert %{
             "ready" => true,
             "completed_core_steps" => 5,
             "total_core_steps" => 5,
             "provider" => %{"complete" => true, "provider_id" => ^provider_id},
             "agent" => %{
               "complete" => true,
               "uid" => ^agent_uid,
               "display_name" => "Ready Agent"
             },
             "model_profiles" => %{
               "complete" => true,
               "agent_uid" => ^agent_uid,
               "missing_profiles" => []
             },
             "worker" => %{"complete" => true, "ready_count" => 1},
             "signal_route" => %{"complete" => true}
           } = conn |> get(~p"/api/v1/console-readiness") |> json_response(200)

    assert {:ok, _principal} = Ankole.Principals.disable_principal(route_agent.uid)

    assert %{
             "ready" => false,
             "completed_core_steps" => 4,
             "total_core_steps" => 5,
             "signal_route" => %{"complete" => false}
           } = conn |> get(~p"/api/v1/console-readiness") |> json_response(200)
  end

  test "missing bearer token is rejected", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/console-readiness")
    assert json_response(conn, 401)
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

  defp active_admin_conn(conn) do
    {:ok, true} = SetupConfig.put_completed(true)
    human = human_fixture(%{uid: unique_uid("readiness-console-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn
    |> init_test_session(%{})
    |> WebSession.put_admin_session(%{
      principal_uid: human.principal.uid,
      provider_id: "lark-main",
      external_id: "external-1"
    })
  end

  defp insert_ready_worker! do
    now = DateTime.utc_now(:microsecond)

    %AgentComputerWorker{
      worker_id: "readiness-worker-#{System.unique_integer([:positive])}",
      incarnation_id: Ecto.UUID.generate(),
      status: "ready",
      version: "test",
      capacity: %{"available_turn_slots" => 1, "max_turns" => 1},
      load: %{"active_turns" => 0},
      transport_route: "readiness-route-#{System.unique_integer([:positive])}",
      last_worker_heartbeat_at: now,
      started_at: now,
      metadata: %{"runtime" => "test"}
    }
    |> Ecto.Changeset.change()
    |> Repo.insert!()
  end

  defp insert_signal_binding!(agent_uid) do
    %Binding{}
    |> Binding.changeset(%{
      agent_uid: agent_uid,
      name: "readiness",
      adapter: "lark",
      config_ref: "signals_gateway.lark.bindings.readiness",
      filters: %{},
      enabled: true
    })
    |> Repo.insert!()
  end
end
