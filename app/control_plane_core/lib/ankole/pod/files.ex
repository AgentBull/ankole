defmodule Ankole.Pod.Files do
  @moduledoc "Page-owned files on the Pod drive, with page authorization and revision checks."

  alias Ankole.Files, as: Drive
  alias Ankole.Pod.{Access, Pages}
  alias Ankole.Repo

  @doc "Lists one page's current file manifest. Paths are relative to the page directory."
  def manifest(uid, page_id) do
    Repo.transact(fn _repo ->
      with {:ok, page} <- Pages.lock(page_id, :share),
           {:ok, _page} <- Pages.authorize(uid, page.id, "page_view"),
           {:ok, files} <- all_files(page.id) do
        {:ok, %{page_id: page.id, revision: page.revision, files: Enum.map(files, &entry/1)}}
      end
    end)
  end

  @doc "Reads a page file, optionally requiring its current content digest."
  def read(uid, page_id, path, digest \\ nil) do
    with {:ok, _page} <- Pages.authorize(uid, page_id, "page_view"),
         {:ok, path} <- page_path(page_id, path),
         {:ok, file, bytes} <- manifest_read(Drive.read(:pod, path), digest),
         :ok <- check_digest(file, digest) do
      {:ok, entry(file), bytes}
    end
  end

  @doc "Streams a page file through a local file for the WorkerFiles relay."
  def read_to_file(uid, page_id, path, local_path, digest \\ nil) do
    with {:ok, _page} <- Pages.authorize(uid, page_id, "page_view"),
         {:ok, path} <- page_path(page_id, path),
         {:ok, file} <- manifest_read(Drive.read_to_file(:pod, path, local_path), digest),
         :ok <- check_digest(file, digest) do
      {:ok, entry(file)}
    end
  end

  # Authorization has succeeded. A missing expected file means that its publication changed.
  defp manifest_read({:error, :not_found}, digest) when not is_nil(digest),
    do: {:error, :manifest_changed}

  defp manifest_read(result, _digest), do: result

  @doc "Stores an uploaded file, image, or attachment, then commits it through its page owner."
  def upload(
        uid,
        page_id,
        role,
        base_revision,
        name,
        source,
        content_type \\ nil,
        authority \\ nil
      ) do
    with {:ok, page} <- Pages.authorize(uid, page_id, "page_edit"),
         :ok <- allowed_role(page, role),
         {:ok, stored} <- Drive.store(source) do
      commit_upload(
        uid,
        page_id,
        role,
        base_revision,
        name,
        stored.sha256,
        content_type,
        authority
      )
    end
  end

  @doc "Saves an attachment visible in a conversation without granting access to the Agent's drive."
  def copy_from_message(uid, page_id, base_revision, message_id, source_path) do
    with {:ok, message_id} <- Ecto.UUID.cast(message_id),
         %Ankole.Conversations.Message{} = message <-
           Repo.get_by(Ankole.Conversations.Message, id: message_id),
         {:ok, _conversation} <- Ankole.Conversations.get(uid, message.conversation_id),
         %{"blob_ref" => digest} = attachment <-
           Enum.find(message.attachments, &(Map.get(&1, "path") == source_path)),
         {:ok, _page} <- Pages.authorize(uid, page_id, "page_edit") do
      commit_upload(
        uid,
        page_id,
        "file",
        base_revision,
        attachment["name"] || Path.basename(source_path),
        digest,
        Ankole.Conversations.Attachments.content_type(attachment),
        nil
      )
    else
      {:error, _reason} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc "Publishes a complete applet source and distribution manifest with compare-and-set."
  def publish(uid, page_id, base_revision, files, authority \\ nil)

  def publish(uid, page_id, base_revision, files, authority) when is_list(files) do
    with {:ok, upserts} <- publish_files(page_id, files) do
      mutate(uid, page_id, authority, fn repo, page ->
        with :ok <- require_type(page, :applet),
             :ok <- revision(page, base_revision),
             :ok <- own_publish_contents(uid, page.id, upserts),
             {:ok, routes} <- inspect_backend(page.id, upserts),
             {:ok, result} <-
               Drive.commit(repo, :pod, upserts, [
                 prefix(page.id) <> "/src",
                 prefix(page.id) <> "/dist",
                 prefix(page.id) <> "/server"
               ]),
             {:ok, page} <- advance(repo, page) do
          {:ok,
           %{
             page_id: page.id,
             revision: page.revision,
             files: Enum.map(result.files, &entry/1),
             routes: routes
           }}
        end
      end)
    end
  end

  def publish(_uid, _page_id, _base_revision, _files, _authority), do: {:error, :invalid_manifest}

  @doc "Parses the authoritative page directory in a Pod drive path."
  def parse_path("pages/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [id, relative] ->
        with {:ok, id} <- Ecto.UUID.cast(id),
             {:ok, _path} <- Drive.normalize_path(relative),
             do: {:ok, id, relative}

      _ ->
        {:error, :invalid_path}
    end
  end

  def parse_path(_path), do: {:error, :invalid_path}

  defp commit_upload(uid, page_id, role, base_revision, name, digest, content_type, authority) do
    mutate(uid, page_id, authority, fn repo, page ->
      with :ok <- allowed_role(page, role),
           :ok <- file_revision(page, base_revision),
           {:ok, path} <- upload_path(page.id, role, digest, name),
           deletes = if(role == "file", do: [prefix(page.id)], else: []),
           {:ok, %{files: [file]}} <-
             Drive.commit(
               repo,
               :pod,
               [%{path: path, sha256: digest, source: "pod", content_type: content_type}],
               deletes
             ),
           {:ok, page} <- maybe_advance(repo, page) do
        result = %{page_id: page.id, revision: page.revision, file: entry(file)}

        result =
          if role == "asset",
            do:
              Map.put(
                result,
                :src,
                "ankole:asset/" <> hex(file.sha256) <> "/" <> Drive.file_name(name)
              ),
            else: result

        {:ok, result}
      end
    end)
  end

  defp mutate(uid, page_id, authority, fun) do
    Repo.assert_outside_transaction!()

    result =
      Access.write_transaction(authority, fn repo ->
        with {:ok, page} <- Pages.lock(page_id),
             {:ok, _page} <- Pages.authorize(uid, page.id, "page_edit") do
          fun.(repo, page)
        end
      end)

    if match?({:ok, _}, result), do: Pages.broadcast(page_id)
    result
  end

  defp publish_files(page_id, files) do
    Enum.reduce_while(files, {:ok, []}, fn
      file, {:ok, upserts} when is_map(file) ->
        relative = Ankole.Attrs.get(file, :path)
        digest = Ankole.Attrs.get(file, :sha256)

        with true <-
               is_binary(relative) and
                 (String.starts_with?(relative, "src/") or String.starts_with?(relative, "dist/") or
                    relative == "server/main.js"),
             {:ok, path} <- page_path(page_id, relative) do
          {:cont,
           {:ok,
            [
              %{
                path: path,
                sha256: digest,
                source: "pod",
                content_type: Ankole.Attrs.get(file, :content_type)
              }
              | upserts
            ]}}
        else
          _ -> {:halt, {:error, :invalid_manifest}}
        end

      _file, _acc ->
        {:halt, {:error, :invalid_manifest}}
    end)
    |> case do
      {:ok, upserts} ->
        paths = Enum.map(upserts, & &1.path)

        if length(Enum.uniq(paths)) == length(paths) and
             Enum.any?(paths, &String.starts_with?(&1, prefix(page_id) <> "/src/")) and
             (prefix(page_id) <> "/dist/index.html") in paths,
           do: {:ok, Enum.reverse(upserts)},
           else: {:error, :invalid_manifest}

      error ->
        error
    end
  end

  defp inspect_backend(page_id, upserts) do
    case Enum.find(upserts, &(&1.path == prefix(page_id) <> "/server/main.js")) do
      nil ->
        {:ok, []}

      file ->
        with {:ok, source} <- Drive.read_content(file.sha256),
             {:ok, limits} <- Ankole.Pod.Config.applet_limits(),
             {:ok, routes} <- Ankole.Kernel.AppletRuntime.inspect(source, limits) do
          {:ok, routes}
        else
          {:error, %{"message" => message}} ->
            {:error, {:invalid_applet_routes, %{reason: message}}}

          error ->
            error
        end
    end
  end

  # A digest alone does not grant access to a site-wide byte content. Public
  # publication can use the writer's drive or this applet's current files.
  defp own_publish_contents(uid, page_id, upserts) do
    with {:ok, files} <- all_files(page_id) do
      current = MapSet.new(files, &hex(&1.sha256))

      if Enum.all?(upserts, fn file ->
           is_binary(file.sha256) and
             (MapSet.member?(current, hex(file.sha256)) or
                Drive.drive_has_content?(uid, file.sha256))
         end),
         do: :ok,
         else: {:error, :unavailable_content}
    end
  end

  defp allowed_role(%{type: :file}, "file"), do: :ok
  defp allowed_role(%{type: :doc}, "asset"), do: :ok
  defp allowed_role(%{type: :database}, "attachment"), do: :ok
  defp allowed_role(_page, _role), do: {:error, :invalid_file_role}
  defp require_type(%{type: type}, type), do: :ok
  defp require_type(_page, _type), do: {:error, :invalid_page_type}

  defp file_revision(%{type: :file} = page, expected), do: revision(page, expected)
  defp file_revision(_page, _expected), do: :ok
  defp revision(%{revision: revision}, revision), do: :ok
  defp revision(%{revision: revision}, _expected), do: {:error, {:revision_conflict, revision}}

  defp advance(repo, page),
    do:
      page
      |> Ecto.Changeset.change(revision: page.revision + 1, updated_at: DateTime.utc_now())
      |> repo.update()

  defp maybe_advance(repo, %{type: :file} = page), do: advance(repo, page)
  defp maybe_advance(_repo, page), do: {:ok, page}

  defp upload_path(id, "file", _digest, name), do: page_path(id, Drive.file_name(name))

  defp upload_path(id, "asset", digest, name),
    do: page_path(id, "assets/" <> hex(digest) <> "/" <> Drive.file_name(name))

  defp upload_path(id, "attachment", digest, name),
    do: page_path(id, "attachments/" <> hex(digest) <> "/" <> Drive.file_name(name))

  defp page_path(id, relative) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, relative} <- Drive.normalize_path(relative),
         do: {:ok, prefix(id) <> "/" <> relative}
  end

  def prefix(id), do: "pages/" <> id
  defp hex(<<digest::binary-size(32)>>), do: Base.encode16(digest, case: :lower)
  defp hex(<<digest::binary-size(64)>>), do: String.downcase(digest)
  defp hex(_digest), do: nil
  defp check_digest(_file, nil), do: :ok

  defp check_digest(file, digest),
    do: if(hex(file.sha256) == digest, do: :ok, else: {:error, :manifest_changed})

  defp all_files(page_id, after_path \\ nil, files \\ []) do
    with {:ok, page} <- Drive.list(:pod, prefix(page_id), limit: 1000, after: after_path) do
      case page.next_after do
        nil -> {:ok, Enum.reverse(files) |> List.flatten() |> Kernel.++(page.files)}
        next -> all_files(page_id, next, [page.files | files])
      end
    end
  end

  defp entry(file) do
    {:ok, _page_id, relative} = parse_path(file.path)
    %{path: relative, sha256: hex(file.sha256), size: file.size, content_type: file.content_type}
  end
end
