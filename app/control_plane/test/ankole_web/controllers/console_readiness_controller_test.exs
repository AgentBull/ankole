defmodule AnkoleWeb.ConsoleReadinessControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AppConfigure.Registry
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.SessionsCase

  setup do
    Registry.clear_for_test()
    CredentialPool.reset_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin sees incomplete deployment instance facts", %{conn: conn} do
    conn = console_conn(conn) |> api_get(~p"/api/v2/console-readiness")

    assert %{
             "ready" => false,
             "completed_core_steps" => 0,
             "total_core_steps" => 4,
             "provider" => %{"complete" => false, "provider_id" => nil},
             "agent" => %{"complete" => false, "uid" => nil, "display_name" => nil},
             "model_profiles" => %{
               "complete" => false,
               "agent_uid" => nil,
               "missing_profiles" => ["primary", "light", "heavy"]
             },
             "worker" => %{"complete" => false, "ready_count" => 0}
           } = json_response(conn, 200)
  end

  test "an Agent is ready for native work without an external message channel", %{conn: conn} do
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
    assert {:ok, []} = Ankole.Signals.Bindings.list_bindings()

    conn = console_conn(conn)
    agent_uid = agent.uid
    response = conn |> api_get(~p"/api/v2/console-readiness") |> json_response(200)

    assert %{
             "ready" => true,
             "completed_core_steps" => 4,
             "total_core_steps" => 4,
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
             "worker" => %{"complete" => true, "ready_count" => 1}
           } = response

    assert Enum.sort(Map.keys(response)) ==
             ~w(agent completed_core_steps model_profiles provider ready total_core_steps worker)

    assert {:ok, _principal} =
             Ankole.PrincipalsFixtures.disable_principal_fixture(agent_uid)

    assert %{
             "ready" => false,
             "completed_core_steps" => 2,
             "total_core_steps" => 4,
             "agent" => %{"complete" => false},
             "model_profiles" => %{"complete" => false}
           } = conn |> api_get(~p"/api/v2/console-readiness") |> json_response(200)
  end

  test "missing browser session is rejected", %{conn: conn} do
    conn = api_get(conn, ~p"/api/v2/console-readiness")
    assert json_response(conn, 401)
  end

  defp mark_worker_ready!(agent_uid) do
    route = "readiness-route-#{System.unique_integer([:positive])}"
    {:ok, _worker} = SessionsCase.admit_worker(route, %{worker_id: agent_uid})
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
