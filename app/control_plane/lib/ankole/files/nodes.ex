defmodule Ankole.Files.Nodes do
  @moduledoc "Owns Drive roots, tree changes and node lifecycle."
  require Ash.Query
  alias Ankole.{ActorRef, Repo}
  alias Ankole.AuthZ.Actor
  alias Ankole.Files.Access
  alias Ankole.Files.Schemas.Node

  @topology [
    :parent_id,
    :name,
    :inherit_permissions,
    :has_local_acl,
    :deleted_at,
    :purge_started_at
  ]

  def fetch(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Node{} = node <- Node |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!(),
         do: {:ok, node},
         else: (_ -> {:error, :not_found})
  end

  def path(%{parent_id: nil} = page), do: {:ok, [page]}

  def path(%{parent_id: parent_id} = page) do
    result =
      Repo.query!(
        """
        WITH RECURSIVE ancestors AS (
          SELECT p.id, p.name, p.parent_id, p.private_owner_uid, p.conversation_id, p.inherit_permissions, p.deleted_at, p.acl_anchor_id, p.is_acl_anchor
            FROM drive_nodes p WHERE p.tenant_id = $1::text::uuid AND p.id = $2::text::uuid
          UNION
          SELECT p.id, p.name, p.parent_id, p.private_owner_uid, p.conversation_id, p.inherit_permissions, p.deleted_at, p.acl_anchor_id, p.is_acl_anchor
            FROM drive_nodes p JOIN ancestors a ON p.id = a.parent_id
            WHERE p.tenant_id = $1::text::uuid
        ) SELECT id::text, name, parent_id::text, private_owner_uid, conversation_id::text, inherit_permissions, deleted_at, acl_anchor_id::text, is_acl_anchor
          FROM ancestors
        """,
        [Repo.tenant_id!(), parent_id]
      )

    parents =
      Map.new(result.rows, fn [
                                id,
                                name,
                                parent_id,
                                owner,
                                conversation,
                                inherit,
                                deleted_at,
                                anchor_id,
                                anchor
                              ] ->
        {id,
         %{
           id: id,
           name: name,
           parent_id: parent_id,
           private_owner_uid: owner,
           conversation_id: conversation,
           inherit_permissions: inherit,
           deleted_at: deleted_at,
           acl_anchor_id: anchor_id,
           is_acl_anchor: anchor
         }}
      end)

    path(page, parents, [], MapSet.new())
  end

  defp path(page, parents, descendants, seen) do
    cond do
      MapSet.member?(seen, page.id) ->
        {:error, :invalid_tree}

      is_nil(page.parent_id) ->
        {:ok, [page | descendants]}

      true ->
        case Map.get(parents, page.parent_id) do
          nil -> {:error, :not_found}
          parent -> path(parent, parents, [page | descendants], MapSet.put(seen, page.id))
        end
    end
  end

  def authorize(actor_or_uid, id, action, opts \\ []) do
    with {:ok, actor} <- actor(actor_or_uid),
         {:ok, node} <- fetch(id),
         do: Access.authorize(actor, node, action, opts)
  end

  defp actor(%Actor{} = actor), do: {:ok, actor}

  defp actor(uid) when is_binary(uid) do
    with {:ok, principal} <- Ankole.Principals.get_principal(uid), do: {:ok, Actor.new(principal)}
  end

  def list_children(parent_id) do
    Node
    |> Ash.Query.filter(parent_id == ^parent_id and is_nil(deleted_at))
    |> Ash.Query.sort(name: :asc, id: :asc)
    |> Ankole.Ash.read!()
  end

  def public_root do
    Node
    |> Ash.Query.filter(
      is_nil(parent_id) and is_nil(private_owner_uid) and is_nil(conversation_id)
    )
    |> root_result()
  end

  def private_root(uid),
    do: Node |> Ash.Query.filter(is_nil(parent_id) and private_owner_uid == ^uid) |> root_result()

  def conversation_root(id),
    do: Node |> Ash.Query.filter(is_nil(parent_id) and conversation_id == ^id) |> root_result()

  defp root_result(query) do
    case Ankole.Ash.read_one(query) do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end

  def root(id) do
    with {:ok, node} <- fetch(id), {:ok, path} <- path(node), do: {:ok, hd(path)}
  end

  def conversation_id(id) do
    with {:ok, root} <- root(id), do: {:ok, root.conversation_id}
  end

  def root_ids(ids) do
    ids
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn id ->
      case root(id) do
        {:ok, %{private_owner_uid: uid, id: root_id}} when not is_nil(uid) -> [root_id]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def root_ids_for_principal(uid) do
    case private_root(uid) do
      {:ok, root} -> [root.id]
      _ -> []
    end
  end

  def delete_private_root_in_tx(uid), do: delete_root_in_tx(fn -> private_root(uid) end)
  def delete_conversation_root_in_tx(id), do: delete_root_in_tx(fn -> conversation_root(id) end)

  defp delete_root_in_tx(read) do
    lock_tree()

    case read.() do
      {:ok, root} ->
        lock_roots(if root.private_owner_uid, do: [root.id], else: [])

        ids = descendants(root.id) |> Enum.sort()

        Enum.each(Enum.chunk_every(ids, 1000), fn batch ->
          Node
          |> Ash.Query.filter(id in ^batch)
          |> Ash.Query.sort(id: :asc)
          |> Ash.Query.lock(:for_update)
          |> Ankole.Ash.read!(lock_identity: {"drive_nodes", batch})
        end)

        with :ok <- Ankole.Files.ContentOwner.purge_nodes_in_tx(ids) do
          # A pass-through descendant can reference an ancestor several cascade
          # steps away. Validate these graph edges after the whole tree is gone,
          # before returning to the caller's transaction. Object FKs stay immediate.
          Repo.query!(
            "SET CONSTRAINTS drive_nodes_acl_anchor_fkey, drive_nodes_parent_anchor_fkey DEFERRED"
          )

          with {:ok, _} <- Ankole.Ash.destroy(root, :remove) do
            Repo.query!(
              "SET CONSTRAINTS drive_nodes_acl_anchor_fkey, drive_nodes_parent_anchor_fkey IMMEDIATE"
            )

            :ok
          end
        end

      {:error, :not_found} ->
        :ok

      error ->
        error
    end
  end

  def ensure_public_root_in_tx do
    ensure_root(&public_root/0, %{name: "Space"})
  end

  def ensure_private_root_in_tx(uid) do
    with {:ok, principal} <- Ankole.Principals.get_principal(uid),
         true <-
           principal.type == :agent or
             (principal.type == :human and principal.membership == :member),
         {:ok, root} <-
           ensure_root(fn -> private_root(uid) end, %{name: "Private", private_owner_uid: uid}),
         :ok <- Access.ensure_private(uid),
         do: {:ok, root},
         else: (
           false -> {:error, :forbidden}
           error -> error
         )
  end

  def ensure_conversation_root_in_tx(id),
    do: ensure_root(fn -> conversation_root(id) end, %{name: "Conversation", conversation_id: id})

  defp ensure_root(read, attrs) do
    lock_tree()

    case read.() do
      {:ok, root} ->
        {:ok, root}

      {:error, :not_found} ->
        id = Ankole.Ecto.UUIDv7.autogenerate()

        Ankole.Ash.create(
          Node,
          :create_in_tx,
          Map.merge(attrs, %{id: id, kind: :folder, acl_anchor_id: id, inherit_permissions: true})
        )

      error ->
        error
    end
  end

  def lock_tree(opts \\ []) do
    :ok = Repo.require_transaction()
    Ankole.AdvisoryLock.lock!(Repo, "drive-tree:" <> Repo.tenant_id!(), opts)
    :ok
  end

  def lock_roots(ids) do
    :ok = Repo.require_transaction()

    ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&Ankole.AdvisoryLock.lock!(Repo, "drive-root:" <> &1))

    :ok
  end

  def lock(id, mode \\ :update) when mode in [:update, :share] do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Node{} = node <-
           Node
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.lock(if(mode == :share, do: "FOR SHARE", else: :for_update))
           |> Ankole.Ash.read_one!(lock_identity: {"drive_nodes", id}),
         do: {:ok, node},
         else: (_ -> {:error, :not_found})
  end

  def create(%Actor{} = actor, attrs) do
    Access.write_tree(actor.turn_authority, fn -> create_authorized_in_tx(actor, attrs) end,
      root_ids: fn -> root_ids([Ankole.Attrs.get(attrs, :parent_id)]) end,
      after_commit: &committed/1
    )
  end

  def create_authorized_in_tx(%Actor{} = actor, attrs) do
    with true <- Ankole.Attrs.get(attrs, :kind) in [:folder, :file, "folder", "file"],
         {:ok, parent} <- fetch(Ankole.Attrs.get(attrs, :parent_id)),
         {:ok, _} <- authorize_child_create(actor, parent),
         do: create_in_tx(Map.put(attrs, :created_by, ActorRef.from_actor(actor))),
         else: (
           false -> {:error, :invalid_kind}
           error -> error
         )
  end

  def authorize_child_create(_actor, %{kind: :file}), do: {:error, :not_a_directory}

  def authorize_child_create(actor, parent),
    do: Access.authorize(actor, parent, child_create_action(parent))

  def child_create_action(%{parent_id: nil, conversation_id: nil}), do: "node_edit"
  def child_create_action(%{kind: :folder}), do: "node_contribute"
  def child_create_action(_parent), do: "node_edit"

  @doc "Creates a child for an already-authorized caller in its transaction."
  def create_in_tx(attrs) do
    lock_tree()
    attrs = atom_attrs(attrs)

    with {:ok, parent} <- fetch(attrs[:parent_id]),
         true <- parent.kind != :file,
         :ok <- live(parent),
         :ok <- valid_name(attrs[:name]) do
      lock_roots(root_ids([parent.id]))
      id = Map.get_lazy(attrs, :id, &Ankole.Ecto.UUIDv7.autogenerate/0)

      attrs =
        attrs
        |> Map.put(:id, id)
        |> Map.drop([:private_owner_uid, :conversation_id])
        |> Map.put(:name, available_name(parent.id, attrs.name))
        |> Access.anchor_attributes()

      Ankole.Ash.create(Node, :create_in_tx, attrs)
    else
      false -> {:error, :not_a_directory}
      error -> error
    end
  end

  @doc "Updates an already-authorized node. Object-only writes do not acquire the tree lock."
  def update_in_tx(node, action, attrs) do
    attrs = atom_attrs(attrs)
    if Enum.any?(@topology, &Map.has_key?(attrs, &1)), do: lock_tree()

    with {:ok, current} <- fetch(node.id) do
      # Permission bookkeeping does not edit the node's content or metadata.
      attrs =
        if action in [:anchor, :sharing],
          do: Map.delete(attrs, :updated_at),
          else: Map.put_new_lazy(attrs, :updated_at, fn -> DateTime.utc_now(:microsecond) end)

      Ankole.Ash.update(current, :update_in_tx, attrs)
    end
  end

  def rename(actor, id, name), do: move(actor, id, %{name: name})

  def move(%Actor{} = actor, id, attrs) do
    Access.write_tree(actor.turn_authority, fn -> move_in_tx(actor, id, attrs) end,
      root_ids: fn -> root_ids([id, Ankole.Attrs.get(attrs, :parent_id)]) end,
      after_commit: &committed/1
    )
  end

  def move_in_tx(actor, id, attrs) do
    lock_tree()

    with {:ok, node} <- lock(id),
         :ok <- mutable(node),
         {:ok, _} <- Access.authorize_move_source(actor, node),
         :ok <- authorize_name_edit(actor, node, attrs),
         parent_id = Ankole.Attrs.get(attrs, :parent_id, node.parent_id),
         {:ok, parent} <- fetch(parent_id),
         :ok <- live(parent),
         :ok <- move_destination(actor, node, parent),
         :ok <- no_cycle(node.id, parent),
         {:ok, _} <- Access.authorize_move(actor, node, parent.id, nil),
         name_supplied? = Ankole.Attrs.get(attrs, :name, :missing) != :missing,
         name = Ankole.Attrs.get(attrs, :name, node.name),
         :ok <- if(name_supplied?, do: valid_name(name), else: :ok) do
      name = available_name(parent.id, name, node.id)

      with {:ok, moved} <-
             Access.update_anchor_in_tx(node, :move, %{
               parent_id: parent.id,
               name: name,
               updated_at: DateTime.utc_now(:microsecond)
             }),
           :ok <- sync_content_name(actor, node, moved, attrs),
           do: {:ok, moved}
    end
  end

  defp authorize_name_edit(actor, node, attrs) do
    case Ankole.Attrs.get(attrs, :name, node.name) do
      name when name == node.name -> :ok
      _ -> with {:ok, _} <- Access.authorize(actor, node, "node_edit"), do: :ok
    end
  end

  defp sync_content_name(actor, old, moved, attrs) do
    if Ankole.Attrs.get(attrs, :name, :missing) != :missing and old.name != moved.name,
      do: Ankole.Files.ContentOwner.rename_node_in_tx(old, moved, actor),
      else: :ok
  end

  defp move_destination(_actor, %{parent_id: id}, %{id: id}), do: :ok

  defp move_destination(actor, _node, parent) do
    with {:ok, _} <- authorize_child_create(actor, parent), do: :ok
  end

  def trash(%Actor{} = actor, id) do
    Access.write_tree(actor.turn_authority, fn -> trash_in_tx(actor, id) end,
      root_ids: fn -> root_ids([id]) end,
      after_commit: &committed/1
    )
  end

  def trash_in_tx(actor, id) do
    lock_tree()

    with {:ok, node} <- lock(id),
         :ok <- mutable(node),
         {:ok, _} <- Access.authorize(actor, node, deletion_action(node)),
         {:ok, node} <-
           Access.update_anchor_in_tx(node, :trash, %{deleted_at: DateTime.utc_now(:microsecond)}),
         :ok <- schedule_purge(node),
         do: {:ok, node}
  end

  defp deletion_action(%{kind: kind}) when kind in [:file, :folder], do: "node_edit"
  defp deletion_action(_node), do: "node_manage"

  def restore(%Actor{} = actor, id) do
    Access.write_tree(actor.turn_authority, fn -> restore_in_tx(actor, id) end,
      root_ids: fn -> root_ids([id]) end,
      after_commit: &committed/1
    )
  end

  def restore_in_tx(actor, id) do
    lock_tree()

    with {:ok, node} <- lock(id),
         :ok <- mutable(node),
         {:ok, _} <- Access.authorize(actor, node, "node_manage", trash: true),
         true <- not is_nil(node.deleted_at) and is_nil(node.purge_started_at),
         {:ok, parent} <- fetch(node.parent_id),
         :ok <- live(parent) do
      Access.update_anchor_in_tx(node, :restore, %{
        deleted_at: nil,
        name: available_name(parent.id, node.name, node.id)
      })
    else
      false -> {:error, :cannot_restore}
      error -> error
    end
  end

  def purge(%Actor{} = actor, id) do
    Access.write_tree(actor.turn_authority, fn -> purge_in_tx(actor, id) end,
      root_ids: fn -> root_ids([id]) end,
      after_commit: &committed/1
    )
  end

  def purge_in_tx(actor, id) do
    lock_tree()

    with {:ok, node} <- lock(id),
         :ok <- mutable(node),
         {:ok, _} <- Access.authorize(actor, node, "node_manage", trash: :self),
         true <- not is_nil(node.deleted_at) and is_nil(node.purge_started_at),
         {:ok, node} <-
           update_in_tx(node, :begin_purge, %{purge_started_at: DateTime.utc_now(:microsecond)}),
         :ok <- schedule_purge(node, DateTime.utc_now(:microsecond)),
         do: {:ok, node},
         else: (
           false -> {:error, :cannot_purge}
           error -> error
         )
  end

  def schedule_purge(node, at \\ nil) do
    with {:ok, days} <- Ankole.AppConfigure.get_tenant_by_key_in_tx("drive.trash_retention_days") do
      Ankole.Job.schedule_in_tx(
        Ankole.Files.Jobs.PurgeNode,
        %{tenant_id: Repo.tenant_id!(), node_id: node.id},
        # With 0 retention the job first checks after a day and keeps the node while it stays 0.
        at || DateTime.add(node.deleted_at, max(days, 1) * 86_400, :second)
      )
    end
  end

  def visible_ids(reachable, ids \\ nil, bit \\ 1) do
    {anchors, own} = Access.visibility_ids(reachable, bit)

    query =
      Node
      |> Ash.Query.filter(
        is_nil(deleted_at) and
          ((not is_acl_anchor and acl_anchor_id in ^anchors) or (is_acl_anchor and id in ^own))
      )

    query = if ids, do: Ash.Query.filter(query, id in ^ids), else: query
    query |> Ash.Query.select([:id]) |> Ankole.Ash.read!() |> Enum.map(& &1.id)
  end

  def anchor_nodes do
    Node |> Ash.Query.filter(is_acl_anchor and is_nil(deleted_at)) |> Ankole.Ash.read!()
  end

  def ancestor_ids(ids) do
    Repo.query!(
      """
      WITH RECURSIVE ancestors AS (
        SELECT parent.id, parent.parent_id FROM drive_nodes child
        JOIN drive_nodes parent ON parent.id = child.parent_id AND parent.tenant_id = child.tenant_id
        WHERE child.tenant_id = $1::text::uuid AND child.id = ANY($2::text[]::uuid[])
        UNION SELECT parent.id, parent.parent_id FROM drive_nodes parent
        JOIN ancestors child ON parent.id = child.parent_id WHERE parent.tenant_id = $1::text::uuid
      ) SELECT id::text FROM ancestors WHERE parent_id IS NOT NULL
      """,
      [Repo.tenant_id!(), ids]
    ).rows
    |> Enum.map(&hd/1)
  end

  def hidden_trashed_ids do
    Repo.query!(
      """
      WITH RECURSIVE hidden AS (
        SELECT child.id FROM drive_nodes child
        JOIN drive_nodes parent ON parent.tenant_id = child.tenant_id
          AND parent.id = child.parent_anchor_id AND parent.deleted_at IS NOT NULL
        WHERE child.tenant_id = $1::text::uuid AND child.is_acl_anchor
        UNION SELECT child.id FROM drive_nodes child JOIN hidden h ON child.parent_anchor_id = h.id
        WHERE child.tenant_id = $1::text::uuid AND child.is_acl_anchor
      ) SELECT id::text FROM hidden
      """,
      [Repo.tenant_id!()]
    ).rows
    |> Enum.map(&hd/1)
  end

  def shared_root_ids(ids, reachable) do
    {anchors, own} = Access.visibility_ids(reachable)

    Repo.query!(
      """
      SELECT n.id::text FROM drive_nodes n
      LEFT JOIN drive_nodes parent ON parent.tenant_id = n.tenant_id AND parent.id = n.parent_id
      WHERE n.tenant_id = $1::text::uuid AND n.id = ANY($2::text[]::uuid[])
        AND (parent.id IS NULL OR NOT ((NOT parent.is_acl_anchor AND parent.acl_anchor_id = ANY($3::text[]::uuid[]))
          OR (parent.is_acl_anchor AND parent.id = ANY($4::text[]::uuid[]))))
      """,
      [Repo.tenant_id!(), ids, anchors, own]
    ).rows
    |> Enum.map(&hd/1)
  end

  def descendants(id) do
    Repo.query!(
      """
      WITH RECURSIVE subtree AS (
        SELECT id FROM drive_nodes WHERE tenant_id = $1::text::uuid AND id = $2::text::uuid
        UNION ALL SELECT c.id FROM drive_nodes c JOIN subtree s ON c.parent_id = s.id WHERE c.tenant_id = $1::text::uuid
      ) SELECT id::text FROM subtree
      """,
      [Repo.tenant_id!(), id]
    ).rows
    |> Enum.map(&hd/1)
  end

  defp mutable(%{parent_id: nil}), do: {:error, :immutable_root}
  defp mutable(_node), do: :ok

  defp live(node) do
    with {:ok, path} <- path(node),
         do:
           if(Enum.any?(path, &(&1.deleted_at || Map.get(&1, :purge_started_at))),
             do: {:error, :not_found},
             else: :ok
           )
  end

  defp no_cycle(id, parent) do
    with {:ok, path} <- path(parent),
         do: if(Enum.any?(path, &(&1.id == id)), do: {:error, :cycle}, else: :ok)
  end

  def valid_name(name) when is_binary(name) do
    if Ankole.Files.Path.valid_segment?(name), do: :ok, else: {:error, :invalid_name}
  end

  def valid_name(_name), do: {:error, :invalid_name}

  def name_from_title(title) do
    name =
      (title || "")
      |> Ankole.Files.Path.strip_bidi()
      |> String.replace(~r/[\x00-\x1f\x7f-\x9f\x{2028}\x{2029}\/]/u, "_")

    name = if name in ["", ".", ".."], do: "未命名", else: name
    truncate_name(name, 255)
  end

  def available_name(parent_id, name, exclude_id \\ nil) do
    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn index ->
      suffix = if index == 0, do: "", else: " (#{index})"
      candidate = truncate_name(name, 255 - byte_size(suffix)) <> suffix

      query =
        Node
        |> Ash.Query.filter(parent_id == ^parent_id and name == ^candidate and is_nil(deleted_at))

      query = if exclude_id, do: Ash.Query.filter(query, id != ^exclude_id), else: query
      if not Ankole.Ash.exists?(query), do: candidate
    end)
  end

  defp truncate_name(name, max) do
    name
    |> String.graphemes()
    |> Enum.reduce_while("", fn char, acc ->
      if byte_size(acc) + byte_size(char) <= max, do: {:cont, acc <> char}, else: {:halt, acc}
    end)
  end

  defp atom_attrs(attrs) do
    fields = Ash.Resource.Info.attributes(Node) |> Enum.map(& &1.name)

    Map.new(attrs, fn {key, value} ->
      key =
        if is_binary(key), do: Enum.find(fields, &(Atom.to_string(&1) == key)) || key, else: key

      {key, value}
    end)
  end

  def committed(%{id: id}) do
    Access.broadcast_change()
    content_committed(%{id: id})
  end

  def content_committed(%{id: id}) do
    broadcast(id)

    Phoenix.PubSub.broadcast(
      Ankole.PubSub,
      "drive-content:" <> Repo.tenant_id!(),
      {:page_updated, id}
    )

    :ok
  end

  def broadcast(id),
    do: Phoenix.PubSub.broadcast(Ankole.PubSub, "drive-node:" <> id, {:node_committed, id})
end
