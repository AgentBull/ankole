defmodule DingTalkOpenAPI.TokenManagerTest do
  use ExUnit.Case, async: false

  alias DingTalkOpenAPI.{Client, TokenManager, TokenStore}

  setup do
    client_id = "ding_tm_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    {:ok, client_id: client_id}
  end

  test "concurrent cache-miss callers trigger exactly one upstream fetch", %{client_id: client_id} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1.0/oauth2/accessToken"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Torque.decode!(body)
      assert decoded["appKey"] == client_id
      assert decoded["appSecret"] == "secret"
      Agent.update(counter, &(&1 + 1))
      Process.sleep(150)
      Req.Test.json(conn, %{"accessToken" => "app-tok", "expireIn" => 7200})
    end)

    client =
      Client.new(
        client_id: client_id,
        client_secret: "secret",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    {:ok, manager_pid} =
      DynamicSupervisor.start_child(
        DingTalkOpenAPI.TokenManager.Supervisor,
        {TokenManager, client}
      )

    Req.Test.allow(__MODULE__, self(), manager_pid)
    on_exit(fn -> :ets.delete(TokenStore.table(), {:app, Client.cache_namespace(client)}) end)

    results =
      for _ <- 1..15 do
        Task.async(fn -> TokenManager.get_app_token(client) end)
      end
      |> Enum.map(&Task.await(&1, :timer.seconds(5)))

    assert Enum.all?(results, &match?({:ok, "app-tok"}, &1))
    assert Agent.get(counter, & &1) == 1
  end

  test "a warm cache is served without any upstream call", %{client_id: client_id} do
    client = Client.new(client_id: client_id, client_secret: "secret")
    key = {:app, Client.cache_namespace(client)}

    :ets.insert(
      TokenStore.table(),
      {key, "warm", System.monotonic_time(:millisecond) + :timer.hours(1)}
    )

    on_exit(fn -> :ets.delete(TokenStore.table(), key) end)

    assert {:ok, "warm"} = TokenManager.get_app_token(client)
  end

  test "a crashing secret closure is returned as an error, not a wedged manager", %{
    client_id: client_id
  } do
    client = Client.new(client_id: client_id, client_secret: fn -> raise "secret exploded" end)
    on_exit(fn -> :ets.delete(TokenStore.table(), {:app, Client.cache_namespace(client)}) end)

    assert {:error, %DingTalkOpenAPI.Error{reason: :transport}} =
             TokenManager.get_app_token(client)
  end
end
