defmodule FeishuOpenAPI.TokenManagerTest do
  use ExUnit.Case, async: false

  alias FeishuOpenAPI.{Client, TokenManager, TokenStore}

  setup do
    # These tests use a unique app_id per run so DynamicSupervisor doesn't hit
    # {:already_started, pid} for a process from a previous test.
    app_id = "cli_tm_" <> Integer.to_string(:erlang.unique_integer([:positive]))

    {:ok, app_id: app_id}
  end

  test "concurrent cache-miss callers trigger exactly one upstream fetch", %{app_id: app_id} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(FeishuOpenAPI.TokenManagerTest, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Process.sleep(200)

      Req.Test.json(conn, %{
        "code" => 0,
        "tenant_access_token" => "t-shared",
        "expire" => 7200
      })
    end)

    client =
      Client.new(app_id, "secret",
        req_options: [plug: {Req.Test, FeishuOpenAPI.TokenManagerTest}]
      )

    # Force-start the per-app TokenManager and allow its process (and, by
    # $callers inheritance, its spawned fetch Tasks) to use the test stub.
    {:ok, manager_pid} =
      DynamicSupervisor.start_child(
        FeishuOpenAPI.TokenManager.Supervisor,
        {TokenManager, client}
      )

    Req.Test.allow(FeishuOpenAPI.TokenManagerTest, self(), manager_pid)

    tasks =
      for _ <- 1..20 do
        Task.async(fn -> TokenManager.get_tenant_token(client) end)
      end

    results = Enum.map(tasks, &Task.await(&1, :timer.seconds(5)))

    assert Enum.all?(results, &match?({:ok, "t-shared"}, &1))
    assert Agent.get(counter, & &1) == 1
  end

  test "bang-style invalidation clears the ETS cache", %{app_id: app_id} do
    client = Client.new(app_id, "s")
    on_exit(fn -> cleanup_client_entries(client) end)
    :ets.insert(TokenStore.table(), {tenant_key(client), "stale", :infinity})

    assert :ok = TokenManager.invalidate(client, :tenant)
    assert :ets.lookup(TokenStore.table(), tenant_key(client)) == []
  end

  test "crashing token fetches are returned as errors and do not wedge the manager", %{
    app_id: app_id
  } do
    client =
      Client.new(app_id, fn ->
        raise "secret fetch exploded"
      end)

    on_exit(fn -> cleanup_client_entries(client) end)

    for _ <- 1..2 do
      task = Task.async(fn -> TokenManager.get_tenant_token(client) end)

      assert {:error, %FeishuOpenAPI.Error{code: :token_fetch_crashed, msg: msg}} =
               Task.await(task, :timer.seconds(1))

      assert msg =~ "secret fetch exploded"
    end
  end

  test "clients with the same app_id but different cache namespaces do not share cached tokens",
       %{
         app_id: app_id
       } do
    client_a = Client.new(app_id, "secret-a")
    client_b = Client.new(app_id, "secret-b", app_type: :marketplace)

    on_exit(fn ->
      cleanup_client_entries(client_a)
      cleanup_client_entries(client_b)
    end)

    assert Client.cache_namespace(client_a) != Client.cache_namespace(client_b)

    :ets.insert(TokenStore.table(), {tenant_key(client_a), "token-a", :infinity})

    assert {:ok, "token-a"} = TokenManager.get_tenant_token(client_a)

    assert {:error, %FeishuOpenAPI.Error{code: :tenant_key_required}} =
             TokenManager.get_tenant_token(client_b)

    assert :ets.lookup(TokenStore.table(), tenant_key(client_b)) == []
  end

  defp tenant_key(client, tenant_key \\ nil) do
    {:tenant, Client.cache_namespace(client), tenant_key}
  end

  defp cleanup_client_entries(client) do
    cache_namespace = Client.cache_namespace(client)
    :ets.match_delete(TokenStore.table(), {{:tenant, cache_namespace, :_}, :_, :_})
    :ets.delete(TokenStore.table(), {:app, cache_namespace})
    :ets.delete(TokenStore.table(), {:app_ticket, cache_namespace})
  end
end
