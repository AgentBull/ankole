defmodule Ankole.Pod.RPCBroker do
  @moduledoc "Agent access to the same Pod domain contracts that serve the browser."

  alias Ankole.Pod.{Bases, Documents, Files, Pages}
  import Ankole.Pod.Serialization, only: [json_value: 1]
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.WorkerFiles

  @read_operations ~w(pages.list pages.children pages.search pages.read pages.sharing files.manifest base.tables base.schema base.query base.aggregate)
  @write_operations ~w(pages.create pages.update pages.move pages.delete pages.restore pages.set_sharing pages.write pages.append files.upload applets.publish applets.call base.create_table base.delete_table base.create_field base.update_field base.delete_field base.create_view base.update_view base.delete_view base.write base.copy)

  def handle_read(turn, %FabricProto.PodRequest{} = request, ctx) do
    with {:ok, actor} <- actor_for_request(turn, request.automation_attempt, ctx) do
      handle(request, Map.put(ctx, :actor, actor), @read_operations)
    else
      {:error, reason} -> error(ctx, reason)
    end
  end

  def handle_write(turn, %FabricProto.PodRequest{} = request, ctx) do
    with {:ok, actor} <- actor_for_request(turn, request.automation_attempt, ctx) do
      ctx = Map.merge(ctx, %{actor: actor, write_authority: actor.turn_authority})

      ctx =
        if request.operation == "pages.create" and turn,
          do:
            Map.put(ctx, :source_message_id, Ankole.Conversations.Route.source_message_id(turn)),
          else: ctx

      handle(request, ctx, @write_operations)
    else
      {:error, reason} -> error(ctx, reason)
    end
  end

  @doc false
  def actor_for_request(nil, %FabricProto.AutomationAttemptRef{} = attempt, ctx),
    do: Ankole.AutomationJobs.authorize_attempt_actor(attempt, ctx)

  def actor_for_request(ref, nil, ctx)
      when is_struct(ref, Ankole.Sessions.RunRef) or is_struct(ref, Ankole.Sessions.JobTurnRef) do
    with {:ok, signal} <- Ankole.Signals.get_signal(ref.signal_id),
         true <- signal.agent_uid == ctx.worker_id and signal.session_id == ref.session_id,
         {:ok, principal} <- Ankole.Principals.get_principal(ctx.worker_id),
         {:ok, human} <- interactive(signal) do
      request = Ankole.Conversations.request_context(signal)
      context = Map.merge(Map.take(request, ["ip"]), %{"surface" => "agent_rpc"})
      interactive_authn = Map.merge(request["authn"] || %{}, context)

      {:ok,
       Ankole.AuthZ.Actor.new(principal,
         interactive_principal: human,
         turn_authority: {ref, ctx.worker_id},
         authn: context,
         interactive_authn: interactive_authn
       )}
    else
      _ -> {:error, :work_authorization_review_required}
    end
  end

  def actor_for_request(_, _, _), do: {:error, :work_authorization_review_required}

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

  defp dispatch("pages.children", actor, params, _ctx),
    do: Pages.list_children(actor, params["parent_id"], params)

  defp dispatch("pages.search", actor, params, _ctx),
    do: Pages.search(actor, params["query"], params)

  defp dispatch("pages.read", actor, params, ctx), do: read_document(actor, params, ctx)
  defp dispatch("pages.sharing", actor, params, _ctx), do: Pages.sharing(actor, params["id"])

  defp dispatch("pages.set_sharing", actor, params, ctx),
    do: Pages.set_sharing(actor, params["id"], params, ctx.write_authority)

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

  defp dispatch(operation, actor, params, ctx)
       when operation in ["pages.write", "pages.append"] do
    with {:ok, _page} <- Pages.authorize(actor, params["id"], "page_edit") do
      receive_document(params["xml_home_relative_path"], ctx, fn xml ->
        with {:ok, result} <-
               apply(Documents, if(operation == "pages.append", do: :append, else: :write), [
                 actor,
                 params["id"],
                 params["base_revision"],
                 xml,
                 ctx.write_authority
               ]),
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

  defp dispatch("base.tables", actor, params, _ctx),
    do: Bases.list_tables(actor, params["id"])

  defp dispatch("base.schema", actor, params, _ctx),
    do: Bases.get_table(actor, params["id"])

  defp dispatch("base.query", actor, params, _ctx),
    do: Bases.query(actor, params["id"], params)

  defp dispatch("base.aggregate", actor, params, _ctx),
    do: Bases.aggregate(actor, params["id"], params)

  defp dispatch("base.create_table", actor, params, ctx),
    do: Bases.create_table(actor, params["id"], params, ctx.write_authority)

  defp dispatch("base.delete_table", actor, params, ctx),
    do: Bases.delete_table(actor, params["id"], ctx.write_authority)

  defp dispatch("base.create_field", actor, params, ctx),
    do: Bases.create_field(actor, params["id"], params, ctx.write_authority)

  defp dispatch("base.update_field", actor, params, ctx),
    do: Bases.update_field(actor, params["id"], params, ctx.write_authority)

  defp dispatch("base.delete_field", actor, params, ctx),
    do: Bases.delete_field(actor, params["id"], params["version"], ctx.write_authority)

  defp dispatch("base.create_view", actor, params, ctx),
    do: Bases.create_view(actor, params["id"], params, ctx.write_authority)

  defp dispatch("base.update_view", actor, params, ctx),
    do: Bases.update_view(actor, params["id"], params, ctx.write_authority)

  defp dispatch("base.delete_view", actor, params, ctx),
    do: Bases.delete_view(actor, params["id"], params["version"], ctx.write_authority)

  defp dispatch("base.write", actor, params, ctx),
    do: Bases.write_records(actor, params["id"], params, ctx.write_authority)

  defp dispatch("base.copy", actor, params, ctx),
    do: Bases.copy_table(actor, params["id"], params, ctx.write_authority)

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

    with {:ok, _page} <-
           Pages.authorize(
             actor,
             params["id"],
             Files.required_upload_action(params["role"] || "file")
           ),
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
