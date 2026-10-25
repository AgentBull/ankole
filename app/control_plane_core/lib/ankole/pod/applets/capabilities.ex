defmodule Ankole.Pod.Applets.Capabilities do
  @moduledoc "The only bridge from Applet code to authorized Pod domain operations."

  alias Ankole.Pod.{Database, Files, Pages, Serialization}
  alias Ankole.Pod.Applets.AI

  def call(context, %Ankole.AuthZ.Actor{} = actor, operation, args) do
    authority = actor.turn_authority
    write? = operation in ["db.write", "file.write"]

    if context["method"] == "GET" and write? do
      error(:read_only_route)
    else
      outcome =
        with {:ok, _page} <- Pages.authorize(actor, context["applet"]["pageId"], "page_view"),
             do: dispatch(actor, authority, operation, args)

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

  defp dispatch(actor, _authority, "db.schema", [id]), do: Database.get_table(actor, id)

  defp dispatch(_uid, _authority, "db.query", [_id, %{"local" => _}]),
    do: {:error, :invalid_request}

  defp dispatch(actor, _authority, "db.query", [id, query]) when is_map(query),
    do: Database.query(actor, id, query)

  defp dispatch(actor, _authority, "db.aggregate", [id, query]) when is_map(query),
    do: Database.aggregate(actor, id, query)

  defp dispatch(actor, authority, "db.write", [id, changes]) when is_map(changes),
    do: Database.write_records(actor, id, changes, authority)

  defp dispatch(actor, _authority, "file.list", [id]) do
    with {:ok, manifest} <- Files.manifest(actor, id) do
      {:ok, %{revision: manifest.revision, files: Enum.map(manifest.files, &file_entry(id, &1))}}
    end
  end

  defp dispatch(actor, _authority, "file.read", [path]) do
    with {:ok, id, relative} <- Files.parse_path(path),
         {:ok, entry, bytes} <- Files.read(actor, id, relative) do
      {:ok, Map.put(file_entry(id, entry), :bytes, %{"__ankole_bytes" => Base.encode64(bytes)})}
    end
  end

  defp dispatch(actor, authority, "file.write", [
         id,
         %{"name" => name, "bytes" => %{"__ankole_bytes" => encoded}} = file
       ]) do
    with {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) <= Ankole.WorkerFiles.max_transfer_bytes(),
         {:ok, page} <- Pages.authorize(actor, id, "page_view"),
         {:ok, role} <- upload_role(page.type),
         {:ok, result} <-
           Files.upload(
             actor,
             id,
             role,
             file["baseRevision"],
             name,
             bytes,
             file["contentType"],
             authority
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

  defp dispatch(_uid, _authority, "ai.generateText", [options]) when is_map(options),
    do: AI.generate_text(options)

  defp dispatch(_uid, _authority, _operation, _args), do: {:error, :invalid_request}

  defp upload_role(:file), do: {:ok, "file"}
  defp upload_role(:doc), do: {:ok, "asset"}
  defp upload_role(:database), do: {:ok, "attachment"}
  defp upload_role(_), do: {:error, :invalid_file_role}

  defp file_entry(id, file),
    do: %{
      path: "pages/#{id}/#{file.path}",
      sha256: file.sha256,
      size: file.size,
      contentType: file.content_type
    }

  defp result({:ok, value}), do: {:ok, Serialization.json_value(value)}
  defp result({:error, %{status: _} = error}), do: {:error, error}
  defp result({:error, reason}), do: error(reason)
  defp result(_), do: error(:handler_error)

  def error(reason) do
    details = Serialization.error(reason)
    {:error, Map.put(details, :status, Serialization.status(details.code))}
  end
end
