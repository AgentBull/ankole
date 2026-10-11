defmodule Ankole.Files.RPCBroker do
  @moduledoc """
  RuntimeFabric brokers for the `files.*` RPCs of the Agent's drive.

  The three operations have `worker_agent` scope: a Worker calls them inside a
  Turn and also while it drains, when there is no Turn. Bytes never travel in
  the RPC payload. The control plane moves them over the WorkerFiles relay of
  the calling Worker, found by the RPC's connection, and names a path in the
  Agent Home relative to that Agent Home.
  """

  alias Ankole.Files
  alias Ankole.Files.Schemas.AgentFile
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.WorkerFiles
  alias Ankole.WorkerFiles.RelayError

  @list_limit 1000
  # Path length and content length of one bundle entry.
  @bundle_entry_header_bytes 12

  @doc "Lists drive files under a folder prefix."
  def handle_list(agent_uid, %FabricProto.FilesListRequest{} = request, ctx) do
    limit = if request.limit in [0, nil], do: @list_limit, else: request.limit

    with {:ok, %{files: files, next_after: next_after, revision: revision}} <-
           Files.list(agent_uid, request.prefix,
             limit: limit,
             after: presence(request.after),
             snapshot: true
           ) do
      {:ok,
       %FabricProto.FilesListResponse{
         files: Enum.map(files, &drive_file/1),
         next_after: next_after || "",
         revision: revision
       }}
    else
      {:error, reason} -> error(ctx, reason)
    end
  end

  @doc "Writes one drive file into the calling Worker's Agent Home."
  def handle_get(agent_uid, %FabricProto.FilesGetRequest{} = request, ctx) do
    with {:ok, target} <- home_relative_path(request.home_relative_path),
         {:ok, file} <- send_file(agent_uid, request.path, target, worker_target(ctx)) do
      {:ok, %FabricProto.FilesGetResponse{file: drive_file(file)}}
    else
      {:error, reason} -> error(ctx, reason)
    end
  end

  @doc """
  Names files from the calling Worker's Agent Home at drive paths, and removes
  drive paths, in one transaction.

  A content that the Agent's drive already names is not transferred again, and
  a content that several upserts declare is transferred once. Files under the
  same top-level folder of the Agent Home travel in bundles of at most one
  transfer bound, using each upsert's declared size; a file alone in its group
  travels by itself. Files committed under `sent/` get the source `sent`;
  every other Worker commit gets the source `agent`.
  """
  def handle_commit(agent_uid, %FabricProto.FilesCommitRequest{} = request, ctx) do
    with {:ok, upserts} <- resolve_upserts(agent_uid, request.upserts, ctx),
         {:ok, %{files: files, deleted: deleted}} <-
           Files.commit(agent_uid, upserts, request.deletes) do
      {:ok,
       %FabricProto.FilesCommitResponse{files: Enum.map(files, &drive_file/1), deleted: deleted}}
    else
      {:error, reason} -> error(ctx, reason)
    end
  end

  @doc "Encodes one drive file for the wire."
  @spec drive_file(AgentFile.t()) :: FabricProto.DriveFile.t()
  def drive_file(%AgentFile{} = file) do
    %FabricProto.DriveFile{
      path: file.path,
      sha256: Base.encode16(file.sha256, case: :lower),
      size: file.size,
      content_type: file.content_type,
      source: file.source,
      signal_channel_id: file.signal_channel_id || "",
      source_entry_id: file.source_entry_id || "",
      mode: file.mode,
      updated_at: DateTime.to_iso8601(file.updated_at)
    }
  end

  defp send_file(agent_uid, path, target, worker) do
    local_path = Files.temp_path()

    try do
      with {:ok, file} <- Files.read_to_file(agent_uid, path, local_path),
           {:ok, _transfer} <-
             WorkerFiles.put(target, {:file, local_path}, worker: worker) do
        {:ok, file}
      end
    after
      File.rm(local_path)
    end
  end

  defp resolve_upserts(agent_uid, upserts, ctx) do
    with {:ok, planned} <- plan_upserts(agent_uid, upserts),
         {:ok, received} <- receive_missing(planned, ctx) do
      {:ok,
       Enum.map(planned, fn
         {:known, attrs} -> attrs
         {:transfer, attrs, transfer} -> Map.put(attrs, :sha256, received[transfer.key])
       end)}
    end
  end

  defp plan_upserts(agent_uid, upserts) do
    upserts
    |> Enum.reduce_while({:ok, []}, fn upsert, {:ok, planned} ->
      case plan_upsert(agent_uid, upsert) do
        {:ok, plan} -> {:cont, {:ok, [plan | planned]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, planned} -> {:ok, Enum.reverse(planned)}
      error -> error
    end
  end

  defp plan_upsert(agent_uid, %FabricProto.FilesCommitUpsert{} = upsert) do
    attrs = %{
      path: upsert.path,
      source: source_for(upsert.path),
      content_type: presence(upsert.content_type),
      mode: if(upsert.mode == 0, do: nil, else: upsert.mode)
    }

    declared = presence(upsert.sha256)

    if declared && Files.drive_has_content?(agent_uid, declared) do
      {:ok, {:known, Map.put(attrs, :sha256, declared)}}
    else
      with {:ok, source_path} <- home_relative_path(upsert.home_relative_path) do
        {:ok,
         {:transfer, attrs,
          %{
            key: declared || {:path, source_path},
            source: source_path,
            declared: declared,
            size: upsert.size
          }}}
      end
    end
  end

  defp receive_missing(planned, ctx) do
    transfers =
      planned
      |> Enum.flat_map(fn
        {:transfer, _attrs, transfer} -> [transfer]
        {:known, _attrs} -> []
      end)
      |> Enum.uniq_by(& &1.key)

    if transfers == [] do
      {:ok, %{}}
    else
      transfers
      |> transfer_batches()
      |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, received} ->
        case receive_batch(batch, worker_target(ctx)) do
          {:ok, stored} -> {:cont, {:ok, Map.merge(received, stored)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp worker_target(ctx), do: %{worker_id: ctx.worker_id, transport_route: ctx.route}

  defp transfer_batches(transfers) do
    {nested, top_level} = Enum.split_with(transfers, &String.contains?(&1.source, "/"))

    nested
    |> Enum.group_by(&(&1.source |> String.split("/", parts: 2) |> hd()))
    |> Enum.flat_map(fn {folder, group} -> bundle_batches(folder, group) end)
    |> Kernel.++(Enum.map(top_level, &{:file, &1}))
  end

  # Packs one folder's files in order into bundles within the transfer bound.
  # A file that does not fit with another becomes a batch of its own.
  defp bundle_batches(folder, transfers) do
    max_bytes = WorkerFiles.max_transfer_bytes()

    transfers
    |> Enum.chunk_while(
      {[], 0},
      fn transfer, {batch, total} ->
        bytes = bundle_entry_bytes(folder, transfer)

        cond do
          batch == [] -> {:cont, {[transfer], bytes}}
          total + bytes <= max_bytes -> {:cont, {[transfer | batch], total + bytes}}
          true -> {:cont, Enum.reverse(batch), {[transfer], bytes}}
        end
      end,
      fn
        {[], _total} -> {:cont, {[], 0}}
        {batch, _total} -> {:cont, Enum.reverse(batch), {[], 0}}
      end
    )
    |> Enum.map(fn
      [transfer] -> {:file, transfer}
      batch -> {:bundle, folder, batch}
    end)
  end

  defp bundle_entry_bytes(folder, transfer),
    do: @bundle_entry_header_bytes + byte_size(bundle_path(folder, transfer)) + transfer.size

  defp bundle_path(folder, transfer),
    do: String.replace_prefix(transfer.source, folder <> "/", "")

  defp receive_batch({:file, transfer}, worker) do
    with {:ok, stored} <- receive_file(transfer.source, worker) do
      store_verified([{transfer, stored}])
    end
  end

  defp receive_batch({:bundle, folder, transfers}, worker) do
    target_dir = Files.temp_path()
    File.mkdir_p!(target_dir)

    try do
      with {:ok, local_paths} <-
             WorkerFiles.receive_bundle(
               folder,
               Enum.map(transfers, &bundle_path(folder, &1)),
               target_dir,
               worker: worker
             ) do
        transfers
        |> Enum.zip(local_paths)
        |> Enum.reduce_while({:ok, []}, fn {transfer, local_path}, {:ok, stored} ->
          case Files.store({:file, local_path}) do
            {:ok, file} -> {:cont, {:ok, [{transfer, file} | stored]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, stored} -> store_verified(stored)
          error -> error
        end
      end
    after
      File.rm_rf(target_dir)
    end
  end

  defp store_verified(stored) do
    Enum.reduce_while(stored, {:ok, %{}}, fn {transfer, file}, {:ok, received} ->
      case verify_digest(transfer.declared, file.sha256) do
        :ok -> {:cont, {:ok, Map.put(received, transfer.key, file.sha256)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp receive_file(source_path, worker) do
    local_path = Files.temp_path()

    try do
      with {:ok, %{"body" => body}} <-
             WorkerFiles.stream(source_path, worker: worker) do
        Enum.into(body, File.stream!(local_path))
        Files.store({:file, local_path})
      end
    rescue
      error in RelayError -> {:error, error.reason}
    after
      File.rm(local_path)
    end
  end

  defp verify_digest(nil, _stored), do: :ok
  defp verify_digest(declared, stored) when declared == stored, do: :ok

  defp verify_digest(declared, stored),
    do: {:error, {:sha256_mismatch, %{"declared" => declared, "received" => stored}}}

  defp source_for("sent/" <> _rest), do: "sent"
  defp source_for(_path), do: "agent"

  defp home_relative_path(path) do
    case Files.normalize_path(path) do
      {:ok, path} -> {:ok, path}
      {:error, {:invalid_path, _path}} -> {:error, {:invalid_home_relative_path, path}}
    end
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_value), do: nil

  # A Worker or object store error already names its code, for example the
  # Worker's `file_not_found`; the caller's recovery depends on it.
  defp error(ctx, %{"code" => code} = reason) when is_binary(code) do
    {:error,
     %{
       "request_id" => ctx.request_id,
       "code" => code,
       "message" => Map.get(reason, "message", code),
       "details_json" => Map.get(reason, "details_json", %{})
     }}
  end

  defp error(ctx, reason) do
    {:error,
     RPCWire.error_payload(ctx.request_id, reason,
       fallback_code: "files_rpc_failed",
       message_style: :tuple_reason
     )}
  end
end
