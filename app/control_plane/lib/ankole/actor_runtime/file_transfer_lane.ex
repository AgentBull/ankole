defmodule Ankole.ActorRuntime.FileTransferLane do
  @moduledoc """
  Control-plane entry point for RuntimeFabric worker-file frames.

  The worker file service is addressed by a worker route plus a filesystem root
  name and relative path inside that root. It is not actor-, session-, or
  turn-scoped; actor messages can reference files after they have been
  materialized, but file materialization itself is independent.
  """

  use GenServer

  require Logger

  alias Ankole.ActorRuntime.Transport.Broker

  @protocol "ANKOLE_FILE/1"
  @chunk_size 1024 * 1024
  @default_timeout 120_000
  @default_content_encoding "zstd"

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
  Writes a binary object into a worker-owned filesystem root.
  """
  @spec put(String.t(), String.t(), String.t(), iodata(), keyword()) :: operation_result()
  def put(route, root, relative_path, content, opts \\ [])
      when is_binary(route) and is_binary(root) and is_binary(relative_path) do
    content = IO.iodata_to_binary(content)

    with {:ok, content_encoding} <-
           normalize_content_encoding(
             Keyword.get(opts, :content_encoding, @default_content_encoding)
           ),
         {:ok, wire_content} <- encode_wire_content(content, content_encoding) do
      transfer_id = transfer_id(opts)

      metadata =
        %{
          root: root,
          relative_path: relative_path,
          content_encoding: content_encoding,
          original_size: byte_size(content)
        }
        |> encode_metadata()

      frames =
        [
          [@protocol, "PUT_BEGIN", transfer_id, metadata]
          | put_chunk_frames(transfer_id, wire_content)
        ] ++
          [[@protocol, "PUT_COMMIT", transfer_id]]

      request(route, transfer_id, frames, "PUT_COMMIT", opts)
    end
  end

  @doc """
  Reads a file from a worker-owned filesystem root.

  The v1 API returns the file content as one binary because the expected files
  are bounded operational artifacts, not unbounded archival objects.
  """
  @spec get(String.t(), String.t(), String.t(), keyword()) :: get_result()
  def get(route, root, relative_path, opts \\ [])
      when is_binary(route) and is_binary(root) and is_binary(relative_path) do
    with {:ok, content_encoding} <-
           normalize_content_encoding(
             Keyword.get(opts, :content_encoding, @default_content_encoding)
           ) do
      transfer_id = transfer_id(opts)

      metadata =
        %{
          root: root,
          relative_path: relative_path,
          content_encoding: content_encoding,
          fingerprint: Keyword.get(opts, :fingerprint, "xxh3_128")
        }
        |> encode_metadata()

      request(
        route,
        transfer_id,
        [[@protocol, "GET", transfer_id, metadata]],
        "GET_END",
        opts,
        %{content_encoding: content_encoding}
      )
    end
  end

  @doc """
  Reads filesystem information for one worker-owned path.
  """
  @spec stat(String.t(), String.t(), String.t(), keyword()) :: operation_result()
  def stat(route, root, relative_path, opts \\ [])
      when is_binary(route) and is_binary(root) and is_binary(relative_path) do
    transfer_id = transfer_id(opts)

    metadata =
      %{
        root: root,
        relative_path: relative_path,
        fingerprint: Keyword.get(opts, :fingerprint, "xxh3_128")
      }
      |> encode_metadata()

    request(route, transfer_id, [[@protocol, "STAT", transfer_id, metadata]], "STAT", opts)
  end

  @doc """
  Lists a directory inside a worker-owned filesystem root.
  """
  @spec list(String.t(), String.t(), String.t(), keyword()) :: operation_result()
  def list(route, root, relative_path \\ "", opts \\ [])
      when is_binary(route) and is_binary(root) and is_binary(relative_path) do
    transfer_id = transfer_id(opts)

    metadata =
      %{
        root: root,
        relative_path: relative_path,
        recursive: Keyword.get(opts, :recursive, false),
        max_entries: Keyword.get(opts, :max_entries)
      }
      |> encode_metadata()

    request(route, transfer_id, [[@protocol, "LIST", transfer_id, metadata]], "LIST", opts)
  end

  @doc """
  Deletes a file or, with `recursive: true`, a directory in a worker-owned root.
  """
  @spec delete(String.t(), String.t(), String.t(), keyword()) :: operation_result()
  def delete(route, root, relative_path, opts \\ [])
      when is_binary(route) and is_binary(root) and is_binary(relative_path) do
    transfer_id = transfer_id(opts)

    metadata =
      %{
        root: root,
        relative_path: relative_path,
        recursive: Keyword.get(opts, :recursive, false)
      }
      |> encode_metadata()

    request(
      route,
      transfer_id,
      [[@protocol, "DELETE", transfer_id, metadata]],
      "DELETE",
      opts
    )
  end

  @doc """
  Moves or renames a path inside a single worker-owned filesystem root.
  """
  @spec move(String.t(), String.t(), String.t(), String.t(), keyword()) :: operation_result()
  def move(route, root, from_relative_path, to_relative_path, opts \\ [])
      when is_binary(route) and is_binary(root) and is_binary(from_relative_path) and
             is_binary(to_relative_path) do
    transfer_id = transfer_id(opts)

    metadata =
      %{
        root: root,
        from_relative_path: from_relative_path,
        to_relative_path: to_relative_path,
        overwrite: Keyword.get(opts, :overwrite, false)
      }
      |> encode_metadata()

    request(route, transfer_id, [[@protocol, "MOVE", transfer_id, metadata]], "MOVE", opts)
  end

  @doc """
  Handles one worker-originated worker-file frame set.

  ACK/ERROR/data frames are matched to the in-memory caller that initiated a
  transfer. There is intentionally no durable state here: callers retry a whole
  file operation if the control plane or worker goes away mid-flight.
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
        GenServer.reply(pending.from, {:error, :timeout})
        {:noreply, update_in(state.pending, &Map.delete(&1, transfer_id))}

      :error ->
        {:noreply, state}
    end
  end

  defp request(route, transfer_id, frames, expected_command, opts, pending_attrs \\ %{}) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    call_timeout = timeout + 1_000

    pending =
      %{
        route: route,
        expected_command: expected_command,
        get_begin: nil,
        get_chunks: [],
        next_chunk_index: 0,
        content_encoding: @default_content_encoding
      }
      |> Map.merge(pending_attrs)

    GenServer.call(
      __MODULE__,
      {:request, route, transfer_id, frames, pending, timeout},
      call_timeout
    )
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, {:noproc, _call} -> {:error, :not_started}
  end

  defp transfer_id(opts) do
    Keyword.get_lazy(opts, :transfer_id, fn ->
      "cp-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    end)
  end

  defp put_chunk_frames(transfer_id, content) do
    content
    |> binary_chunks()
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      [@protocol, "PUT_CHUNK", transfer_id, Integer.to_string(index), chunk]
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

  defp dispatch_response("ACK", transfer_id, [payload_frame], pending, state) do
    with {:ok, payload} <- decode_payload(payload_frame),
         true <- payload["command"] == pending.expected_command do
      finish(transfer_id, {:ok, payload}, state)
    else
      false -> state
      {:error, reason} -> finish(transfer_id, {:error, reason}, state)
    end
  end

  defp dispatch_response("ERROR", transfer_id, [payload_frame], _pending, state) do
    reason =
      case decode_payload(payload_frame) do
        {:ok, %{"message" => message}} -> message
        {:ok, payload} -> payload
        {:error, reason} -> reason
      end

    finish(transfer_id, {:error, reason}, state)
  end

  defp dispatch_response("LIST_RESULT", transfer_id, [payload_frame], pending, state) do
    with true <- pending.expected_command == "LIST",
         {:ok, payload} <- decode_payload(payload_frame) do
      finish(transfer_id, {:ok, payload}, state)
    else
      false -> state
      {:error, reason} -> finish(transfer_id, {:error, reason}, state)
    end
  end

  defp dispatch_response("GET_BEGIN", transfer_id, [payload_frame], pending, state) do
    if pending.expected_command == "GET_END" do
      case decode_payload(payload_frame) do
        {:ok, payload} ->
          put_in(state, [:pending, transfer_id], %{pending | get_begin: payload})

        {:error, reason} ->
          finish(transfer_id, {:error, reason}, state)
      end
    else
      state
    end
  end

  defp dispatch_response("GET_CHUNK", transfer_id, [chunk_index_frame, chunk], pending, state) do
    if pending.expected_command == "GET_END" do
      with {:ok, chunk_index} <- parse_non_negative_integer(chunk_index_frame),
           true <- chunk_index == pending.next_chunk_index do
        pending = %{
          pending
          | get_chunks: [chunk | pending.get_chunks],
            next_chunk_index: pending.next_chunk_index + 1
        }

        put_in(state, [:pending, transfer_id], pending)
      else
        false ->
          finish(transfer_id, {:error, :unexpected_chunk_index}, state)

        {:error, reason} ->
          finish(transfer_id, {:error, reason}, state)
      end
    else
      state
    end
  end

  defp dispatch_response("GET_END", transfer_id, [payload_frame], pending, state) do
    if pending.expected_command == "GET_END" do
      with {:ok, payload} <- decode_payload(payload_frame),
           {:ok, content} <-
             pending.get_chunks
             |> Enum.reverse()
             |> IO.iodata_to_binary()
             |> decode_wire_content(pending.content_encoding) do
        reply = %{
          "content" => content,
          "begin" => pending.get_begin,
          "end" => payload
        }

        finish(transfer_id, {:ok, reply}, state)
      else
        {:error, reason} ->
          finish(transfer_id, {:error, reason}, state)
      end
    else
      state
    end
  end

  defp dispatch_response(command, transfer_id, _rest, _pending, state) do
    Logger.warning(
      "worker file lane ignored unsupported response command=#{inspect(command)} transfer_id=#{inspect(transfer_id)}"
    )

    state
  end

  defp finish(transfer_id, reply, state) do
    {pending, pending_map} = Map.pop(state.pending, transfer_id)

    if pending do
      Process.cancel_timer(pending.timer)
      GenServer.reply(pending.from, reply)
    end

    %{state | pending: pending_map}
  end

  defp encode_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Torque.encode!()
  end

  defp decode_payload(payload_frame) do
    {:ok, Torque.decode!(payload_frame)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp normalize_content_encoding(value) when value in ["identity", "zstd"], do: {:ok, value}
  defp normalize_content_encoding(value), do: {:error, {:unsupported_content_encoding, value}}

  defp encode_wire_content(content, "identity"), do: {:ok, content}
  defp encode_wire_content(content, "zstd"), do: run_zstd(["-q", "-c"], content, "zstd encode")

  defp decode_wire_content(content, "identity"), do: {:ok, content}

  defp decode_wire_content(content, "zstd"),
    do: run_zstd(["-q", "-d", "-c"], content, "zstd decode")

  defp run_zstd(args, input, label) do
    path =
      Path.join(System.tmp_dir!(), "ankole-file-lane-zstd-#{System.unique_integer([:positive])}")

    try do
      with :ok <- File.write(path, input) do
        case System.cmd("zstd", args ++ [path], stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, output}

          {output, status} ->
            {:error, "#{label} failed with status #{status}: #{String.trim(output)}"}
        end
      end
    rescue
      error -> {:error, "#{label} failed: #{Exception.message(error)}"}
    after
      File.rm(path)
    end
  end

  defp parse_non_negative_integer(frame) do
    with text when is_binary(text) <- frame,
         {value, ""} <- Integer.parse(text),
         true <- value >= 0 do
      {:ok, value}
    else
      _value -> {:error, :invalid_chunk_index}
    end
  end
end
