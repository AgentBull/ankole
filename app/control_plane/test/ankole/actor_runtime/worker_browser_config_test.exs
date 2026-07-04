defmodule Ankole.ActorRuntime.WorkerBrowserConfigTest do
  use Ankole.AIGatewayCase

  import Ecto.Query

  alias Ankole.ActorRuntime.WorkerBrowserConfig
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.Repo

  setup do
    allow_cache_database_access()
    :ok = WorkerBrowserConfig.ensure_registered()

    remote_definition = WorkerBrowserConfig.remote_cdp_config_definition()
    ttl_definition = WorkerBrowserConfig.local_browser_idle_ttl_ms_definition()
    :ok = AppConfigure.delete_global(remote_definition)
    :ok = AppConfigure.delete_global(ttl_definition)

    {:ok, remote_definition: remote_definition, ttl_definition: ttl_definition}
  end

  test "remote CDP config defaults to local browser and resolves agent over global", %{
    remote_definition: definition
  } do
    %{principal: agent} = agent_fixture()

    assert {:ok, %{value: nil, source: :default}} =
             WorkerBrowserConfig.resolve_remote_cdp_config(agent.uid)

    global_config = %{
      "adapter" => "cdp_endpoint",
      "endpoint_url" =>
        "wss://api.cloudflare.com/client/v4/accounts/account/browser-rendering/devtools/browser",
      "headers" => %{"Authorization" => "Bearer cf-token"},
      "connect_timeout_ms" => 30_000
    }

    assert {:ok, ^global_config} = AppConfigure.put_global(definition, global_config)

    assert {:ok, %{value: ^global_config, source: :global}} =
             WorkerBrowserConfig.resolve_remote_cdp_config(agent.uid)

    agent_config = %{
      "adapter" => "cdp_session_request",
      "request" => %{
        "url" => "http://rayobrowse.lan:3000/connect?headless=true",
        "response" => %{"type" => "json", "path" => ["webSocketDebuggerUrl"]}
      }
    }

    assert {:ok, ^agent_config} = AppConfigure.put_for_agent(agent.uid, definition, agent_config)

    assert {:ok, %{value: ^agent_config, source: :agent}} =
             WorkerBrowserConfig.resolve_remote_cdp_config(agent.uid)
  end

  test "local browser idle TTL is scoped, conservative by default, and range-checked", %{
    ttl_definition: definition
  } do
    %{principal: agent} = agent_fixture()

    assert {:ok, %{value: 1_800_000, source: :default}} =
             WorkerBrowserConfig.resolve_local_browser_idle_ttl_ms(agent.uid)

    assert {:error, {:invalid_local_browser_idle_ttl_ms, _range}} =
             AppConfigure.put_global(definition, 1_000)

    global_ttl = 45 * 60 * 1_000
    assert {:ok, ^global_ttl} = AppConfigure.put_global(definition, global_ttl)

    assert {:ok, %{value: ^global_ttl, source: :global}} =
             WorkerBrowserConfig.resolve_local_browser_idle_ttl_ms(agent.uid)

    agent_ttl = 2 * 60 * 60 * 1_000
    assert {:ok, ^agent_ttl} = AppConfigure.put_for_agent(agent.uid, definition, agent_ttl)

    assert {:ok, %{value: ^agent_ttl, source: :agent}} =
             WorkerBrowserConfig.resolve_local_browser_idle_ttl_ms(agent.uid)
  end

  test "remote CDP config is encrypted at rest and validates adapter shape", %{
    remote_definition: definition
  } do
    config = %{
      "adapter" => "cdp_endpoint",
      "endpoint_url" => "wss://USER:PASS@brd.superproxy.io:9222"
    }

    assert {:ok, ^config} = AppConfigure.put_global(definition, config)

    row =
      Repo.one!(
        from row in AppConfig, where: row.scope == "global" and row.key == ^definition.key
      )

    assert get_in(row.value, ["type"]) == "cipher"
    refute inspect(row.value) =~ "USER:PASS"

    assert {:error, {:unsupported_adapter, "fetch"}} =
             AppConfigure.put_global(definition, %{"adapter" => "fetch"})
  end

  test "RuntimeFabric app_configure.resolve returns effective worker config without turn_start persistence",
       %{
         remote_definition: remote_definition,
         ttl_definition: ttl_definition
       } do
    %{principal: agent} = agent_fixture()

    config = %{
      "adapter" => "cdp_endpoint",
      "endpoint_url" => "https://browser.lan:9222",
      "headers" => %{"X-Browser-Token" => "secret"}
    }

    ttl = 45 * 60 * 1_000

    assert {:ok, ^config} = AppConfigure.put_for_agent(agent.uid, remote_definition, config)
    assert {:ok, ^ttl} = AppConfigure.put_global(ttl_definition, ttl)

    assert {:ok, envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "app-configure-1",
                 "method" => "app_configure.resolve",
                 "payload_json" => %{
                   "request_id" => "app-configure-1",
                   "agent_uid" => agent.uid,
                   "keys" => [
                     remote_definition.key,
                     ttl_definition.key
                   ]
                 }
               },
               "trusted-worker-route"
             )

    response = get_in(envelope, ["body", "rpc_response", "payload_json"])
    assert response["request_id"] == "app-configure-1"
    assert response["agent_uid"] == agent.uid
    assert get_in(response, ["values", remote_definition.key, "source"]) == "agent"
    assert get_in(response, ["values", remote_definition.key, "value"]) == config
    assert get_in(response, ["values", ttl_definition.key, "source"]) == "global"
    assert get_in(response, ["values", ttl_definition.key, "value"]) == ttl
  end

  test "RuntimeFabric app_configure.resolve rejects unknown agents", %{
    remote_definition: definition
  } do
    assert {:ok, envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "browser-config-missing-agent",
                 "method" => "app_configure.resolve",
                 "payload_json" => %{
                   "request_id" => "browser-config-missing-agent",
                   "agent_uid" => "agent-missing",
                   "keys" => [definition.key]
                 }
               },
               "trusted-worker-route"
             )

    assert get_in(envelope, ["body", "type"]) == "rpc_error"
    assert get_in(envelope, ["body", "rpc_error", "code"]) in ["not_found", "agent_not_found"]
  end

  test "RuntimeFabric app_configure.resolve rejects invalid payloads with a stable error" do
    assert {:ok, envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "browser-config-invalid",
                 "method" => "app_configure.resolve",
                 "payload_json" => %{"request_id" => "browser-config-invalid"}
               },
               "trusted-worker-route"
             )

    assert get_in(envelope, ["body", "type"]) == "rpc_error"
    assert get_in(envelope, ["body", "rpc_error", "code"]) == "missing_agent_uid"
  end

  test "RuntimeFabric app_configure.resolve rejects unknown keys" do
    %{principal: agent} = agent_fixture()

    assert {:ok, envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "app-configure-unknown-key",
                 "method" => "app_configure.resolve",
                 "payload_json" => %{
                   "request_id" => "app-configure-unknown-key",
                   "agent_uid" => agent.uid,
                   "keys" => ["worker.unknown"]
                 }
               },
               "trusted-worker-route"
             )

    assert get_in(envelope, ["body", "type"]) == "rpc_error"
    assert get_in(envelope, ["body", "rpc_error", "code"]) == "app_configure_resolve_failed"
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
