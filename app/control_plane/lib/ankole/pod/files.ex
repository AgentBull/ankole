defmodule Ankole.Pod.Files do
  @moduledoc """
  Pod-managed objects and file-node content, with node authorization.

  Manifest reads and commits run in top-level transactions under the Drive node
  lock. File replacements compare object IDs; Applet publications compare Pod
  revisions.
  """

  alias Ankole.Files, as: Drive
  alias Ankole.Files.Access
  alias Ankole.Pod.{Pages, PodFile}
  require Ash.Query
  alias Ankole.Repo

  @doc "Lists one page's current file manifest. Paths are relative to the page directory."
  def manifest(%Ankole.AuthZ.Actor{} = actor, page_id) do
    Repo.transact_top_level(fn -> manifest_in_tx(actor, page_id) end)
  end

  @doc false
  def manifest_in_tx(%Ankole.AuthZ.Actor{} = actor, page_id) do
    with {:ok, page} <- Pages.lock(page_id, :share),
         {:ok, _page} <- Pages.authorize(actor, page.id, "node_view"),
         {:ok, files} <- all_files(page.id) do
      {:ok,
       %{
         page_id: page.id,
         revision: page.revision,
         files: files |> readable_files(actor, page) |> Enum.map(&entry/1)
       }}
    end
  end

  @doc "Reads a page file, optionally requiring its current content digest."
  def read(%Ankole.AuthZ.Actor{} = actor, page_id, path, digest \\ nil, opts \\ []) do
    with {:ok, file} <- resolve_read(actor, page_id, path, digest),
         :ok <- read_size(file, opts[:max_bytes]),
         {:ok, bytes} <- Drive.read_object(file.object_id) do
      {:ok, entry(file), bytes}
    end
  end

  defp read_size(_file, nil), do: :ok
  defp read_size(%{size: size}, max) when size <= max, do: :ok
  defp read_size(_file, _max), do: {:error, :file_too_large}

  @doc "Streams a page file through a local file for the WorkerFiles relay."
  def read_to_file(%Ankole.AuthZ.Actor{} = actor, page_id, path, local_path, digest \\ nil) do
    with {:ok, file} <- resolve_read(actor, page_id, path, digest),
         :ok <- Drive.read_object_to_file(file.object_id, local_path) do
      {:ok,
       Map.merge(
         entry(file),
         Map.take(file, [:source, :mode, :updated_at, :conversation_id, :message_id])
       )}
    end
  end

  @doc "Resolves an authorized immutable file reference without downloading its bytes."
  def resolve_read(actor, page_id, relative, digest \\ nil) do
    Repo.transact_top_level(fn ->
      with {:ok, _path} <- page_path(page_id, relative),
           {:ok, page} <- Pages.lock(page_id, :share),
           {:ok, action} <- required_read_action(page, relative),
           {:ok, _} <- Pages.authorize(actor, page.id, action),
           {:ok, file} <- manifest_read(fetch_file(page_id, relative), digest),
           :ok <- check_digest(file, digest),
           do: {:ok, file}
    end)
  end

  @doc "Returns the action required to read a normalized page-relative path."
  def required_read_action(%{type: :applet}, path) do
    cond do
      String.starts_with?(path, ["dist/", "assets/"]) ->
        {:ok, "node_view"}

      String.starts_with?(path, ["src/", "server/"]) or
          path in ~w(package.json bun.lock tsconfig.json applet.env.json) ->
        {:ok, "node_edit"}

      true ->
        {:error, :forbidden}
    end
  end

  def required_read_action(_page, _path), do: {:ok, "node_view"}

  defp readable_files(files, actor, %{type: :applet} = page) do
    edit? = match?({:ok, _}, Pages.authorize(actor, page.id, "node_edit"))

    Enum.filter(files, fn file ->
      case required_read_action(page, file.path) do
        {:ok, "node_view"} -> true
        {:ok, "node_edit"} -> edit?
        _ -> false
      end
    end)
  end

  defp readable_files(files, _actor, _page), do: files

  @doc "Resolves a revision-pinned Applet asset under its page lock, then reads immutable bytes."
  def resolve_applet_frame_asset(actor, page_id, expected_revision, relative) do
    with {:ok, file} <- resolve_applet_frame_object(actor, page_id, expected_revision, relative),
         {:ok, bytes} <- Drive.read_object(file.object_id),
         do: {:ok, {file.content_type, hex(file.sha256), bytes}}
  end

  @doc "Resolves a revision-pinned Applet object under its page lock."
  def resolve_applet_frame_object(actor, page_id, expected_revision, relative) do
    Repo.transact_top_level(fn ->
      with {:ok, _path} <- page_path(page_id, "dist/" <> relative),
           {:ok, page} <- Pages.lock(page_id, :share),
           :ok <- require_type(page, :applet),
           {:ok, action} <- required_read_action(page, "dist/" <> relative),
           {:ok, _} <- Pages.authorize(actor, page.id, action, trash: false),
           :ok <- frame_revision(page, expected_revision),
           {:ok, file} <- fetch_file(page_id, "dist/" <> relative),
           do: {:ok, file}
    end)
  end

  defp frame_revision(%{revision: revision}, revision), do: :ok

  defp frame_revision(page, _),
    do: {:error, {:applet_revision_changed, %{revision: page.revision}}}

  # Authorization has succeeded. A missing expected file means that its publication changed.
  defp manifest_read({:error, :not_found}, digest) when not is_nil(digest),
    do: {:error, :manifest_changed}

  defp manifest_read(result, _digest), do: result

  @doc "Stores an uploaded file, image, or attachment, then commits it through its page owner."
  def upload(
        %Ankole.AuthZ.Actor{} = actor,
        page_id,
        role,
        base_object_id,
        name,
        source,
        content_type \\ nil,
        authority \\ nil
      ) do
    with {:ok, page} <- authorize_upload(actor, page_id, role),
         :ok <- allowed_role(page, role),
         {:ok, stored} <- Drive.store(source) do
      commit_upload(
        actor,
        page_id,
        role,
        base_object_id,
        name,
        stored,
        content_type,
        authority
      )
    end
  end

  @doc "Creates a file page and its manifest in one transaction after storing the bytes."
  def create_from_upload(%Ankole.AuthZ.Actor{} = actor, attrs, name, source, content_type) do
    with {:ok, _} <- Access.principal(actor),
         {:ok, stored} <- Drive.store(source) do
      create_file_page(actor, attrs, name, stored, content_type)
    end
  end

  @doc "Creates a file page from a visible conversation attachment in one transaction."
  def create_from_message(%Ankole.AuthZ.Actor{} = actor, attrs) do
    message_id = Ankole.Attrs.get(attrs, :saved_from_message_id)
    position = Ankole.Attrs.get(attrs, :attachment_position)

    with true <- Ankole.Attrs.get(attrs, :type) in [:file, "file"],
         {:ok, attachment} <- message_attachment(actor, message_id, position) do
      create_file_page(
        actor,
        attrs,
        attachment["name"] || "attachment",
        attachment["object_id"],
        Ankole.Conversations.Attachments.content_type(attachment)
      )
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp create_file_page(actor, attrs, name, stored, content_type) do
    upload = %{
      role: "file",
      base_object_id: nil,
      name: name,
      object: stored,
      content_type: content_type
    }

    Access.write_tree(
      actor.turn_authority,
      fn ->
        with {:ok, page} <-
               Pages.create_in_tx(
                 actor,
                 attrs |> Map.put(:type, :file) |> Map.put_new(:title, Drive.file_name(name))
               ),
             {:ok, _} <- commit_upload_in_tx(actor, page.id, %{upload | name: page.name}),
             do: Pages.fetch(page.id)
      end,
      root_ids: fn -> Pages.destination_root_ids(actor, attrs) end,
      after_commit: &Pages.committed_tree/1
    )
  end

  @doc "Saves an attachment visible in a conversation without granting access to the Agent's drive."
  def copy_from_message(
        %Ankole.AuthZ.Actor{} = actor,
        page_id,
        base_object_id,
        message_id,
        position
      ) do
    with {:ok, attachment} <- message_attachment(actor, message_id, position),
         {:ok, _page} <- authorize_upload(actor, page_id, "file") do
      commit_upload(
        actor,
        page_id,
        "file",
        base_object_id,
        attachment["name"] || "attachment",
        attachment["object_id"],
        Ankole.Conversations.Attachments.content_type(attachment),
        nil
      )
    end
  end

  defp message_attachment(actor, message_id, position)
       when is_integer(position) and position >= 0 do
    with {:ok, message_id} <- Ecto.UUID.cast(message_id),
         {:ok, %Ankole.Conversations.Message{} = message} <-
           Ankole.Conversations.get_message(message_id) do
      Ankole.Conversations.resolve_attachment(
        actor,
        message.conversation_id,
        message_id,
        position
      )
    else
      _ -> {:error, :not_found}
    end
  end

  defp message_attachment(_actor, _message_id, _position), do: {:error, :not_found}

  @doc "Publishes a complete applet source and distribution manifest with compare-and-set."
  def publish(uid, page_id, base_revision, files, authority \\ nil)

  def publish(%Ankole.AuthZ.Actor{} = actor, page_id, base_revision, files, authority)
      when is_list(files) do
    authority = authority || actor.turn_authority

    with {:ok, _} <- Pages.authorize(actor, page_id, "node_edit"),
         {:ok, upserts} <- publish_files(page_id, files),
         :ok <- own_publish_contents(actor, page_id, upserts),
         {:ok, env} <- validate_environment(page_id, upserts),
         {:ok, routes} <- inspect_backend(page_id, upserts, env) do
      Access.write(
        authority,
        fn -> publish_in_tx(actor, page_id, base_revision, upserts, routes) end,
        after_commit: &committed/1
      )
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

  @doc "Returns the primary file descriptor for each requested file page ID."
  def primary_files_by_page([]), do: %{}

  def primary_files_by_page(page_ids) when is_list(page_ids) do
    Enum.reduce(page_ids, %{}, fn id, result ->
      case all_files(id) do
        {:ok, [file | _]} -> Map.put(result, id, entry(file))
        _ -> result
      end
    end)
  end

  @doc false
  def publish_in_tx(%Ankole.AuthZ.Actor{} = actor, page_id, base_revision, upserts, routes) do
    write_file_in_tx(actor, page_id, "node_edit", fn page ->
      with :ok <- require_type(page, :applet),
           :ok <- revision(page, base_revision),
           :ok <- own_publish_contents(actor, page.id, upserts),
           {:ok, result} <-
             commit_files_in_tx(page.id, upserts, [
               "src",
               "dist",
               "server",
               "package.json",
               "bun.lock",
               "tsconfig.json",
               "applet.env.json"
             ]),
           {:ok, page} <- advance(page) do
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

  defp commit_upload(
         %Ankole.AuthZ.Actor{} = actor,
         page_id,
         role,
         base_object_id,
         name,
         stored,
         content_type,
         authority
       ) do
    authority = authority || actor.turn_authority

    upload = %{
      role: role,
      base_object_id: base_object_id,
      name: name,
      object: stored,
      content_type: content_type
    }

    writer = if role == "file", do: &Access.write_tree/3, else: &Access.write/3

    writer.(authority, fn -> commit_upload_in_tx(actor, page_id, upload) end,
      root_ids: if(role == "file", do: fn -> Drive.root_ids([page_id]) end, else: []),
      after_commit: &committed/1
    )
  end

  @doc false
  def commit_upload_in_tx(%Ankole.AuthZ.Actor{} = actor, page_id, upload) do
    %{role: role, base_object_id: base_object_id, name: name, object: stored} = upload

    write_file_in_tx(
      actor,
      page_id,
      if(role == "file", do: :file_content, else: required_upload_action(role)),
      fn page ->
        with :ok <- allowed_role(page, role),
             :ok <- file_object(page, base_object_id),
             {:ok, object} <- Drive.complete_object_in_tx(stored),
             {:ok, path} <- upload_path(page.id, role, object.sha256, name),
             {:ok, file} <-
               commit_upload_object(actor, page, role, path, object.id, upload.content_type) do
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
      end
    )
  end

  defp commit_upload_object(actor, page, "file", path, object_id, content_type) do
    with :ok <- rename_upload(actor, page, path),
         do:
           Drive.commit_node_object_in_tx(actor, page.id, object_id, %{
             content_type: content_type,
             source: "pod"
           })
  end

  defp commit_upload_object(_actor, page, _role, path, object_id, content_type) do
    with {:ok, %{files: [file]}} <-
           commit_files_in_tx(
             page.id,
             [%{path: path, object_id: object_id, source: "pod", content_type: content_type}],
             []
           ),
         do: {:ok, file}
  end

  defp rename_upload(_actor, %{name: name}, name), do: :ok

  defp rename_upload(actor, page, name) do
    with {:ok, _} <- Drive.rename_node_in_tx(actor, page.id, name), do: :ok
  end

  @doc "Publishes a committed page file change to the page channel."
  def committed(%{page_id: id}), do: Drive.node_committed(%{id: id})

  defp write_file_in_tx(%Ankole.AuthZ.Actor{} = actor, page_id, action, fun) do
    with {:ok, page} <- Pages.lock(page_id),
         :ok <- authorize_file_write(actor, page, action) do
      fun.(page)
    end
  end

  @doc "Checks upload authority before a Worker relay receives bytes."
  def authorize_upload(actor, page_id, role) do
    with {:ok, page} <- Pages.fetch(page_id),
         :ok <- allowed_role(page, role),
         :ok <-
           authorize_file_write(
             actor,
             page,
             if(role == "file", do: :file_content, else: required_upload_action(role))
           ),
         do: {:ok, page}
  end

  defp authorize_file_write(actor, page, :file_content) do
    Drive.authorize_node_write(actor, %{
      kind: page.type,
      id: page.id,
      parent_id: page.parent_id,
      object_id: page.object_id
    })
  end

  defp authorize_file_write(actor, page, action) do
    with {:ok, _} <- Pages.authorize(actor, page.id, action), do: :ok
  end

  defp publish_files(_page_id, files) do
    Enum.reduce_while(files, {:ok, []}, fn
      file, {:ok, upserts} when is_map(file) ->
        relative = Ankole.Attrs.get(file, :path)
        object_id = Ankole.Attrs.get(file, :object_id)

        with true <-
               is_binary(relative) and
                 (String.starts_with?(relative, "src/") or String.starts_with?(relative, "dist/") or
                    relative in ~w(server/main.js package.json bun.lock tsconfig.json applet.env.json)),
             {:ok, _id} <- Ecto.UUID.cast(object_id),
             {:ok, path} <- Drive.normalize_path(relative) do
          {:cont,
           {:ok,
            [
              %{
                path: path,
                object_id: object_id,
                source_path: Ankole.Attrs.get(file, :source_path),
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
             Enum.any?(paths, &String.starts_with?(&1, "src/")) and
             "dist/index.html" in paths,
           do: {:ok, Enum.reverse(upserts)},
           else: {:error, :invalid_manifest}

      error ->
        error
    end
  end

  defp inspect_backend(_page_id, upserts, env) do
    case Enum.find(upserts, &(&1.path == "server/main.js")) do
      nil ->
        {:ok, []}

      file ->
        with {:ok, source} <- Drive.read_object(file.object_id),
             {:ok, limits} <- Ankole.Pod.Config.applet_limits(),
             {:ok, routes} <- Ankole.FunctionRuntime.AppletClient.inspect(source, limits, env) do
          {:ok, routes}
        else
          {:error, %{"code" => "applet_busy"}} ->
            {:error, :applet_busy}

          {:error, %{"message" => message}} ->
            {:error, {:invalid_applet_routes, %{reason: message}}}

          error ->
            error
        end
    end
  end

  defp validate_environment(_page_id, upserts) do
    case Enum.find(upserts, &(&1.path == "applet.env.json")) do
      nil ->
        {:ok, %{}}

      file ->
        with {:ok, bytes} <- Drive.read_object(file.object_id),
             true <- byte_size(bytes) <= 65_536,
             {:ok, env} when is_map(env) <- Torque.decode(bytes),
             true <- Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end),
             do: {:ok, env},
             else: (_ -> {:error, :invalid_manifest})
    end
  end

  def required_upload_action("attachment"), do: "node_contribute"
  def required_upload_action(_role), do: "node_edit"

  # An object ID names bytes, not authority. The publication must reference a
  # current asset of this Applet or an explicit path on the executing Agent's Drive.
  defp own_publish_contents(%Ankole.AuthZ.Actor{} = actor, page_id, upserts) do
    with {:ok, files} <- all_files(page_id) do
      current = MapSet.new(files, & &1.object_id)

      if Enum.all?(upserts, fn file ->
           MapSet.member?(current, file.object_id) or
             case Drive.fetch(actor, file.source_path) do
               {:ok, %{object_id: id}} -> id == file.object_id
               _ -> false
             end
         end), do: :ok, else: {:error, :unavailable_content}
    end
  end

  defp allowed_role(%{type: :file}, "file"), do: :ok
  defp allowed_role(%{type: :doc}, "asset"), do: :ok
  defp allowed_role(%{type: :base}, "attachment"), do: :ok
  defp allowed_role(_page, _role), do: {:error, :invalid_file_role}
  defp require_type(%{type: type}, type), do: :ok
  defp require_type(_page, _type), do: {:error, :invalid_page_type}

  defp file_object(%{type: :file, object_id: id}, id), do: :ok
  defp file_object(%{type: :file}, _expected), do: {:error, :manifest_changed}
  defp file_object(_page, _expected), do: :ok
  defp revision(%{revision: revision}, revision), do: :ok
  defp revision(%{revision: revision}, _expected), do: {:error, {:revision_conflict, revision}}

  defp advance(page),
    do:
      Ankole.Pod.Pages.update_properties_in_tx(page, :advance_revision, %{
        updated_at: DateTime.utc_now()
      })

  defp upload_path(_id, "file", _digest, name), do: Drive.normalize_path(Drive.file_name(name))

  defp upload_path(_id, "asset", digest, name),
    do: Drive.normalize_path("assets/" <> hex(digest) <> "/" <> Drive.file_name(name))

  defp upload_path(_id, "attachment", digest, name),
    do: Drive.normalize_path("attachments/" <> hex(digest) <> "/" <> Drive.file_name(name))

  defp page_path(id, relative) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, relative} <- Drive.normalize_existing_path(relative),
         do: {:ok, prefix(id) <> "/" <> relative}
  end

  def prefix(id), do: "pages/" <> id
  defp hex(<<digest::binary-size(32)>>), do: Base.encode16(digest, case: :lower)
  defp hex(<<digest::binary-size(64)>>), do: String.downcase(digest)
  defp hex(_digest), do: nil
  defp check_digest(_file, nil), do: :ok

  defp check_digest(file, digest),
    do: if(hex(file.sha256) == digest, do: :ok, else: {:error, :manifest_changed})

  defp all_files(page_id), do: list_files(page_id)

  @doc false
  def list_files(node_id, prefix \\ "") do
    case if(node_id, do: Drive.fetch_node(node_id), else: {:ok, nil}) do
      {:ok, %{kind: :file, object_id: nil}} ->
        {:ok, []}

      {:ok, %{kind: :file} = node} ->
        with {:ok, file} <- node_file(node), do: {:ok, [file]}

      {:ok, _} ->
        query =
          if is_nil(node_id),
            do: Ash.Query.filter(PodFile, is_nil(node_id)),
            else: Ash.Query.filter(PodFile, node_id == ^node_id)

        query = query |> Ash.Query.load([:sha256, :size]) |> Ash.Query.sort(path: :asc)

        with {:ok, files} <- Ankole.Ash.read(query),
             do:
               {:ok,
                Enum.filter(
                  files,
                  &(prefix == "" or &1.path == prefix or
                      String.starts_with?(&1.path, prefix <> "/"))
                )}

      error ->
        error
    end
  end

  @doc false
  def fetch_file(node_id, relative) do
    with {:ok, path} <- Drive.normalize_existing_path(relative),
         {:ok, files} <- list_files(node_id),
         file when not is_nil(file) <- Enum.find(files, &(&1.path == path)),
         do: {:ok, file},
         else: (
           {:error, _} = error -> error
           _ -> {:error, :not_found}
         )
  end

  defp node_file(node) do
    with {:ok, object} <- Drive.fetch_object(node.object_id) do
      {:ok,
       %{
         node_id: node.id,
         path: node.name,
         object_id: object.id,
         sha256: object.sha256,
         size: object.size,
         mode: node.mode,
         source: node.source,
         content_type: node.content_type || MIME.from_path(node.name),
         updated_at: node.updated_at
       }}
    end
  end

  @doc false
  def commit_files_in_tx(node_id, upserts, deletes \\ []) do
    unless Repo.in_transaction?(),
      do:
        raise(Ankole.Errors.Framework.TransactionRequired,
          operation: {__MODULE__, :commit_files_in_tx}
        )

    with {:ok, current} <- list_files(node_id),
         :ok <- remove_files(current, deletes) do
      Enum.reduce_while(upserts, {:ok, []}, fn attrs, {:ok, files} ->
        path = Ankole.Attrs.get(attrs, :path)
        stored = Ankole.Attrs.get(attrs, :object) || Ankole.Attrs.get(attrs, :object_id)

        with {:ok, path} <- Drive.normalize_path(path),
             {:ok, object} <- Drive.complete_object_in_tx(stored),
             {:ok, file} <-
               Ankole.Ash.create(PodFile, :commit_in_tx, %{
                 node_id: node_id,
                 path: path,
                 object_id: object.id,
                 source: Ankole.Attrs.get(attrs, :source, "pod"),
                 mode: Ankole.Attrs.get(attrs, :mode, 0o644),
                 content_type: Ankole.Attrs.get(attrs, :content_type) || MIME.from_path(path)
               }) do
          {:cont,
           {:ok,
            [
              Map.merge(Map.from_struct(file), %{sha256: object.sha256, size: object.size})
              | files
            ]}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, files} -> {:ok, %{files: Enum.reverse(files)}}
        error -> error
      end
    end
  end

  defp remove_files(files, prefixes) do
    files
    |> Enum.filter(fn file ->
      Enum.any?(prefixes, &(file.path == &1 or String.starts_with?(file.path, &1 <> "/")))
    end)
    |> Enum.reduce_while(:ok, fn file, :ok ->
      case Ankole.Ash.destroy(file, :remove) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp entry(file) do
    %{
      path: file.path,
      object_id: file.object_id,
      sha256: hex(file.sha256),
      size: file.size,
      content_type: file.content_type
    }
  end
end
