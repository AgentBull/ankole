defmodule Ankole.Pod.Pages.Tree do
  @moduledoc "Owns Page roots, parent relationships, names and lifecycle."
  require Ash.Query
  alias Ankole.{ActorRef, Repo}
  alias Ankole.AuthZ.Actor
  alias Ankole.Pod.Access
  alias Ankole.Pod.Page, as: Node

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

  def system_node(key) do
    Node
    |> Ash.Query.filter(system_key == ^key and is_nil(deleted_at))
    |> Ankole.Ash.read_one!()
    |> found_node()
  end

  def child(parent_id, name) do
    Node
    |> Ash.Query.filter(parent_id == ^parent_id and name == ^name and is_nil(deleted_at))
    |> Ankole.Ash.read_one!()
    |> found_node()
  end

  def claim_system_in_tx(node, key) do
    lock_tree()
    Ankole.Ash.update(node, :claim_system, %{system_key: key})
  end

  defp found_node(nil), do: {:error, :not_found}
  defp found_node(node), do: {:ok, node}

  def path(%{parent_id: nil} = page), do: {:ok, [page]}

  def path(%{parent_id: parent_id} = page) do
    result =
      Repo.query!(
        """
        WITH RECURSIVE ancestors AS (
          SELECT p.id, p.name, p.parent_id, p.private_owner_uid, p.conversation_id, p.inherit_permissions, p.deleted_at, p.acl_anchor_id, p.is_acl_anchor, p.system_key
            FROM pages p WHERE p.tenant_id = $1::text::uuid AND p.id = $2::text::uuid
          UNION
          SELECT p.id, p.name, p.parent_id, p.private_owner_uid, p.conversation_id, p.inherit_permissions, p.deleted_at, p.acl_anchor_id, p.is_acl_anchor, p.system_key
            FROM pages p JOIN ancestors a ON p.id = a.parent_id
            WHERE p.tenant_id = $1::text::uuid
        ) SELECT id::text, name, parent_id::text, private_owner_uid, conversation_id::text, inherit_permissions, deleted_at, acl_anchor_id::text, is_acl_anchor, system_key
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
                                anchor,
                                system_key
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
           is_acl_anchor: anchor,
           system_key: system_key
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
      is_nil(parent_id) and is_nil(private_owner_uid) and is_nil(conversation_id) and
        is_nil(system_key)
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

  def root_ids_for_conversations(ids) do
    Node
    |> Ash.Query.filter(conversation_id in ^ids and is_nil(parent_id))
    |> Ash.Query.select([:id])
    |> Ankole.Ash.read!()
    |> Enum.map(& &1.id)
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
          |> Ankole.Ash.read!(lock_identity: {"pages", batch})
        end)

        with :ok <- Ankole.Pod.Pages.Lifecycle.purge_nodes_in_tx(ids) do
          # A pass-through descendant can reference an ancestor several cascade
          # steps away. Validate these graph edges after the whole tree is gone,
          # before returning to the caller's transaction. Object FKs stay immediate.
          Repo.query!("SET CONSTRAINTS pages_acl_anchor_fkey, pages_parent_anchor_fkey DEFERRED")

          with {:ok, _} <- Ankole.Ash.destroy(root, :remove) do
            Repo.query!(
              "SET CONSTRAINTS pages_acl_anchor_fkey, pages_parent_anchor_fkey IMMEDIATE"
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

  def ensure_brain_root_in_tx do
    ensure_root(
      fn -> system_node("ankole_brain") end,
      %{name: "Brain", type: :knowledge, system_key: "ankole_brain", inherit_permissions: false}
    )
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
    case read.() do
      {:error, :not_found} ->
        lock_tree()
        create_root_if_missing(read, attrs)

      result ->
        result
    end
  end

  defp create_root_if_missing(read, attrs) do
    case read.() do
      {:ok, root} ->
        {:ok, root}

      {:error, :not_found} ->
        id = Ankole.Ecto.UUIDv7.autogenerate()

        with {:ok, page} <-
               Ankole.Ash.create(
                 Node,
                 :create_in_tx,
                 Map.merge(attrs, %{
                   id: id,
                   type: Map.get(attrs, :type, :doc),
                   title: Map.fetch!(attrs, :name),
                   acl_anchor_id: id,
                   inherit_permissions: Map.get(attrs, :inherit_permissions, true)
                 })
               ),
             do: initialize_content(page)

      error ->
        error
    end
  end

  def lock_tree(opts \\ []) do
    :ok = Repo.require_transaction()
    Ankole.AdvisoryLock.lock!(Repo, "page-tree:" <> Repo.tenant_id!(), opts)
    :ok
  end

  def lock_roots(ids) do
    :ok = Repo.require_transaction()

    ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&Ankole.AdvisoryLock.lock!(Repo, "page-root:" <> &1))

    :ok
  end

  def lock(id, mode \\ :update) when mode in [:update, :share] do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Node{} = node <-
           Node
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.lock(if(mode == :share, do: "FOR SHARE", else: :for_update))
           |> Ankole.Ash.read_one!(lock_identity: {"pages", id}),
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
    with true <-
           Ankole.Attrs.get(attrs, :type) in [
             :doc,
             :knowledge,
             :base,
             :applet,
             :file,
             "doc",
             "knowledge",
             "base",
             "applet",
             "file"
           ],
         {:ok, parent} <- fetch(Ankole.Attrs.get(attrs, :parent_id)),
         {:ok, _} <- authorize_child_create(actor, parent),
         do: create_in_tx(Map.put(attrs, :created_by, ActorRef.from_actor(actor))),
         else: (
           false -> {:error, :invalid_kind}
           error -> error
         )
  end

  def authorize_child_create(_actor, %{system_key: "ankole_brain"}),
    do: {:error, :ontology_owned_category}

  def authorize_child_create(_actor, %{system_key: "ankole_brain_sources"}),
    do: {:error, :ontology_owned_category}

  def authorize_child_create(_actor, %{system_key: "ankole_brain_agents"}),
    do: {:error, :ontology_owned_category}

  def authorize_child_create(_actor, %{type: :file}), do: {:error, :not_a_directory}

  def authorize_child_create(actor, parent),
    do: Access.authorize(actor, parent, child_create_action(parent))

  def child_create_action(_parent), do: "node_edit"

  @doc "Creates a child for an already-authorized caller in its transaction."
  def create_in_tx(attrs, opts \\ []) do
    lock_tree()
    attrs = atom_attrs(attrs)

    with {:ok, parent} <- fetch(attrs[:parent_id]),
         true <- parent.type != :file,
         :ok <- live(parent),
         :ok <- domain_type(parent, attrs[:type]),
         :ok <- valid_name(attrs[:name]),
         {:ok, name} <- allocate_name(parent.id, attrs.name, nil, attrs[:type], opts) do
      lock_roots(root_ids([parent.id]))
      id = Map.get_lazy(attrs, :id, &Ankole.Ecto.UUIDv7.autogenerate/0)

      attrs =
        attrs
        |> Map.put(:id, id)
        |> Map.drop([:private_owner_uid, :conversation_id])
        |> Map.put(:name, name)
        |> Map.put_new(:title, name)
        |> Access.anchor_attributes()

      with {:ok, page} <- Ankole.Ash.create(Node, :create_in_tx, attrs),
           do: initialize_content(page, Keyword.get(opts, :initial_content))
    else
      false -> {:error, :not_a_directory}
      error -> error
    end
  end

  defp initialize_content(page, content \\ nil)

  defp initialize_content(%{type: type} = page, content) when type in [:doc, :knowledge] do
    author =
      page.created_by || ActorRef.from_principal(%{tenant_id: Repo.tenant_id!(), uid: "system"})

    plain_text = (content && content.plain_text) || ""

    with {:ok, _} <-
           Ankole.Ash.create(Ankole.Pod.PageContent, :create_in_tx, %{
             page_id: page.id,
             content: (content && content.content) || "<page />",
             plain_text: plain_text,
             updated_by: author,
             updated_at: page.updated_at
           }),
         :ok <- Ankole.Pod.SearchProjection.upsert_in_tx(page, body_text: plain_text),
         do: {:ok, page}
  end

  defp initialize_content(page, _content) do
    with :ok <- Ankole.Pod.SearchProjection.upsert_in_tx(page, body_text: ""),
         do: {:ok, page}
  end

  @doc "Updates an already-authorized node. Object-only writes do not acquire the tree lock."
  def update_in_tx(node, action, attrs) do
    attrs = atom_attrs(attrs)
    if Enum.any?(@topology, &Map.has_key?(attrs, &1)), do: lock_tree()

    with {:ok, current} <- fetch(node.id),
         :ok <- system_structure(current, attrs) do
      # Permission bookkeeping does not edit the node's content or metadata.
      attrs =
        if action in [:anchor, :sharing],
          do: Map.delete(attrs, :updated_at),
          else: Map.put_new_lazy(attrs, :updated_at, fn -> DateTime.utc_now(:microsecond) end)

      with {:ok, updated} <- Ankole.Ash.update(current, :update_in_tx, attrs),
           :ok <- Ankole.Pod.SearchProjection.upsert_in_tx(updated),
           :ok <- Ankole.Pod.FileExtraction.reconcile_renamed_in_tx(current, updated),
           do: {:ok, updated}
    end
  end

  def rename(actor, id, name), do: move(actor, id, %{name: name})

  def move(%Actor{} = actor, id, attrs) do
    Access.write_tree(actor.turn_authority, fn -> move_in_tx(actor, id, attrs) end,
      root_ids: fn -> root_ids([id, Ankole.Attrs.get(attrs, :parent_id)]) end,
      after_commit: &committed/1
    )
  end

  def move_in_tx(actor, id, attrs, opts \\ []) do
    lock_tree()

    with {:ok, node} <- lock(id),
         :ok <- mutable(node),
         {:ok, _} <- Access.authorize_move_source(actor, node),
         :ok <- authorize_name_edit(actor, node, attrs),
         parent_id = Ankole.Attrs.get(attrs, :parent_id, node.parent_id),
         {:ok, parent} <- fetch(parent_id),
         :ok <- live(parent),
         :ok <- move_destination(actor, node, parent),
         :ok <- domain_type(parent, node.type),
         :ok <- no_cycle(node.id, parent),
         {:ok, _} <- Access.authorize_move(actor, node, parent.id, nil),
         name_supplied? = Ankole.Attrs.get(attrs, :name, :missing) != :missing,
         name = Ankole.Attrs.get(attrs, :name, node.name),
         :ok <- if(name_supplied?, do: valid_name(name), else: :ok),
         {:ok, name} <- allocate_name(parent.id, name, node.id, node.type, opts) do
      {:ok, old_path} = path(node)

      with {:ok, moved} <-
             Access.update_anchor_in_tx(node, :move, %{
               parent_id: parent.id,
               name: name,
               updated_at: DateTime.utc_now(:microsecond)
             }),
           :ok <- sync_content_name(actor, node, moved, attrs),
           :ok <- Ankole.Pod.Pages.Lifecycle.move_node_in_tx(node.id, old_path),
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
      do: Ankole.Pod.Pages.Lifecycle.rename_node_in_tx(old, moved, actor),
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

    with {:ok, node} <- lock(id), do: trash_node_in_tx(actor, node, deletion_action(node))
  end

  def trash_empty_directory_in_tx(actor, id) do
    lock_tree()

    with {:ok, %{type: :doc} = node} <- lock(id),
         true <- Ankole.Pod.Pages.content_empty?(node) and list_children(id) == [],
         do: trash_node_in_tx(actor, node, "node_edit"),
         else: (
           false -> {:error, :not_empty}
           error -> error
         )
  end

  defp trash_node_in_tx(actor, node, action) do
    with :ok <- mutable(node),
         {:ok, _} <-
           Access.authorize(actor, node, action, requester_action: "node_edit"),
         {:ok, node} <-
           Access.update_anchor_in_tx(node, :trash, %{deleted_at: DateTime.utc_now(:microsecond)}),
         :ok <- Ankole.Pod.Pages.Lifecycle.trash_node_in_tx(node.id),
         :ok <- schedule_purge(node),
         do: {:ok, node}
  end

  def deletion_action(%{type: :file}), do: "node_edit"
  def deletion_action(_node), do: "node_manage"

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
         {:ok, _} <-
           Access.authorize(actor, node, "node_manage",
             trash: true,
             requester_action: "node_edit"
           ),
         true <- not is_nil(node.deleted_at) and is_nil(node.purge_started_at),
         {:ok, parent} <- fetch(node.parent_id),
         :ok <- live(parent),
         {:ok, restored} <-
           Access.update_anchor_in_tx(node, :restore, %{
             deleted_at: nil,
             name: available_name(parent.id, node.name, node.id, node.type)
           }),
         :ok <- Ankole.Pod.Pages.Lifecycle.restore_node_in_tx(id),
         :ok <- restore_descendants_in_tx(actor, restored),
         do: {:ok, restored},
         else: (
           false -> {:error, :cannot_restore}
           error -> error
         )
  end

  defp restore_descendants_in_tx(_actor, %{type: :file}), do: :ok

  defp restore_descendants_in_tx(actor, parent) do
    children =
      Node
      |> Ash.Query.filter(parent_id == ^parent.id and is_nil(purge_started_at))
      |> Ash.Query.sort(id: :asc)
      |> Ankole.Ash.read!()

    Enum.reduce_while(children, :ok, fn child, :ok ->
      result =
        cond do
          is_nil(child.deleted_at) ->
            restore_descendants_in_tx(actor, child)

          match?(
            {:ok, _},
            Access.authorize(actor, child, "node_manage",
              trash: true,
              requester_action: "node_edit"
            )
          ) ->
            case restore_in_tx(actor, child.id) do
              {:ok, _} -> :ok
              error -> error
            end

          true ->
            :ok
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  @doc "Consumes a leaf file whose immutable object has been transferred to another node."
  def consume_file_in_tx(actor, id) do
    lock_tree()

    with {:ok, %{type: :file} = node} <- lock(id),
         :ok <- mutable(node),
         {:ok, _} <- Access.authorize(actor, node, "node_edit"),
         now = DateTime.utc_now(:microsecond),
         {:ok, node} <-
           Access.update_anchor_in_tx(node, :trash, %{deleted_at: now, purge_started_at: now}),
         :ok <- schedule_purge(node, now),
         do: {:ok, node}
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
        Ankole.Pod.Jobs.PurgeTree,
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

  def page_live?(id) do
    ids = [id | ancestor_ids([id])]

    pages =
      Node
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id, :deleted_at, :purge_started_at])
      |> Ankole.Ash.read!()

    Enum.any?(pages, &(&1.id == id)) and
      Enum.all?(pages, &(is_nil(&1.deleted_at) and is_nil(&1.purge_started_at)))
  end

  @doc "Maps each given Page in a Private tree to the owner of its Private root."
  def private_owners([]), do: %{}

  def private_owners(ids) do
    Repo.query!(
      """
      WITH RECURSIVE up AS (
        SELECT id AS page_id, parent_id, private_owner_uid FROM pages
        WHERE tenant_id = $1::text::uuid AND id = ANY($2::text[]::uuid[])
        UNION ALL SELECT up.page_id, parent.parent_id, parent.private_owner_uid FROM pages parent
        JOIN up ON parent.id = up.parent_id WHERE parent.tenant_id = $1::text::uuid
      ) SELECT page_id::text, private_owner_uid FROM up
      WHERE parent_id IS NULL AND private_owner_uid IS NOT NULL
      """,
      [Repo.tenant_id!(), Enum.uniq(ids)]
    ).rows
    |> Map.new(fn [id, owner] -> {id, owner} end)
  end

  def ancestor_ids(ids) do
    Repo.query!(
      """
      WITH RECURSIVE ancestors AS (
        SELECT parent.id, parent.parent_id FROM pages child
        JOIN pages parent ON parent.id = child.parent_id AND parent.tenant_id = child.tenant_id
        WHERE child.tenant_id = $1::text::uuid AND child.id = ANY($2::text[]::uuid[])
        UNION SELECT parent.id, parent.parent_id FROM pages parent
        JOIN ancestors child ON parent.id = child.parent_id WHERE parent.tenant_id = $1::text::uuid
      ) SELECT id::text FROM ancestors
      """,
      [Repo.tenant_id!(), ids]
    ).rows
    |> Enum.map(&hd/1)
  end

  def hidden_trashed_ids do
    Repo.query!(
      """
      WITH RECURSIVE hidden AS (
        SELECT child.id FROM pages child
        JOIN pages parent ON parent.tenant_id = child.tenant_id
          AND parent.id = child.parent_anchor_id AND parent.deleted_at IS NOT NULL
        WHERE child.tenant_id = $1::text::uuid AND child.is_acl_anchor
        UNION SELECT child.id FROM pages child JOIN hidden h ON child.parent_anchor_id = h.id
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
      SELECT n.id::text FROM pages n
      LEFT JOIN pages parent ON parent.tenant_id = n.tenant_id AND parent.id = n.parent_id
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
        SELECT id FROM pages WHERE tenant_id = $1::text::uuid AND id = $2::text::uuid
        UNION ALL SELECT c.id FROM pages c JOIN subtree s ON c.parent_id = s.id WHERE c.tenant_id = $1::text::uuid
      ) SELECT id::text FROM subtree
      """,
      [Repo.tenant_id!(), id]
    ).rows
    |> Enum.map(&hd/1)
  end

  defp domain_type(parent, type) do
    with {:ok, root} <- root(parent.id) do
      types =
        if root.system_key == "ankole_brain",
          do: [:knowledge, :file],
          else: [:doc, :base, :applet, :file]

      if type in types or to_string(type) in Enum.map(types, &to_string/1),
        do: :ok,
        else: {:error, :invalid_page_domain}
    end
  end

  defp mutable(%{system_key: key}) when not is_nil(key), do: {:error, :immutable_root}
  defp mutable(%{parent_id: nil}), do: {:error, :immutable_root}

  defp mutable(%{type: :knowledge, metadata: %{"subtype" => "internal", "entity_type" => type}})
       when type in ["person", "agent"], do: {:error, :principal_owned_object}

  defp mutable(_node), do: :ok

  defp system_structure(%{system_key: nil}, _attrs), do: :ok

  defp system_structure(node, attrs) do
    if Enum.any?([:name, :parent_id, :deleted_at, :purge_started_at], fn key ->
         Map.has_key?(attrs, key) and Map.fetch!(attrs, key) != Map.fetch!(node, key)
       end), do: {:error, :immutable_root}, else: :ok
  end

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

  @doc """
  Names a file Page after a new title while keeping the stored file's extension,
  so a renamed Office file still opens in its editor and downloads with its type.
  A title that already ends with that extension is used as given.
  """
  def file_name_from_title(title, current_name) do
    extension = Path.extname(current_name)
    name = name_from_title(title)

    if extension == "" or String.ends_with?(String.downcase(name), String.downcase(extension)),
      do: name,
      else: truncate_name(name, 255 - byte_size(extension)) <> extension
  end

  def available_name(parent_id, name, exclude_id \\ nil, type \\ nil) do
    # A file keeps its extension last, so a second "report.txt" becomes "report (1).txt".
    extension = if type in [:file, "file"], do: Path.extname(name), else: ""
    stem = binary_part(name, 0, byte_size(name) - byte_size(extension))

    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate =
        if index == 0 do
          truncate_name(name, 255)
        else
          suffix = " (#{index})" <> extension
          truncate_name(stem, 255 - byte_size(suffix)) <> suffix
        end

      query =
        Node
        |> Ash.Query.filter(parent_id == ^parent_id and name == ^candidate and is_nil(deleted_at))

      query = if exclude_id, do: Ash.Query.filter(query, id != ^exclude_id), else: query
      if not Ankole.Ash.exists?(query), do: candidate
    end)
  end

  defp allocate_name(parent_id, name, exclude_id, type, opts) do
    if Keyword.get(opts, :exact_name, false) do
      case child(parent_id, name) do
        {:error, :not_found} -> {:ok, name}
        {:ok, %{id: ^exclude_id}} -> {:ok, name}
        {:ok, _} -> {:error, :name_conflict}
      end
    else
      {:ok, available_name(parent_id, name, exclude_id, type)}
    end
  end

  defp truncate_name(name, max), do: Ankole.Text.grapheme_prefix(name, max)

  defp atom_attrs(attrs) do
    fields = Ash.Resource.Info.attributes(Node) |> Enum.map(& &1.name)

    Map.new(attrs, fn {key, value} ->
      key =
        if is_binary(key), do: Enum.find(fields, &(Atom.to_string(&1) == key)) || key, else: key

      {key, value}
    end)
  end

  def committed(%{id: id} = node) do
    Access.broadcast_change(Map.get(node, :type) != :file)
    content_committed(%{id: id})
  end

  def content_committed(%{id: id}) do
    ids =
      case fetch(id) do
        {:ok, page} -> [id, page.parent_id]
        _ -> [id]
      end

    for id <- Enum.reject(ids, &is_nil/1) do
      broadcast(id)

      Phoenix.PubSub.broadcast(
        Ankole.PubSub,
        "drive-content:" <> Repo.tenant_id!(),
        {:page_updated, id}
      )
    end

    :ok
  end

  def broadcast(id),
    do: Phoenix.PubSub.broadcast(Ankole.PubSub, "drive-node:" <> id, {:node_committed, id})
end
