defmodule Ankole.Plugins.EmailAdapter.Imap.Client do
  @moduledoc """
  Narrow IMAP4rev1 client for one mailbox owner.

  The client speaks only the commands the adapter needs: CAPABILITY, LOGIN or
  AUTHENTICATE PLAIN, SELECT, UID SEARCH, UID FETCH, UID STORE, IDLE, NOOP, and
  LOGOUT. It keeps the socket in passive line mode and switches to raw mode
  only to read a literal, so a response with a message body arrives as one
  token list. The caller owns the process and the reconnect decision.
  """

  alias Ankole.Plugins.EmailAdapter.Config

  @connect_timeout 15_000
  @command_timeout 120_000
  # The mailbox session fetches a full body only below 25 MB, so a larger
  # literal is a lying or broken server, not a message to read.
  @max_literal_bytes 32 * 1024 * 1024
  @line_options [:binary, active: false, packet: :line, packet_size: 4_194_304, buffer: 65_536]

  defstruct [:socket, :transport, tag: 0, capabilities: MapSet.new()]

  @type t :: %__MODULE__{
          socket: term(),
          transport: :ssl | :gen_tcp,
          tag: non_neg_integer(),
          capabilities: MapSet.t(String.t())
        }

  @type token :: String.t() | integer() | {:literal, binary()} | [token()]
  @type untagged :: %{line: String.t(), tokens: [token()]}

  @spec connect(keyword()) :: {:ok, t()} | {:error, term()}
  def connect(opts) do
    host = opts |> Keyword.fetch!(:host) |> String.to_charlist()
    port = Keyword.fetch!(opts, :port)
    timeout = Keyword.get(opts, :timeout, @connect_timeout)

    result =
      case Keyword.get(opts, :transport, :ssl) do
        :ssl ->
          :ssl.connect(host, port, @line_options ++ Config.tls_options(host), timeout)
          |> wrap(:ssl)

        :tcp ->
          :gen_tcp.connect(host, port, @line_options, timeout) |> wrap(:gen_tcp)
      end

    with {:ok, client} <- result,
         {:ok, greeting} <- read_line(client) do
      cond do
        String.starts_with?(greeting, ["* OK", "* PREAUTH"]) -> capability(client)
        true -> {:error, {:greeting_rejected, bounded(greeting)}}
      end
    end
  end

  @spec capability(t()) :: {:ok, t()} | {:error, term()}
  def capability(%__MODULE__{} = client) do
    with {:ok, client, untagged, tagged} <- command(client, "CAPABILITY") do
      capabilities =
        (Enum.map(untagged, & &1.line) ++ [tagged])
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/CAPABILITY\s+([^\]\r\n]+)/i, line) do
            [_all, list] -> list |> String.split() |> Enum.map(&String.upcase/1)
            nil -> []
          end
        end)
        |> MapSet.new()

      {:ok, %{client | capabilities: capabilities}}
    end
  end

  @spec supports?(t(), String.t()) :: boolean()
  def supports?(%__MODULE__{capabilities: capabilities}, name),
    do: MapSet.member?(capabilities, String.upcase(name))

  @doc "Logs in, using AUTHENTICATE PLAIN when the server disables LOGIN."
  @spec login(t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def login(%__MODULE__{} = client, username, password) do
    result =
      if supports?(client, "LOGINDISABLED") do
        authenticate_plain(client, username, password)
      else
        command(client, ["LOGIN ", quote_string(username), " ", quote_string(password)])
      end

    with {:ok, client, _untagged, _tagged} <- result do
      capability(client)
    end
  end

  @spec select(t(), String.t()) ::
          {:ok, t(), %{uidvalidity: pos_integer() | nil, exists: non_neg_integer()}}
          | {:error, term()}
  def select(%__MODULE__{} = client, mailbox) do
    with {:ok, client, untagged, _tagged} <- command(client, ["SELECT ", quote_string(mailbox)]) do
      lines = Enum.map(untagged, & &1.line)

      {:ok, client,
       %{
         uidvalidity: find_integer(lines, ~r/UIDVALIDITY\s+(\d+)/),
         exists: find_integer(lines, ~r/\*\s+(\d+)\s+EXISTS/) || 0
       }}
    end
  end

  @spec uid_search_unseen(t()) :: {:ok, t(), [pos_integer()]} | {:error, term()}
  def uid_search_unseen(%__MODULE__{} = client) do
    with {:ok, client, untagged, _tagged} <- command(client, "UID SEARCH UNSEEN") do
      uids =
        untagged
        |> Enum.flat_map(fn
          %{tokens: ["*", "SEARCH" | uids]} -> Enum.filter(uids, &is_integer/1)
          _other -> []
        end)
        |> Enum.sort()

      {:ok, client, uids}
    end
  end

  @spec uid_fetch_size(t(), pos_integer()) :: {:ok, t(), non_neg_integer()} | {:error, term()}
  def uid_fetch_size(%__MODULE__{} = client, uid) do
    with {:ok, client, attributes} <- uid_fetch(client, uid, "(RFC822.SIZE)") do
      case fetch_attribute(attributes, "RFC822.SIZE") do
        size when is_integer(size) -> {:ok, client, size}
        _missing -> {:error, {:fetch_incomplete, uid}}
      end
    end
  end

  @doc "Fetches the full message, or only its header block, without setting flags."
  @spec uid_fetch_body(t(), pos_integer(), :full | :header) ::
          {:ok, t(), binary()} | {:error, term()}
  def uid_fetch_body(%__MODULE__{} = client, uid, section) do
    item = if section == :header, do: "BODY.PEEK[HEADER]", else: "BODY.PEEK[]"
    key = if section == :header, do: "BODY[HEADER]", else: "BODY[]"

    with {:ok, client, attributes} <- uid_fetch(client, uid, "(#{item})") do
      case fetch_attribute(attributes, key) do
        {:literal, body} -> {:ok, client, body}
        body when is_binary(body) -> {:ok, client, body}
        _missing -> {:error, {:fetch_incomplete, uid}}
      end
    end
  end

  @spec uid_store_seen(t(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def uid_store_seen(%__MODULE__{} = client, uid) do
    with {:ok, client, _untagged, _tagged} <-
           command(client, "UID STORE #{uid} +FLAGS.SILENT (\\Seen)") do
      {:ok, client}
    end
  end

  @spec noop(t()) :: {:ok, t()} | {:error, term()}
  def noop(%__MODULE__{} = client) do
    with {:ok, client, _untagged, _tagged} <- command(client, "NOOP"), do: {:ok, client}
  end

  @doc """
  Waits in IDLE until the mailbox changes or the timeout passes.

  A server keepalive such as `* OK Still here` does not end the wait.
  """
  @spec idle(t(), pos_integer()) :: {:ok, t(), :changed | :timeout} | {:error, term()}
  def idle(%__MODULE__{} = client, timeout_ms) do
    {client, tag} = next_tag(client)

    with :ok <- send_data(client, [tag, " IDLE\r\n"]),
         {:ok, line} <- read_line(client),
         true <- String.starts_with?(line, "+") || {:error, {:idle_rejected, bounded(line)}},
         {:ok, outcome} <- idle_wait(client, monotonic_ms() + timeout_ms),
         :ok <- send_data(client, "DONE\r\n"),
         {:ok, client, _untagged, _tagged} <- read_tagged(client, tag, []) do
      {:ok, client, outcome}
    end
  end

  @spec logout(t()) :: :ok
  def logout(%__MODULE__{} = client) do
    _result = command(client, "LOGOUT")
    close(client)
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{socket: socket, transport: transport}) do
    _result = transport.close(socket)
    :ok
  end

  defp uid_fetch(client, uid, items) do
    with {:ok, client, untagged, _tagged} <- command(client, "UID FETCH #{uid} #{items}") do
      attributes =
        Enum.find_value(untagged, fn
          %{tokens: ["*", _sequence, "FETCH", attributes]} when is_list(attributes) ->
            if fetch_attribute(attributes, "UID") == uid, do: attributes

          _other ->
            nil
        end)

      case attributes do
        nil -> {:error, {:fetch_incomplete, uid}}
        attributes -> {:ok, client, attributes}
      end
    end
  end

  # FETCH attributes arrive as a flat `key value key value` list.
  defp fetch_attribute([key, value | rest], wanted) do
    if is_binary(key) and String.upcase(key) == wanted,
      do: value,
      else: fetch_attribute(rest, wanted)
  end

  defp fetch_attribute(_attributes, _wanted), do: nil

  defp authenticate_plain(client, username, password) do
    {client, tag} = next_tag(client)
    credentials = Base.encode64(<<0, username::binary, 0, password::binary>>)

    with :ok <- send_data(client, [tag, " AUTHENTICATE PLAIN\r\n"]),
         {:ok, line} <- read_line(client),
         true <-
           String.starts_with?(line, "+") || {:error, {:authenticate_rejected, bounded(line)}},
         :ok <- send_data(client, [credentials, "\r\n"]) do
      read_tagged(client, tag, [])
    end
  end

  defp command(client, command) do
    {client, tag} = next_tag(client)

    with :ok <- send_data(client, [tag, " ", command, "\r\n"]) do
      read_tagged(client, tag, [])
    end
  end

  defp read_tagged(client, tag, untagged) do
    with {:ok, line} <- read_line(client) do
      cond do
        String.starts_with?(line, tag <> " ") ->
          tagged_result(client, String.trim(line), Enum.reverse(untagged))

        String.starts_with?(line, "* ") ->
          with {:ok, entry} <- read_untagged(client, line) do
            read_tagged(client, tag, [entry | untagged])
          end

        String.starts_with?(line, "+") ->
          {:error, :unexpected_continuation}

        true ->
          read_tagged(client, tag, untagged)
      end
    end
  end

  defp tagged_result(client, line, untagged) do
    case String.split(line, " ", parts: 3) do
      [_tag, "OK" | rest] -> {:ok, client, untagged, Enum.join(rest, " ")}
      [_tag, "NO" | rest] -> {:error, {:no, bounded(Enum.join(rest, " "))}}
      [_tag, "BAD" | rest] -> {:error, {:bad, bounded(Enum.join(rest, " "))}}
      _other -> {:error, {:invalid_tagged_response, bounded(line)}}
    end
  end

  # A line that ends in `{n}` continues with n literal bytes and then more
  # of the same response line.
  defp read_untagged(client, line) do
    with {:ok, segments} <- read_segments(client, line, []) do
      first =
        segments
        |> Enum.find(&is_binary/1)
        |> Kernel.||("")
        |> String.trim()

      {:ok, %{line: first, tokens: tokenize(segments)}}
    end
  end

  defp read_segments(client, line, segments) do
    case Regex.run(~r/\{(\d+)\}\r?\n\z/, line) do
      [marker, count] ->
        text = binary_part(line, 0, byte_size(line) - byte_size(marker))
        count = String.to_integer(count)

        with :ok <- check_literal_size(count),
             {:ok, literal} <- read_bytes(client, count),
             {:ok, next_line} <- read_line(client) do
          read_segments(client, next_line, [{:literal, literal}, text | segments])
        end

      nil ->
        {:ok, Enum.reverse([line | segments])}
    end
  end

  defp tokenize(segments) do
    segments
    |> Enum.reduce([[]], fn
      {:literal, literal}, [current | stack] -> [[{:literal, literal} | current] | stack]
      text, stack -> tokenize_text(text, stack)
    end)
    |> close_all()
  end

  defp tokenize_text("", stack), do: stack

  defp tokenize_text(<<char, rest::binary>>, stack) when char in [?\s, ?\t, ?\r, ?\n],
    do: tokenize_text(rest, stack)

  defp tokenize_text("(" <> rest, stack), do: tokenize_text(rest, [[] | stack])

  defp tokenize_text(")" <> rest, [current, parent | stack]),
    do: tokenize_text(rest, [[Enum.reverse(current) | parent] | stack])

  defp tokenize_text(")" <> rest, stack), do: tokenize_text(rest, stack)

  defp tokenize_text("\"" <> rest, [current | stack]) do
    {string, remaining} = take_quoted(rest, [])
    tokenize_text(remaining, [[string | current] | stack])
  end

  defp tokenize_text(text, [current | stack]) do
    {atom, remaining} = take_atom(text, [])
    tokenize_text(remaining, [[atom_token(atom) | current] | stack])
  end

  defp take_quoted("", acc), do: {List.to_string(Enum.reverse(acc)), ""}
  defp take_quoted("\\" <> <<char, rest::binary>>, acc), do: take_quoted(rest, [char | acc])
  defp take_quoted("\"" <> rest, acc), do: {List.to_string(Enum.reverse(acc)), rest}
  defp take_quoted(<<char, rest::binary>>, acc), do: take_quoted(rest, [char | acc])

  defp take_atom(<<char, _rest::binary>> = text, acc) when char in [?\s, ?\t, ?\r, ?\n, ?(, ?)],
    do: {List.to_string(Enum.reverse(acc)), text}

  defp take_atom("", acc), do: {List.to_string(Enum.reverse(acc)), ""}
  defp take_atom(<<char, rest::binary>>, acc), do: take_atom(rest, [char | acc])

  defp atom_token(atom) do
    case Integer.parse(atom) do
      {integer, ""} -> integer
      _other -> atom
    end
  end

  defp close_all([current]), do: Enum.reverse(current)

  defp close_all([current, parent | stack]),
    do: close_all([[Enum.reverse(current) | parent] | stack])

  defp idle_wait(client, deadline) do
    remaining = deadline - monotonic_ms()

    if remaining <= 0 do
      {:ok, :timeout}
    else
      case client.transport.recv(client.socket, 0, remaining) do
        {:ok, line} ->
          if Regex.match?(~r/\A\*\s+\d+\s+(EXISTS|RECENT|EXPUNGE)/i, line),
            do: {:ok, :changed},
            else: idle_wait(client, deadline)

        {:error, :timeout} ->
          {:ok, :timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp read_line(%__MODULE__{socket: socket, transport: transport}) do
    case transport.recv(socket, 0, @command_timeout) do
      {:ok, line} when is_binary(line) -> {:ok, line}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_literal_size(count) when count > @max_literal_bytes,
    do: {:error, {:literal_too_large, count}}

  defp check_literal_size(_count), do: :ok

  defp read_bytes(_client, 0), do: {:ok, ""}

  defp read_bytes(%__MODULE__{socket: socket, transport: transport} = client, count) do
    with :ok <- set_packet(client, :raw),
         {:ok, bytes} <- transport.recv(socket, count, @command_timeout),
         :ok <- set_packet(client, :line) do
      {:ok, bytes}
    end
  end

  defp set_packet(%__MODULE__{socket: socket, transport: :ssl}, mode),
    do: :ssl.setopts(socket, packet: mode)

  defp set_packet(%__MODULE__{socket: socket, transport: :gen_tcp}, mode),
    do: :inet.setopts(socket, packet: mode)

  defp send_data(%__MODULE__{socket: socket, transport: transport}, data) do
    transport.send(socket, data)
  end

  defp next_tag(%__MODULE__{tag: tag} = client) do
    next = tag + 1
    {%{client | tag: next}, "A" <> String.pad_leading(Integer.to_string(next), 4, "0")}
  end

  defp quote_string(value) do
    "\"" <> String.replace(value, ~r/(["\\])/, "\\\\\\1") <> "\""
  end

  defp find_integer(lines, regex) do
    Enum.find_value(lines, fn line ->
      case Regex.run(regex, line) do
        [_all, value] -> String.to_integer(value)
        nil -> nil
      end
    end)
  end

  defp wrap({:ok, socket}, transport),
    do: {:ok, %__MODULE__{socket: socket, transport: transport}}

  defp wrap({:error, reason}, _transport), do: {:error, {:connect_failed, reason}}

  defp bounded(text), do: text |> String.trim() |> String.slice(0, 200)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end

defimpl Inspect, for: Ankole.Plugins.EmailAdapter.Imap.Client do
  import Inspect.Algebra

  def inspect(client, opts) do
    concat([
      "#Ankole.Plugins.EmailAdapter.Imap.Client<",
      to_doc(%{transport: client.transport, tag: client.tag}, opts),
      ">"
    ])
  end
end
