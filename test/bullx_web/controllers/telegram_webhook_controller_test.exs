defmodule BullXWeb.TelegramWebhookControllerTest do
  use BullXWeb.ConnCase, async: false

  alias BullX.Config.GeneratedSecret
  alias BullXGateway.AdapterSupervisor

  defmodule GatewayStub do
    @pid_key {__MODULE__, :pid}

    def put_pid(pid), do: :persistent_term.put(@pid_key, pid)

    def clear do
      :persistent_term.erase(@pid_key)
      :persistent_term.erase({__MODULE__, :publish_response})
    end

    def put_publish_response(response),
      do: :persistent_term.put({__MODULE__, :publish_response}, response)

    def deliver(delivery) do
      send(:persistent_term.get(@pid_key), {:delivery, delivery})
      {:ok, delivery.id}
    end

    def publish_inbound(input) do
      send(:persistent_term.get(@pid_key), {:publish_inbound, input})
      :persistent_term.get({__MODULE__, :publish_response}, {:ok, :published})
    end
  end

  defmodule AccountsStub do
    def match_or_create_from_channel(_input), do: {:ok, %{id: "user-1"}, %{id: "binding-1"}}
  end

  setup do
    GatewayStub.put_pid(self())
    secret = GeneratedSecret.generate()
    channel = {:telegram, "default"}

    {:ok, _pid} =
      AdapterSupervisor.start_channel(channel, BullXTelegram.Adapter, %{
        bot_token: "bot",
        transport: %{mode: "webhook", secret_token: secret},
        gateway_module: GatewayStub,
        accounts_module: AccountsStub,
        start_transport?: false
      })

    on_exit(fn ->
      GatewayStub.clear()
      AdapterSupervisor.stop_channel(channel)
    end)

    {:ok, secret: secret}
  end

  test "rejects missing or invalid webhook secrets", %{conn: conn} do
    conn =
      post(conn, ~p"/gateway/telegram/default/webhook", %{
        "update_id" => 1
      })

    assert json_response(conn, 401)["ok"] == false
  end

  test "dispatches authenticated Telegram webhook updates to the channel", %{
    conn: conn,
    secret: secret
  } do
    conn =
      conn
      |> put_req_header("x-telegram-bot-api-secret-token", secret)
      |> post(~p"/gateway/telegram/default/webhook", ping_update())

    assert %{"ok" => true} = json_response(conn, 200)

    assert_receive {:delivery, delivery}
    assert delivery.channel == {:telegram, "default"}
    assert delivery.scope_id == "200"
    assert delivery.content.body["text"] == "PONG!"
  end

  test "duplicate direct-command webhook updates still return 200", %{conn: conn, secret: secret} do
    conn =
      conn
      |> put_req_header("x-telegram-bot-api-secret-token", secret)
      |> post(~p"/gateway/telegram/default/webhook", ping_update())

    assert %{"ok" => true} = json_response(conn, 200)
    assert_receive {:delivery, _delivery}

    conn =
      build_conn()
      |> put_req_header("x-telegram-bot-api-secret-token", secret)
      |> post(~p"/gateway/telegram/default/webhook", ping_update())

    assert %{"ok" => true, "result" => %{"duplicate" => true}} = json_response(conn, 200)
    refute_receive {:delivery, _delivery}
  end

  test "returns 404 for unknown or non-webhook channels", %{conn: conn, secret: secret} do
    conn =
      conn
      |> put_req_header("x-telegram-bot-api-secret-token", secret)
      |> post(~p"/gateway/telegram/missing/webhook", ping_update())

    assert json_response(conn, 404)["ok"] == false

    {:ok, _pid} =
      AdapterSupervisor.start_channel({:telegram, "polling"}, BullXTelegram.Adapter, %{
        bot_token: "bot",
        transport: %{mode: "polling"},
        gateway_module: GatewayStub,
        start_transport?: false
      })

    on_exit(fn -> AdapterSupervisor.stop_channel({:telegram, "polling"}) end)

    conn =
      build_conn()
      |> put_req_header("x-telegram-bot-api-secret-token", secret)
      |> post(~p"/gateway/telegram/polling/webhook", ping_update())

    assert json_response(conn, 404)["ok"] == false
  end

  test "returns 400 for invalid authenticated payload", %{conn: conn, secret: secret} do
    conn =
      conn
      |> put_req_header("x-telegram-bot-api-secret-token", secret)
      |> post(~p"/gateway/telegram/default/webhook", %{"message" => %{}})

    assert json_response(conn, 400)["ok"] == false
  end

  test "ignored authenticated updates return 200", %{conn: conn, secret: secret} do
    update = put_in(ping_update(), ["message", "from", "is_bot"], true)

    conn =
      conn
      |> put_req_header("x-telegram-bot-api-secret-token", secret)
      |> post(~p"/gateway/telegram/default/webhook", update)

    assert %{"ok" => true} = json_response(conn, 200)
    refute_receive {:delivery, _delivery}
  end

  test "dispatch errors return 500 for authenticated webhook updates", %{
    conn: conn,
    secret: secret
  } do
    GatewayStub.put_publish_response(
      {:error, %{"kind" => "transport", "message" => "publish failed", "details" => %{}}}
    )

    conn =
      conn
      |> put_req_header("x-telegram-bot-api-secret-token", secret)
      |> post(~p"/gateway/telegram/default/webhook", text_update())

    assert %{"ok" => false, "error" => %{"kind" => "transport"}} = json_response(conn, 500)
    assert_receive {:publish_inbound, _input}
  end

  defp ping_update do
    %{
      "update_id" => 100,
      "message" => %{
        "message_id" => 10,
        "date" => 1_777_777_777,
        "text" => "/ping",
        "chat" => %{"id" => 200, "type" => "private"},
        "from" => %{"id" => 300, "first_name" => "Alice", "is_bot" => false}
      }
    }
  end

  defp text_update do
    %{
      "update_id" => 101,
      "message" => %{
        "message_id" => 11,
        "date" => 1_777_777_777,
        "text" => "hello",
        "chat" => %{"id" => 200, "type" => "private"},
        "from" => %{"id" => 300, "first_name" => "Alice", "is_bot" => false}
      }
    }
  end
end
