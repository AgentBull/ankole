defmodule Ankole.WorkerFiles do
  @moduledoc """
  Moves file bytes between the control plane and one Worker's Agent Home.

  This module owns the transfer policy: which Worker a transfer reaches and
  the authoritative byte bound. Bulk bytes never enter RuntimeFabric:
  `put/3`, `stream/2`, and `receive_bundle/4` open an
  `Ankole.WorkerFiles.Relay` session on this control-plane Pod and hand the
  Worker a one-time relay URL that it pulls from or pushes to over HTTP.

  A path is relative to the Agent Home of the Worker in `worker:`; the
  Worker's connection already names its Agent. The drive RPCs
  (`Ankole.Files.RPCBroker`) pass the Worker that called them, so the bytes
  go to the Worker that asked for them.

  `put/3` rejects oversize content before any RPC is sent, and the push relay
  rejects a Worker upload larger than the bound before it reads the body. The
  bound is a module guarantee and cannot be widened per call.
  """

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRoute
  alias Ankole.WorkerFiles.Relay
  alias Ankole.WorkerFiles.RelayError

  @max_transfer_bytes 100 * 1024 * 1024
  @transfer_timeout_ms 120_000
  @relay_chunk_timeout_ms 30_000
  @max_bundle_path_bytes 4096

  @type operation_result :: {:ok, map()} | {:error, term()}

  @doc """
  Authoritative byte bound for one transferred file in either direction.
  """
  @spec max_transfer_bytes() :: pos_integer()
  def max_transfer_bytes, do: @max_transfer_bytes

  @doc """
  Writes a local file to a path in the Agent Home of the Worker in `worker:`.

  The file streams from disk. The result carries the `"size"` that the Worker
  wrote.
  """
  @spec put(String.t(), {:file, Path.t()}, keyword()) :: operation_result()
  def put(home_relative_path, {:file, path}, opts \\ [])
      when is_binary(home_relative_path) and is_binary(path) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @transfer_timeout_ms)

    with {:ok, size} <- regular_file_size(path),
         :ok <- validate_size(size),
         worker = worker(opts),
         {:ok, session} <-
           Relay.open(%{
             direction: :pull,
             worker: worker,
             max_bytes: @max_transfer_bytes,
             ttl_ms: timeout_ms,
             source: {:file, path},
             owner: self()
           }) do
      request = transfer_request(session, home_relative_path)

      try do
        with {:ok, response} <-
               rpc(worker, "pull", request, FabricProto.WorkerFileTransferResponse,
                 timeout_ms: timeout_ms
               ) do
          {:ok, %{"size" => response.size}}
        end
      after
        Relay.close(session.transfer_id)
      end
    end
  end

  @doc """
  Opens one bounded file of the Agent Home of the Worker in `worker:` as a
  stream.

  The result carries `"size"` and a `"body"` stream of binaries. The stream
  must be consumed in the calling process; it raises `RelayError` when the
  Worker or the relay fails after the first bytes arrived.
  """
  @spec stream(String.t(), keyword()) :: operation_result()
  def stream(home_relative_path, opts \\ []) when is_binary(home_relative_path) do
    push(worker(opts), home_relative_path, opts)
  end

  @doc """
  Copies several files under one directory of the Agent Home of the Worker in
  `worker:` into `target_dir` with one transfer.

  `paths` are relative to `home_relative_dir`. The Worker sends one bundle:
  for each path in order, a 4-byte big-endian path length, the path, an
  8-byte big-endian content length, and the content. The whole bundle has the
  byte bound of one file. The result lists the local files in the order of
  `paths`.
  """
  @spec receive_bundle(String.t(), [String.t()], Path.t(), keyword()) ::
          {:ok, [Path.t()]} | {:error, term()}
  def receive_bundle(home_relative_dir, paths, target_dir, opts \\ [])
      when is_binary(home_relative_dir) and is_list(paths) and paths != [] and
             is_binary(target_dir) do
    with worker = worker(opts),
         {:ok, %{"body" => body}} <-
           push(worker, home_relative_dir, Keyword.put(opts, :bundle_paths, paths)) do
      write_bundle(body, paths, target_dir)
    end
  rescue
    error in RelayError -> {:error, error.reason}
  end

  # The push RPC runs in a task so this process stays free to receive the
  # relayed chunks. The Worker answers the RPC only after its PUT completed,
  # so an RPC error before `:relay_opened` is the authoritative failure.
  defp push(worker, home_relative_path, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @transfer_timeout_ms)

    with {:ok, session} <-
           Relay.open(%{
             direction: :push,
             worker: worker,
             max_bytes: @max_transfer_bytes,
             ttl_ms: timeout_ms,
             consumer: self(),
             owner: self()
           }) do
      transfer_id = session.transfer_id

      request = %{
        transfer_request(session, home_relative_path)
        | bundle_paths: Keyword.get(opts, :bundle_paths, [])
      }

      task =
        Task.Supervisor.async_nolink(
          Ankole.WorkerFiles.TaskSupervisor,
          Ankole.Repo.bind_tenant(fn ->
            rpc(worker, "push", request, FabricProto.WorkerFileTransferResponse,
              timeout_ms: timeout_ms
            )
          end)
        )

      receive do
        {:relay_opened, ^transfer_id, handler, size} ->
          {:ok, %{"size" => size, "body" => relay_body(transfer_id, handler, task, timeout_ms)}}

        {ref, result} when ref == task.ref ->
          Process.demonitor(ref, [:flush])
          Relay.close(transfer_id)
          push_failure(result)

        {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
          Relay.close(transfer_id)
          {:error, {:relay_failed, reason}}
      after
        timeout_ms ->
          Task.shutdown(task, :brutal_kill)
          Relay.close(transfer_id)
          {:error, :timeout}
      end
    end
  end

  defp push_failure({:error, _reason} = error), do: error
  defp push_failure({:ok, _response}), do: {:error, {:relay_failed, :completed_without_body}}

  defp relay_body(transfer_id, handler, task, timeout_ms) do
    Stream.resource(
      fn -> :streaming end,
      fn
        :done ->
          {:halt, :done}

        :streaming ->
          receive do
            {:relay_chunk, ^transfer_id, data} ->
              send(handler, {:relay_ack, transfer_id})
              {[data], :streaming}

            {:relay_done, ^transfer_id} ->
              await_push(task, timeout_ms)
              {:halt, :done}

            {:relay_failed, ^transfer_id, reason} ->
              raise RelayError, reason: reason
          after
            @relay_chunk_timeout_ms ->
              raise RelayError, reason: :timeout
          end
      end,
      fn _state ->
        Relay.close(transfer_id)
        Task.shutdown(task, :brutal_kill)
        flush_relay_messages(transfer_id)
      end
    )
  end

  defp await_push(task, timeout_ms) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, _response}} -> :ok
      {:ok, {:error, reason}} -> raise RelayError, reason: reason
      {:exit, reason} -> raise RelayError, reason: reason
      nil -> raise RelayError, reason: :timeout
    end
  end

  defp flush_relay_messages(transfer_id) do
    receive do
      {tag, ^transfer_id} when tag in [:relay_done] ->
        flush_relay_messages(transfer_id)

      {tag, ^transfer_id, _value} when tag in [:relay_chunk, :relay_failed] ->
        flush_relay_messages(transfer_id)

      {:relay_opened, ^transfer_id, _handler, _size} ->
        flush_relay_messages(transfer_id)
    after
      0 -> :ok
    end
  end

  # A file left open by a relay failure closes when the calling process exits;
  # the drive RPCs run in one short-lived task per request.
  defp write_bundle(body, paths, target_dir) do
    initial = %{
      phase: :path_length,
      buffer: <<>>,
      pending: paths,
      file: nil,
      remaining: 0,
      files: []
    }

    body
    |> Enum.reduce_while(initial, fn chunk, state ->
      case parse_bundle(%{state | buffer: state.buffer <> chunk}, target_dir) do
        {:ok, state} -> {:cont, state}
        {:error, reason, state} -> {:halt, close_bundle_file(state, {:error, reason})}
      end
    end)
    |> case do
      {:error, _reason} = error ->
        error

      %{phase: :path_length, buffer: <<>>, pending: []} = state ->
        {:ok, Enum.reverse(state.files)}

      state ->
        close_bundle_file(state, {:error, {:invalid_bundle, :truncated}})
    end
  end

  defp parse_bundle(%{phase: :path_length, buffer: <<length::32-big, rest::binary>>} = state, dir) do
    if length in 1..@max_bundle_path_bytes,
      do: parse_bundle(%{state | phase: {:path, length}, buffer: rest}, dir),
      else: {:error, {:invalid_bundle, :path_length}, state}
  end

  defp parse_bundle(%{phase: {:path, length}, buffer: buffer} = state, dir)
       when byte_size(buffer) >= length do
    <<path::binary-size(^length), rest::binary>> = buffer

    case state.pending do
      [^path | pending] ->
        parse_bundle(%{state | phase: :content_length, buffer: rest, pending: pending}, dir)

      _other ->
        {:error, {:invalid_bundle, :unexpected_path}, state}
    end
  end

  defp parse_bundle(
         %{phase: :content_length, buffer: <<size::64-big, rest::binary>>} = state,
         dir
       ) do
    local_path = Path.join(dir, Integer.to_string(length(state.files)))

    case File.open(local_path, [:write, :binary, :raw]) do
      {:ok, file} ->
        parse_bundle(
          %{
            state
            | phase: :content,
              buffer: rest,
              file: file,
              remaining: size,
              files: [local_path | state.files]
          },
          dir
        )

      {:error, reason} ->
        {:error, {:bundle_write_failed, reason}, state}
    end
  end

  defp parse_bundle(%{phase: :content, remaining: 0} = state, dir) do
    case File.close(state.file) do
      :ok -> parse_bundle(%{state | phase: :path_length, file: nil}, dir)
      {:error, reason} -> {:error, {:bundle_write_failed, reason}, %{state | file: nil}}
    end
  end

  defp parse_bundle(%{phase: :content, buffer: buffer} = state, dir) when buffer != <<>> do
    take = min(byte_size(buffer), state.remaining)
    <<data::binary-size(^take), rest::binary>> = buffer

    case :file.write(state.file, data) do
      :ok -> parse_bundle(%{state | buffer: rest, remaining: state.remaining - take}, dir)
      {:error, reason} -> {:error, {:bundle_write_failed, reason}, state}
    end
  end

  defp parse_bundle(state, _dir), do: {:ok, state}

  defp close_bundle_file(%{file: nil}, result), do: result

  defp close_bundle_file(%{file: file}, result) do
    File.close(file)
    result
  end

  defp transfer_request(session, home_relative_path) do
    %FabricProto.WorkerFileTransferRequest{
      transfer_id: session.transfer_id,
      url: session.url,
      home_relative_path: home_relative_path,
      max_bytes: @max_transfer_bytes,
      expires_at: DateTime.to_iso8601(session.expires_at)
    }
  end

  defp rpc(worker, operation, request, response_module, opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    {iodata, _size} = request.__struct__.encode!(request)

    with {:ok, payload} <-
           WorkerRoute.request_rpc(
             worker,
             "worker_files." <> operation,
             IO.iodata_to_binary(iodata),
             timeout_ms: timeout_ms,
             request_id: "worker-files-#{operation}-#{Ecto.UUID.generate()}"
           ) do
      response_module.decode(payload)
    end
  end

  defp worker(opts) do
    case Keyword.fetch!(opts, :worker) do
      %AgentWorker{} = worker -> AgentWorkers.target(worker)
      %{worker_id: _, transport_route: _} = target -> target
    end
  end

  defp regular_file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:ok, %File.Stat{}} -> {:error, {:invalid_source, :not_regular_file}}
      {:error, reason} -> {:error, {:invalid_source, reason}}
    end
  end

  defp validate_size(size) when size <= @max_transfer_bytes, do: :ok
  defp validate_size(size), do: {:error, {:file_too_large, size, @max_transfer_bytes}}
end
