defmodule SlackOpenAPI.SocketMode.ClientTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias SlackOpenAPI.Client, as: APIClient
  alias SlackOpenAPI.SocketMode.{Client, Dispatcher}

  test "a connection at its dispatch limit leaves a new envelope unacked for redelivery" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()
    server = spawn_link(fn -> run_ws_server(listener, parent) end)
    on_exit(fn -> send(server, :close) end)

    dispatcher =
      Dispatcher.on(Dispatcher.new(), "message", fn _event, _envelope ->
        send(parent, :dispatched)
        :ok
      end)

    client =
      APIClient.new(
        app_token: "xapp-test",
        req_options: [
          plug: fn conn ->
            Req.Test.json(conn, %{"ok" => true, "url" => "ws://127.0.0.1:#{port}/link"})
          end
        ]
      )

    pid =
      start_supervised!({Client, client: client, dispatcher: dispatcher, auto_reconnect: false})

    assert_receive :upgraded, 1_000
    in_flight = Map.new(1..64, fn _ -> {make_ref(), {"envelope", "message", 0}} end)
    :sys.replace_state(pid, &%{&1 | dispatch_tasks: in_flight})
    send(server, :push)

    assert_receive {:client_frame, {:error, :timeout}}, 3_000
    refute_received :dispatched
    assert map_size(:sys.get_state(pid).dispatch_tasks) == 64
  end

  defp run_ws_server(listener, parent) do
    with {:ok, socket} <- :gen_tcp.accept(listener, 2_000),
         :ok <- :gen_tcp.close(listener),
         {:ok, request} <- recv_until_headers(socket),
         {:ok, key} <- websocket_key(request),
         :ok <- :gen_tcp.send(socket, upgrade_response(key)),
         :ok <- :gen_tcp.send(socket, server_text_frame(Torque.encode!(%{"type" => "hello"}))) do
      send(parent, :upgraded)

      receive do
        :push -> :ok = :gen_tcp.send(socket, server_text_frame(envelope()))
      end

      send(parent, {:client_frame, recv_client_text_frame(socket)})

      receive do
        :close -> :gen_tcp.close(socket)
      after
        5_000 -> :gen_tcp.close(socket)
      end
    end
  end

  defp envelope do
    Torque.encode!(%{
      "envelope_id" => "envelope-1",
      "type" => "events_api",
      "payload" => %{"event" => %{"type" => "message", "text" => "hi"}}
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
