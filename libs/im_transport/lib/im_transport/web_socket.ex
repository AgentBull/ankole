defmodule IMTransport.WebSocket do
  @moduledoc "WebSocket URL decomposition shared by clients with the same error contract."

  def parse_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when scheme in ["ws", "wss"] and is_binary(host) ->
        ws_scheme = if scheme == "wss", do: :wss, else: :ws
        port = uri.port || if(ws_scheme == :wss, do: 443, else: 80)
        path = if uri.query, do: "#{uri.path || "/"}?#{uri.query}", else: uri.path || "/"
        {:ok, ws_scheme, host, port, path}

      _uri ->
        {:error, :invalid_websocket_url}
    end
  end
end
