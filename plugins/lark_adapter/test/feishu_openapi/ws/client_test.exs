defmodule FeishuOpenAPI.WS.ClientTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias FeishuOpenAPI.Client, as: APIClient
  alias FeishuOpenAPI.Event.Dispatcher
  alias FeishuOpenAPI.WS.{Client, Frame}

  test "callback failures keep the real WebSocket failure ack without disclosing private data" do
    # CaptureLog cannot capture messages that the primary Logger filter drops.
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    secret = "private-websocket-callback-should-not-escape"

    for {mode, failure} <- [
          returned: "Elixir.Ash.Error.Invalid",
          raised: "Elixir.ArgumentError",
          thrown: "throw",
          exited: "exit"
        ] do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, {_address, port}} = :inet.sockname(listener)
      owner = self()

      frame = %Frame{
        seq_id: 7,
        log_id: 8,
        service: 9,
        method: 1,
        headers: [{"type", "event"}],
        payload:
          Torque.encode!(%{
            "schema" => "2.0",
            "header" => %{"event_type" => "im.message.receive_v1"},
            "event" => %{"private" => secret}
          })
      }

      server = spawn_link(fn -> run_dispatch_server(listener, owner, frame) end)
      on_exit(fn -> send(server, :close) end)

      dispatcher =
        Dispatcher.new()
        |> Dispatcher.on("im.message.receive_v1", fn _, event ->
          value = event.content["private"]

          result =
            case mode do
              :returned ->
                {:error,
                 Ash.Error.Invalid.exception(
                   errors: [
                     Ash.Error.Changes.InvalidAttribute.exception(
                       field: :content,
                       message: "invalid content",
                       value: value
                     )
                   ]
                 )}

              :raised ->
                :erlang.binary_to_integer(value)

              :thrown ->
                throw(value)

              :exited ->
                exit(value)
            end

          send(owner, {:callback_finished, mode})
          result
        end)

      log =
        ExUnit.CaptureLog.capture_log(
          [level: :info, format: "$metadata$message\n", metadata: :all],
          fn ->
            {:ok, pid} =
              Client.start_link(
                client: handshake_client("cli_ws_private_#{mode}", port),
                dispatcher: dispatcher,
                auto_reconnect: false
              )

            try do
              assert_receive {:dispatch_ack, ^server, {:ok, ack}}, 1_000
              assert {ack.seq_id, ack.log_id, ack.service, ack.method} == {7, 8, 9, 1}
              assert Torque.decode!(ack.payload) == %{"code" => 500}
              assert Client.status(pid) == :connected
              refute ack.payload =~ secret
              if mode == :returned, do: assert_receive({:callback_finished, :returned})
            after
              if Process.alive?(pid), do: Client.stop(pid)
              send(server, :close)
            end
          end
        )

      assert log =~ "feishu_openapi.ws.dispatch_result"
      assert log =~ "failure=#{failure}"
      if mode != :returned, do: assert(log =~ "client_test.exs:")
      refute log =~ secret
    end
  end

  test "dispatch DOWN retains exit classification and call sites without the private reason" do
    secret = "private-dispatch-exit-should-not-escape"

    reason =
      try do
        :erlang.binary_to_integer(secret)
      rescue
        exception -> {exception, __STACKTRACE__}
      end

    assert inspect(reason) =~ secret
    ref = make_ref()

    state = %Client{
      dispatch_tasks: %{
        ref => {%Frame{}, "im.message.receive_v1", System.monotonic_time(:millisecond)}
      }
    }

    log =
      ExUnit.CaptureLog.capture_log([format: "$metadata$message\n", metadata: :all], fn ->
        assert {:noreply, %{dispatch_tasks: tasks, socket: nil}} =
                 Client.handle_info({:DOWN, ref, :process, self(), reason}, state)

        assert tasks == %{}
      end)

    assert log =~ "feishu_openapi.ws.dispatch_crashed"
    assert log =~ "failure=exit"
    assert log =~ ":erlang.binary_to_integer/1"
    assert log =~ "client_test.exs:"
    refute log =~ secret
  end

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
        | socket: nil,
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

  test "HTTP error bodies preserve the handshake failure classification" do
    previous = Process.flag(:trap_exit, true)

    try do
      for status <- [503, 403] do
        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

        {:ok, {_address, port}} = :inet.sockname(listener)
        spawn_link(fn -> run_http_error_server(listener, status) end)

        client = handshake_client("cli_ws_http_#{status}", port)

        {:ok, pid} =
          Client.start_link(client: client, dispatcher: Dispatcher.new(), auto_reconnect: false)

        assert_receive {:EXIT, ^pid,
                        {:shutdown,
                         {:handshake_error, ^status,
                          %Mint.WebSocket.UpgradeFailureError{status_code: ^status}}}},
                       1_000
      end
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "an HTTP error body schedules the existing reconnect for a transient handshake failure" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)
    spawn_link(fn -> run_http_error_server(listener, 503) end)
    client = handshake_client("cli_ws_http_retry", port)

    pid = start_supervised!({Client, client: client, dispatcher: Dispatcher.new()})

    wait_until(fn ->
      state = :sys.get_state(pid)
      state.status == :disconnected and not is_nil(state.reconnect_timer)
    end)

    assert Process.alive?(pid)
    assert :sys.get_state(pid).socket == nil
  end

  test "decodes a WebSocket frame received with the HTTP upgrade response" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()
    server = spawn_link(fn -> run_websocket_server(listener, parent, true) end)
    client = handshake_client("cli_ws_upgrade_frame", port)
    pid = start_supervised!({Client, client: client, dispatcher: Dispatcher.new()})

    on_exit(fn -> send(server, :close) end)

    assert_receive {:websocket_frame, ^server, {:ok, payload}}, 1_000
    assert {:ok, frame} = Frame.decode(payload)
    assert Frame.type(frame) == "ping"
    assert_receive {:websocket_pong, ^server, "provider-heartbeat"}, 1_000
    assert Client.status(pid) == :connected
  end

  defp handshake_client(app_id, port) do
    APIClient.new(app_id, "secret",
      req_options: [
        plug: fn conn ->
          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{"URL" => "ws://127.0.0.1:#{port}/ws"}
          })
        end
      ]
    )
  end

  defp run_http_error_server(listener, status) do
    {:ok, socket} = :gen_tcp.accept(listener, 1_000)
    :ok = :gen_tcp.close(listener)
    {:ok, _request} = recv_until_headers(socket)
    body = "handshake unavailable"

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} Handshake Error\r\n",
        "Content-Length: #{byte_size(body)}\r\n",
        "Connection: close\r\n\r\n",
        body
      ])

    :gen_tcp.close(socket)
  end

  defp run_dispatch_server(listener, parent, frame) do
    result =
      with {:ok, socket} <- :gen_tcp.accept(listener, 1_000),
           :ok <- :gen_tcp.close(listener),
           {:ok, request} <- recv_until_headers(socket),
           {:ok, key} <- websocket_key(request),
           :ok <- :gen_tcp.send(socket, upgrade_response(key)),
           {:ok, {0x2, _ping}} <- recv_masked_websocket_frame(socket),
           :ok <- :gen_tcp.send(socket, websocket_frame(0x2, Frame.encode(frame))),
           {:ok, {0x2, ack}} <- recv_masked_websocket_frame(socket) do
        send(parent, {:dispatch_ack, self(), Frame.decode(ack)})

        receive do
          :close -> :gen_tcp.close(socket)
        after
          2_000 -> :gen_tcp.close(socket)
        end

        :ok
      end

    if result != :ok, do: send(parent, {:dispatch_ack, self(), result})
  end

  defp run_websocket_server(listener, parent, early_ping? \\ false) do
    result =
      with {:ok, socket} <- :gen_tcp.accept(listener, 1_000),
           :ok <- :gen_tcp.close(listener),
           {:ok, request} <- recv_until_headers(socket),
           {:ok, websocket_key} <- websocket_key(request),
           :ok <-
             :gen_tcp.send(socket, [
               upgrade_response(websocket_key),
               if(early_ping?, do: websocket_frame(0x9, "provider-heartbeat"), else: <<>>)
             ]),
           {:ok, {0x2, payload}} <- recv_masked_websocket_frame(socket),
           :ok <-
             if(early_ping?,
               do: :ok,
               else: :gen_tcp.send(socket, websocket_frame(0x9, "provider-heartbeat"))
             ),
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

  defp websocket_frame(opcode, payload) when byte_size(payload) <= 65_535 do
    <<0x80 ||| opcode, 126, byte_size(payload)::16>> <> payload
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
