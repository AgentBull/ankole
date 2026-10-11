defmodule Ankole.SignalsGateway.ActorRuntime.WorkerWebFetchConfigTest do
  use Ankole.AIGatewayCase

  alias Ankole.AppConfigure
  alias Ankole.SignalsGateway.ActorRuntime.WorkerWebFetchConfig

  setup do
    allow_cache_database_access()
    definition = WorkerWebFetchConfig.definition()
    :ok = AppConfigure.delete_global(definition)
    {:ok, definition: definition}
  end

  test "builds the same typed fetch policy from default and tenant settings" do
    %{principal: agent} = agent_fixture()

    for ssrf? <- [true, false] do
      assert {:ok, ^ssrf?} =
               AppConfigure.put_global(Ankole.Security.SSRFFilter.definition(), ssrf?)

      assert {:ok, %{ssrf_filter: ^ssrf?, rendered_fetch_idle_ttl_ms: 1_800_000}} =
               WorkerWebFetchConfig.runtime_config(agent.uid)

      assert {:ok, 600_000} =
               AppConfigure.put_tenant_by_key("worker.rendered_fetch_idle_ttl_ms", 600_000)

      assert {:ok, %{ssrf_filter: ^ssrf?, rendered_fetch_idle_ttl_ms: 600_000}} =
               WorkerWebFetchConfig.runtime_config(agent.uid)

      assert :ok = AppConfigure.delete_tenant_by_key("worker.rendered_fetch_idle_ttl_ms")
    end
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
    assert {:ok, ^agent_ttl} = AppConfigure.put_tenant_by_key(definition.key, agent_ttl)
    assert {:ok, %{value: ^agent_ttl, source: :tenant}} = WorkerWebFetchConfig.resolve(agent.uid)
  end
end
