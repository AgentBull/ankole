defmodule Ankole.Pod.RPCBroker do
  @moduledoc "Agent access to the same Pod domain contracts that serve the browser."

  alias Ankole.Pod.{Bases, Comments, Documents, Files, Pages}
  import Ankole.Pod.Serialization, only: [json_value: 1, navigation_page: 1]
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.WorkerFiles

  @read_operations ~w(skills.bundle pages.list pages.children pages.search pages.read pages.sharing comments.list comments.show files.manifest files.download chat.attachment.get base.tables base.schema base.query base.aggregate)
  @write_operations ~w(chat.send_to_agent pages.create pages.update pages.move pages.delete pages.restore pages.set_sharing pages.update_sharing pages.write pages.append comments.reply comments.resolve files.upload applets.publish applets.call base.create_table base.delete_table base.create_field base.update_field base.delete_field base.create_view base.update_view base.delete_view base.write base.copy)

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
         {:ok, _human} <- instruction_subject(signal) do
      request = Ankole.Conversations.request_context(signal)
      context = Map.merge(Map.take(request, ["ip"]), %{"surface" => "agent_rpc"})

      {:ok,
       Ankole.AuthZ.Actor.new(principal,
         turn_authority: {ref, ctx.worker_id},
         authn: context
       )}
    else
      _ -> {:error, :work_authorization_review_required}
    end
  end

  def actor_for_request(_, _, _), do: {:error, :work_authorization_review_required}

  defp instruction_subject(%{authorization_kind: "human", human_uid: uid}) when is_binary(uid),
    do: Ankole.Principals.get_principal(uid)

  defp instruction_subject(%{authorization_kind: "service"}), do: {:ok, nil}
  defp instruction_subject(_), do: {:error, :work_authorization_review_required}

  defp handle(request, ctx, allowed) do
    with true <- request.operation in allowed,
         {:ok, params} when is_map(params) <- Torque.decode(request.params_json),
         :ok <- disclosure_target(request.operation, ctx.actor, params),
         {:ok, result} <- dispatch(request.operation, ctx.actor, params, ctx) do
      {:ok, %{"result" => json_value(result)}}
    else
      false -> error(ctx, :invalid_pod_operation)
      {:error, reason} -> error(ctx, reason)
      _ -> error(ctx, :invalid_pod_payload)
    end
  end

  defp dispatch("chat.send_to_agent", %{turn_authority: {ref, _}}, params, _ctx),
    do:
      Ankole.Conversations.send_peer_from_job(
        ref,
        Map.delete(params, "call_id"),
        params["call_id"]
      )

  defp dispatch("skills.bundle", actor, params, _ctx) do
    with {:ok, context} <- page_context(actor),
         {:ok, files} <-
           Ankole.AIAgent.Library.skill_bundle(Ankole.AuthZ.Actor.uid(actor), params["name"],
             request_context: context
           ),
         do: {:ok, %{files: files}}
  end

  defp dispatch("pages.list", actor, params, _ctx) do
    with {:ok, opts} <- page_options(actor, params), do: Pages.list(actor, opts)
  end

  defp dispatch("pages.children", actor, params, _ctx) do
    with {:ok, opts} <- page_options(actor, params),
         {:ok, directory} <- Pages.list_children(actor, params["parent_id"], opts),
         do: {:ok, %{directory | pages: Enum.map(directory.pages, &navigation_page/1)}}
  end

  defp dispatch("pages.search", actor, params, _ctx) do
    with {:ok, opts} <- page_options(actor, params),
         do: Pages.search(actor, params["query"], opts)
  end

  defp dispatch("pages.read", actor, params, ctx), do: read_document(actor, params, ctx)
  defp dispatch("pages.sharing", actor, params, _ctx), do: Pages.sharing(actor, params["id"])

  defp dispatch("comments.list", actor, params, _ctx) do
    page_id = params["id"] || params["page_id"]

    status =
      case params["status"] do
        "resolved" -> :resolved
        "all" -> :all
        "unread" -> :unread
        _ -> :open
      end

    opts = %{
      status: status,
      cursor: params["cursor"],
      limit: if(is_integer(params["limit"]), do: params["limit"], else: 25)
    }

    Comments.list(actor, page_id, opts)
  end

  defp dispatch("comments.show", actor, params, _ctx),
    do: Comments.read(actor, params["id"] || params["page_id"], params["comment_id"])

  defp dispatch("comments.reply", actor, params, _ctx) do
    page_id = params["id"] || params["page_id"]
    root_id = params["root_id"]

    if is_binary(root_id) and String.trim(root_id) != "" do
      Comments.create(actor, page_id, %{"root_id" => root_id, "body" => params["body"]})
    else
      {:error, :invalid_comment_reply}
    end
  end

  defp dispatch("comments.resolve", actor, params, _ctx) do
    page_id = params["id"] || params["page_id"]

    Comments.resolve(actor, page_id, params["comment_id"], %{
      "version" => params["version"],
      "resolved" => Map.get(params, "resolved", true)
    })
  end

  defp dispatch("pages.set_sharing", actor, params, ctx),
    do: change_page(:set_sharing, actor, params, ctx)

  defp dispatch("pages.update_sharing", actor, params, ctx),
    do: change_page(:update_sharing, actor, params, ctx)

  defp dispatch("pages.create", actor, params, ctx) do
    params =
      if ctx[:source_message_id],
        do: Map.put_new(params, "saved_from_message_id", ctx.source_message_id),
        else: params

    if params["type"] == "knowledge" do
      with {:ok, context} <- page_context(actor),
           do:
             Ankole.Pod.AgentPages.create(
               actor,
               context,
               params["parent_id"],
               params["title"],
               params["markdown"] || ""
             )
    else
      Pages.create(actor, params, ctx.write_authority)
    end
  end

  defp dispatch("pages.update", actor, params, ctx),
    do: change_page(:update, actor, params, ctx)

  defp dispatch("pages.move", actor, params, ctx) do
    with {:ok, %{page: page}} <- change_page(:move, actor, params, ctx),
         do: {:ok, page}
  end

  defp dispatch("pages.delete", actor, params, ctx),
    do: change_page(:delete, actor, params, ctx)

  defp dispatch("pages.restore", actor, params, ctx),
    do: change_page(:restore, actor, params, ctx)

  defp dispatch(operation, actor, params, ctx)
       when operation in ["pages.write", "pages.append"] do
    with {:ok, context} <- page_context(actor),
         {:ok, page} <- Pages.authorize(actor, params["id"], "node_edit"),
         :ok <- Ankole.Pod.AgentPages.editable(actor, context, page) do
      if page.type == :knowledge do
        if operation == "pages.write" and is_binary(params["markdown"]) do
          with {:ok, result} <-
                 Ankole.Pod.AgentPages.save(
                   actor,
                   context,
                   page.id,
                   params["base_revision"],
                   params["markdown"]
                 ),
               do: {:ok, Map.drop(result, [:content])}
        else
          {:error, :invalid_request}
        end
      else
        write_document(operation, actor, params, ctx)
      end
    end
  end

  defp dispatch("files.manifest", actor, params, _ctx), do: Files.manifest(actor, params["id"])

  defp dispatch("files.download", actor, params, ctx) do
    send_file(params["home_relative_path"], ctx, fn local ->
      Files.read_to_file(actor, params["id"], params["path"], local, params["sha256"])
    end)
  end

  defp dispatch("chat.attachment.get", actor, params, ctx) do
    send_file(params["home_relative_path"], ctx, fn local ->
      Ankole.Conversations.read_attachment_to_file(
        actor,
        params["conversation_id"],
        params["message_id"],
        params["position"],
        local
      )
    end)
  end

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

  defp disclosure_target(operation, actor, params)
       when operation in ~w(pages.sharing comments.list comments.show files.manifest files.download base.tables) do
    readable_target(actor, params["id"] || params["page_id"])
  end

  defp disclosure_target(operation, actor, params)
       when operation in ~w(base.schema base.query base.aggregate) do
    with {:ok, table} <- Ankole.Pod.Bases.fetch_table(params["id"]),
         do: readable_target(actor, table.page_id)
  end

  defp disclosure_target(_operation, _actor, _params), do: :ok

  defp readable_target(actor, id) do
    with {:ok, context} <- page_context(actor),
         {:ok, page} <- Pages.fetch(id),
         {:ok, _} <- Ankole.Pod.AgentPages.visible(context, page),
         do: :ok
  end

  defp page_options(actor, params) do
    with {:ok, context} <- page_context(actor),
         {:ok, reachable} <- Ankole.Brain.Access.visibility(context) do
      disclosure = context.disclosure

      recipients =
        List.wrap(disclosure.asker_uid) ++
          if(disclosure.mode == :strict, do: disclosure.present_uids, else: [])

      readers =
        if disclosure.mode == :strict and recipients == [],
          do: [],
          else: Enum.uniq([context.querier_uid | recipients])

      {:ok, params |> Map.put(:reachable, reachable) |> Map.put(:reader_uids, readers)}
    end
  end

  @doc false
  def page_context(%{turn_authority: {ref, _}} = actor)
      when is_struct(ref, Ankole.Sessions.RunRef) or is_struct(ref, Ankole.Sessions.JobTurnRef) do
    with {:ok, context} <-
           Ankole.Brain.RequestContext.build(Ankole.AuthZ.Actor.uid(actor), %{
             "signal_id" => ref.signal_id
           }),
         do: {:ok, %{context | authn: actor.authn}}
  end

  def page_context(actor) do
    context = Ankole.Brain.Tools.Context.for_subject(Ankole.AuthZ.Actor.uid(actor))
    {:ok, %{context | authn: actor.authn}}
  end

  defp page_detail(actor, id) do
    Ankole.Repo.transact_top_level(fn ->
      with {:ok, context} <- page_context(actor),
           {:ok, page} <- Pages.lock(id, :share),
           {:ok, reachable} <- Ankole.Pod.AgentPages.visible(context, page),
           {:ok, detail} <- Pages.get_in_tx(actor, id),
           {:ok, ancestors} <-
             Ankole.Pod.Pages.Queries.readable_ancestors_in_tx(actor, page, reachable) do
        {:ok,
         Map.merge(detail, %{
           ancestors: ancestors,
           child_count: Ankole.Pod.Pages.Queries.visible_child_count_in_tx(actor, page, reachable)
         })}
      end
    end)
  end

  defp read_document(actor, params, ctx) do
    with {:ok, detail} <- page_detail(actor, params["id"]) do
      cond do
        detail.page.type == :knowledge ->
          with {:ok, markdown} <-
                 Ankole.Kernel.knowledge_export(detail.content.content, detail.page.metadata),
               do: {:ok, Map.put(detail, :content, %{markdown: markdown})}

        detail.content ->
          local = Ankole.Files.temp_path()

          try do
            with {:ok, target} <- Ankole.Files.normalize_path(params["xml_home_relative_path"]),
                 :ok <- File.write(local, detail.content.content),
                 {:ok, _} <-
                   WorkerFiles.put(target, {:file, local},
                     worker: %{worker_id: ctx.worker_id, transport_route: ctx.route}
                   ) do
              references =
                Pages.resolve_xml_references(actor, detail.content.content, detail.page.id)

              {:ok,
               detail
               |> Map.put(:content, %{xml_file: true})
               |> Map.put(:references, references)}
            end
          after
            File.rm(local)
          end

        true ->
          {:ok, detail}
      end
    end
  end

  defp send_file(target, ctx, receive_file) do
    local = Ankole.Files.temp_path()

    try do
      with {:ok, target} <- Ankole.Files.normalize_path(target),
           {:ok, metadata} <- receive_file.(local),
           {:ok, object} <- Ankole.Files.fetch_object(Ankole.Attrs.get(metadata, :object_id)),
           {:ok, _} <-
             WorkerFiles.put(target, {:file, local},
               worker: %{worker_id: ctx.worker_id, transport_route: ctx.route},
               max_bytes: max(object.size, 1)
             ) do
        {:ok, metadata}
      end
    after
      File.rm(local)
    end
  end

  # Structural edits of knowledge use the same requester/Agent contract as body edits.
  defp change_page(operation, actor, params, ctx) do
    with {:ok, context} <- page_context(actor),
         {:ok, result} <-
           Ankole.Files.Access.write_tree(
             ctx.write_authority,
             fn ->
               with {:ok, current} <- Pages.lock(params["id"]),
                    :ok <- authorize_page_change(operation, actor, context, current, params),
                    do: change_page_in_tx(operation, actor, params)
             end,
             root_ids: fn ->
               Ankole.Files.Nodes.root_ids([params["id"]]) ++
                 if(operation == :move, do: Pages.destination_root_ids(actor, params), else: [])
             end,
             after_commit: fn result -> publish_page_change(operation, result) end
           ) do
      if operation == :update_sharing do
        with {:ok, sharing} <- Pages.sharing(actor, result.id),
             do: {:ok, %{page: result, sharing: sharing}}
      else
        {:ok, result}
      end
    end
  end

  defp authorize_page_change(operation, actor, context, page, params) do
    if knowledge_subtree?(page) do
      action =
        if operation in [:set_sharing, :update_sharing], do: "node_manage", else: "node_edit"

      opts = if operation == :restore, do: [trash: true], else: []

      with :ok <- Ankole.Pod.AgentPages.authorize_change(actor, context, page, action, opts),
           do: editable_destination(operation, actor, context, page, params)
    else
      :ok
    end
  end

  defp knowledge_subtree?(%{type: :knowledge}), do: true

  defp knowledge_subtree?(page), do: Ankole.Files.subtree_has_kind?(page.id, :knowledge)

  defp editable_destination(:move, actor, context, page, params) do
    with {:ok, parent} <- Pages.destination_root_in_tx(actor, params) do
      if parent.id == page.parent_id,
        do: :ok,
        else: Ankole.Pod.AgentPages.editable(actor, context, parent)
    end
  end

  defp editable_destination(_operation, _actor, _context, _page, _params), do: :ok

  defp change_page_in_tx(:update, actor, params),
    do: Pages.update_in_tx(actor, params["id"], params)

  defp change_page_in_tx(:move, actor, params), do: Pages.move_in_tx(actor, params["id"], params)
  defp change_page_in_tx(:delete, actor, params), do: Pages.delete_in_tx(actor, params["id"])
  defp change_page_in_tx(:restore, actor, params), do: Pages.restore_in_tx(actor, params["id"])

  defp change_page_in_tx(:set_sharing, actor, params),
    do: Pages.set_sharing_in_tx(actor, params["id"], params)

  defp change_page_in_tx(:update_sharing, actor, params),
    do: Pages.update_sharing_in_tx(actor, params["id"], params)

  defp publish_page_change(:update, page), do: Pages.committed_page(page)
  defp publish_page_change(:move, result), do: Pages.committed_tree(result)
  defp publish_page_change(:delete, page), do: Pages.committed_access_tree(page)
  defp publish_page_change(:restore, page), do: Pages.committed_access_tree(page)

  defp publish_page_change(operation, page) when operation in [:set_sharing, :update_sharing],
    do: Pages.committed(page)

  defp write_document(operation, actor, params, ctx) do
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

    with {:ok, _page} <- Files.authorize_upload(actor, params["id"], params["role"] || "file"),
         {:ok, maximum} <- Ankole.Files.upload_limit(),
         {:ok, source} <- Ankole.Files.normalize_path(source),
         {:ok, %{"body" => body}} <-
           WorkerFiles.stream(source,
             worker: %{worker_id: ctx.worker_id, transport_route: ctx.route},
             max_bytes: maximum
           ) do
      Files.upload(
        actor,
        params["id"],
        params["role"] || "file",
        params["base_object_id"],
        params["name"] || Path.basename(source),
        body,
        params["content_type"],
        ctx.write_authority
      )
    end
  rescue
    exception in WorkerFiles.RelayError -> {:error, exception.reason}
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
