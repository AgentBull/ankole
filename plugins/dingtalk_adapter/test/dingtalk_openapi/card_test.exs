defmodule DingTalkOpenAPI.CardTest do
  # async: false — seeds a shared-ETS app token.
  use ExUnit.Case, async: false

  alias DingTalkOpenAPI.{Card, Client}

  setup do
    client =
      Client.new(
        client_id: "ding-card",
        client_secret: "secret",
        api_base_url: "https://api.dingtalk.test",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    seed_app_token(client, "atok")
    %{client: client}
  end

  test "create_instance posts the template params", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1.0/card/instances"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Torque.decode!(body)
      assert decoded["cardTemplateId"] == "tpl-1"
      assert decoded["outTrackId"] == "ot-1"
      assert decoded["callbackType"] == "STREAM"
      Req.Test.json(conn, %{"result" => %{"outTrackId" => "ot-1"}})
    end)

    assert {:ok, _} =
             Card.create_instance(client, %{
               "cardTemplateId" => "tpl-1",
               "outTrackId" => "ot-1",
               "callbackType" => "STREAM",
               "cardData" => %{"cardParamMap" => %{}}
             })
  end

  test "streaming_update PUTs the streaming variable payload", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v1.0/card/streaming"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Torque.decode!(body)
      assert decoded["outTrackId"] == "ot-1"
      assert decoded["key"] == "answer"
      assert decoded["isFull"] == true
      assert decoded["guid"] == "g-1"
      Req.Test.json(conn, %{"success" => true})
    end)

    assert {:ok, _} =
             Card.streaming_update(client, %{
               "outTrackId" => "ot-1",
               "guid" => "g-1",
               "key" => "answer",
               "content" => "partial",
               "isFull" => true,
               "isFinalize" => false,
               "isError" => false
             })
  end

  test "update_instance PUTs the terminal cardData", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v1.0/card/instances"
      Req.Test.json(conn, %{"success" => true})
    end)

    assert {:ok, _} =
             Card.update_instance(client, %{
               "outTrackId" => "ot-1",
               "cardData" => %{"cardParamMap" => %{"answer" => "done"}}
             })
  end

  test "create_and_deliver hits the combined endpoint", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1.0/card/instances/createAndDeliver"
      Req.Test.json(conn, %{"result" => %{"outTrackId" => "ot-1"}})
    end)

    assert {:ok, _} = Card.create_and_deliver(client, %{"outTrackId" => "ot-1"})
  end

  defp seed_app_token(client, token) do
    key = {:app, Client.cache_namespace(client)}
    expires_at = System.monotonic_time(:millisecond) + :timer.hours(1)
    :ets.insert(DingTalkOpenAPI.TokenStore.table(), {key, token, expires_at})

    on_exit(fn -> :ets.delete(DingTalkOpenAPI.TokenStore.table(), key) end)
  end
end
