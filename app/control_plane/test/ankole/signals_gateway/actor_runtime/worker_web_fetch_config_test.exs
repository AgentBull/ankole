defmodule Ankole.SignalsGateway.ActorRuntime.WorkerWebFetchConfigTest do
  use Ankole.AIGatewayCase

  import Ankole.SignalsGateway.ActorRuntimeCase,
    only: [
      rpc_request: 3,
      rpc_response_payload!: 1,
      rpc_error_payload!: 1,
      envelope_body_type: 1,
      envelope_body!: 2
    ]

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.RPCLane
  alias Ankole.SignalsGateway.ActorRuntime.WorkerWebFetchConfig

  setup do
    allow_cache_database_access()
    :ok = WorkerWebFetchConfig.ensure_registered()
    definition = WorkerWebFetchConfig.definition()
    :ok = AppConfigure.delete_global(definition)
    {:ok, definition: definition}
  end

  test "rendered fetch idle TTL is scoped, conservative by default, and range checked", %{
    definition: definition
  } do
    %{principal: agent} = agent_fixture()

    assert definition.key == "worker.rendered_fetch_idle_ttl_ms"

    assert {:ok, %{value: 1_800_000, source: :default}} =
             WorkerWebFetchConfig.resolve(agent.uid)

    assert {:error, {:invalid_rendered_fetch_idle_ttl_ms, _range}} =
             AppConfigure.put_global(definition, 1_000)

    global_ttl = 45 * 60 * 1_000
    assert {:ok, ^global_ttl} = AppConfigure.put_global(definition, global_ttl)
    assert {:ok, %{value: ^global_ttl, source: :global}} = WorkerWebFetchConfig.resolve(agent.uid)

    agent_ttl = 2 * 60 * 60 * 1_000
    assert {:ok, ^agent_ttl} = AppConfigure.put_for_agent(agent.uid, definition, agent_ttl)
    assert {:ok, %{value: ^agent_ttl, source: :agent}} = WorkerWebFetchConfig.resolve(agent.uid)
  end

  test "RuntimeFabric exposes only the rendered fetch TTL definition", %{
    definition: definition
  } do
    %{principal: agent} = agent_fixture()
    ttl = 45 * 60 * 1_000
    assert {:ok, ^ttl} = AppConfigure.put_for_agent(agent.uid, definition, ttl)

    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request("web-fetch-config", "app_configure.resolve", %{
                 "request_id" => "web-fetch-config",
                 "agent_uid" => agent.uid,
                 "keys" => [definition.key]
               }),
               "trusted-worker-route"
             )

    response = rpc_response_payload!(envelope)
    assert get_in(response, ["values", definition.key, "value"]) == ttl

    assert {:ok, rejected} =
             RPCLane.handle_request(
               rpc_request("remote-browser-dormant", "app_configure.resolve", %{
                 "request_id" => "remote-browser-dormant",
                 "agent_uid" => agent.uid,
                 "keys" => ["worker.remote_browser_cdp_config"]
               }),
               "trusted-worker-route"
             )

    assert envelope_body_type(rejected) == :rpc_error
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
