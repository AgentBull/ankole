defmodule Ankole.Pod.RPCBroker do
  @moduledoc "Agent access to the same Pod domain contracts that serve the browser."

  alias Ankole.Pod.{Database, Documents, Files, Pages}
  import Ankole.Pod.Serialization, only: [json_value: 1]
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.WorkerFiles

  @read_operations ~w(pages.list pages.read pages.sharing files.manifest database.tables database.schema database.query database.aggregate)
  @write_operations ~w(pages.create pages.update pages.move pages.delete pages.restore pages.write files.upload applets.publish applets.call database.create_table database.create_field database.update_field database.delete_field database.create_view database.update_view database.delete_view database.write database.copy)

  def handle_read(turn, %FabricProto.PodRequest{} = request, ctx),
    do:
      with_request(turn, ctx, fn actor ->
        handle(request, Map.put(ctx, :actor, actor), @read_operations)
      end)

  def handle_write(turn, %FabricProto.PodRequest{} = request, ctx) do
    ctx = Map.put(ctx, :write_authority, {turn, ctx.worker_id})

    ctx =
      if request.operation == "pages.create",
        do: Map.put(ctx, :source_message_id, Ankole.Conversations.Route.source_message_id(turn)),
        else: ctx

    with_request(turn, ctx, fn actor ->
      handle(request, Map.put(ctx, :actor, actor), @write_operations)
    end)
  end

  defp with_request(ref, ctx, fun)
       when is_struct(ref, Ankole.Sessions.RunRef) or is_struct(ref, Ankole.Sessions.JobTurnRef) do
    with {:ok, signal} <- Ankole.Signals.get_signal(ref.signal_id),
         true <- signal.agent_uid == ctx.worker_id and signal.session_id == ref.session_id,
         {:ok, principal} <- Ankole.Principals.get_principal(ctx.worker_id),
         {:ok, human} <- interactive(signal) do
      request = Ankole.Conversations.request_context(signal)
      context = Map.merge(Map.take(request, ["ip"]), %{"surface" => "agent_rpc"})
      interactive_authn = Map.merge(request["authn"] || %{}, context)

      actor =
        Ankole.AuthZ.Actor.new(principal,
          interactive_principal: human,
          turn_authority: {ref, ctx.worker_id},
          authn: context,
          interactive_authn: interactive_authn
        )

      fun.(actor)
    else
      _ -> error(ctx, :work_authorization_review_required)
    end
  end

  defp interactive(%{authorization_kind: "human", human_uid: uid}) when is_binary(uid),
    do: Ankole.Principals.get_principal(uid)

  defp interactive(%{authorization_kind: "service"}), do: {:ok, nil}
  defp interactive(_), do: {:error, :work_authorization_review_required}

  defp handle(request, ctx, allowed) do
    with true <- request.operation in allowed,
         {:ok, params} when is_map(params) <- Torque.decode(request.params_json),
         {:ok, result} <- dispatch(request.operation, ctx.actor, params, ctx) do
      {:ok, %{"result" => json_value(result)}}
    else
      false -> error(ctx, :invalid_pod_operation)
      {:error, reason} -> error(ctx, reason)
      _ -> error(ctx, :invalid_pod_payload)
    end
  end

  defp dispatch("pages.list", actor, params, _ctx), do: Pages.list(actor, params)
  defp dispatch("pages.read", actor, params, ctx), do: read_document(actor, params, ctx)
  defp dispatch("pages.sharing", actor, params, _ctx), do: Pages.sharing(actor, params["id"])

  defp dispatch("pages.create", actor, params, ctx) do
    params =
      if ctx[:source_message_id],
        do: Map.put_new(params, "saved_from_message_id", ctx.source_message_id),
        else: params

    Pages.create(actor, params, ctx.write_authority)
  end

  defp dispatch("pages.update", actor, params, ctx),
    do: Pages.update(actor, params["id"], params, ctx.write_authority)

  defp dispatch("pages.move", actor, params, ctx) do
    with {:ok, %{page: page}} <- Pages.move(actor, params["id"], params, ctx.write_authority),
         do: {:ok, page}
  end

  defp dispatch("pages.delete", actor, params, ctx),
    do: Pages.delete(actor, params["id"], ctx.write_authority)

  defp dispatch("pages.restore", actor, params, ctx),
    do: Pages.restore(actor, params["id"], ctx.write_authority)

  defp dispatch("pages.write", actor, params, ctx) do
    with {:ok, _page} <- Pages.authorize(actor, params["id"], "page_edit") do
      receive_document(params["xml_home_relative_path"], ctx, fn xml ->
        with {:ok, result} <-
               Documents.write(
                 actor,
                 params["id"],
                 params["base_revision"],
                 xml,
                 ctx.write_authority
               ),
             do: {:ok, Map.drop(result, [:content])}
      end)
    end
  end

  defp dispatch("files.manifest", actor, params, _ctx), do: Files.manifest(actor, params["id"])
  defp dispatch("files.upload", actor, params, ctx), do: upload(actor, params, ctx)

  defp dispatch("applets.publish", actor, params, ctx),
    do:
      Files.publish(
        actor,
        params["id"],
        params["base_revision"],
        params["files"],
        ctx.write_authority
      )

  defp dispatch("applets.call", actor, params, ctx) do
    request = Map.put_new(params, "query", %{})
    Ankole.Pod.Applets.call(actor, params["id"], request, authority: ctx.write_authority)
  end

  defp dispatch("database.tables", actor, params, _ctx),
    do: Database.list_tables(actor, params["id"])

  defp dispatch("database.schema", actor, params, _ctx),
    do: Database.get_table(actor, params["id"])

  defp dispatch("database.query", actor, params, _ctx),
    do: Database.query(actor, params["id"], params)

  defp dispatch("database.aggregate", actor, params, _ctx),
    do: Database.aggregate(actor, params["id"], params)

  defp dispatch("database.create_table", actor, params, ctx),
    do: Database.create_table(actor, params["id"], params, ctx.write_authority)

  defp dispatch("database.create_field", actor, params, ctx),
    do: Database.create_field(actor, params["id"], params, ctx.write_authority)

  defp dispatch("database.update_field", actor, params, ctx),
    do: Database.update_field(actor, params["id"], params, ctx.write_authority)

  defp dispatch("database.delete_field", actor, params, ctx),
    do: Database.delete_field(actor, params["id"], params["version"], ctx.write_authority)

  defp dispatch("database.create_view", actor, params, ctx),
    do: Database.create_view(actor, params["id"], params, ctx.write_authority)

  defp dispatch("database.update_view", actor, params, ctx),
    do: Database.update_view(actor, params["id"], params, ctx.write_authority)

  defp dispatch("database.delete_view", actor, params, ctx),
    do: Database.delete_view(actor, params["id"], params["version"], ctx.write_authority)

  defp dispatch("database.write", actor, params, ctx),
    do: Database.write_records(actor, params["id"], params, ctx.write_authority)

  defp dispatch("database.copy", actor, params, ctx),
    do: Database.copy_table(actor, params["id"], params, ctx.write_authority)

  defp read_document(actor, params, ctx) do
    with {:ok, detail} <- Pages.get(actor, params["id"]) do
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

  defp upload(actor, params, ctx) do
    source = params["home_relative_path"]

    with {:ok, _page} <- Pages.authorize(actor, params["id"], "page_edit"),
         {:ok, source} <- Ankole.Files.normalize_path(source) do
      WorkerFiles.with_received_file(
        source,
        [worker: %{worker_id: ctx.worker_id, transport_route: ctx.route}],
        fn local ->
          Files.upload(
            actor,
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
