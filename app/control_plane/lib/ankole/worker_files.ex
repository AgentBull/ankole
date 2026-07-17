defmodule Ankole.WorkerFiles do
  @moduledoc """
  Control-plane facade for files inside worker-visible filesystem roots.

  This module owns the worker-file policy surface: which roots exist, how a
  live worker route is chosen, and the authoritative transfer byte bound.
  `Ankole.SignalsGateway.ActorRuntime.FileTransferLane` owns only the active-transfer
  implementation underneath, and workers still validate their own mounted
  roots at the process boundary.

  Reads and writes are bounded operational artifacts. `put/4` rejects oversize
  content before any frame is sent, and `get/3` has the lane reject an
  oversize file at `READ_READY` — on the worker's authoritative size, before
  any byte credit is granted — so no caller can stream an unbounded file. The
  bound is a module guarantee and cannot be widened per call.

  Operations reach the installation-shared workspace through any ready worker
  by default. Passing `worker_id: ...` pins the operation to one specific
  worker so mount reachability stays attributable to that runtime (the Console
  file API relies on this); pinned routes never fall back to another worker.
  """

  alias Ankole.SignalsGateway.ActorRuntime.FileTransferLane
  alias Ankole.SignalsGateway.ActorRuntime.WorkerPool

  @roots ~w(user_files agent_installed_skills workspace_sessions)
  @internal_roots @roots ++ ~w(background_agent_jobs codex_accounts)
  @max_transfer_bytes 100 * 1024 * 1024

  @type operation_result :: FileTransferLane.operation_result()
  @type get_result :: FileTransferLane.get_result()

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
  Writes bytes into a worker filesystem root.
  """
  @spec put(String.t(), String.t(), iodata(), keyword()) :: operation_result()
  def put(root, relative_path, content, opts \\ [])
      when is_binary(root) and is_binary(relative_path) do
    content = IO.iodata_to_binary(content)

    with :ok <- validate_public_root(root),
         :ok <- validate_put_size(content),
         {:ok, route} <- route(opts) do
      FileTransferLane.put(route, root, relative_path, content, lane_opts(opts))
    end
  end

  @doc """
  Reads one bounded file from a worker filesystem root.
  """
  @spec get(String.t(), String.t(), keyword()) :: get_result()
  def get(root, relative_path, opts \\ [])
      when is_binary(root) and is_binary(relative_path) do
    with :ok <- validate_public_root(root),
         {:ok, route} <- route(opts) do
      opts = Keyword.put(lane_opts(opts), :max_bytes, @max_transfer_bytes)
      FileTransferLane.get(route, root, relative_path, opts)
    end
  end

  @doc """
  Lists a directory inside a worker filesystem root.
  """
  @spec list(String.t(), String.t(), keyword()) :: operation_result()
  def list(root, relative_path \\ "", opts \\ [])
      when is_binary(root) and is_binary(relative_path) do
    with :ok <- validate_public_root(root),
         {:ok, route} <- route(opts) do
      FileTransferLane.list(route, root, relative_path, lane_opts(opts))
    end
  end

  @doc """
  Deletes a file or, with `recursive: true`, a directory in a worker root.
  """
  @spec delete(String.t(), String.t(), keyword()) :: operation_result()
  def delete(root, relative_path, opts \\ [])
      when is_binary(root) and is_binary(relative_path) do
    with :ok <- validate_delete_root(root),
         {:ok, route} <- route(opts) do
      FileTransferLane.delete(route, root, relative_path, lane_opts(opts))
    end
  end

  @doc """
  Moves or renames a path inside a single worker filesystem root.
  """
  @spec move(String.t(), String.t(), String.t(), keyword()) :: operation_result()
  def move(root, from_relative_path, to_relative_path, opts \\ [])
      when is_binary(root) and is_binary(from_relative_path) and is_binary(to_relative_path) do
    with :ok <- validate_public_root(root),
         {:ok, route} <- route(opts) do
      FileTransferLane.move(route, root, from_relative_path, to_relative_path, lane_opts(opts))
    end
  end

  defp route(opts) do
    case Keyword.get(opts, :worker_id) do
      nil -> WorkerPool.file_worker_route()
      worker_id when is_binary(worker_id) -> WorkerPool.worker_file_route(worker_id)
    end
  end

  defp lane_opts(opts), do: Keyword.drop(opts, [:worker_id, :max_bytes])

  defp validate_public_root(root) when root in @roots, do: :ok
  defp validate_public_root(root), do: {:error, {:unsupported_file_root, root}}

  defp validate_delete_root(root) when root in @internal_roots, do: :ok
  defp validate_delete_root(root), do: {:error, {:unsupported_file_root, root}}

  defp validate_put_size(content) when byte_size(content) <= @max_transfer_bytes, do: :ok

  defp validate_put_size(content) do
    {:error, {:file_too_large, byte_size(content), @max_transfer_bytes}}
  end
end
