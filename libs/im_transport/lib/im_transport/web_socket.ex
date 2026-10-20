defmodule IMTransport.WebSocket do
  @moduledoc """
  Mint WebSocket connection with no reconnect policy and no frame meaning.

  `connect/2` and `open/5` send the upgrade request and return before the
  handshake completes. `stream/2` accepts transport messages, finishes the
  handshake, and returns decoded frames. The caller chooses what a frame means
  and when to reconnect.
  """

  defstruct [
    :conn,
    :websocket,
    :request_ref,
    :upgrade_status,
    :upgrade_headers,
    upgrade_buffer: <<>>
  ]

  @type t :: %__MODULE__{}

  @spec parse_url(String.t()) ::
          {:ok, :ws | :wss, String.t(), integer(), String.t()} | {:error, :invalid_websocket_url}
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

  @doc """
  Opens a WebSocket upgrade to `url`.

  Options:

    * `:headers` — extra request headers appended after the upgrade headers.
    * `:mint_options` — options for `Mint.HTTP.connect/4`. `:protocols` defaults
      to `[:http1]`.
    * `:upgrade` — `:mint` (default) or `:canonical`. `:canonical` sends the
      conventional HTTP/1 header names and `Connection: Upgrade`.
    * `:owner` — process that should receive transport messages. When set, the
      socket is transferred with `Mint.HTTP.controlling_process/2`.
  """
  @spec connect(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(url, opts \\ []) when is_binary(url) and is_list(opts) do
    with {:ok, scheme, host, port, path} <- parse_url(url) do
      open(scheme, host, port, path, opts)
    end
  end

  @doc """
  Opens a WebSocket upgrade from parts the caller already parsed.

  Use this when the caller's URL error is different from
  `:invalid_websocket_url`. The options match `connect/2`.
  """
  @spec open(:ws | :wss, term(), integer(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def open(scheme, host, port, path, opts \\ [])
      when scheme in [:ws, :wss] and is_integer(port) and is_binary(path) and is_list(opts) do
    opts = Keyword.validate!(opts, [:headers, :mint_options, :upgrade, :owner])
    headers = Keyword.get(opts, :headers, [])
    upgrade = Keyword.get(opts, :upgrade, :mint)
    mint_options = Keyword.merge([protocols: [:http1]], Keyword.get(opts, :mint_options, []))

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme(scheme), host, port, mint_options),
         {:ok, conn, ref} <- request_upgrade(upgrade, scheme, conn, path, headers),
         {:ok, conn} <- transfer(conn, Keyword.get(opts, :owner)) do
      {:ok, %__MODULE__{conn: conn, request_ref: ref}}
    else
      {:error, reason} ->
        {:error, reason}

      {:error, conn, reason} ->
        _ = Mint.HTTP.close(conn)
        {:error, reason}
    end
  end

  @doc """
  Streams one transport message.

  Returns decoded frames and the new socket. `:unknown` means the message did
  not belong to this connection. `{:upgrade, reason}` means the handshake
  response was rejected. `{:websocket_decode, reason}` means frame bytes could
  not be decoded. Other errors mean the transport failed.
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
    _ = Mint.HTTP.close(socket.conn)
    :ok
  end

  defp request_upgrade(:mint, scheme, conn, path, headers) do
    Mint.WebSocket.upgrade(scheme, conn, path, headers)
  end

  defp request_upgrade(:canonical, scheme, conn, path, headers) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.encode64()

    conn =
      conn
      |> Mint.HTTP.put_private(:scheme, scheme)
      |> Mint.HTTP.put_private(:sec_websocket_key, nonce)
      |> Mint.HTTP.put_private(:extensions, [])

    upgrade_headers = [
      {"Upgrade", "websocket"},
      {"Connection", "Upgrade"},
      {"Sec-WebSocket-Version", "13"},
      {"Sec-WebSocket-Key", nonce}
    ]

    Mint.HTTP.request(conn, "GET", path, upgrade_headers ++ headers, nil)
  end

  defp transfer(conn, nil), do: {:ok, conn}
  defp transfer(conn, owner) when is_pid(owner), do: Mint.HTTP.controlling_process(conn, owner)

  defp handle_responses([], socket, frames), do: {:ok, socket, Enum.reverse(frames)}

  defp handle_responses([{:status, ref, status} | rest], %{request_ref: ref} = socket, frames) do
    handle_responses(rest, %{socket | upgrade_status: status}, frames)
  end

  defp handle_responses([{:headers, ref, headers} | rest], %{request_ref: ref} = socket, frames) do
    handle_responses(rest, %{socket | upgrade_headers: headers}, frames)
  end

  defp handle_responses([{:done, ref} | rest], %{request_ref: ref} = socket, frames) do
    case Mint.WebSocket.new(
           socket.conn,
           ref,
           socket.upgrade_status,
           socket.upgrade_headers || []
         ) do
      {:ok, conn, websocket} ->
        socket = %{socket | conn: conn, websocket: websocket}

        case take_buffer(socket) do
          {:ok, socket, buffered} ->
            handle_responses(rest, socket, Enum.reverse(buffered) ++ frames)

          {:error, _socket, _reason} = error ->
            error
        end

      {:error, conn, reason} ->
        {:error, %{socket | conn: conn}, {:upgrade, reason}}
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
        {:error, %{socket | websocket: websocket}, {:websocket_decode, reason}}
    end
  end

  defp handle_responses([{:error, ref, reason} | _rest], %{request_ref: ref} = socket, _frames),
    do: {:error, socket, reason}

  defp handle_responses([_response | rest], socket, frames),
    do: handle_responses(rest, socket, frames)

  defp take_buffer(%{upgrade_buffer: <<>>} = socket), do: {:ok, socket, []}

  defp take_buffer(socket) do
    data = socket.upgrade_buffer
    socket = %{socket | upgrade_buffer: <<>>}

    case Mint.WebSocket.decode(socket.websocket, data) do
      {:ok, websocket, frames} ->
        {:ok, %{socket | websocket: websocket}, frames}

      {:error, websocket, reason} ->
        {:error, %{socket | websocket: websocket}, {:websocket_decode, reason}}
    end
  end

  defp http_scheme(:ws), do: :http
  defp http_scheme(:wss), do: :https
end
