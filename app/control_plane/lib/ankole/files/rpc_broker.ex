defmodule Ankole.Files.RPCBroker do
  @moduledoc "Drive RPCs resolve node identities and stream bytes through the calling Worker's relay."
  alias Ankole.{Files, Principals, WorkerFiles}
  alias Ankole.AuthZ.Actor
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.AgentWorkers.RPCWire

  @list_limit 1000

  def handle_list(agent_uid, %FabricProto.FilesListRequest{} = request, ctx) do
    limit = if request.limit in [0, nil], do: @list_limit, else: request.limit

    with {:ok, actor} <- actor(agent_uid, request.automation_attempt, ctx),
         {:ok, page} <-
           Files.list(actor, request.prefix,
             limit: limit,
             after: presence(request.after),
             snapshot: true
           ) do
      {:ok,
       %FabricProto.FilesListResponse{
         files: Enum.map(page.files, &drive_file/1),
         next_after: page.next_after || "",
         revision: page.revision
       }}
    else
      {:error, reason} -> error(ctx, reason)
    end
  end

  def handle_get(agent_uid, %FabricProto.FilesGetRequest{} = request, ctx) do
    with {:ok, actor} <- actor(agent_uid, request.automation_attempt, ctx),
         {:ok, target} <- home_relative_path(request.home_relative_path),
         {:ok, file} <- requested_file(actor, request),
         {:ok, opts} <- transfer_opts(ctx),
         :ok <- send_file(file.object_id, target, opts) do
      {:ok, %FabricProto.FilesGetResponse{file: drive_file(file)}}
    else
      {:error, reason} -> error(ctx, reason)
    end
  end

  defp requested_file(actor, %{node_id: id}) when is_binary(id) and id != "" do
    with {:ok, node} <- Files.authorize_node(actor, id, "node_view"),
         true <- node.kind == :file,
         do: Files.Paths.project(node, node.name),
         else: (
           false -> {:error, :not_a_file}
           error -> error
         )
  end

  defp requested_file(actor, request), do: Files.fetch(actor, request.path)

  def handle_commit(agent_uid, %FabricProto.FilesCommitRequest{} = request, ctx) do
    with {:ok, actor} <- actor(agent_uid, request.automation_attempt, ctx),
         {:ok, opts} <- transfer_opts(ctx),
         {:ok, upserts} <- receive_upserts(request.upserts, opts),
         {:ok, result} <- Files.commit(actor, upserts, request.deletes) do
      {:ok,
       %FabricProto.FilesCommitResponse{
         files: Enum.map(result.files, &drive_file/1),
         deleted: result.deleted
       }}
    else
      {:error, reason} -> error(ctx, reason)
    end
  end

  defp actor(_uid, attempt, ctx) when not is_nil(attempt),
    do: Ankole.AutomationJobs.authorize_attempt_actor(attempt, ctx)

  defp actor(uid, nil, ctx) do
    authority = if ref = ctx[:turn_ref], do: {ref, uid}

    with {:ok, principal} <- Principals.get_principal(uid),
         :ok <- Ankole.AuthZ.validate_turn_authority(authority),
         do:
           {:ok,
            Actor.new(principal, turn_authority: authority, authn: %{"surface" => "agent_rpc"})}
  end

  defp receive_upserts(upserts, opts) do
    Enum.reduce_while(upserts, {:ok, []}, fn upsert, {:ok, received} ->
      case receive_upsert(upsert, opts) do
        {:ok, stored} -> {:cont, {:ok, [stored | received]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, received} -> {:ok, Enum.reverse(received)}
      error -> error
    end
  end

  defp receive_upsert(upsert, opts) do
    with {:ok, path} <- Files.normalize_path(upsert.path),
         {:ok, source} <- home_relative_path(upsert.home_relative_path),
         {:ok, maximum} <- Files.upload_limit(),
         :ok <- declared_size(upsert.size, maximum),
         {:ok, %{"body" => body}} <-
           WorkerFiles.stream(source, Keyword.put(opts, :max_bytes, maximum)),
         {:ok, stored} <- Files.store(body),
         :ok <- verify_digest(presence(upsert.sha256), stored.sha256),
         true <- upsert.size == stored.size do
      {:ok,
       Map.merge(stored, %{
         path: path,
         source: "agent",
         content_type: presence(upsert.content_type),
         mode: if(upsert.mode == 0, do: nil, else: upsert.mode)
       })}
    else
      false -> {:error, :file_size_mismatch}
      error -> error
    end
  rescue
    exception in WorkerFiles.RelayError -> {:error, exception.reason}
  end

  defp declared_size(size, maximum) when size <= maximum, do: :ok
  defp declared_size(size, maximum), do: {:error, {:file_too_large, size, maximum}}

  defp send_file(object_id, target, opts) do
    local_path = Files.temp_path()

    try do
      with :ok <- copy_object(object_id, local_path),
           {:ok, _} <-
             WorkerFiles.put(
               target,
               {:file, local_path},
               Keyword.put(opts, :max_bytes, max(File.stat!(local_path).size, 1))
             ),
           do: :ok
    after
      File.rm(local_path)
    end
  end

  defp copy_object(nil, path), do: File.write(path, "")
  defp copy_object(id, path), do: Files.read_object_to_file(id, path)

  defp drive_file(file) do
    %FabricProto.DriveFile{
      node_id: file.id,
      object_id: file.object_id || "",
      path: file.path,
      sha256: if(file.sha256, do: Base.encode16(file.sha256, case: :lower), else: ""),
      size: file.size,
      content_type: file.content_type,
      source: to_string(file.source),
      conversation_id: Map.get(file, :conversation_id) || "",
      message_id: Map.get(file, :message_id) || "",
      mode: file.mode,
      updated_at: DateTime.to_iso8601(file.updated_at)
    }
  end

  defp transfer_opts(ctx) do
    deadline = Map.get(ctx, :deadline_unix_ms, 0)
    remaining = if deadline > 0, do: deadline - System.system_time(:millisecond), else: 120_000

    if remaining > 0,
      do:
        {:ok,
         [worker: %{worker_id: ctx.worker_id, transport_route: ctx.route}, timeout_ms: remaining]},
      else: {:error, :rpc_deadline_exceeded}
  end

  defp verify_digest(nil, _stored), do: :ok
  defp verify_digest(digest, digest), do: :ok

  defp verify_digest(declared, stored),
    do: {:error, {:sha256_mismatch, %{"declared" => declared, "received" => stored}}}

  defp home_relative_path(path) do
    case Files.normalize_path(path) do
      {:ok, path} -> {:ok, path}
      {:error, _} -> {:error, {:invalid_home_relative_path, path}}
    end
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  defp error(ctx, %{"code" => code} = reason) when is_binary(code) do
    {:error,
     %{
       "request_id" => ctx.request_id,
       "code" => code,
       "message" => Map.get(reason, "message", code),
       "details_json" => Map.get(reason, "details_json", %{})
     }}
  end

  defp error(ctx, reason),
    do:
      {:error,
       RPCWire.error_payload(ctx.request_id, reason,
         fallback_code: "files_rpc_failed",
         message_style: :tuple_reason
       )}
end
