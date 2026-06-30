defmodule Ankole.ActorRuntime.FileTransferLane do
  @moduledoc """
  Control-plane entry point for RuntimeFabric worker-file frames.

  The worker file service is addressed by a worker route plus a virtual path
  inside one worker-visible root. File lane state is in-memory request/response
  state only; durable references to written files belong in PG domain rows.
  """

  use GenServer

  require Logger

  alias Ankole.ActorRuntime.Transport.Broker

  @protocol "ANKOLE_FILE/1"
  @chunk_size 2 * 1024 * 1024
  @credit_window 4 * 1024 * 1024
  @zstd_level 3
  @default_timeout 120_000
  @roots ~w(user_files agent_installed_skills)

  @type route_auth :: %{
          route: String.t(),
          worker_id: String.t() | nil,
          key_revision: integer() | nil
        }

  @type operation_result :: {:ok, map()} | {:error, term()}
  @type get_result :: {:ok, map()} | {:error, term()}

  @doc """
  Starts the in-memory response router for worker-file operations.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Writes bytes into a worker-owned filesystem root.
  """
  @spec put(String.t(), String.t(), String.t(), iodata(), keyword()) :: operation_result()
  def put(route, root, relative_path, content, opts \\ [])
      when is_binary(route) and is_binary(root) and is_binary(relative_path) do
    content = IO.iodata_to_binary(content)

    with {:ok, path} <- virtual_path(root, relative_path),
         {:ok, chunks} <- compress_chunks(content) do
      transfer_id = transfer_id(opts)

      pending = %{
        mode: :write,
        route: route,
        expected_command: "WRITE_COMMITTED",
        chunks: chunks,
        next_sequence: 0,
        next_offset: 0,
        credit: 0,
        commit_sent?: false
      }

      frames = [[@protocol, "WRITE_OPEN", transfer_id, path, u64(byte_size(content))]]
      request(route, transfer_id, frames, pending, opts)
    end
  end

  @doc """
  Reads a file from a worker-owned filesystem root.

  The public API returns content as one binary because current Ankole file-lane
  callers handle bounded operational artifacts rather than archival streams.
  """
  @spec get(String.t(), String.t(), String.t(), keyword()) :: get_result()
  def get(route, root, relative_path, opts \\ [])
      when is_binary(route) and is_binary(root) and is_binary(relative_path) do
    with {:ok, path} <- virtual_path(root, relative_path),
         {:ok, fingerprint} <- fingerprint_mode(opts) do
      transfer_id = transfer_id(opts)

      pending = %{
        mode: :read,
        route: route,
        expected_command: "READ_DONE",
        read_begin: nil,
        chunks: [],
        next_sequence: 0,
        next_offset: 0
      }

      frames = [[@protocol, "READ_OPEN", transfer_id, path, fingerprint]]

      # Decompression (and the decompressed-size check) run here in the CALLER process,
      # symmetric with put/5's caller-side compress_chunks: the lane GenServer only accumulates
      # and protocol-validates the compressed frames, so a large read never blocks the shared
      # file-lane process on zstd.
      with {:ok, raw} <- request(route, transfer_id, frames, pending, opts),
           {:ok, content} <- decompress_chunks(raw["chunks"]),
           :ok <- validate_read_content(raw["begin"], content) do
        {:ok, %{"content" => content, "begin" => raw["begin"], "end" => raw["end"]}}
      end
    end
  end

  @doc """
  Reads filesystem information for one worker-owned path.
  """
  @spec stat(String.t(), String.t(), String.t(), keyword()) :: operation_result()
  def stat(route, root, relative_path, opts \\ [])
      when is_binary(route) and is_binary(root) and is_binary(relative_path) do
    with {:ok, path} <- virtual_path(root, relative_path),
         {:ok, fingerprint} <- fingerprint_mode(opts) do
      transfer_id = transfer_id(opts)

      request(
        route,
        transfer_id,
        [[@protocol, "STAT", transfer_id, path, fingerprint]],
        simple_pending(route, "STAT_OK"),
        opts
      )
    end
  end

  @doc """
  Lists a directory inside a worker-owned filesystem root.
  """
  @spec list(String.t(), String.t(), String.t(), keyword()) :: operation_result()
  def list(route, root, relative_path \\ "", opts \\ [])
      when is_binary(route) and is_binary(root) and is_binary(relative_path) do
    with {:ok, path} <- virtual_path(root, relative_path, allow_root?: true) do
      transfer_id = transfer_id(opts)

      frames = [
        [
          @protocol,
          "LIST",
          transfer_id,
          path,
          bool(Keyword.get(opts, :recursive, false)),
          u64(Keyword.get(opts, :max_entries, 1000))
        ]
      ]

      request(route, transfer_id, frames, simple_pending(route, "LIST_OK"), opts)
    end
  end

  @doc """
  Deletes a file or, with `recursive: true`, a directory in a worker-owned root.
  """
  @spec delete(String.t(), String.t(), String.t(), keyword()) :: operation_result()
  def delete(route, root, relative_path, opts \\ [])
      when is_binary(route) and is_binary(root) and is_binary(relative_path) do
    with {:ok, path} <- virtual_path(root, relative_path) do
      transfer_id = transfer_id(opts)

      frames = [
        [@protocol, "DELETE", transfer_id, path, bool(Keyword.get(opts, :recursive, false))]
      ]

      request(route, transfer_id, frames, simple_pending(route, "DELETE_OK"), opts)
    end
  end

  @doc """
  Moves or renames a path inside a single worker-owned filesystem root.
  """
  @spec move(String.t(), String.t(), String.t(), String.t(), keyword()) :: operation_result()
  def move(route, root, from_relative_path, to_relative_path, opts \\ [])
      when is_binary(route) and is_binary(root) and is_binary(from_relative_path) and
             is_binary(to_relative_path) do
    with {:ok, from_path} <- virtual_path(root, from_relative_path),
         {:ok, to_path} <- virtual_path(root, to_relative_path) do
      transfer_id = transfer_id(opts)

      frames = [
        [
          @protocol,
          "MOVE",
          transfer_id,
          from_path,
          to_path,
          bool(Keyword.get(opts, :overwrite, false))
        ]
      ]

      request(route, transfer_id, frames, simple_pending(route, "MOVE_OK"), opts)
    end
  end

  @doc """
  Handles one worker-originated worker-file frame set.
  """
  @spec handle_worker_frame(route_auth(), [binary()]) :: :ok
  def handle_worker_frame(route_auth, [@protocol, command, transfer_id | _rest] = frames)
      when is_binary(command) and is_binary(transfer_id) do
    Logger.debug(
      "worker file lane frame route=#{inspect(route_auth.route)} command=#{inspect(command)} transfer_id=#{inspect(transfer_id)} frame_count=#{length(frames)}"
    )

    if pid = Process.whereis(__MODULE__) do
      GenServer.cast(pid, {:worker_frame, route_auth, frames})
    end

    :ok
  end

  def handle_worker_frame(route_auth, frames) do
    Logger.warning(
      "invalid worker file lane frame route=#{inspect(route_auth.route)} frame_count=#{length(frames)}"
    )

    :ok
  end

  @doc """
  Returns the protocol marker frame shared by Elixir and Bun callers.
  """
  @spec protocol() :: binary()
  def protocol, do: @protocol

  @impl true
  def init(_opts), do: {:ok, %{pending: %{}}}

  @impl true
  def format_status(status) do
    case status do
      %{state: state} -> %{status | state: redact_status_state(state)}
      _status -> status
    end
  end

  @impl true
  def handle_call({:request, route, transfer_id, frames, pending, timeout}, from, state) do
    case send_frames(route, frames) do
      {:ok, :sent_or_queued} ->
        timer = Process.send_after(self(), {:request_timeout, transfer_id}, timeout)
        pending = pending |> Map.put(:from, from) |> Map.put(:timer, timer)
        {:noreply, put_in(state, [:pending, transfer_id], pending)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:worker_frame, route_auth, frames}, state) do
    {:noreply, handle_response(route_auth, frames, state)}
  end

  @impl true
  def handle_info({:request_timeout, transfer_id}, state) do
    case Map.fetch(state.pending, transfer_id) do
      {:ok, pending} ->
        maybe_abort_pending_request(transfer_id, pending)
        GenServer.reply(pending.from, {:error, :timeout})
        {:noreply, update_in(state.pending, &Map.delete(&1, transfer_id))}

      :error ->
        {:noreply, state}
    end
  end

  defp request(route, transfer_id, frames, pending, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    call_timeout = timeout + 1_000

    GenServer.call(
      __MODULE__,
      {:request, route, transfer_id, frames, pending, timeout},
      call_timeout
    )
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, {:noproc, _call} -> {:error, :not_started}
  end

  defp simple_pending(route, expected_command) do
    %{mode: :simple, route: route, expected_command: expected_command}
  end

  defp redact_status_state(%{pending: pending} = state) when is_map(pending) do
    %{state | pending: Map.new(pending, fn {id, request} -> {id, redact_pending(request)} end)}
  end

  defp redact_status_state(state), do: state

  defp redact_pending(%{mode: mode, route: route, expected_command: expected_command} = pending) do
    pending
    |> Map.take([:next_sequence, :next_offset, :credit, :commit_sent?, :eof?])
    |> Map.merge(%{
      mode: mode,
      route: route,
      expected_command: expected_command,
      chunks: chunk_count(Map.get(pending, :chunks)),
      read_begin: redacted_read_begin(Map.get(pending, :read_begin)),
      from: :redacted,
      timer: :redacted
    })
  end

  defp redact_pending(pending) when is_map(pending), do: Map.take(pending, [:mode, :route])
  defp redact_pending(_pending), do: :redacted

  defp chunk_count(chunks) when is_list(chunks), do: length(chunks)
  defp chunk_count(_chunks), do: 0

  defp redacted_read_begin(nil), do: nil
  defp redacted_read_begin(_read_begin), do: :redacted

  defp transfer_id(opts) do
    Keyword.get_lazy(opts, :transfer_id, fn ->
      "cp-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    end)
  end

  defp binary_chunks(<<>>), do: []
  defp binary_chunks(content), do: binary_chunks(content, [])
  defp binary_chunks(<<>>, acc), do: Enum.reverse(acc)

  defp binary_chunks(content, acc) do
    size = min(byte_size(content), @chunk_size)
    <<chunk::binary-size(^size), rest::binary>> = content
    binary_chunks(rest, [chunk | acc])
  end

  defp send_frames(route, frames) do
    Enum.reduce_while(frames, {:ok, :sent_or_queued}, fn frame, _acc ->
      case Broker.send_file_frame(route, frame) do
        {:ok, :sent_or_queued} = ok -> {:cont, ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp maybe_abort_pending_request(transfer_id, %{mode: :write, route: route}) do
    abort_pending_request(route, transfer_id, "WRITE_ABORT")
  end

  defp maybe_abort_pending_request(transfer_id, %{mode: :read, route: route}) do
    abort_pending_request(route, transfer_id, "READ_ABORT")
  end

  defp maybe_abort_pending_request(_transfer_id, _pending), do: :ok

  defp abort_pending_request(route, transfer_id, command) do
    case Broker.send_file_frame(route, [@protocol, command, transfer_id]) do
      {:ok, :sent_or_queued} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "worker file lane #{command} failed after timeout transfer_id=#{inspect(transfer_id)} reason=#{inspect(reason)}"
        )
    end
  end

  defp handle_response(route_auth, [@protocol, response_command, transfer_id | rest], state)
       when is_binary(response_command) and is_binary(transfer_id) do
    case Map.fetch(state.pending, transfer_id) do
      {:ok, %{route: route} = pending} when route == route_auth.route ->
        dispatch_response(response_command, transfer_id, rest, pending, state)

      {:ok, pending} ->
        Logger.warning(
          "worker file lane ignored mismatched route transfer_id=#{inspect(transfer_id)} expected=#{inspect(pending.route)} got=#{inspect(route_auth.route)}"
        )

        state

      :error ->
        Logger.debug("worker file lane ignored unmatched transfer_id=#{inspect(transfer_id)}")
        state
    end
  end

  defp handle_response(route_auth, frames, state) do
    Logger.warning(
      "invalid worker file lane response route=#{inspect(route_auth.route)} frame_count=#{length(frames)}"
    )

    state
  end

  defp dispatch_response(
         "WRITE_READY",
         transfer_id,
         [credit_frame],
         %{mode: :write} = pending,
         state
       ) do
    with {:ok, credit} <- parse_u64(credit_frame),
         {:ok, pending} <-
           send_write_data(transfer_id, %{pending | credit: pending.credit + credit}) do
      put_in(state, [:pending, transfer_id], pending)
    else
      {:error, reason} -> finish(transfer_id, {:error, reason}, state)
    end
  end

  defp dispatch_response("CREDIT", transfer_id, [credit_frame], %{mode: :write} = pending, state) do
    with {:ok, credit} <- parse_u64(credit_frame),
         {:ok, pending} <-
           send_write_data(transfer_id, %{pending | credit: pending.credit + credit}) do
      put_in(state, [:pending, transfer_id], pending)
    else
      {:error, reason} -> finish(transfer_id, {:error, reason}, state)
    end
  end

  defp dispatch_response(
         "WRITE_COMMITTED",
         transfer_id,
         [path, size_frame, fingerprint],
         %{expected_command: "WRITE_COMMITTED"},
         state
       ) do
    with {:ok, size} <- parse_u64(size_frame),
         {:ok, address} <- address_map(path) do
      finish(
        transfer_id,
        {:ok,
         Map.merge(address, %{
           "command" => "WRITE_COMMITTED",
           "size" => size,
           "xxh3_128" => empty_to_nil(fingerprint)
         })},
        state
      )
    else
      {:error, reason} -> finish(transfer_id, {:error, reason}, state)
    end
  end

  defp dispatch_response(
         "READ_READY",
         transfer_id,
         [path, size_frame, fingerprint],
         %{mode: :read} = pending,
         state
       ) do
    with {:ok, size} <- parse_u64(size_frame),
         {:ok, address} <- address_map(path),
         {:ok, :sent_or_queued} <-
           Broker.send_file_frame(pending.route, [
             @protocol,
             "CREDIT",
             transfer_id,
             u64(@credit_window)
           ]) do
      read_begin =
        Map.merge(address, %{
          "command" => "READ_READY",
          "original_size" => size,
          "content_encoding" => "zstd",
          "xxh3_128" => empty_to_nil(fingerprint)
        })

      put_in(state, [:pending, transfer_id], %{pending | read_begin: read_begin})
    else
      {:error, reason} -> finish(transfer_id, {:error, reason}, state)
    end
  end

  defp dispatch_response(
         "DATA",
         transfer_id,
         [sequence_frame, offset_frame, eof_frame, chunk],
         %{mode: :read} = pending,
         state
       ) do
    with {:ok, sequence} <- parse_u64(sequence_frame),
         {:ok, offset} <- parse_u64(offset_frame),
         {:ok, eof?} <- parse_bool(eof_frame),
         true <- sequence == pending.next_sequence,
         true <- offset == pending.next_offset,
         :ok <- maybe_send_read_credit(pending.route, transfer_id, chunk, eof?) do
      pending = %{
        pending
        | chunks: [chunk | pending.chunks],
          next_sequence: pending.next_sequence + 1,
          next_offset: pending.next_offset + byte_size(chunk)
      }

      put_in(state, [:pending, transfer_id], Map.put(pending, :eof?, eof?))
    else
      false -> finish(transfer_id, {:error, :unexpected_data_sequence}, state)
      {:error, reason} -> finish(transfer_id, {:error, reason}, state)
    end
  end

  defp dispatch_response(
         "READ_DONE",
         transfer_id,
         [chunks_frame, wire_size_frame],
         %{mode: :read} = pending,
         state
       ) do
    with {:ok, chunks} <- parse_u64(chunks_frame),
         {:ok, wire_size} <- parse_u64(wire_size_frame),
         :ok <- validate_read_done(pending, chunks, wire_size) do
      # Reply the compressed chunks (newest-first) and let the caller decompress, keeping zstd off
      # the shared lane GenServer. The decompressed-size check moves caller-side with the chunks.
      reply = %{
        "chunks" => pending.chunks,
        "begin" => pending.read_begin,
        "end" => %{
          "command" => "READ_DONE",
          "chunks" => chunks,
          "wire_size" => wire_size,
          "content_encoding" => "zstd"
        }
      }

      finish(transfer_id, {:ok, reply}, state)
    else
      {:error, reason} -> finish(transfer_id, {:error, reason}, state)
    end
  end

  defp dispatch_response(
         "STAT_OK",
         transfer_id,
         [path, kind, size_frame, modified_frame, fingerprint],
         %{expected_command: "STAT_OK"},
         state
       ) do
    with {:ok, size} <- parse_u64(size_frame),
         {:ok, modified_unix_ms} <- parse_u64(modified_frame),
         {:ok, address} <- address_map(path) do
      finish(
        transfer_id,
        {:ok,
         Map.merge(address, %{
           "command" => "STAT",
           "kind" => kind,
           "size" => size,
           "modified_unix_ms" => modified_unix_ms,
           "xxh3_128" => empty_to_nil(fingerprint)
         })},
        state
      )
    else
      {:error, reason} -> finish(transfer_id, {:error, reason}, state)
    end
  end

  defp dispatch_response(
         "LIST_OK",
         transfer_id,
         [path, recursive_frame, truncated_frame, entries_frame],
         %{expected_command: "LIST_OK"},
         state
       ) do
    with {:ok, recursive?} <- parse_bool(recursive_frame),
         {:ok, truncated?} <- parse_bool(truncated_frame),
         {:ok, entries} <- decode_entries(entries_frame),
         {:ok, address} <- address_map(path) do
      finish(
        transfer_id,
        {:ok,
         Map.merge(address, %{
           "command" => "LIST",
           "recursive" => recursive?,
           "entries" => entries,
           "truncated" => truncated?
         })},
        state
      )
    else
      {:error, reason} -> finish(transfer_id, {:error, reason}, state)
    end
  end

  defp dispatch_response(
         "MOVE_OK",
         transfer_id,
         [from_path, to_path],
         %{expected_command: "MOVE_OK"},
         state
       ) do
    with {:ok, from_address} <- address_map(from_path, "from_relative_path"),
         {:ok, to_address} <- address_map(to_path, "to_relative_path") do
      finish(
        transfer_id,
        {:ok,
         %{
           "command" => "MOVE",
           "root" => from_address["root"],
           "from_relative_path" => from_address["from_relative_path"],
           "to_relative_path" => to_address["to_relative_path"],
           "moved" => true
         }},
        state
      )
    else
      {:error, reason} -> finish(transfer_id, {:error, reason}, state)
    end
  end

  defp dispatch_response(
         "DELETE_OK",
         transfer_id,
         [path],
         %{expected_command: "DELETE_OK"},
         state
       ) do
    with {:ok, address} <- address_map(path) do
      finish(
        transfer_id,
        {:ok, Map.merge(address, %{"command" => "DELETE", "deleted" => true})},
        state
      )
    else
      {:error, reason} -> finish(transfer_id, {:error, reason}, state)
    end
  end

  defp dispatch_response("ERROR", transfer_id, [code, reason], _pending, state) do
    finish(transfer_id, {:error, %{"code" => code, "message" => reason}}, state)
  end

  defp dispatch_response("RTFM", transfer_id, [reason], _pending, state) do
    finish(transfer_id, {:error, {:protocol_error, reason}}, state)
  end

  defp dispatch_response(command, transfer_id, _rest, _pending, state) do
    Logger.warning(
      "worker file lane ignored unsupported response command=#{inspect(command)} transfer_id=#{inspect(transfer_id)}"
    )

    state
  end

  # Protocol-level READ_DONE checks that need only the accumulated pending state. The
  # decompressed-content size check runs caller-side in validate_read_content/2 so the lane
  # GenServer never decompresses.
  defp validate_read_done(pending, chunks, wire_size) do
    cond do
      pending.read_begin == nil ->
        {:error, :missing_read_ready}

      chunks != pending.next_sequence ->
        {:error, :read_done_chunk_count_mismatch}

      wire_size != pending.next_offset ->
        {:error, :read_done_wire_size_mismatch}

      Map.get(pending, :eof?) != true ->
        {:error, :read_done_before_eof}

      true ->
        :ok
    end
  end

  defp validate_read_content(read_begin, content) do
    expected_size = get_in(read_begin || %{}, ["original_size"])

    if byte_size(content) == expected_size do
      :ok
    else
      {:error, :read_done_size_mismatch}
    end
  end

  defp send_write_data(transfer_id, pending) do
    case drain_write_chunks(transfer_id, pending) do
      {:ok, %{chunks: [], commit_sent?: false} = drained} ->
        with {:ok, :sent_or_queued} <-
               Broker.send_file_frame(drained.route, [@protocol, "WRITE_COMMIT", transfer_id]) do
          {:ok, %{drained | commit_sent?: true}}
        end

      other ->
        other
    end
  end

  defp drain_write_chunks(transfer_id, %{chunks: [chunk | rest]} = pending)
       when pending.credit >= byte_size(chunk) do
    sequence = pending.next_sequence
    offset = pending.next_offset
    eof? = rest == []

    frame = [
      @protocol,
      "DATA",
      transfer_id,
      u64(sequence),
      u64(offset),
      bool(eof?),
      chunk
    ]

    with {:ok, :sent_or_queued} <- Broker.send_file_frame(pending.route, frame) do
      drain_write_chunks(transfer_id, %{
        pending
        | chunks: rest,
          next_sequence: sequence + 1,
          next_offset: offset + byte_size(chunk),
          credit: pending.credit - byte_size(chunk)
      })
    end
  end

  defp drain_write_chunks(_transfer_id, pending), do: {:ok, pending}

  defp maybe_send_read_credit(_route, _transfer_id, _chunk, true), do: :ok

  defp maybe_send_read_credit(route, transfer_id, chunk, false) do
    case Broker.send_file_frame(route, [@protocol, "CREDIT", transfer_id, u64(byte_size(chunk))]) do
      {:ok, :sent_or_queued} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish(transfer_id, reply, state) do
    {pending, pending_map} = Map.pop(state.pending, transfer_id)

    if pending do
      Process.cancel_timer(pending.timer)
      GenServer.reply(pending.from, reply)
    end

    %{state | pending: pending_map}
  end

  defp virtual_path(root, relative_path, opts \\ [])

  defp virtual_path(root, relative_path, opts) when root in @roots do
    allow_root? = Keyword.get(opts, :allow_root?, false)

    with {:ok, relative_path} <- normalize_relative_path(relative_path, allow_root?: allow_root?) do
      if relative_path == "" do
        {:ok, "/" <> root}
      else
        {:ok, "/" <> root <> "/" <> relative_path}
      end
    end
  end

  defp virtual_path(root, _relative_path, _opts), do: {:error, {:unsupported_file_root, root}}

  defp normalize_relative_path(value, opts) when is_binary(value) do
    allow_root? = Keyword.get(opts, :allow_root?, false)

    normalized =
      value
      |> String.replace("\\", "/")
      |> String.replace(~r/^\/+/, "")
      |> String.replace(~r/\/+/, "/")

    cond do
      allow_root? and normalized in ["", "."] ->
        {:ok, ""}

      normalized in ["", ".", ".."] ->
        {:error, {:invalid_relative_path, value}}

      Enum.any?(String.split(normalized, "/"), &(&1 in ["", ".", ".."])) ->
        {:error, {:invalid_relative_path, value}}

      true ->
        {:ok, normalized}
    end
  end

  defp normalize_relative_path(value, _opts), do: {:error, {:invalid_relative_path, value}}

  defp address_map(path, relative_key \\ "relative_path") do
    case split_virtual_path(path) do
      {:ok, root, relative_path} -> {:ok, %{"root" => root, relative_key => relative_path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp split_virtual_path("/" <> path) do
    case String.split(path, "/", parts: 2) do
      [root, relative_path] when root in @roots ->
        {:ok, root, relative_path}

      [root] when root in @roots ->
        {:ok, root, ""}

      _value ->
        {:error, {:invalid_virtual_path, "/" <> path}}
    end
  end

  defp split_virtual_path(path), do: {:error, {:invalid_virtual_path, path}}

  defp fingerprint_mode(opts) do
    case Keyword.get(opts, :fingerprint, "xxh3_128") do
      value when value in ["none", "xxh3_128"] -> {:ok, value}
      value -> {:error, {:unsupported_fingerprint_mode, value}}
    end
  end

  defp compress_chunks(content) do
    content
    |> binary_chunks()
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case Ankole.Kernel.zstd_compress_block(chunk, @zstd_level) do
        compressed when is_binary(compressed) -> {:cont, {:ok, [compressed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp decompress_chunks(chunks) do
    # `chunks` is stored newest-first (prepended on each DATA frame), so iterating
    # in stored order and prepending each decoded block yields oldest-first order.
    Enum.reduce_while(chunks, {:ok, []}, fn chunk, {:ok, acc} ->
      case Ankole.Kernel.zstd_decompress_block(chunk, @chunk_size) do
        decoded when is_binary(decoded) -> {:cont, {:ok, [decoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, IO.iodata_to_binary(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp u64(value) when is_integer(value) and value >= 0 and value <= 18_446_744_073_709_551_615 do
    <<value::unsigned-big-integer-size(64)>>
  end

  defp parse_u64(<<value::unsigned-big-integer-size(64)>>), do: {:ok, value}
  defp parse_u64(_frame), do: {:error, :invalid_u64_frame}

  defp bool(true), do: <<1>>
  defp bool(false), do: <<0>>
  defp bool(_value), do: <<0>>

  defp parse_bool(<<0>>), do: {:ok, false}
  defp parse_bool(<<1>>), do: {:ok, true}
  defp parse_bool(_frame), do: {:error, :invalid_bool_frame}

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp decode_entries(<<count::unsigned-big-integer-size(32), rest::binary>>) do
    decode_entries(count, rest, [])
  end

  defp decode_entries(_frame), do: {:error, :invalid_entries_frame}

  defp decode_entries(0, <<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_entries(count, bytes, acc) when count > 0 do
    with {:ok, relative_path, bytes} <- take_sized_string(bytes),
         {:ok, kind, bytes} <- take_sized_string(bytes),
         <<size::unsigned-big-integer-size(64), modified::unsigned-big-integer-size(64),
           rest::binary>> <- bytes do
      decode_entries(count - 1, rest, [
        %{
          "relative_path" => relative_path,
          "kind" => kind,
          "size" => size,
          "modified_unix_ms" => modified
        }
        | acc
      ])
    else
      _value -> {:error, :invalid_entries_frame}
    end
  end

  defp take_sized_string(<<size::unsigned-big-integer-size(32), rest::binary>>)
       when byte_size(rest) >= size do
    <<value::binary-size(^size), tail::binary>> = rest
    {:ok, value, tail}
  end

  defp take_sized_string(_bytes), do: {:error, :invalid_sized_string}
end
