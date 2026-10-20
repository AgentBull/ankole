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
end
