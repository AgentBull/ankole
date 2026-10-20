defmodule FeishuOpenAPI.RequestInstrumentationTest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.{Client, TokenStore}

  setup do
    if :ets.info(TokenStore.table()) == :undefined do
      :ets.new(TokenStore.table(), [:named_table, :public, :set])
    end

    client =
      FeishuOpenAPI.new("cli_ri", "secret_x",
        req_options: [plug: {Req.Test, FeishuOpenAPI.RequestInstrumentationTest}]
      )

    put_tenant_token(client)

    on_exit(fn ->
      if :ets.info(TokenStore.table()) != :undefined do
        delete_tenant_token(client)
      end
    end)

    {:ok, client: client}
  end

  test "emits start + stop telemetry events with metadata", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.RequestInstrumentationTest, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-tt-logid", "log-tel")
      |> Req.Test.json(%{"code" => 0, "data" => %{}})
    end)

    handler_id = {__MODULE__, :tel, :erlang.unique_integer()}
    parent = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:feishu_openapi, :request, :start],
        [:feishu_openapi, :request, :stop]
      ],
      fn event, measurements, metadata, _ ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    try do
      assert {:ok, _} = FeishuOpenAPI.get(client, "im/v1/chats")

      assert_receive {:telemetry, [:feishu_openapi, :request, :start], _,
                      %{method: :get, path: "im/v1/chats", app_id: "cli_ri"}}

      assert_receive {:telemetry, [:feishu_openapi, :request, :stop], %{duration: d},
                      %{app_id: "cli_ri", outcome: :ok}}

      assert is_integer(d) and d > 0
    after
      :telemetry.detach(handler_id)
    end
  end

  test "get!/3 returns the decoded body on success", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.RequestInstrumentationTest, fn conn ->
      Req.Test.json(conn, %{"code" => 0, "data" => %{"ok" => true}})
    end)

    assert %{"code" => 0, "data" => %{"ok" => true}} =
             FeishuOpenAPI.get!(client, "ping")
  end

  test "get!/3 raises FeishuOpenAPI.Error on failure", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.RequestInstrumentationTest, fn conn ->
      Req.Test.json(conn, %{"code" => 99_999, "msg" => "boom"})
    end)

    assert_raise FeishuOpenAPI.Error, fn ->
      FeishuOpenAPI.get!(client, "ping")
    end
  end

  test "429 with Retry-After is honored and then retried once", %{client: client} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(FeishuOpenAPI.RequestInstrumentationTest, fn conn ->
      call = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

      if call == 0 do
        conn
        |> Plug.Conn.put_resp_header("retry-after", "1")
        |> Plug.Conn.put_status(429)
        |> Req.Test.text("rate limited")
      else
        Req.Test.json(conn, %{"code" => 0, "data" => %{"after" => "retry"}})
      end
    end)

    start = System.monotonic_time(:millisecond)
    assert {:ok, %{"code" => 0}} = FeishuOpenAPI.get(client, "ping")
    elapsed = System.monotonic_time(:millisecond) - start

    assert Agent.get(counter, & &1) == 2
    assert elapsed >= 900
  end

  test "persistent 429 returns a rate_limited error after retry budget is exhausted", %{
    client: client
  } do
    Req.Test.stub(FeishuOpenAPI.RequestInstrumentationTest, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "1")
      |> Plug.Conn.put_status(429)
      |> Req.Test.text("keep rate limiting")
    end)

    assert {:error, %FeishuOpenAPI.Error{code: :rate_limited, http_status: 429}} =
             FeishuOpenAPI.get(client, "ping")
  end

  test "logger metadata is restored after requests, including feishu_log_id", %{client: client} do
    initial_metadata = [existing: "keep", request_id: "rid-1"]
    Logger.reset_metadata(initial_metadata)

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(FeishuOpenAPI.RequestInstrumentationTest, fn conn ->
      call = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

      case call do
        0 ->
          conn
          |> Plug.Conn.put_resp_header("x-tt-logid", "log-first")
          |> Req.Test.json(%{"code" => 0, "data" => %{}})

        1 ->
          Req.Test.json(conn, %{"code" => 0, "data" => %{}})
      end
    end)

    try do
      assert {:ok, _} = FeishuOpenAPI.get(client, "ping")
      assert Logger.metadata() == initial_metadata

      assert {:ok, _} = FeishuOpenAPI.get(client, "ping-2")
      assert Logger.metadata() == initial_metadata
    after
      Logger.reset_metadata([])
    end
  end

  defp put_tenant_token(client, token \\ "t-token", tenant_key \\ nil) do
    :ets.insert(TokenStore.table(), {tenant_key(client, tenant_key), token, :infinity})
  end

  defp delete_tenant_token(client, tenant_key \\ nil) do
    :ets.delete(TokenStore.table(), tenant_key(client, tenant_key))
  end

  defp tenant_key(%Client{} = client, tenant_key) do
    {:tenant, Client.cache_namespace(client), tenant_key}
  end
end
