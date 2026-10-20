defmodule IMTransport.WebSocketTest do
  use ExUnit.Case, async: true

  alias IMTransport.WebSocket

  test "URL decomposition preserves the path, query, explicit port, and scheme defaults" do
    assert WebSocket.parse_url("wss://example.test") == {:ok, :wss, "example.test", 443, "/"}

    assert WebSocket.parse_url("ws://example.test:8080/events?ticket=a%2Fb") ==
             {:ok, :ws, "example.test", 8080, "/events?ticket=a%2Fb"}

    assert WebSocket.parse_url("ws://example.test?ticket=x") ==
             {:ok, :ws, "example.test", 80, "/?ticket=x"}
  end

  test "unsupported schemes and missing hosts retain the shared client error" do
    for url <- ["https://example.test", "ws:/events", "not-a-url"] do
      assert WebSocket.parse_url(url) == {:error, :invalid_websocket_url}
    end
  end

  test "a socket without a connection ignores transport messages" do
    socket = %WebSocket{}
    assert WebSocket.stream(socket, :not_a_socket_message) == :unknown
    assert WebSocket.send_frame(socket, {:text, "hi"}) == {:error, socket, :websocket_not_ready}
    assert WebSocket.close(nil) == :ok
    assert WebSocket.close(socket) == :ok
  end

  test "canonical upgrade sends conventional HTTP/1 header names" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        WebSocket.connect("ws://127.0.0.1:#{port}/socket",
          upgrade: :canonical,
          headers: [{"User-Agent", "im-transport-test"}],
          mint_options: [case_sensitive_headers: true, transport_opts: [timeout: 1_000]]
        )
      end)

    {:ok, socket} = :gen_tcp.accept(listener, 2_000)
    {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
    :gen_tcp.close(socket)
    :gen_tcp.close(listener)
    Task.shutdown(task, :brutal_kill)

    names =
      request
      |> String.split("\r\n")
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 2) do
          [name, _value] -> name
          _parts -> nil
        end
      end)

    assert "Upgrade" in names
    assert "Connection" in names
    assert "Sec-WebSocket-Version" in names
    assert "Sec-WebSocket-Key" in names
    assert "User-Agent" in names
    assert request =~ "Connection: Upgrade\r\n"
  end
end
