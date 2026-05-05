defmodule BullXFeishu.StreamingCardTest do
  use ExUnit.Case, async: false

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXGateway.Delivery.Outcome
  alias BullXFeishu.{Config, StreamingCard}
  alias FeishuOpenAPI.{Client, TokenStore}

  setup do
    if :ets.info(TokenStore.table()) == :undefined do
      :ets.new(TokenStore.table(), [:named_table, :public, :set])
    end

    client =
      FeishuOpenAPI.new("cli_test", "secret_test", req_options: [plug: {Req.Test, __MODULE__}])

    put_tenant_token(client)

    {:ok, config} =
      Config.normalize({:feishu, "default"}, %{
        client: client,
        app_id: "cli_test",
        app_secret: "secret_test",
        stream_update_interval_ms: 0
      })

    on_exit(fn -> delete_tenant_token(client) end)

    {:ok, config: config}
  end

  test "creates a CardKit streaming card, batches small chunks, and closes it", %{
    config: config
  } do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    Req.Test.stub(__MODULE__, fn conn ->
      call = Agent.get_and_update(calls, fn count -> {count, count + 1} end)
      body = decoded_body(conn)

      case call do
        0 ->
          assert conn.method == "POST"
          assert conn.request_path == "/open-apis/cardkit/v1/cards"
          assert body["type"] == "card_json"

          card = Jason.decode!(body["data"])
          assert card["schema"] == "2.0"
          assert card["config"]["streaming_mode"] == true
          assert card["config"]["streaming_config"]["print_strategy"] == "fast"
          assert [element] = card["body"]["elements"]
          assert element["tag"] == "markdown"
          assert element["element_id"] == "content"

          Req.Test.json(conn, %{"code" => 0, "data" => %{"card_id" => "card_1"}})

        1 ->
          assert conn.method == "POST"
          assert conn.request_path == "/open-apis/im/v1/messages/om_parent/reply"
          assert body["msg_type"] == "interactive"

          assert Jason.decode!(body["content"]) == %{
                   "type" => "card",
                   "data" => %{"card_id" => "card_1"}
                 }

          Req.Test.json(conn, %{"code" => 0, "data" => %{"message_id" => "om_stream"}})

        2 ->
          assert conn.method == "PUT"

          assert conn.request_path ==
                   "/open-apis/cardkit/v1/cards/card_1/elements/content/content"

          assert body["content"] == "abcdefghijk"
          assert body["sequence"] == 2

          Req.Test.json(conn, %{"code" => 0, "data" => %{}})

        3 ->
          assert conn.method == "PUT"

          assert conn.request_path ==
                   "/open-apis/cardkit/v1/cards/card_1/elements/content/content"

          assert body["content"] == "abcdefghijkl"
          assert body["sequence"] == 3

          Req.Test.json(conn, %{"code" => 0, "data" => %{}})

        4 ->
          assert conn.method == "PATCH"
          assert conn.request_path == "/open-apis/cardkit/v1/cards/card_1/settings"
          assert body["sequence"] == 4

          settings = Jason.decode!(body["settings"])
          assert settings["config"]["streaming_mode"] == false
          assert settings["config"]["summary"]["content"] == "abcdefghijkl"

          Req.Test.json(conn, %{"code" => 0, "data" => %{}})
      end
    end)

    delivery = %GatewayDelivery{
      id: "delivery_stream",
      op: :stream,
      channel: {:feishu, "default"},
      scope_id: "oc_1",
      reply_to_external_id: "om_parent",
      content: ["abc", "defg", "hijk", "l"]
    }

    assert {:ok, %Outcome{status: :sent, primary_external_id: "om_stream", warnings: []}} =
             StreamingCard.stream(delivery, delivery.content, config)

    assert Agent.get(calls, & &1) == 5
  end

  test "preserves markdown newlines and repeated fragments across batched chunks", %{
    config: config
  } do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    Req.Test.stub(__MODULE__, fn conn ->
      call = Agent.get_and_update(calls, fn count -> {count, count + 1} end)
      body = decoded_body(conn)

      case call do
        0 ->
          assert conn.method == "POST"
          assert conn.request_path == "/open-apis/cardkit/v1/cards"
          Req.Test.json(conn, %{"code" => 0, "data" => %{"card_id" => "card_md"}})

        1 ->
          assert conn.method == "POST"
          assert conn.request_path == "/open-apis/im/v1/messages/om_parent/reply"
          Req.Test.json(conn, %{"code" => 0, "data" => %{"message_id" => "om_stream"}})

        2 ->
          assert conn.method == "PUT"

          assert conn.request_path ==
                   "/open-apis/cardkit/v1/cards/card_md/elements/content/content"

          assert body["content"] == "# A\n\n- one"
          assert body["sequence"] == 2

          Req.Test.json(conn, %{"code" => 0, "data" => %{}})

        3 ->
          assert conn.method == "PUT"

          assert conn.request_path ==
                   "/open-apis/cardkit/v1/cards/card_md/elements/content/content"

          assert body["content"] == "# A\n\n- one\n- one\ndone"
          assert body["sequence"] == 3

          Req.Test.json(conn, %{"code" => 0, "data" => %{}})

        4 ->
          assert conn.method == "PATCH"
          assert conn.request_path == "/open-apis/cardkit/v1/cards/card_md/settings"
          assert body["sequence"] == 4

          settings = Jason.decode!(body["settings"])
          assert settings["config"]["streaming_mode"] == false
          assert settings["config"]["summary"]["content"] == "# A - one - one done"

          Req.Test.json(conn, %{"code" => 0, "data" => %{}})
      end
    end)

    delivery = %GatewayDelivery{
      id: "delivery_markdown_stream",
      op: :stream,
      channel: {:feishu, "default"},
      scope_id: "oc_1",
      reply_to_external_id: "om_parent",
      content: ["# A", "\n\n", "- one", "\n", "- one", "\n", "done"]
    }

    assert {:ok, %Outcome{status: :sent, primary_external_id: "om_stream", warnings: []}} =
             StreamingCard.stream(delivery, delivery.content, config)

    assert Agent.get(calls, & &1) == 5
  end

  defp decoded_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  defp put_tenant_token(%Client{} = client) do
    :ets.insert(
      TokenStore.table(),
      {{:tenant, Client.cache_namespace(client), nil}, "t-token", :infinity}
    )
  end

  defp delete_tenant_token(%Client{} = client) do
    :ets.delete(TokenStore.table(), {:tenant, Client.cache_namespace(client), nil})
  end
end
