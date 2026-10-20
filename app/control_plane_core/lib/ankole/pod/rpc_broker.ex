defmodule Ankole.Pod.RPCBroker do
  @moduledoc "Agent access to the same Pod domain contracts that serve the browser."

  alias Ankole.Pod.{Database, Documents, Files, Pages}
  import Ankole.Pod.Serialization, only: [json_value: 1]
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.WorkerFiles

  @read_operations ~w(pages.list pages.read pages.sharing files.manifest database.tables database.schema database.query database.aggregate)
  @write_operations ~w(pages.create pages.update pages.move pages.delete pages.restore pages.write files.upload applets.publish applets.call database.create_table database.create_field database.update_field database.delete_field database.create_view database.update_view database.delete_view database.write database.copy)

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

  defp receive_document(source, ctx, fun) do
    with {:ok, source} <- Ankole.Files.normalize_path(source) do
      WorkerFiles.with_received_file(
        source,
        [worker: %{worker_id: ctx.worker_id, transport_route: ctx.route}],
        fn local ->
          with {:ok, xml} <- File.read(local), do: fun.(xml)
        end
      )
    end
  end

  defp upload(uid, params, ctx) do
    source = params["home_relative_path"]

    with {:ok, _page} <- Pages.authorize(uid, params["id"], "page_edit"),
         {:ok, source} <- Ankole.Files.normalize_path(source) do
      WorkerFiles.with_received_file(
        source,
        [worker: %{worker_id: ctx.worker_id, transport_route: ctx.route}],
        fn local ->
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
      )
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
