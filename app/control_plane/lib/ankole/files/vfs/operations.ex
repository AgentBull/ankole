defmodule Ankole.Files.Vfs.Operations do
  @moduledoc "Composes WebDAV changes with the Drive and Pod transaction owners."
  alias Ankole.{Files, Kernel, Repo}
  alias Ankole.Files.{Access, Nodes}
  alias Ankole.Files.Vfs.{Content, Namespace}

  def propfind(scope, path, depth) do
    result =
      Repo.transact_top_level(fn ->
        with {:ok, entry} <- Namespace.resolve(scope, path),
             {:ok, children} <-
               if(depth == 1 && Namespace.collection?(entry),
                 do: Namespace.children(scope, entry),
                 else: {:ok, []}
               ),
             {:ok, stats} <- Content.stats([entry | children]),
             do: {:ok, stats}
      end)

    case result do
      {:ok, [entry | rest]} ->
        with {:ok, entry} <- Ankole.Files.Vfs.Exports.materialize(scope, entry),
             do: {:ok, [entry | rest]}

      error ->
        error
    end
  end

  def read(scope, path, expected) do
    result =
      Repo.transact_top_level(fn ->
        with {:ok, entry} <- Namespace.resolve(scope, path),
             :ok <- lock_read(entry),
             {:ok, meta} <- Content.stat(entry),
             :ok <- if(Map.has_key?(meta, :export), do: :ok, else: matches(expected, meta.etag)),
             {:ok, content} <- Content.read(meta),
             do: {:ok, {meta, content}}
      end)

    case result do
      {:ok, {%{export: _} = meta, _}} ->
        with {:ok, meta} <- Ankole.Files.Vfs.Exports.materialize(scope, meta),
             :ok <- matches(expected, meta.etag),
             do: {:ok, {meta, meta.content}}

      result ->
        result
    end
  end

  def put(scope, path, local_path, headers) do
    case Repo.transact_top_level(fn -> Namespace.resolve(scope, path) end) do
      {:ok, %{base_write: _} = entry} ->
        with :ok <- Ankole.Files.Vfs.Base.write(scope, entry, local_path, headers),
             {:ok, [meta]} <- propfind(scope, path, 0),
             do: {:ok, meta}

      {:ok, %{kind: kind}} when kind in [:virtual_file, :virtual_directory] ->
        {:error, :forbidden}

      error ->
        if virtual_path?(path),
          do: if(match?({:error, :not_found}, error), do: {:error, :forbidden}, else: error),
          else: put_node(scope, path, local_path, headers)
    end
  end

  defp virtual_path?(path),
    do:
      path
      |> Enum.drop(-1)
      |> Enum.any?(&(String.ends_with?(&1, "._abase") || String.ends_with?(&1, "._aapp")))

  defp put_node(scope, path, local_path, headers) do
    with {:ok, prepared} <- prepare(scope, path, local_path, headers) do
      topology? = match?({:error, :not_found}, Namespace.resolve(scope, path))

      write(scope, [path], topology?, fn scope ->
        case Namespace.resolve(scope, path) do
          {:ok, %{node: nil}} ->
            {:error, :forbidden}

          {:ok, entry} ->
            replace_target_in_tx(scope, entry, prepared, headers)

          {:error, :not_found} ->
            create_file_in_tx(scope, path, prepared, headers)

          error ->
            error
        end
      end)
    end
  end

  defp create_file_in_tx(scope, path, prepared, headers) do
    if headers["if-match"] do
      {:error, :precondition_failed}
    else
      with {:ok, node} <- create_exact_in_tx(scope, path, :file, prepared),
           do: receipt_in_tx(node, headers)
    end
  end

  def mkdir(scope, path) do
    write(scope, [path], true, fn scope -> create_exact_in_tx(scope, path, :folder, nil) end)
  end

  def delete(scope, path, headers) do
    write(scope, [path], true, fn scope ->
      with {:ok, %{node: node, kind: kind} = entry}
           when not is_nil(node) and kind not in [:virtual_file, :virtual_directory] <-
             Namespace.resolve(scope, path),
           {:ok, _} <- Namespace.authorize(scope, node, Nodes.deletion_action(node)),
           {:ok, _} <- Nodes.lock(node.id),
           {:ok, meta} <- Content.stat(entry),
           :ok <- matches(headers["if-match"], meta.etag),
           {:ok, deleted} <- Nodes.trash_in_tx(scope.actor, node.id),
           do: {:ok, deleted},
           else: (
             {:ok, _} -> {:error, :forbidden}
             error -> error
           )
    end)
  end

  def move(scope, source, destination, headers) do
    with {:ok, %{node: source_node, kind: kind}}
         when not is_nil(source_node) and kind not in [:virtual_file, :virtual_directory] <-
           Namespace.resolve(scope, source),
         {:ok, prepared} <- prepare_move(scope, source_node, destination) do
      write(scope, [source, destination], true, fn scope ->
        with {:ok, %{node: node} = source_entry} <- Namespace.resolve(scope, source),
             true <- node.object_id == source_node.object_id,
             {:ok, _} <- Namespace.authorize(scope, node, "node_edit") do
          move_target_in_tx(scope, source_entry, destination, prepared, headers)
        else
          false -> {:error, :precondition_failed}
          error -> error
        end
      end)
    else
      {:ok, _} -> {:error, :forbidden}
      {:error, :not_found} -> replay_move(scope, destination, headers)
      error -> error
    end
  end

  defp replay_move(scope, destination, headers) do
    write(scope, [destination], false, fn scope ->
      with {:ok, %{node: node} = entry} when not is_nil(node) <-
             Namespace.resolve(scope, destination),
           {:ok, _} <- Namespace.authorize(scope, node, "node_edit"),
           {:ok, node} <- Nodes.lock(node.id),
           true <-
             not is_nil(headers["x-ankole-request-id"]) and
               node.last_vfs_req_id == headers["x-ankole-request-id"],
           {:ok, meta} <- Content.stat(%{entry | node: node}),
           do:
             {:ok,
              node
              |> Map.put(:vfs_meta, meta)
              |> Map.put(:vfs_refresh_body, node.last_vfs_etag != meta.etag)},
           else: (_ -> {:error, :not_found})
    end)
  end

  defp move_target_in_tx(scope, %{node: node} = source_entry, destination, prepared, headers) do
    case Namespace.resolve(scope, destination) do
      {:ok, %{node: %{id: id}}} when id == node.id ->
        {:ok, node}

      {:ok, %{node: nil}} ->
        {:error, :forbidden}

      {:ok, target} ->
        if headers["overwrite"] == "F" do
          {:error, :precondition_failed}
        else
          overwrite_move_in_tx(scope, node, target, prepared, headers)
        end

      {:error, :not_found} ->
        with {:ok, _} <- Nodes.lock(node.id),
             {:ok, meta} <- Content.stat(source_entry),
             :ok <- matches(headers["if-match"], meta.etag),
             {:ok, parent, name, kind} <- destination(scope, destination, source_entry.kind),
             true <- kind == source_entry.kind,
             {:ok, moved} <-
               Nodes.move_in_tx(scope.actor, node.id, %{parent_id: parent.id, name: name},
                 exact_name: true
               ),
             do: receipt_in_tx(moved, headers),
             else: (
               false -> {:error, :invalid_kind}
               error -> error
             )

      error ->
        error
    end
  end

  defp overwrite_move_in_tx(scope, %{kind: :file} = source, target, prepared, headers) do
    with false <- Namespace.collection?(target),
         {:ok, result} <- replace_target_in_tx(scope, target, prepared, headers),
         {:ok, _} <- Nodes.consume_file_in_tx(scope.actor, source.id),
         do: {:ok, result},
         else: (
           true -> {:error, :precondition_failed}
           error -> error
         )
  end

  defp overwrite_move_in_tx(scope, source, %{node: target}, _prepared, headers)
       when source.kind == target.kind and
              source.kind in [:doc, :knowledge, :base, :applet, :folder] do
    with {:ok, _} <- Namespace.authorize(scope, target, "node_manage"),
         {:ok, meta} <- Content.stat(Namespace.entry(target, target.kind)),
         :ok <- matches(headers["if-match"], meta.etag),
         {:ok, _} <- Nodes.trash_in_tx(scope.actor, target.id),
         {:ok, moved} <-
           Nodes.move_in_tx(
             scope.actor,
             source.id,
             %{parent_id: target.parent_id, name: target.name},
             exact_name: true
           ),
         do: receipt_in_tx(moved, headers)
  end

  defp overwrite_move_in_tx(_, _, _, _, _), do: {:error, :precondition_failed}

  def copy(scope, source, destination, headers) do
    write(scope, [source, destination], true, fn scope ->
      with {:ok, %{kind: :file, node: source_node} = entry} <- Namespace.resolve(scope, source),
           {:ok, meta} <- Content.stat(entry),
           :ok <- matches(headers["x-ankole-expected-etag"], meta.etag) do
        prepared = %{stored: source_node.object_id, content_type: source_node.content_type}

        case Namespace.resolve(scope, destination) do
          {:ok, %{kind: :file} = target} ->
            if headers["overwrite"] == "F",
              do: {:error, :precondition_failed},
              else: replace_target_in_tx(scope, target, prepared, headers)

          {:error, :not_found} ->
            with {:ok, _, _, :file} <- destination(scope, destination, :file),
                 do: create_file_in_tx(scope, destination, prepared, headers),
                 else: (_ -> {:error, :precondition_failed})

          {:ok, _} ->
            {:error, :precondition_failed}

          error ->
            error
        end
      else
        {:ok, _} -> {:error, :precondition_failed}
        error -> error
      end
    end)
  end

  def create_exact_in_tx(scope, path, requested_kind, prepared) do
    with {:ok, parent, name, kind} <- destination(scope, path, requested_kind),
         {:ok, _} <- Namespace.authorize(scope, parent, Nodes.child_create_action(parent)),
         {:error, :not_found} <- Nodes.child(parent.id, name) do
      case kind do
        kind when kind in [:file, :folder] ->
          attrs = %{
            parent_id: parent.id,
            name: name,
            kind: kind,
            created_by: Ankole.ActorRef.from_actor(scope.actor)
          }

          with {:ok, node} <- Nodes.create_in_tx(attrs, exact_name: true),
               do: bind_created_in_tx(scope, node, prepared)

        kind when kind in [:doc, :knowledge] and not is_nil(prepared) ->
          with {:ok, page} <- Content.create_in_tx(scope, parent, name, kind, prepared),
               do: Nodes.fetch(page.id)

        _ ->
          {:error, :forbidden}
      end
    else
      {:ok, _} -> {:error, :name_conflict}
      error -> error
    end
  end

  defp bind_created_in_tx(scope, %{kind: :file} = node, prepared) do
    with {:ok, _} <- Content.replace_in_tx(scope, node, prepared), do: Nodes.fetch(node.id)
  end

  defp bind_created_in_tx(_scope, node, _prepared), do: {:ok, node}

  def replace_target_in_tx(scope, %{node: node, kind: kind} = entry, prepared, headers)
      when kind in [:file, :doc, :knowledge] do
    with {:ok, _} <- Namespace.authorize(scope, node, "node_edit"),
         {:ok, current} <- Nodes.lock(node.id),
         {:ok, meta} <- Content.stat(%{entry | node: current}) do
      cond do
        headers["x-ankole-request-id"] &&
            current.last_vfs_req_id == headers["x-ankole-request-id"] ->
          {:ok,
           current
           |> Map.put(:vfs_meta, meta)
           |> Map.put(:vfs_refresh_body, current.last_vfs_etag != meta.etag)}

        headers["if-none-match"] == "*" ->
          {:error, :precondition_failed}

        true ->
          with {:ok, refresh?} <-
                 Content.replace_version_in_tx(
                   scope,
                   current,
                   prepared,
                   headers["if-match"],
                   meta.etag
                 ),
               {:ok, updated} <- Nodes.fetch(current.id),
               {:ok, updated} <- receipt_in_tx(updated, headers),
               do: {:ok, Map.put(updated, :vfs_refresh_body, refresh?)}
      end
    end
  end

  def replace_target_in_tx(_, _, _, _), do: {:error, :is_a_directory}

  defp receipt_in_tx(node, headers) do
    with {:ok, meta} <- Content.stat(Namespace.entry(node, node.kind)),
         {:ok, node} <-
           if(request = headers["x-ankole-request-id"],
             do:
               Nodes.update_in_tx(node, :vfs_receipt, %{
                 last_vfs_req_id: request,
                 last_vfs_etag: meta.etag
               }),
             else: {:ok, node}
           ),
         do: {:ok, Map.put(node, :vfs_meta, meta)}
  end

  defp destination(scope, path, requested_kind) do
    with false <- path == [],
         {:ok, parent} <- Namespace.resolve(scope, Enum.drop(path, -1)),
         true <- parent.kind in [:folder, :children],
         {name, type} when is_binary(name) <- Kernel.vfs_decode_name(List.last(path)),
         :ok <- Nodes.valid_name(name) do
      kind = if type == "file", do: requested_kind, else: String.to_existing_atom(type)
      {:ok, parent.node, name, kind}
    else
      boolean when is_boolean(boolean) -> {:error, :not_a_directory}
      error -> error
    end
  end

  def upload_kind(scope, path) do
    case Namespace.resolve(scope, path) do
      {:ok, entry} ->
        entry.kind

      _ ->
        case Kernel.vfs_decode_name(List.last(path) || "") do
          {_, kind} when kind in ["doc", "knowledge"] -> String.to_existing_atom(kind)
          _ -> :file
        end
    end
  end

  defp prepare(_scope, path, {:stored, stored}, headers),
    do:
      {:ok,
       %{stored: stored, content_type: headers["content-type"] || MIME.from_path(List.last(path))}}

  defp prepare(scope, path, local_path, headers) do
    if upload_kind(scope, path) in [:doc, :knowledge] do
      with {:ok, bytes} <- File.read(local_path), do: {:ok, %{bytes: bytes}}
    else
      with {:ok, stored} <- Files.store({:file, local_path}),
           do: prepare(scope, path, {:stored, stored}, headers)
    end
  end

  defp prepare_move(scope, %{kind: :file} = source, destination) do
    case Namespace.resolve(scope, destination) do
      {:ok, %{kind: kind}} when kind in [:doc, :knowledge] ->
        with {:ok, bytes} <- Files.read_object(source.object_id), do: {:ok, %{bytes: bytes}}

      _ ->
        {:ok, %{stored: source.object_id}}
    end
  end

  defp prepare_move(_scope, _source, _destination), do: {:ok, nil}

  defp write(scope, paths, topology?, fun) do
    writer = if topology?, do: &Access.write_tree/3, else: &Access.write/3

    writer.(
      scope.actor.turn_authority,
      fn ->
        with {:ok, access} <- Ankole.Brain.Access.for_context(scope.context),
             do: fun.(%{scope | access: access})
      end,
      shared_tree: !topology?,
      root_ids: fn -> path_root_ids(scope, paths) end,
      after_commit: fn node ->
        if topology?, do: Nodes.committed(node), else: Nodes.content_committed(node)
      end
    )
  end

  defp path_root_ids(scope, paths) do
    roots = Namespace.roots(scope)

    paths
    |> Enum.flat_map(fn path ->
      case Enum.find(roots, &(&1.name == List.first(path))) do
        %{node: node} -> if node.private_owner_uid, do: [node.id], else: []
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp lock_read(%{node: %{kind: kind, id: id}}) when kind in [:doc, :knowledge] do
    with {:ok, _} <- Nodes.lock(id, :share), do: :ok
  end

  defp lock_read(_), do: :ok

  defp matches(nil, _etag), do: :ok
  defp matches(etag, etag), do: :ok
  defp matches("*", _etag), do: :ok
  defp matches(_, _), do: {:error, :precondition_failed}
end
