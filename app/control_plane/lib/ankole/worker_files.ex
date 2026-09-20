defmodule Ankole.WorkerFiles do
  @moduledoc """
  Control-plane facade for files inside worker-visible filesystem roots.

  This module owns the worker-file policy surface: which roots exist, how a
  live worker is chosen, and the authoritative transfer byte bound. Small
  operations are Worker-owned RPCs. Bulk bytes never enter RuntimeFabric:
  `put/4` and `get/3` open an `Ankole.WorkerFiles.Relay` session on this
  control-plane Pod and hand the Worker a one-time signed URL that it pulls
  from or pushes to over HTTP.

  Reads and writes are bounded operational artifacts. `put/4` rejects
  oversize content before any RPC is sent, and the push relay rejects a
  Worker upload larger than the bound before it reads the body. The bound is
  a module guarantee and cannot be widened per call.

  Operations reach the installation-shared Agent Home filesystem through any
  ready worker by default. Passing `worker_id: ...` pins the operation to one
  specific worker so mount reachability stays attributable to that runtime
  (the Console file API relies on this); pinned routes never fall back.
  """

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRoute
  alias Ankole.SignalsGateway.ActorRuntime.WorkerPool
  alias Ankole.WorkerFiles.Relay
  alias Ankole.WorkerFiles.RelayError

  @roots ~w(user_files agent_installed_skills agent_sessions)
  @internal_roots @roots ++ ~w(agent_home_documents)
  @max_transfer_bytes 100 * 1024 * 1024
  @transfer_timeout_ms 120_000
  @operation_timeout_ms 30_000
  @relay_chunk_timeout_ms 30_000

  @type source :: iodata() | {:file, Path.t()}
  @type operation_result :: {:ok, map()} | {:error, term()}
  @type get_result :: {:ok, map()} | {:error, term()}

  @doc """
  Worker filesystem roots addressable through the control plane.
  """
  @spec roots() :: [String.t()]
  def roots, do: @roots

  @doc """
  Authoritative byte bound for one transferred file in either direction.
  """
  @spec max_transfer_bytes() :: pos_integer()
  def max_transfer_bytes, do: @max_transfer_bytes

  @doc """
  Makes one provider-supplied value safe as a worker-file path segment.

  Transliterates the value to ASCII, keeps only `[A-Za-z0-9._-]`, trims `_`,
  and bounds the segment to 160 characters. A value that reduces to `""`,
  `"."`, or `".."` becomes `"attachment"`.
  """
  @spec sanitize_path_segment(term()) :: String.t()
  def sanitize_path_segment(value) when is_binary(value) do
    value
    |> Ankole.Kernel.any_ascii()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 160)
    |> case do
      segment when segment in ["", ".", ".."] -> "attachment"
      segment -> segment
    end
  end

  def sanitize_path_segment(_value), do: "attachment"

  @doc """
  Writes bytes into a worker filesystem root.

  `source` is iodata or `{:file, path}`; a file source streams from disk.
  """
  @spec put(String.t(), String.t(), source(), keyword()) :: operation_result()
  def put(root, relative_path, source, opts \\ [])
      when is_binary(root) and is_binary(relative_path) do
    with :ok <- validate_public_root(root) do
      pull(root, relative_path, source, opts)
    end
  end

  @doc false
  @spec put_internal(String.t(), String.t(), source(), keyword()) :: operation_result()
  def put_internal(root, relative_path, source, opts \\ [])
      when is_binary(root) and is_binary(relative_path) do
    if root in @internal_roots,
      do: pull(root, relative_path, source, opts),
      else: {:error, {:unsupported_file_root, root}}
  end

  @doc """
  Reads one bounded file from a worker filesystem root into memory.

  The result carries `"content"` and `"size"`. Callers that forward bytes to
  another stream use `stream/3` instead.
  """
  @spec get(String.t(), String.t(), keyword()) :: get_result()
  def get(root, relative_path, opts \\ [])
      when is_binary(root) and is_binary(relative_path) do
    with {:ok, %{"body" => body} = result} <- stream(root, relative_path, opts) do
      content = body |> Enum.to_list() |> IO.iodata_to_binary()
      {:ok, result |> Map.delete("body") |> Map.put("content", content)}
    end
  rescue
    error in RelayError -> {:error, error.reason}
  end

  @doc """
  Opens one bounded file from a worker filesystem root as a stream.

  The result carries `"size"` and a `"body"` stream of binaries. The stream
  must be consumed in the calling process; it raises `RelayError` when the
  Worker or the relay fails after the first bytes arrived.
  """
  @spec stream(String.t(), String.t(), keyword()) :: get_result()
  def stream(root, relative_path, opts \\ [])
      when is_binary(root) and is_binary(relative_path) do
    with :ok <- validate_public_root(root),
         {:ok, worker} <- worker(opts) do
      push(worker, root, relative_path, opts)
    end
  end

  @doc """
  Lists a directory inside a worker filesystem root.
  """
  @spec list(String.t(), String.t(), keyword()) :: operation_result()
  def list(root, relative_path \\ "", opts \\ [])
      when is_binary(root) and is_binary(relative_path) do
    request = %FabricProto.WorkerFileListRequest{
      root: root,
      relative_path: relative_path,
      recursive: Keyword.get(opts, :recursive, false),
      max_entries: Keyword.get(opts, :max_entries, 1000)
    }

    with :ok <- validate_public_root(root),
         {:ok, worker} <- worker(opts),
         {:ok, response} <-
           rpc(worker, "list", request, FabricProto.WorkerFileListResponse, opts) do
      {:ok,
       %{
         "root" => response.root,
         "relative_path" => response.relative_path,
         "truncated" => response.truncated,
         "entries" =>
           Enum.map(response.entries, fn entry ->
             %{
               "relative_path" => entry.relative_path,
               "kind" => entry.kind,
               "size" => entry.size,
               "modified_unix_ms" => entry.modified_unix_ms
             }
           end)
       }}
    end
  end

  @doc """
  Deletes a file or, with `recursive: true`, a directory in a worker root.
  """
  @spec delete(String.t(), String.t(), keyword()) :: operation_result()
  def delete(root, relative_path, opts \\ [])
      when is_binary(root) and is_binary(relative_path) do
    request = %FabricProto.WorkerFileDeleteRequest{
      root: root,
      relative_path: relative_path,
      recursive: Keyword.get(opts, :recursive, false)
    }

    with :ok <- validate_public_root(root),
         {:ok, worker} <- worker(opts),
         {:ok, response} <-
           rpc(worker, "delete", request, FabricProto.WorkerFileDeleteResponse, opts) do
      {:ok,
       %{"root" => response.root, "relative_path" => response.relative_path, "deleted" => true}}
    end
  end

  @doc """
  Moves or renames a path inside a single worker filesystem root.
  """
  @spec move(String.t(), String.t(), String.t(), keyword()) :: operation_result()
  def move(root, from_relative_path, to_relative_path, opts \\ [])
      when is_binary(root) and is_binary(from_relative_path) and is_binary(to_relative_path) do
    request = %FabricProto.WorkerFileMoveRequest{
      root: root,
      from_relative_path: from_relative_path,
      to_relative_path: to_relative_path,
      overwrite: Keyword.get(opts, :overwrite, false)
    }

    with :ok <- validate_public_root(root),
         {:ok, worker} <- worker(opts),
         {:ok, response} <-
           rpc(worker, "move", request, FabricProto.WorkerFileMoveResponse, opts) do
      {:ok,
       %{
         "root" => response.root,
         "from_relative_path" => response.from_relative_path,
         "to_relative_path" => response.to_relative_path,
         "moved" => true
       }}
    end
  end

  defp pull(root, relative_path, source, opts) do
    with {:ok, source, size} <- normalize_source(source),
         :ok <- validate_size(size),
         {:ok, worker} <- worker(opts) do
      timeout_ms = Keyword.get(opts, :timeout_ms, @transfer_timeout_ms)

      {:ok, session} =
        Relay.open(%{
          direction: :pull,
          worker: worker,
          root: root,
          relative_path: relative_path,
          max_bytes: @max_transfer_bytes,
          ttl_ms: timeout_ms,
          source: source,
          owner: self()
        })

      request = transfer_request(session, root, relative_path)

      try do
        with {:ok, response} <-
               rpc(worker, "pull", request, FabricProto.WorkerFileTransferResponse,
                 timeout_ms: timeout_ms
               ) do
          {:ok, transfer_result(response)}
        end
      after
        Relay.close(session.transfer_id)
      end
    end
  end

  # The push RPC runs in a task so this process stays free to receive the
  # relayed chunks. The Worker answers the RPC only after its PUT completed,
  # so an RPC error before `:relay_opened` is the authoritative failure.
  defp push(worker, root, relative_path, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @transfer_timeout_ms)

    {:ok, session} =
      Relay.open(%{
        direction: :push,
        worker: worker,
        root: root,
        relative_path: relative_path,
        max_bytes: @max_transfer_bytes,
        ttl_ms: timeout_ms,
        consumer: self(),
        owner: self()
      })

    transfer_id = session.transfer_id
    request = transfer_request(session, root, relative_path)

    task =
      Task.Supervisor.async_nolink(Ankole.WorkerFiles.TaskSupervisor, fn ->
        rpc(worker, "push", request, FabricProto.WorkerFileTransferResponse,
          timeout_ms: timeout_ms
        )
      end)

    receive do
      {:relay_opened, ^transfer_id, handler, size} ->
        {:ok,
         %{
           "root" => root,
           "relative_path" => relative_path,
           "size" => size,
           "body" => relay_body(transfer_id, handler, task, timeout_ms)
         }}

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

  defp transfer_request(session, root, relative_path) do
    %FabricProto.WorkerFileTransferRequest{
      transfer_id: session.transfer_id,
      url: session.url,
      root: root,
      relative_path: relative_path,
      max_bytes: @max_transfer_bytes,
      expires_at: DateTime.to_iso8601(session.expires_at)
    }
  end

  defp transfer_result(%FabricProto.WorkerFileTransferResponse{} = response) do
    %{
      "root" => response.root,
      "relative_path" => response.relative_path,
      "size" => response.size,
      "xxh3_128" => empty_to_nil(response.xxh3_128)
    }
  end

  defp rpc(%AgentComputerWorker{} = worker, operation, request, response_module, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @operation_timeout_ms)
    {iodata, _size} = request.__struct__.encode!(request)

    with {:ok, payload} <-
           WorkerRoute.request_rpc(
             WorkerPool.worker_target(worker),
             "worker_files." <> operation,
             IO.iodata_to_binary(iodata),
             timeout_ms: timeout_ms,
             request_id: "worker-files-#{operation}-#{Ecto.UUID.generate()}"
           ) do
      response_module.decode(payload)
    end
  end

  defp worker(opts) do
    case Keyword.get(opts, :worker_id) do
      nil -> WorkerPool.file_worker()
      worker_id when is_binary(worker_id) -> WorkerPool.file_worker_by_id(worker_id)
    end
  end

  defp normalize_source({:file, path}) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, {:file, path}, size}
      {:ok, %File.Stat{}} -> {:error, {:invalid_source, :not_regular_file}}
      {:error, reason} -> {:error, {:invalid_source, reason}}
    end
  end

  defp normalize_source(content) do
    binary = IO.iodata_to_binary(content)
    {:ok, {:binary, binary}, byte_size(binary)}
  end

  defp validate_public_root(root) when root in @roots, do: :ok
  defp validate_public_root(root), do: {:error, {:unsupported_file_root, root}}

  defp validate_size(size) when size <= @max_transfer_bytes, do: :ok
  defp validate_size(size), do: {:error, {:file_too_large, size, @max_transfer_bytes}}

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
