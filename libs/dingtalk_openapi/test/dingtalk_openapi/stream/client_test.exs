defmodule DingTalkOpenAPI.Stream.ClientTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias DingTalkOpenAPI.Client, as: APIClient
  alias DingTalkOpenAPI.Stream.{Client, Dispatcher}

  test "start_link validates the dispatcher type" do
    client = APIClient.new(client_id: "ding-bad", client_secret: "secret")

    assert_raise ArgumentError, ~r/Dispatcher/, fn ->
      Client.start_link(client: client, dispatcher: :bad)
    end
  end

  test "registers, connects, echoes a SYSTEM ping opaque, and acks a CALLBACK after dispatch" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()
    server = spawn_link(fn -> run_ws_server(listener, parent) end)

    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on_callback("/v1.0/im/bot/messages/get", fn _topic, event ->
        send(parent, {:dispatched, event.data})
        {:ok, %{"received" => true}}
      end)

    client =
      APIClient.new(
        client_id: "ding-stream",
        client_secret: "secret",
        req_options: [
          plug: fn conn ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(parent, {:register, conn.request_path, Torque.decode!(body)})
            Req.Test.json(conn, %{"endpoint" => "ws://127.0.0.1:#{port}", "ticket" => "ticket-1"})
          end
        ]
      )

    {:ok, pid} =
      Client.start_link(client: client, dispatcher: dispatcher, auto_reconnect: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Client.stop(pid)
      send(server, :close)
    end)

    # Registration used the open endpoint with the client id and derived subscriptions.
    assert_receive {:register, "/v1.0/gateway/connections/open", register_body}, 1_000
    assert register_body["clientId"] == "ding-stream"

    assert %{"type" => "CALLBACK", "topic" => "/v1.0/im/bot/messages/get"} in register_body[
             "subscriptions"
           ]

    # SYSTEM ping is echoed with the same messageId and opaque, synchronously.
    assert_receive {:client_frame, ping_reply}, 1_500
    assert ping_reply["code"] == 200
    assert ping_reply["headers"]["messageId"] == "ping-msg"
    assert Torque.decode!(ping_reply["data"]) == %{"opaque" => "opaque-1"}

    # CALLBACK is dispatched, then acked 200 with the handler response.
    assert_receive {:dispatched, %{"msgId" => "in-1"}}, 1_500
    assert_receive {:client_frame, callback_ack}, 1_500
    assert callback_ack["code"] == 200
    assert callback_ack["headers"]["messageId"] == "cb-msg"
    assert Torque.decode!(callback_ack["data"]) == %{"response" => %{"received" => true}}

    assert Client.status(pid) == :connected
  end

  # --- fake WebSocket server ------------------------------------------------

  defp run_ws_server(listener, parent) do
    with {:ok, socket} <- :gen_tcp.accept(listener, 2_000),
         :ok <- :gen_tcp.close(listener),
         {:ok, request} <- recv_until_headers(socket),
         {:ok, key} <- websocket_key(request),
         :ok <- :gen_tcp.send(socket, upgrade_response(key)) do
      # Push a SYSTEM ping and read the client's opaque echo.
      :ok = :gen_tcp.send(socket, server_text_frame(ping_frame()))
      {:ok, ping_reply} = recv_client_text_frame(socket)
      send(parent, {:client_frame, Torque.decode!(ping_reply)})

      # Push a CALLBACK and read the ack.
      :ok = :gen_tcp.send(socket, server_text_frame(callback_frame()))
      {:ok, callback_ack} = recv_client_text_frame(socket)
      send(parent, {:client_frame, Torque.decode!(callback_ack)})

      receive do
        :close -> :gen_tcp.close(socket)
      after
        2_000 -> :gen_tcp.close(socket)
      end
    end
  end

  defp ping_frame do
    Torque.encode!(%{
      "specVersion" => "1.0",
      "type" => "SYSTEM",
      "headers" => %{
        "topic" => "ping",
        "messageId" => "ping-msg",
        "contentType" => "application/json"
      },
      "data" => Torque.encode!(%{"opaque" => "opaque-1"})
    })
  end

  defp callback_frame do
    Torque.encode!(%{
      "specVersion" => "1.0",
      "type" => "CALLBACK",
      "headers" => %{
        "topic" => "/v1.0/im/bot/messages/get",
        "messageId" => "cb-msg",
        "contentType" => "application/json"
      },
      "data" => Torque.encode!(%{"msgId" => "in-1", "conversationId" => "cid"})
    })
  end

  defp recv_until_headers(socket, buffer \\ <<>>) do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch ->
        case :gen_tcp.recv(socket, 0, 2_000) do
          {:ok, data} -> recv_until_headers(socket, buffer <> data)
          {:error, _reason} = error -> error
        end

      {_offset, _length} ->
        {:ok, buffer}
    end
  end

  defp websocket_key(request) do
    request
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> if String.downcase(name) == "sec-websocket-key", do: String.trim(value)
        _parts -> nil
      end
    end)
    |> case do
      key when is_binary(key) -> {:ok, key}
      nil -> {:error, :websocket_key_missing}
    end
  end

  defp upgrade_response(key) do
    accept =
      :sha
      |> :crypto.hash(key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      |> Base.encode64()

    [
      "HTTP/1.1 101 Switching Protocols\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Accept: ",
      accept,
      "\r\n\r\n"
    ]
  end

  # Server-to-client text frame (unmasked, opcode 0x1). Payloads here stay < 65536.
  defp server_text_frame(payload) when byte_size(payload) < 126 do
    <<0x81, byte_size(payload)>> <> payload
  end

  defp server_text_frame(payload) when byte_size(payload) < 65_536 do
    <<0x81, 126, byte_size(payload)::16>> <> payload
  end

  defp recv_client_text_frame(socket) do
    with {:ok, <<_fin_opcode, mask_and_length>>} <- :gen_tcp.recv(socket, 2, 2_000),
         true <- (mask_and_length &&& 0x80) == 0x80,
         {:ok, length} <- client_payload_length(socket, mask_and_length &&& 0x7F),
         {:ok, mask} <- :gen_tcp.recv(socket, 4, 2_000),
         {:ok, masked} <- :gen_tcp.recv(socket, length, 2_000) do
      {:ok, unmask(masked, mask)}
    else
      false -> {:error, :unmasked_client_frame}
      {:error, _reason} = error -> error
    end
  end

  defp client_payload_length(_socket, length) when length < 126, do: {:ok, length}

  defp client_payload_length(socket, 126) do
    case :gen_tcp.recv(socket, 2, 2_000) do
      {:ok, <<length::16>>} -> {:ok, length}
      {:error, _reason} = error -> error
    end
  end

  defp unmask(payload, mask) do
    mask_bytes = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> bxor(byte, Enum.at(mask_bytes, rem(index, 4))) end)
    |> :erlang.list_to_binary()
  end
end
