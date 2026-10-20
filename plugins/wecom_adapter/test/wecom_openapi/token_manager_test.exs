defmodule WeComOpenAPI.TokenManagerTest do
  use ExUnit.Case, async: false

  alias WeComOpenAPI.Corp.Client
  alias WeComOpenAPI.{TokenManager, TokenStore}

  test "a killed fetch task releases waiters and permits a retry" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:token_fetch_started, self()})

      receive do
        :finish_token_fetch ->
          Req.Test.json(conn, %{
            "errcode" => 0,
            "errmsg" => "ok",
            "access_token" => "wecom-after-retry",
            "expires_in" => 7200
          })
      end
    end)

    client =
      Client.new(
        corp_id: "corp-token-manager-test",
        secret: "secret",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    {:ok, manager_pid} =
      DynamicSupervisor.start_child(
        WeComOpenAPI.TokenManager.Supervisor,
        {TokenManager, client}
      )

    Req.Test.allow(__MODULE__, self(), manager_pid)
    on_exit(fn -> :ets.delete(TokenStore.table(), {:corp, Client.cache_namespace(client)}) end)

    first = Task.async(fn -> TokenManager.get_corp_token(client) end)
    assert_receive {:token_fetch_started, fetch_pid}, 1_000
    Process.exit(fetch_pid, :kill)

    assert {:error, %WeComOpenAPI.Error{reason: :transport}} = Task.await(first, 1_000)

    second = Task.async(fn -> TokenManager.get_corp_token(client) end)
    assert_receive {:token_fetch_started, retry_pid}, 1_000
    send(retry_pid, :finish_token_fetch)
    assert {:ok, "wecom-after-retry"} = Task.await(second, 1_000)
  end
end
