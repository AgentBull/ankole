defmodule Ankole.Plugins.DiscordAdapter.Socket do
  @moduledoc """
  Mint websocket transport for one Discord gateway session.

  The struct holds the connection and decoding state. The caller owns the
  process, receives raw transport messages, and passes them to `stream/2`.
  This module never decides when to reconnect; it only reports that the
  connection ended.
  """

  alias Ankole.Plugins.DiscordAdapter.Gateway

  defstruct [
    :conn,
    :websocket,
    :request_ref,
    :upgrade_status,
    :upgrade_headers,
    upgrade_buffer: <<>>
  ]

  @type t :: %__MODULE__{}

  @connect_timeout 10_000

  @spec connect(String.t(), pid()) :: {:ok, t()} | {:error, term()}
  def connect(url, owner) when is_binary(url) and is_pid(owner) do
    with {:ok, scheme, host, port, path} <- parse_url(Gateway.socket_url(url)),
         {:ok, conn} <-
           Mint.HTTP.connect(http_scheme(scheme), host, port,
             protocols: [:http1],
             transport_opts: [timeout: @connect_timeout]
           ),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(scheme, conn, path, []),
         {:ok, conn} <- Mint.HTTP.controlling_process(conn, owner) do
      {:ok, %__MODULE__{conn: conn, request_ref: ref}}
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  @doc """
  Streams one transport message.

  Returns the decoded frames alongside the new socket state. `:unknown` means
  the message did not belong to this connection.
  """
  @spec stream(t(), term()) ::
          {:ok, t(), [term()]} | {:error, t(), term()} | :unknown
  def stream(%__MODULE__{conn: nil}, _message), do: :unknown

  def stream(%__MODULE__{} = socket, message) do
    case Mint.WebSocket.stream(socket.conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, %{socket | conn: conn}, [])

      {:error, conn, reason, _responses} ->
        {:error, %{socket | conn: conn}, reason}

      :unknown ->
        :unknown
    end
  end

  @spec send_frame(t(), term()) :: {:ok, t()} | {:error, t(), term()}
  def send_frame(%__MODULE__{websocket: nil} = socket, _frame),
    do: {:error, socket, :websocket_not_ready}

  def send_frame(%__MODULE__{} = socket, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(socket.websocket, frame),
         {:ok, conn} <-
           Mint.WebSocket.stream_request_body(socket.conn, socket.request_ref, data) do
      {:ok, %{socket | conn: conn, websocket: websocket}}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        {:error, %{socket | websocket: websocket}, reason}

      {:error, conn, reason} ->
        {:error, %{socket | conn: conn}, reason}
    end
  end

  @spec close(t() | nil) :: :ok
  def close(nil), do: :ok

  def close(%__MODULE__{conn: nil}), do: :ok

  def close(%__MODULE__{} = socket) do
    _ignored = Mint.HTTP.close(socket.conn)
    :ok
  end

  defp handle_responses([], socket, frames), do: {:ok, socket, Enum.reverse(frames)}

  defp handle_responses([{:status, ref, status} | rest], %{request_ref: ref} = socket, frames),
    do: handle_responses(rest, %{socket | upgrade_status: status}, frames)

  defp handle_responses([{:headers, ref, headers} | rest], %{request_ref: ref} = socket, frames),
    do: handle_responses(rest, %{socket | upgrade_headers: headers}, frames)

  defp handle_responses([{:done, ref} | rest], %{request_ref: ref} = socket, frames) do
    case Mint.WebSocket.new(
           socket.conn,
           ref,
           socket.upgrade_status,
           socket.upgrade_headers || []
         ) do
      {:ok, conn, websocket} ->
        socket = %{socket | conn: conn, websocket: websocket}
        {socket, buffered} = decode_buffer(socket)
        handle_responses(rest, socket, Enum.reverse(buffered) ++ frames)

      {:error, conn, reason} ->
        {:error, %{socket | conn: conn}, reason}
    end
  end

  defp handle_responses(
         [{:data, ref, data} | rest],
         %{request_ref: ref, websocket: nil} = socket,
         frames
       ) do
    handle_responses(rest, %{socket | upgrade_buffer: socket.upgrade_buffer <> data}, frames)
  end

  defp handle_responses([{:data, ref, data} | rest], %{request_ref: ref} = socket, frames) do
    case Mint.WebSocket.decode(socket.websocket, data) do
      {:ok, websocket, decoded} ->
        handle_responses(rest, %{socket | websocket: websocket}, Enum.reverse(decoded) ++ frames)

      {:error, websocket, reason} ->
        {:error, %{socket | websocket: websocket}, reason}
    end
  end

  defp handle_responses([{:error, ref, reason} | _rest], %{request_ref: ref} = socket, _frames),
    do: {:error, socket, reason}

  defp handle_responses([_response | rest], socket, frames),
    do: handle_responses(rest, socket, frames)

  defp decode_buffer(%{upgrade_buffer: <<>>} = socket), do: {socket, []}

  defp decode_buffer(socket) do
    data = socket.upgrade_buffer
    socket = %{socket | upgrade_buffer: <<>>}

    case Mint.WebSocket.decode(socket.websocket, data) do
      {:ok, websocket, frames} -> {%{socket | websocket: websocket}, frames}
      {:error, websocket, _reason} -> {%{socket | websocket: websocket}, []}
    end
  end

  defp parse_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when scheme in ["ws", "wss"] and is_binary(host) ->
        ws_scheme = if scheme == "wss", do: :wss, else: :ws
        port = uri.port || if(ws_scheme == :wss, do: 443, else: 80)
        path = if uri.query, do: "#{uri.path || "/"}?#{uri.query}", else: uri.path || "/"
        {:ok, ws_scheme, host, port, path}

      _uri ->
        {:error, :invalid_gateway_url}
    end
  end

  defp http_scheme(:ws), do: :http
  defp http_scheme(:wss), do: :https
end
