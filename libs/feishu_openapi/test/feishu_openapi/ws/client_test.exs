defmodule FeishuOpenAPI.WS.ClientTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias FeishuOpenAPI.Client, as: APIClient
  alias FeishuOpenAPI.Event.Dispatcher
  alias FeishuOpenAPI.WS.{Client, Frame}

  test "late dispatch results after disconnect are ignored instead of crashing the client" do
    client =
      APIClient.new("cli_ws_#{System.unique_integer([:positive])}", "secret",
        req_options: [
          plug: fn conn ->
            Req.Test.json(conn, %{"code" => 99_999, "msg" => "endpoint unavailable"})
          end
        ]
      )

    {:ok, pid} =
      Client.start_link(client: client, dispatcher: Dispatcher.new(), auto_reconnect: true)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    wait_until(fn ->
      state = :sys.get_state(pid)
      Client.status(pid) == :disconnected and not is_nil(state.reconnect_timer)
    end)

    ref = make_ref()

    frame = %Frame{
      seq_id: 1,
      log_id: 2,
      service: 3,
      method: 1,
      headers: [{"type", "event"}]
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | conn: nil,
          websocket: nil,
          request_ref: nil,
          dispatch_tasks: %{
            ref => {frame, "im.message.receive_v1", System.monotonic_time(:millisecond)}
          }
      }
    end)

    send(pid, {ref, {:ok, :handled}})
    Process.sleep(100)

    assert Process.alive?(pid)
    assert :sys.get_state(pid).dispatch_tasks == %{}
  end

  test "start_link validates required option types" do
    client = APIClient.new("cli_ws_bad", "secret")

    assert_raise RuntimeError, ~r/:dispatcher/, fn ->
      start_supervised!({Client, client: client, dispatcher: :bad})
    end
  end

  test "endpoint discovery accepts a URL-only response without ClientConfig" do
    previous = Process.flag(:trap_exit, true)

    try do
      client =
        APIClient.new("cli_ws_url_only", "secret",
          req_options: [
            plug: fn conn ->
              Req.Test.json(conn, %{
                "code" => 0,
                "data" => %{"URL" => "http://endpoint-only.example.test/ws"}
              })
            end
          ]
        )

      {:ok, pid} =
        Client.start_link(client: client, dispatcher: Dispatcher.new(), auto_reconnect: false)

      assert_receive {:EXIT, ^pid, {:shutdown, {:bad_scheme, "http"}}}, :timer.seconds(1)
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "sends the first application ping immediately after the WebSocket upgrade" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()
    server = spawn_link(fn -> run_websocket_server(listener, parent) end)

    client =
      APIClient.new("cli_ws_initial_ping", "secret",
        req_options: [
          plug: fn conn ->
            Req.Test.json(conn, %{
              "code" => 0,
              "data" => %{
                "URL" => "ws://127.0.0.1:#{port}/ws?service_id=42",
                "ClientConfig" => %{"PingInterval" => 90}
              }
            })
          end
        ]
      )

    {:ok, pid} =
      Client.start_link(client: client, dispatcher: Dispatcher.new(), auto_reconnect: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Client.stop(pid)
      send(server, :close)
    end)

    assert_receive {:websocket_frame, ^server, {:ok, payload}}, 1_000
    assert {:ok, frame} = Frame.decode(payload)
    assert Frame.type(frame) == "ping"
    assert frame.method == 0
    assert frame.service == 42
    assert_receive {:websocket_pong, ^server, "provider-heartbeat"}, 1_000
    assert Client.status(pid) == :connected
  end

  defp run_websocket_server(listener, parent) do
    result =
      with {:ok, socket} <- :gen_tcp.accept(listener, 1_000),
           :ok <- :gen_tcp.close(listener),
           {:ok, request} <- recv_until_headers(socket),
           {:ok, websocket_key} <- websocket_key(request),
           :ok <- :gen_tcp.send(socket, upgrade_response(websocket_key)),
           {:ok, {0x2, payload}} <- recv_masked_websocket_frame(socket),
           :ok <- :gen_tcp.send(socket, websocket_frame(0x9, "provider-heartbeat")),
           {:ok, {0xA, "provider-heartbeat"}} <- recv_masked_websocket_frame(socket) do
        send(parent, {:websocket_frame, self(), {:ok, payload}})
        send(parent, {:websocket_pong, self(), "provider-heartbeat"})

        receive do
          :close -> :gen_tcp.close(socket)
        after
          2_000 -> :gen_tcp.close(socket)
        end

        :ok
      end

    if result != :ok do
      send(parent, {:websocket_frame, self(), result})
    end
  end

  defp recv_until_headers(socket, buffer \\ <<>>) do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch ->
        case :gen_tcp.recv(socket, 0, 1_000) do
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
        [name, value] ->
          if String.downcase(name) == "sec-websocket-key", do: String.trim(value)

        _parts ->
          nil
      end
    end)
    |> case do
      key when is_binary(key) -> {:ok, key}
      nil -> {:error, :websocket_key_missing}
    end
  end

  defp upgrade_response(websocket_key) do
    accept =
      :sha
      |> :crypto.hash(websocket_key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
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

  defp recv_masked_websocket_frame(socket) do
    with {:ok, <<fin_and_opcode, mask_and_length>>} <- :gen_tcp.recv(socket, 2, 1_000),
         true <- (mask_and_length &&& 0x80) == 0x80,
         {:ok, payload_length} <- websocket_payload_length(socket, mask_and_length &&& 0x7F),
         {:ok, mask} <- :gen_tcp.recv(socket, 4, 1_000),
         {:ok, masked_payload} <- :gen_tcp.recv(socket, payload_length, 1_000) do
      {:ok, {fin_and_opcode &&& 0x0F, unmask_payload(masked_payload, mask)}}
    else
      false -> {:error, :unmasked_client_frame}
      {:error, _reason} = error -> error
    end
  end

  defp websocket_frame(opcode, payload) when byte_size(payload) < 126 do
    <<0x80 ||| opcode, byte_size(payload)>> <> payload
  end

  defp websocket_payload_length(_socket, length) when length < 126, do: {:ok, length}

  defp websocket_payload_length(socket, 126) do
    case :gen_tcp.recv(socket, 2, 1_000) do
      {:ok, <<length::16>>} -> {:ok, length}
      {:error, _reason} = error -> error
    end
  end

  defp websocket_payload_length(socket, 127) do
    case :gen_tcp.recv(socket, 8, 1_000) do
      {:ok, <<length::64>>} -> {:ok, length}
      {:error, _reason} = error -> error
    end
  end

  defp unmask_payload(payload, mask) do
    mask_bytes = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> bxor(byte, Enum.at(mask_bytes, rem(index, 4))) end)
    |> :erlang.list_to_binary()
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0) do
    flunk("condition was not met before timeout")
  end
end
