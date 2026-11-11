defmodule Ankole.Pod.RPCBroker do
  @moduledoc "Agent access to the same Pod domain contracts that serve the browser."

  alias Ankole.Pod.{Bases, Comments, Documents, Files, Pages}
  import Ankole.Pod.Serialization, only: [json_value: 1, navigation_page: 1]
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.WorkerFiles

  @read_operations ~w(jobs.actions jobs.runs jobs.list jobs.get_run bindings.list jobs.schedules.list jobs.schedules.runs jobs.webhooks.list skills.bundle pages.list pages.children pages.search pages.read pages.sharing comments.list comments.show files.manifest files.download chat.attachment.get base.tables base.schema base.query base.aggregate)
  @write_operations ~w(jobs.schedules.put jobs.schedules.pause jobs.schedules.resume jobs.schedules.run jobs.schedules.delete jobs.webhooks.create jobs.webhooks.update jobs.webhooks.pause jobs.webhooks.resume jobs.webhooks.cancel jobs.webhooks.delete chat.send_to_agent pages.create pages.update pages.move pages.delete pages.restore pages.set_sharing pages.update_sharing pages.write pages.append comments.reply comments.resolve files.upload applets.publish applets.call applets.transfer_owner jobs.create jobs.configure jobs.delete bindings.put base.configure_table base.create_table base.delete_table base.create_field base.update_field base.delete_field base.create_view base.update_view base.delete_view base.write base.copy)

  def handle_read(turn, %FabricProto.PodRequest{} = request, ctx) do
    with {:ok, actor} <- actor_for_request(turn, ctx) do
      handle(request, Map.put(ctx, :actor, actor), @read_operations)
    else
      {:error, reason} -> error(ctx, reason)
    end
  end

  def handle_write(turn, %FabricProto.PodRequest{} = request, ctx) do
    with {:ok, actor} <- actor_for_request(turn, ctx) do
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

  def actor_for_request(ref, ctx)
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

  def actor_for_request(_, _), do: {:error, :work_authorization_review_required}

  defp instruction_subject(%{authorization_kind: "human", human_uid: uid}) when is_binary(uid),
    do: Ankole.Principals.get_principal(uid)

  defp instruction_subject(%{authorization_kind: "service"}), do: {:ok, nil}
  defp instruction_subject(_), do: {:error, :work_authorization_review_required}

  defp handle(request, ctx, allowed) do
    with true <- request.operation in allowed,
         {:ok, params} when is_map(params) <- Torque.decode(request.params_json) do
      case run_authorized_operation(request.operation, ctx, params) do
        {:ok, result} ->
          {:ok, %{"result" => json_value(result)}}

        {:error, reason} ->
          Ankole.Pod.Access.BlockedWaits.maybe_record_blocked_turn(
            ctx,
            request.operation,
            params,
            reason
          )

          error(ctx, reason)
      end
    else
      false -> error(ctx, :invalid_pod_operation)
      _ -> error(ctx, :invalid_pod_payload)
    end
  end

  defp run_authorized_operation(operation, ctx, params) do
    with :ok <- disclosure_target(operation, ctx.actor, params) do
      dispatch(operation, ctx.actor, params, ctx)
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
         {:ok, projection} <-
           Ankole.BackgroundAgentJobs.RuntimeProjection.for_turn(actor.turn_authority),
         {:ok, files} <-
           Ankole.AIAgent.Library.skill_bundle(Ankole.AuthZ.Actor.uid(actor), params["name"],
             request_context: context,
             runtime_projection: projection
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
    params =
      if Map.has_key?(params, "domain") or Map.has_key?(params, :domain),
        do: params,
        else: Map.put(params, "domain", "all")

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
      with {:ok, params} <- initial_document(params),
           do: Pages.create(actor, params, ctx.write_authority)
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
        if operation == "pages.write" do
          write_knowledge(actor, context, page.id, params, ctx)
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
      Files.publish_from_worker(
        actor,
        params["id"],
        params["base_revision"],
        params["files"],
        Ankole.AgentWorkers.WorkerRoute.caller(ctx),
        ctx.write_authority
      )

  defp dispatch("applets.call", actor, params, ctx) do
    request = Map.put_new(params, "query", %{})
    Ankole.Pod.Applets.call(actor, params["id"], request, authority: ctx.write_authority)
  end

  defp dispatch("applets.transfer_owner", actor, params, _ctx),
    do: Ankole.Pod.transfer_applet_owner(actor, params["id"], params["owner_uid"])

  defp dispatch("base.configure_table", actor, params, _ctx),
    do: Bases.configure_table(actor, params["id"], params)

  defp dispatch("jobs.schedules.list", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.JobSources.schedules(
        actor,
        params["page_id"],
        params["job_id"],
        :list,
        params
      )

  defp dispatch("jobs.schedules.put", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.JobSources.schedules(
        actor,
        params["page_id"],
        params["job_id"],
        :put,
        params
      )

  defp dispatch("jobs.schedules.pause", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.JobSources.schedules(
        actor,
        params["page_id"],
        params["job_id"],
        :pause,
        params
      )

  defp dispatch("jobs.schedules.resume", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.JobSources.schedules(
        actor,
        params["page_id"],
        params["job_id"],
        :resume,
        params
      )

  defp dispatch("jobs.schedules.run", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.JobSources.schedules(
        actor,
        params["page_id"],
        params["job_id"],
        :run,
        params
      )

  defp dispatch("jobs.schedules.delete", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.JobSources.schedules(
        actor,
        params["page_id"],
        params["job_id"],
        :delete,
        params
      )

  defp dispatch("jobs.schedules.runs", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.JobSources.schedules(
        actor,
        params["page_id"],
        params["job_id"],
        :runs,
        params
      )

  defp dispatch("jobs.webhooks.list", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.JobSources.webhooks(
        actor,
        params["page_id"],
        params["job_id"],
        :list,
        params
      )

  defp dispatch("jobs.webhooks.create", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.JobSources.webhooks(
        actor,
        params["page_id"],
        params["job_id"],
        :create,
        params
      )

  defp dispatch("jobs.webhooks.update", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.JobSources.webhooks(
        actor,
        params["page_id"],
        params["job_id"],
        :update,
        params
      )

  defp dispatch("jobs.webhooks.pause", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.JobSources.webhooks(
        actor,
        params["page_id"],
        params["job_id"],
        :pause,
        params
      )

  defp dispatch("jobs.webhooks.resume", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.JobSources.webhooks(
        actor,
        params["page_id"],
        params["job_id"],
        :resume,
        params
      )

  defp dispatch("jobs.webhooks.cancel", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.JobSources.webhooks(
        actor,
        params["page_id"],
        params["job_id"],
        :cancel,
        params
      )

  defp dispatch("jobs.webhooks.delete", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.JobSources.webhooks(
        actor,
        params["page_id"],
        params["job_id"],
        :delete,
        params
      )

  defp dispatch("jobs.create", actor, params, _ctx),
    do:
      Ankole.AutomationJobs.create_applet_job(
        actor,
        params["page_id"],
        params["action_key"],
        params
      )

  defp dispatch("bindings.put", actor, params, _ctx),
    do: Ankole.Signals.put_event_binding(actor, params)

  defp dispatch("bindings.list", actor, params, _ctx) do
    with {:ok, bindings} <-
           Ankole.Signals.list_event_bindings(actor, params["config_ref"], params["job_id"]) do
      {:ok,
       Enum.filter(bindings, fn binding ->
         disclosure_target("bindings.list", actor, %{"config_ref" => binding.config_ref}) == :ok
       end)}
    end
  end

  defp dispatch("jobs.configure", actor, params, _ctx),
    do: Ankole.AutomationJobs.configure_applet_job(actor, params["page_id"], params["id"], params)

  defp dispatch("jobs.delete", actor, params, _ctx),
    do: Ankole.AutomationJobs.delete_applet_job(actor, params["page_id"], params["id"])

  defp dispatch("jobs.list", actor, params, _ctx),
    do: Ankole.AutomationJobs.list_applet_jobs(actor, params["page_id"])

  defp dispatch("jobs.actions", actor, params, _ctx),
    do: Ankole.AutomationJobs.list_applet_actions(actor, params["page_id"])

  defp dispatch("jobs.runs", actor, params, _ctx),
    do: Ankole.AutomationJobs.list_applet_runs(actor, params["page_id"], params["job_id"])

  defp dispatch("jobs.get_run", actor, params, _ctx),
    do: Ankole.AutomationJobs.get_applet_run(actor, params["page_id"], params["run_id"])

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

  defp disclosure_target(operation, actor, params)
       when operation in ~w(jobs.actions jobs.runs jobs.list jobs.get_run jobs.schedules.list jobs.schedules.runs jobs.webhooks.list) do
    readable_target(actor, params["page_id"])
  end

  defp disclosure_target("bindings.list", actor, %{"config_ref" => "base://" <> id}) do
    with {:ok, table} <- Bases.fetch_table(id), do: readable_target(actor, table.page_id)
  end

  defp disclosure_target("bindings.list", actor, %{"config_ref" => "applet://" <> id}),
    do: readable_target(actor, id)

  defp disclosure_target("bindings.list", actor, %{"config_ref" => "job://" <> id}) do
    with {:ok, id} <- Ankole.ModelIntegerID.parse(id),
         {:ok, job} when not is_nil(job) <- Ankole.AutomationJobs.get_automation_job(id) do
      readable_target(actor, job.page_id)
    else
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end

  defp disclosure_target("bindings.list", actor, %{"job_id" => id}) do
    with {:ok, id} <- Ankole.ModelIntegerID.parse(id),
         do: disclosure_target("bindings.list", actor, %{"config_ref" => "job://#{id}"})
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
         {:ok, reachable} <- Ankole.Pod.AgentPages.visibility(context) do
      {:ok, params |> Map.put(:reachable, reachable) |> Map.put(:page_context, context)}
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
            with {:ok, target} <-
                   Ankole.Files.normalize_path(params["markdown_home_relative_path"]),
                 {:ok, markdown} <- Ankole.Kernel.vfs_document_export(detail.content.content),
                 :ok <- File.write(local, markdown),
                 {:ok, _} <-
                   WorkerFiles.put(target, {:file, local},
                     worker: Ankole.AgentWorkers.WorkerRoute.caller(ctx)
                   ) do
              references =
                Pages.resolve_xml_references(actor, detail.content.content, detail.page.id)

              {:ok,
               detail
               |> Map.put(:content, %{markdown_file: true})
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
               worker: Ankole.AgentWorkers.WorkerRoute.caller(ctx),
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
           Ankole.Pod.Access.write_tree(
             ctx.write_authority,
             fn ->
               with {:ok, current} <- Pages.lock(params["id"]),
                    :ok <- authorize_page_change(operation, actor, context, current, params),
                    do: change_page_in_tx(operation, actor, params)
             end,
             root_ids: fn ->
               Ankole.Pod.Pages.Tree.root_ids([params["id"]]) ++
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
    if page.type == :knowledge do
      action =
        if operation in [:set_sharing, :update_sharing], do: "node_manage", else: "node_edit"

      opts = if operation == :restore, do: [trash: true], else: []

      with :ok <- Ankole.Pod.AgentPages.authorize_change(actor, context, page, action, opts),
           do: editable_destination(operation, actor, context, page, params)
    else
      :ok
    end
  end

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

  defp initial_document(%{"markdown" => markdown} = params) when is_binary(markdown) do
    if Map.get(params, "type", "doc") == "doc" do
      with {:ok, parsed} <- Ankole.Kernel.vfs_document_reconcile("<page />", markdown),
           do: {:ok, Map.put(params, "xml", parsed.xml)}
    else
      {:error, :invalid_request}
    end
  end

  defp initial_document(params), do: {:ok, params}

  defp write_knowledge(actor, context, id, params, ctx) do
    receive_markdown(params, ctx, fn markdown ->
      with {:ok, result} <-
             Ankole.Pod.AgentPages.save(actor, context, id, params["base_revision"], markdown),
           do: {:ok, Map.drop(result, [:content])}
    end)
  end

  defp write_document(operation, actor, params, ctx) do
    receive_markdown(params, ctx, fn markdown ->
      with {:ok, result} <-
             Documents.edit_markdown(
               actor,
               params["id"],
               params["base_revision"],
               markdown,
               if(operation == "pages.append", do: :append, else: :write),
               ctx.write_authority
             ),
           do: {:ok, Map.drop(result, [:content])}
    end)
  end

  defp receive_markdown(%{"markdown" => markdown}, _ctx, fun) when is_binary(markdown),
    do: fun.(markdown)

  defp receive_markdown(params, ctx, fun),
    do: receive_document(params["markdown_home_relative_path"], ctx, fun)

  defp receive_document(source, ctx, fun) do
    with {:ok, source} <- Ankole.Files.normalize_path(source) do
      WorkerFiles.with_received_file(
        source,
        [worker: Ankole.AgentWorkers.WorkerRoute.caller(ctx)],
        fn local ->
          with {:ok, markdown} <- File.read(local), do: fun.(markdown)
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
             worker: Ankole.AgentWorkers.WorkerRoute.caller(ctx),
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
