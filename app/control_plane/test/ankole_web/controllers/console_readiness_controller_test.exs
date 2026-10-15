defmodule AnkoleWeb.ConsoleReadinessControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.SessionsCase
  alias Ankole.Signals.Binding

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()
    CredentialPool.reset_for_test()

    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin sees incomplete deployment instance facts", %{conn: conn} do
    conn = console_conn(conn) |> get(~p"/api/v1/console-readiness")

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
    Ankole.AgentWorkerDockerHTTP.install()
    worker_provider_fixture(%{is_default: true})
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

    mark_worker_ready!(agent.uid)
    %{principal: route_agent} = agent_fixture(%{display_name: "Route Agent"})
    insert_signal_binding!(route_agent.uid)

    conn = console_conn(conn)
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

    assert {:ok, _principal} =
             Ankole.PrincipalsFixtures.disable_principal_fixture(route_agent.uid)

    assert %{
             "ready" => false,
             "completed_core_steps" => 4,
             "total_core_steps" => 5,
             "signal_route" => %{"complete" => false}
           } = conn |> get(~p"/api/v1/console-readiness") |> json_response(200)
  end

  test "missing browser session is rejected", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/console-readiness")
    assert json_response(conn, 401)
  end

  defp mark_worker_ready!(agent_uid) do
    route = "readiness-route-#{System.unique_integer([:positive])}"
    {:ok, _worker} = SessionsCase.admit_worker(route, %{worker_id: agent_uid})
  end

  defp insert_signal_binding!(agent_uid) do
    %Binding{}
    |> Binding.changeset(%{
      agent_uid: agent_uid,
      name: "readiness",
      adapter: "lark",
      config_ref: "app-config://signals.lark.bindings.readiness",
      filters: %{},
      enabled: true
    })
    |> Repo.insert!()
  end
end
