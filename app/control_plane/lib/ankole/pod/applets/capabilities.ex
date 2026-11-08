defmodule Ankole.Pod.Applets.Capabilities do
  @moduledoc "The only bridge from Applet code to authorized Pod domain operations."

  alias Ankole.Pod.Access
  alias Ankole.Pod.{Bases, Files, Pages, Serialization}
  alias Ankole.Pod.Applets.{AI, Web}

  def call(context, caller, operation, args) do
    {admin?, operation} =
      case operation do
        "admin." <> operation -> {true, operation}
        operation -> {false, operation}
      end

    write? =
      operation in [
        "base.write",
        "file.write",
        "state.set",
        "state.delete",
        "signals.emit",
        "ai.generateImage"
      ]

    if (context["read_only"] == true or context["method"] == "GET") and write? do
      error(:read_only_route)
    else
      outcome =
        with {:ok, page} <- Pages.fetch(context["applet"]["pageId"]),
             :ok <- Ankole.Pod.Applets.available(page),
             {:ok, actor} <- actor(context, page, caller, admin?, operation),
             do: dispatch_context(context, page, actor, caller, operation, args)

      result(outcome)
    end
  rescue
    exception ->
      Ankole.Logging.error("pod.applet.capability_failed", "Applet capability failed", %{
        tenant_id: Ankole.Repo.tenant_id(),
        page_id: get_in(context, ["applet", "pageId"]),
        revision: get_in(context, ["applet", "revision"]),
        operation: operation,
        exception: inspect(exception.__struct__),
        stacktrace:
          __STACKTRACE__
          |> Enum.map(fn
            {module, function, args, location} when is_list(args) ->
              {module, function, length(args), location}

            frame ->
              frame
          end)
          |> Exception.format_stacktrace()
      })

      error(:handler_error)
  end

  @doc false
  def actor(context, page, caller, admin?, operation) do
    cond do
      operation in ["state.get", "state.set", "state.delete"] ->
        with {:ok, _} <-
               if(caller, do: Access.principal(caller), else: Ankole.Pod.Applets.owner(page)),
             do: {:ok, caller}

      admin? ->
        with {:ok, principal} <- Ankole.Pod.Applets.owner(page) do
          authority = Ankole.AutomationJobs.applet_attempt_authority(context, principal.uid)

          {:ok,
           Ankole.AuthZ.Actor.new(principal,
             turn_authority: authority || (caller && caller.turn_authority)
           )}
        end

      is_nil(caller) ->
        {:error, :user_authority_unavailable}

      true ->
        with {:ok, _} <- Access.authorize(caller, page, "node_view", trash: false),
             do: {:ok, caller}
    end
  end

  defp dispatch_context(context, _page, _actor, _caller, "state." <> operation, args),
    do: Ankole.AutomationJobs.applet_state(context, operation, args)

  defp dispatch_context(context, page, actor, caller, "signals." <> operation, args),
    do: Ankole.Signals.applet_dispatch(context, page, actor, caller, operation, args)

  defp dispatch_context(context, page, actor, _caller, "ai.generateImage", [options])
       when is_map(options),
       do:
         AI.generate_image(page, actor, options,
           authentication_ref: context["authentication_ref"]
         )

  defp dispatch_context(_context, page, actor, _caller, operation, args),
    do: dispatch(page, actor, operation, args)

  defp dispatch(_page, actor, "base.schema", [id]), do: Bases.get_table(actor, id)

  defp dispatch(_page, _actor, "base.query", [_id, %{"local" => _}]),
    do: {:error, :invalid_request}

  defp dispatch(_page, actor, "base.query", [id, query]) when is_map(query),
    do: Bases.query(actor, id, query)

  defp dispatch(_page, actor, "base.aggregate", [id, query]) when is_map(query),
    do: Bases.aggregate(actor, id, query)

  defp dispatch(_page, actor, "metrics.query", [metric, options]) when is_map(options),
    do: Ankole.Brain.execute_metric(actor, metric, options["revision"], options["params"] || %{})

  defp dispatch(_page, actor, "base.write", [id, changes]) when is_map(changes),
    do: Bases.write_records(actor, id, changes, actor.turn_authority)

  defp dispatch(_page, actor, "file.list", [id]) do
    with {:ok, manifest} <- Files.manifest(actor, id) do
      {:ok, %{revision: manifest.revision, files: Enum.map(manifest.files, &file_entry(id, &1))}}
    end
  end

  defp dispatch(_page, actor, "file.read", [path]) do
    with {:ok, id, relative} <- Files.parse_path(path),
         {:ok, entry, bytes} <-
           Files.read(actor, id, relative, nil,
             max_bytes: Ankole.WorkerFiles.max_transfer_bytes()
           ) do
      {:ok, Map.put(file_entry(id, entry), :bytes, %{"__ankole_bytes" => Base.encode64(bytes)})}
    end
  end

  defp dispatch(_page, actor, "file.write", [
         id,
         %{"name" => name, "bytes" => %{"__ankole_bytes" => encoded}} = file
       ]) do
    with {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) <= Ankole.WorkerFiles.max_transfer_bytes(),
         {:ok, page} <- Pages.authorize(actor, id, "node_view"),
         {:ok, role} <- upload_role(page.type),
         {:ok, result} <-
           Files.upload(
             actor,
             id,
             role,
             file["baseObjectId"],
             name,
             bytes,
             file["contentType"],
             actor.turn_authority
           ) do
      {:ok,
       Map.merge(file_entry(id, result.file), %{
         pageId: result.page_id,
         revision: result.revision,
         name: name,
         mime: result.file.content_type || "application/octet-stream"
       })
       |> then(fn entry -> if result[:src], do: Map.put(entry, :url, result.src), else: entry end)}
    else
      false -> {:error, :file_too_large}
      :error -> {:error, :invalid_request}
      error -> error
    end
  end

  defp dispatch(_page, actor, "ai.generateText", [options]) when is_map(options),
    do: AI.generate_text(actor, options)

  defp dispatch(_page, actor, "web.search", [options]) when is_map(options),
    do: Web.search(actor, options)

  defp dispatch(_page, actor, "web.fetch", [options]) when is_map(options),
    do: Web.fetch(actor, options)

  defp dispatch(_page, _actor, _operation, _args), do: {:error, :invalid_request}

  defp upload_role(:file), do: {:ok, "file"}
  defp upload_role(:doc), do: {:ok, "asset"}
  defp upload_role(:base), do: {:ok, "attachment"}
  defp upload_role(_), do: {:error, :invalid_file_role}

  defp file_entry(id, file),
    do: %{
      path: "pages/#{id}/#{file.path}",
      objectId: file.object_id,
      sha256: file.sha256,
      size: file.size,
      contentType: file.content_type
    }

  defp result({:ok, value}), do: {:ok, Serialization.json_value(value)}
  defp result({:error, %{status: _} = error}), do: {:error, error}

  defp result({:error, %{code: code} = failure}),
    do:
      {:error,
       failure
       |> Map.put(:code, to_string(code))
       |> Map.put_new(:status, 502)
       |> Map.put_new(:message, to_string(code))}

  defp result({:error, reason}), do: error(reason)
  defp result(_), do: error(:handler_error)

  def error(reason) do
    details = Serialization.error(reason)
    {:error, Map.put(details, :status, Serialization.status(details.code))}
  end
end
