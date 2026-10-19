defmodule Ankole.Pod.RPCBroker do
  @moduledoc "Agent access to the same Pod domain contracts that serve the browser."

  alias Ankole.Pod.{Database, Documents, Files, Pages}
  import Ankole.Pod.Serialization, only: [json_value: 1]
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.WorkerFiles

  @read_operations ~w(pages.list pages.read pages.sharing files.manifest database.tables database.schema database.query database.aggregate sync.list)
  @write_operations ~w(pages.create pages.update pages.move pages.delete pages.restore pages.write files.upload applets.publish applets.call database.create_table database.create_field database.update_field database.delete_field database.create_view database.update_view database.delete_view database.write database.copy sync.bind sync.status)

  @doc "Reads a sync batch from the authenticated Worker's file relay."
  def handle_sync(uid, %FabricProto.PodSyncRequest{} = request, ctx) do
    with {run_id, ""} when run_id > 0 <- Integer.parse(request.automation_job_run_id),
         {:ok, max_bytes} <- Ankole.Pod.Sync.source_batch_bytes(uid, request.binding_id),
         {:ok, rows} when is_list(rows) <-
           read_json_file(request.records_home_relative_path, ctx, max_bytes),
         {:ok, cursor} <- decode_cursor(request.cursor_json),
         {:ok, result} <-
           Ankole.Pod.Sync.apply_attempt(
             uid,
             request.binding_id,
             run_id,
             request.attempt_id,
             rows,
             cursor
           ) do
      {:ok, %{"result" => Map.take(result, [:data_version, :changed_ids, :deleted_ids])}}
    else
      {:error, reason} -> error(ctx, reason)
      _ -> error(ctx, :invalid_sync_request)
    end
  end

  defp read_json_file(path, ctx, max_bytes) do
    receive_document(path, ctx, &Torque.decode/1, max_bytes: max_bytes)
  end

  defp decode_cursor(<<>>), do: {:ok, :unchanged}
  defp decode_cursor(json), do: Torque.decode(json)

  def handle_read(_turn, %FabricProto.PodRequest{} = request, ctx),
    do: handle(request, ctx, @read_operations)

  def handle_write(turn, %FabricProto.PodRequest{} = request, ctx) do
    ctx = Map.put(ctx, :write_authority, {turn, ctx.worker_id})

    ctx =
      if request.operation == "pages.create",
        do: Map.put(ctx, :source_message_id, Ankole.Conversations.Route.source_message_id(turn)),
        else: ctx

    handle(request, ctx, @write_operations)
  end

  defp handle(request, ctx, allowed) do
    with true <- request.operation in allowed,
         {:ok, params} when is_map(params) <- Torque.decode(request.params_json),
         {:ok, result} <- dispatch(request.operation, ctx.worker_id, params, ctx) do
      {:ok, %{"result" => json_value(result)}}
    else
      false -> error(ctx, :invalid_pod_operation)
      {:error, reason} -> error(ctx, reason)
      _ -> error(ctx, :invalid_pod_payload)
    end
  end

  defp dispatch("pages.list", uid, params, _ctx), do: Pages.list(uid, params)
  defp dispatch("pages.read", uid, params, ctx), do: read_document(uid, params, ctx)
  defp dispatch("pages.sharing", uid, params, _ctx), do: Pages.sharing(uid, params["id"])

  defp dispatch("pages.create", uid, params, ctx) do
    params =
      if ctx[:source_message_id],
        do: Map.put_new(params, "saved_from_message_id", ctx.source_message_id),
        else: params

    Pages.create(uid, params, ctx.write_authority)
  end

  defp dispatch("pages.update", uid, params, ctx),
    do: Pages.update(uid, params["id"], params, ctx.write_authority)

  defp dispatch("pages.move", uid, params, ctx),
    do: Pages.move(uid, params["id"], params, ctx.write_authority)

  defp dispatch("pages.delete", uid, params, ctx),
    do: Pages.delete(uid, params["id"], ctx.write_authority)

  defp dispatch("pages.restore", uid, params, ctx),
    do: Pages.restore(uid, params["id"], ctx.write_authority)

  defp dispatch("pages.write", uid, params, ctx) do
    with {:ok, _page} <- Pages.authorize(uid, params["id"], "page_edit") do
      receive_document(params["xml_home_relative_path"], ctx, fn xml ->
        with {:ok, result} <-
               Documents.write(
                 uid,
                 params["id"],
                 params["base_revision"],
                 xml,
                 ctx.write_authority
               ),
             do: {:ok, Map.drop(result, [:content])}
      end)
    end
  end

  defp dispatch("files.manifest", uid, params, _ctx), do: Files.manifest(uid, params["id"])
  defp dispatch("files.upload", uid, params, ctx), do: upload(uid, params, ctx)

  defp dispatch("applets.publish", uid, params, ctx),
    do:
      Files.publish(
        uid,
        params["id"],
        params["base_revision"],
        params["files"],
        ctx.write_authority
      )

  defp dispatch("applets.call", uid, params, ctx) do
    request = Map.put_new(params, "query", %{})
    Ankole.Pod.Applets.call(uid, params["id"], request, authority: ctx.write_authority)
  end

  defp dispatch("database.tables", uid, params, _ctx), do: Database.list_tables(uid, params["id"])
  defp dispatch("database.schema", uid, params, _ctx), do: Database.get_table(uid, params["id"])

  defp dispatch("database.query", uid, params, _ctx),
    do: Database.query(uid, params["id"], params)

  defp dispatch("database.aggregate", uid, params, _ctx),
    do: Database.aggregate(uid, params["id"], params)

  defp dispatch("database.create_table", uid, params, ctx),
    do: Database.create_table(uid, params["id"], params, ctx.write_authority)

  defp dispatch("database.create_field", uid, params, ctx),
    do: Database.create_field(uid, params["id"], params, ctx.write_authority)

  defp dispatch("database.update_field", uid, params, ctx),
    do: Database.update_field(uid, params["id"], params, ctx.write_authority)

  defp dispatch("database.delete_field", uid, params, ctx),
    do: Database.delete_field(uid, params["id"], params["version"], ctx.write_authority)

  defp dispatch("database.create_view", uid, params, ctx),
    do: Database.create_view(uid, params["id"], params, ctx.write_authority)

  defp dispatch("database.update_view", uid, params, ctx),
    do: Database.update_view(uid, params["id"], params, ctx.write_authority)

  defp dispatch("database.delete_view", uid, params, ctx),
    do: Database.delete_view(uid, params["id"], params["version"], ctx.write_authority)

  defp dispatch("database.write", uid, params, ctx),
    do: Database.write_records(uid, params["id"], params, ctx.write_authority)

  defp dispatch("database.copy", uid, params, ctx),
    do: Database.copy_table(uid, params["id"], params, ctx.write_authority)

  defp dispatch("sync.list", uid, params, _ctx), do: Ankole.Pod.Sync.list(uid, params["id"])

  defp dispatch("sync.bind", uid, params, ctx),
    do: Ankole.Pod.Sync.create(uid, params["id"], params, ctx.write_authority)

  defp dispatch("sync.status", uid, params, ctx),
    do: Ankole.Pod.Sync.set_status(uid, params["id"], params["status"], ctx.write_authority)

  defp read_document(uid, params, ctx) do
    with {:ok, detail} <- Pages.get(uid, params["id"]) do
      if detail.content do
        local = Ankole.Files.temp_path()

        try do
          with {:ok, target} <- Ankole.Files.normalize_path(params["xml_home_relative_path"]),
               :ok <- File.write(local, detail.content.content),
               {:ok, _} <-
                 WorkerFiles.put(target, {:file, local},
                   worker: %{worker_id: ctx.worker_id, transport_route: ctx.route}
                 ) do
            {:ok, %{detail | content: %{xml_file: true}}}
          end
        after
          File.rm(local)
        end
      else
        {:ok, detail}
      end
    end
  end

  defp receive_document(source, ctx, fun, opts \\ []) do
    local = Ankole.Files.temp_path()

    try do
      with {:ok, source} <- Ankole.Files.normalize_path(source),
           {:ok, %{"body" => body}} <-
             WorkerFiles.stream(
               source,
               Keyword.put(opts, :worker, %{worker_id: ctx.worker_id, transport_route: ctx.route})
             ) do
        Enum.into(body, File.stream!(local))
        with {:ok, xml} <- File.read(local), do: fun.(xml)
      end
    rescue
      error in Ankole.WorkerFiles.RelayError -> {:error, error.reason}
    after
      File.rm(local)
    end
  end

  defp upload(uid, params, ctx) do
    source = params["home_relative_path"]
    local = Ankole.Files.temp_path()

    try do
      with {:ok, _page} <- Pages.authorize(uid, params["id"], "page_edit"),
           {:ok, source} <- Ankole.Files.normalize_path(source),
           {:ok, %{"body" => body}} <-
             WorkerFiles.stream(
               source,
               worker: %{worker_id: ctx.worker_id, transport_route: ctx.route}
             ) do
        Enum.into(body, File.stream!(local))

        Files.upload(
          uid,
          params["id"],
          params["role"] || "file",
          params["base_revision"],
          params["name"] || Path.basename(source),
          {:file, local},
          params["content_type"],
          ctx.write_authority
        )
      end
    after
      File.rm(local)
    end
  end

  defp error(ctx, reason) do
    error = Ankole.Pod.Serialization.error(reason)

    {:error,
     %{
       "request_id" => ctx.request_id,
       "code" => error.code,
       "message" => error.message,
       "details_json" => Ankole.Pod.Serialization.json_value(error.details || %{})
     }}
  end
end
