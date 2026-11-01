defmodule Ankole.Files.Paths do
  @moduledoc "Resolves Agent runtime paths against their private Drive nodes."

  require Ash.Query

  alias Ankole.AuthZ.Actor
  alias Ankole.Files.{Access, Nodes, NodeContents, Objects}
  alias Ankole.Files.Schemas.Node
  alias Ankole.{Files, Repo}

  @default_limit 1000
  @max_limit 5000

  def fetch(uid, path) do
    with {:ok, path} <- Files.normalize_existing_path(path),
         {:ok, root} <- private_root(uid),
         {:ok, node} <- resolve(root, path),
         {:ok, _} <- Nodes.authorize(uid, node.id, "node_view") do
      project(node, path)
    end
  end

  def fetch_many(uid, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, files} ->
      case fetch(uid, path) do
        {:ok, file} -> {:cont, {:ok, [file | files]}}
        {:error, :not_found} -> {:cont, {:ok, files}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  def list_under_prefixes(uid, prefixes) do
    with {:ok, root} <- private_root(uid),
         {:ok, files} <- authorized_rows(uid, root.id, "", []) do
      {:ok,
       Enum.filter(files, fn row ->
         Enum.any?(prefixes, &(row.path == &1 or String.starts_with?(row.path, &1 <> "/")))
       end)}
    else
      {:error, :not_found} -> {:ok, []}
      error -> error
    end
  end

  def read(uid, path) do
    with {:ok, file} <- fetch(uid, path), {:ok, bytes} <- read_bytes(file), do: {:ok, file, bytes}
  end

  defp read_bytes(%{kind: :file, object_id: nil}), do: {:ok, ""}
  defp read_bytes(%{kind: :file, object_id: id}), do: Objects.read(id)
  defp read_bytes(_), do: {:error, :not_a_file}

  def read_to_file(uid, path, local_path) do
    with {:ok, file} <- fetch(uid, path), :ok <- copy_bytes(file, local_path), do: {:ok, file}
  end

  defp copy_bytes(%{kind: :file, object_id: nil}, path), do: File.write(path, "")
  defp copy_bytes(%{kind: :file, object_id: id}, path), do: Objects.read_to_file(id, path)
  defp copy_bytes(_, _), do: {:error, :not_a_file}

  def list(uid, prefix \\ "", opts \\ []) do
    if Keyword.get(opts, :snapshot, false),
      do: Repo.transact_top_level(fn -> list_snapshot_in_tx(uid, prefix, opts) end),
      else: list_page(uid, prefix, opts)
  end

  defp list_page(uid, prefix, opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@max_limit)

    with {:ok, root} <- private_root(uid),
         {:ok, files} <-
           authorized_rows(uid, root.id, prefix, Keyword.put(opts, :limit, limit + 1)) do
      page = Enum.take(files, limit)
      next_after = if length(files) > limit, do: List.last(page).path
      {:ok, %{files: page, next_after: next_after}}
    else
      {:error, :not_found} -> {:ok, %{files: [], next_after: nil}}
      error -> error
    end
  end

  def list_snapshot_in_tx(uid, prefix, opts) do
    with :ok <- lock_drive(uid),
         {:ok, files} <- snapshot_rows(uid, prefix) do
      manifest = Enum.map(files, &{&1.path, &1.object_id, &1.mode})

      revision =
        :crypto.hash(:sha256, :erlang.term_to_binary(manifest)) |> Base.encode16(case: :lower)

      limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@max_limit)
      cursor = Keyword.get(opts, :after)
      remaining = if cursor, do: Enum.drop_while(files, &(&1.path <= cursor)), else: files
      page = Enum.take(remaining, limit)
      next_after = if length(remaining) > limit, do: List.last(page).path

      {:ok, %{files: page, next_after: next_after, revision: revision}}
    end
  end

  defp snapshot_rows(uid, prefix) do
    with {:ok, root} <- private_root(uid),
         {:ok, files} <- authorized_rows(uid, root.id, prefix, []) do
      {:ok, files}
    else
      {:error, :not_found} -> {:ok, []}
      error -> error
    end
  end

  def commit(uid, upserts, deletes \\ []),
    do:
      Repo.transact_top_level(fn -> commit_in_tx(uid, upserts, deletes) end,
        after_commit: fn result ->
          Access.broadcast_change()
          Enum.each(result.files, &Nodes.content_committed/1)
        end
      )

  def commit_in_tx(uid, upserts, deletes \\ []) do
    with {:ok, actor} <- NodeContents.actor(uid),
         {:ok, root, topology?} <-
           root_for_commit(Actor.uid(actor), upserts, deletes),
         :ok <- lock_root(root.id),
         :ok <- validate_content_paths(root, upserts, topology?),
         :ok <- Ankole.AuthZ.authorize_turn_in_tx(actor.turn_authority),
         {:ok, deleted} <- delete_paths(actor, root, deletes),
         {:ok, files} <- put_paths(actor, root, upserts) do
      {:ok, %{files: files, deleted: deleted}}
    end
  end

  defp root_for_commit(uid, upserts, deletes) do
    case private_root(uid) do
      {:ok, root} ->
        topology? =
          deletes != [] or
            Enum.any?(upserts, fn attrs ->
              match?({:error, :not_found}, resolve(root, Ankole.Attrs.get(attrs, :path)))
            end)

        if topology?, do: Nodes.lock_tree()

        {:ok, root, topology?}

      {:error, :not_found} ->
        with {:ok, root} <- Nodes.ensure_private_root_in_tx(uid), do: {:ok, root, true}

      error ->
        error
    end
  end

  defp validate_content_paths(_root, _upserts, true), do: :ok

  defp validate_content_paths(root, upserts, false) do
    # A rename/delete may finish between the optimistic lookup and our root
    # lock. Do not turn an overwrite into a create while holding higher locks.
    if Enum.all?(upserts, fn attrs ->
         match?({:ok, _}, resolve(root, Ankole.Attrs.get(attrs, :path)))
       end), do: :ok, else: {:error, :path_changed}
  end

  defp put_paths(actor, root, upserts) do
    upserts
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, files} ->
      case put_path(actor, root, attrs) do
        {:ok, file} -> {:cont, {:ok, [file | files]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp put_path(actor, root, attrs) do
    path = Ankole.Attrs.get(attrs, :path)

    with {:ok, path} <- Files.normalize_path(path),
         {:ok, node} <- file_for_write(actor, root, path, attrs),
         {:ok, file} <- NodeContents.commit_in_tx(actor, node.id, attrs),
         {:ok, node} <- Ankole.Ash.update(node, :update_in_tx, metadata(attrs, path)) do
      {:ok,
       %{file | path: path, content_type: node.content_type, mode: node.mode, source: node.source}}
    end
  end

  defp file_for_write(actor, root, path, attrs) do
    case resolve(root, path) do
      {:ok, %{kind: :file} = node} ->
        {:ok, node}

      {:ok, _} ->
        {:error, :is_a_directory}

      {:error, :not_found} ->
        segments = String.split(path, "/")

        with {:ok, parent} <- ensure_folders(actor, root, Enum.drop(segments, -1)),
             {:ok, _} <- Nodes.authorize(actor, parent.id, Nodes.child_create_action(parent)) do
          attrs =
            metadata(attrs, path)
            |> Map.merge(%{
              parent_id: parent.id,
              name: List.last(segments),
              kind: :file,
              created_by: Ankole.ActorRef.from_actor(actor)
            })

          Nodes.create_in_tx(attrs)
        end

      error ->
        error
    end
  end

  defp ensure_folders(_actor, parent, []), do: {:ok, parent}

  defp ensure_folders(actor, parent, [name | rest]) do
    result =
      case child(parent.id, name) do
        {:ok, %{kind: :file}} ->
          {:error, :not_a_directory}

        {:ok, node} ->
          {:ok, node}

        {:error, :not_found} ->
          with {:ok, _} <- Nodes.authorize(actor, parent.id, Nodes.child_create_action(parent)) do
            Nodes.create_in_tx(%{
              parent_id: parent.id,
              name: name,
              kind: :folder,
              mode: 0o755,
              created_by: Ankole.ActorRef.from_actor(actor)
            })
          end

        error ->
          error
      end

    with {:ok, folder} <- result, do: ensure_folders(actor, folder, rest)
  end

  defp metadata(attrs, path) do
    %{
      mode: Ankole.Attrs.get(attrs, :mode) || 0o644,
      source: Ankole.Attrs.get(attrs, :source) || "agent",
      content_type: Ankole.Attrs.get(attrs, :content_type) || MIME.from_path(path),
      message_id: Ankole.Attrs.get(attrs, :message_id),
      source_conversation_id: Ankole.Attrs.get(attrs, :conversation_id)
    }
  end

  defp delete_paths(actor, root, paths) do
    Enum.reduce_while(paths, {:ok, 0}, fn path, {:ok, count} ->
      case delete_path(actor, root, path) do
        {:ok, deleted} -> {:cont, {:ok, count + deleted}}
        error -> {:halt, error}
      end
    end)
  end

  def delete(uid, path),
    do:
      Repo.transact_top_level(fn -> delete_in_tx(uid, path) end,
        after_commit: fn _ -> Access.broadcast_change() end
      )

  def delete_in_tx(uid, path) do
    Nodes.lock_tree()

    with {:ok, actor} <- NodeContents.actor(uid),
         {:ok, root} <- private_root(uid),
         :ok <- lock_root(root.id),
         do: delete_path(actor, root, path)
  end

  defp delete_path(actor, root, path) do
    with {:ok, path} <- Files.normalize_existing_path(path) do
      case resolve(root, path) do
        {:ok, node} ->
          ids = Nodes.descendants(node.id)

          count =
            Node
            |> Ash.Query.filter(id in ^ids and kind == :file and is_nil(deleted_at))
            |> Ankole.Ash.read!()
            |> length()

          with {:ok, _} <- Nodes.trash_in_tx(actor, node.id), do: {:ok, count}

        {:error, :not_found} ->
          {:ok, 0}

        error ->
          error
      end
    end
  end

  def move(uid, from, to),
    do:
      Repo.transact_top_level(fn -> move_in_tx(uid, from, to) end,
        after_commit: fn _ -> Access.broadcast_change() end
      )

  def move_in_tx(uid, from, to) do
    Nodes.lock_tree()

    with {:ok, from} <- Files.normalize_existing_path(from),
         {:ok, to} <- Files.normalize_path(to),
         {:ok, actor} <- NodeContents.actor(uid),
         {:ok, root} <- private_root(uid),
         :ok <- lock_root(root.id),
         {:ok, node} <- resolve(root, from),
         {:ok, parent} <- ensure_folders(actor, root, Enum.drop(String.split(to, "/"), -1)),
         {:ok, _} <-
           Nodes.move_in_tx(actor, node.id, %{parent_id: parent.id, name: Path.basename(to)}) do
      {:ok, 1}
    end
  end

  defp private_root(%Actor{} = actor), do: Nodes.private_root(Actor.uid(actor))
  defp private_root(uid), do: Nodes.private_root(uid)

  def lock_drive(uid) do
    case private_root(uid) do
      {:ok, root} -> lock_root(root.id)
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  def lock_root(id) do
    Ankole.AdvisoryLock.lock!(Repo, "drive-root:#{id}")
    :ok
  end

  def resolve(root, ""), do: {:ok, root}

  def resolve(root, path) do
    with {:ok, path} <- Files.normalize_existing_path(path) do
      Enum.reduce_while(String.split(path, "/"), {:ok, root}, fn name, {:ok, parent} ->
        case child(parent.id, name) do
          {:ok, node} -> {:cont, {:ok, node}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp child(parent_id, name) do
    case Node
         |> Ash.Query.filter(parent_id == ^parent_id and name == ^name and is_nil(deleted_at))
         |> Ankole.Ash.read_one() do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end

  def project(%{object_id: nil} = node, path),
    do: {:ok, project(node, %{sha256: nil, size: 0}, path)}

  def project(node, path) do
    with {:ok, object} <- Objects.fetch(node.object_id), do: {:ok, project(node, object, path)}
  end

  def project(node, object, path) do
    node
    |> Map.from_struct()
    |> Map.merge(%{
      node_id: node.id,
      path: path,
      sha256: object.sha256,
      size: object.size,
      content_type: node.content_type || MIME.from_path(node.name)
    })
  end

  defp authorized_rows(uid, root_id, prefix, opts) do
    with {:ok, actor} <- NodeContents.actor(uid),
         {:ok, _} <- Nodes.authorize(actor, root_id, "node_view"),
         {:ok, prefix} <- normalize_prefix(prefix),
         {:ok, reachable} <- Access.reachable_anchors(actor) do
      {containers, own} = Access.visibility_ids(reachable)
      {:ok, rows(root_id, prefix, opts, containers, own)}
    end
  end

  defp normalize_prefix(""), do: {:ok, ""}
  defp normalize_prefix(prefix), do: Files.normalize_path(prefix)

  defp rows(root_id, prefix, opts, containers, own) do
    %{columns: columns, rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE subtree AS (
          SELECT n.*, n.name::text AS path FROM drive_nodes n
          WHERE n.tenant_id = $1::text::uuid AND n.parent_id = $2::text::uuid AND n.deleted_at IS NULL
          UNION ALL
          SELECT n.*, (s.path || '/' || n.name)::text FROM drive_nodes n JOIN subtree s ON n.parent_id = s.id
          WHERE n.tenant_id = $1::text::uuid AND n.deleted_at IS NULL
        )
        SELECT n.id::text, n.id::text AS node_id, n.object_id::text, n.name, n.path,
          object.sha256, COALESCE(object.size, 0) AS size, n.mode,
          COALESCE(n.content_type, 'application/octet-stream') AS content_type,
          n.source, n.source_conversation_id::text AS conversation_id, n.message_id::text, n.updated_at
        FROM subtree n LEFT JOIN file_objects object ON object.tenant_id = n.tenant_id AND object.id = n.object_id
        WHERE n.kind = 'file'
          AND ($3 = '' OR n.path = $3 OR left(n.path, length($3) + 1) = $3 || '/')
          AND ($4::text IS NULL OR n.path > $4)
          AND ((NOT n.is_acl_anchor AND n.acl_anchor_id = ANY($6::text[]::uuid[]))
            OR (n.is_acl_anchor AND n.id = ANY($7::text[]::uuid[])))
        ORDER BY n.path LIMIT $5
        """,
        [
          Repo.tenant_id!(),
          root_id,
          prefix,
          Keyword.get(opts, :after),
          Keyword.get(opts, :limit),
          containers,
          own
        ]
      )

    keys = Enum.map(columns, &String.to_existing_atom/1)
    Enum.map(rows, &Map.new(Enum.zip(keys, &1)))
  end
end
