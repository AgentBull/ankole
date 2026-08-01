defmodule WeComOpenAPI.FakeWsServer do
  @moduledoc """
  Minimal scripted WebSocket server for bot client tests.

  Accepts one connection, completes the RFC 6455 upgrade, then relays:

    * every client text frame is decoded and sent to the test process as
      `{:client_frame, map}`;
    * `{:push, map}` messages from the test process are JSON-encoded and sent
      to the client as text frames;
    * `:close` closes the socket.
  """

  import Bitwise

  @doc "Start the server; returns `{pid, port}`. Frames go to `parent`."
  def start(parent, opts \\ []) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    pid = spawn_link(fn -> accept(listener, parent, opts) end)
    {pid, port}
  end

  defp accept(listener, parent, opts) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    :ok = :gen_tcp.close(listener)
    {:ok, request} = recv_until_headers(socket)

    with :ok <- validate_header_case(request, opts),
         {:ok, key} <- websocket_key(request) do
      :ok = :gen_tcp.send(socket, upgrade_response(key))
      send(parent, {:ws_upgraded, self()})
      :ok = :inet.setopts(socket, active: true)
      loop(socket, parent, <<>>)
    else
      {:error, reason} ->
        :ok = :gen_tcp.send(socket, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        :ok = :gen_tcp.close(socket)
        send(parent, {:ws_rejected, self(), reason})
    end
  end

  defp loop(socket, parent, buffer) do
    receive do
      {:tcp, ^socket, data} ->
        {frames, rest} = parse_frames(buffer <> data, [])

        Enum.each(frames, fn payload ->
          send(parent, {:client_frame, Torque.decode!(payload)})
        end)

        loop(socket, parent, rest)

      {:tcp_closed, ^socket} ->
        send(parent, {:ws_closed, self()})

      {:push, map} ->
        payload = Torque.encode!(map)
        :ok = :gen_tcp.send(socket, server_text_frame(payload))
        loop(socket, parent, buffer)

      :close ->
        :gen_tcp.close(socket)
        send(parent, {:ws_closed, self()})
    after
      10_000 -> :gen_tcp.close(socket)
    end
  end

  # --- handshake -----------------------------------------------------------

  defp validate_header_case(request, opts) do
    if Keyword.get(opts, :require_wecom_header_case, false) do
      required_names = ["Upgrade", "Connection", "Sec-WebSocket-Version", "Sec-WebSocket-Key"]
      present_names = request |> String.split("\r\n") |> Enum.map(&header_name/1)

      case Enum.find(required_names, &(&1 not in present_names)) do
        nil -> :ok
        missing -> {:error, {:incorrect_header_case, missing}}
      end
    else
      :ok
    end
  end

  defp header_name(line) do
    case String.split(line, ":", parts: 2) do
      [name, _value] -> name
      _parts -> nil
    end
  end

  defp recv_until_headers(socket, buffer \\ <<>>) do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch ->
        case :gen_tcp.recv(socket, 0, 5_000) do
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

  # --- frames --------------------------------------------------------------

  defp server_text_frame(payload) when byte_size(payload) < 126 do
    <<0x81, byte_size(payload)>> <> payload
  end

  defp server_text_frame(payload) when byte_size(payload) < 65_536 do
    <<0x81, 126, byte_size(payload)::16>> <> payload
  end

  # Parse complete masked client frames from the buffer; ignore non-text
  # opcodes (close/ping) and return text payloads.
  defp parse_frames(buffer, acc) do
    case parse_frame(buffer) do
      {:ok, opcode, payload, rest} ->
        acc = if opcode == 0x1, do: acc ++ [payload], else: acc
        parse_frames(rest, acc)

      :incomplete ->
        {acc, buffer}
    end
  end

  defp parse_frame(<<_fin_opcode, mask_len, rest::binary>> = buffer)
       when (mask_len &&& 0x80) == 0x80 do
    <<fin_opcode, _mask_len, _rest::binary>> = buffer
    opcode = fin_opcode &&& 0x0F

    case payload_length(mask_len &&& 0x7F, rest) do
      {:ok, length, after_len} when byte_size(after_len) >= length + 4 ->
        <<mask::binary-size(4), masked::binary-size(^length), remainder::binary>> = after_len
        {:ok, opcode, unmask(masked, mask), remainder}

      _other ->
        :incomplete
    end
  end

  defp parse_frame(_buffer), do: :incomplete

  defp payload_length(len, rest) when len < 126, do: {:ok, len, rest}

  defp payload_length(126, <<length::16, rest::binary>>), do: {:ok, length, rest}
  defp payload_length(126, _rest), do: :incomplete

  defp payload_length(127, <<length::64, rest::binary>>), do: {:ok, length, rest}
  defp payload_length(127, _rest), do: :incomplete

  defp unmask(payload, mask) do
    mask_bytes = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> bxor(byte, Enum.at(mask_bytes, rem(index, 4))) end)
    |> :erlang.list_to_binary()
  end
end
