defmodule Ankole.Pod.Pages do
  @moduledoc """
  Owns Pod properties, page details and personal page state over the Drive tree.

  Each operation that changes the tree or reads under a page lock runs in a
  top-level transaction. The `*_in_tx` functions run in the caller's
  transaction and do not publish.
  """
  require Ash.Query
  alias Ankole.{ActorRef, AuthZ, Repo}
  alias Ankole.Files.{Access, Nodes}
  alias Ankole.Pod.{Page, PageContent, PageUserState, Position, Properties}
  alias Ankole.Pod.Pages.{Mentions, Queries, Sharing}
  alias Ankole.Pod.Documents.History

  defdelegate list_children(actor, parent_id, opts \\ %{}), to: Queries
  defdelegate navigation(actor, active_page_id), to: Queries
  defdelegate navigation_entries(actor, ids), to: Queries
  defdelegate search(actor, query, opts \\ %{}), to: Queries
  defdelegate visible_descendant_count(actor, id), to: Queries
  defdelegate list(actor, opts \\ %{}), to: Queries
  defdelegate can_create_private?(actor), to: Queries
  defdelegate reconcile_versions(actor, page_ids, table_ids), to: Queries
  defdelegate mention_candidates(actor, opts \\ %{}), to: Mentions, as: :candidates
  defdelegate resolve_mentions(actor, attrs), to: Mentions, as: :resolve
  defdelegate resolve_xml_references(actor, xml, context_page_id \\ nil), to: Mentions

  def can_create_space?(%Ankole.AuthZ.Actor{} = actor),
    do: match?(:ok, destination(actor, nil, nil))

  defdelegate sharing(actor, id), to: Sharing
  defdelegate subjects(actor), to: Sharing
  defdelegate set_sharing(actor, id, attrs, authority \\ nil), to: Sharing
  defdelegate set_sharing_in_tx(actor, id, attrs), to: Sharing
  defdelegate update_sharing(actor, id, attrs, authority \\ nil), to: Sharing
  defdelegate update_sharing_in_tx(actor, id, attrs), to: Sharing
  defdelegate space(actor), to: Sharing
  defdelegate set_space(actor, role, authority \\ nil), to: Sharing
  defdelegate set_space_in_tx(actor, role), to: Sharing
  defdelegate space_agent(actor, agent_uid, role, authority \\ nil), to: Sharing
  defdelegate space_agent_in_tx(actor, agent_uid, role), to: Sharing
  defdelegate remove_space_agent(actor, agent_uid, authority \\ nil), to: Sharing
  defdelegate remove_space_agent_in_tx(actor, agent_uid), to: Sharing

  @doc "Checks the active Principal and the page's inherited AuthZ permission."
  def authorize(%Ankole.AuthZ.Actor{} = actor, id, action, opts \\ []) do
    with {:ok, page} <- fetch(id), do: Access.authorize(actor, page, action, opts)
  end

  def fetch(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Page{} = page <- Page |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!(),
         do: {:ok, page},
         else: (_ -> {:error, :not_found})
  end

  @doc "Returns the manageable Page IDs from the caller's evaluated access graph."
  def manageable_ids(ids, reachable) do
    Nodes.visible_ids(reachable, ids, 8) |> MapSet.new()
  end

  @doc "Returns visible Pages saved from the live Messages of one Conversation."
  def saved_from_conversation(actor, id) do
    Page
    |> Ash.Query.filter(
      saved_from_message.conversation_id == ^id and not saved_from_message.withdrawn
    )
    |> Ankole.Ash.read_authorized(actor)
  end

  def create(%Ankole.AuthZ.Actor{} = actor, attrs, authority \\ nil) when is_map(attrs) do
    authority = authority || actor.turn_authority

    Access.write_tree(authority, fn -> create_in_tx(actor, attrs) end,
      root_ids: fn -> destination_root_ids(actor, attrs) end,
      after_commit: &committed_tree/1
    )
  end

  @doc "Creates a page in the caller's transaction."
  def create_in_tx(%Ankole.AuthZ.Actor{} = actor, attrs) when is_map(attrs) do
    lock_tree()
    uid = Ankole.AuthZ.Actor.uid(actor)

    with {:ok, principal} <- Access.principal(actor),
         {:ok, parent} <- destination_root_in_tx(actor, attrs),
         {:ok, _} <- Nodes.authorize_child_create(actor, parent),
         {:ok, source} <- source_message(actor, Ankole.Attrs.get(attrs, :saved_from_message_id)),
         {:ok, children_view} <-
           normalize_children_view(Ankole.Attrs.get(attrs, :children_view, %{})) do
      title = Ankole.Attrs.get(attrs, :title, "") |> Ankole.Files.Path.strip_bidi_and_controls()
      kind = Ankole.Attrs.get(attrs, :type, "doc")

      with {:ok, node} <-
             Nodes.create_in_tx(%{
               parent_id: parent.id,
               kind: kind,
               name: Nodes.name_from_title(title),
               created_by: ActorRef.from_principal(principal)
             }),
           {:ok, _} <-
             ensure_properties_in_tx(node.id, %{
               title: title,
               icon: Ankole.Attrs.get(attrs, :icon),
               position: Ankole.Attrs.get(attrs, :position),
               saved_from_message_id: source && source.id,
               children_view: children_view
             }),
           {:ok, page} <- fetch(node.id),
           :ok <-
             initial_content(
               page,
               uid,
               Ankole.Attrs.get(attrs, :skip_default_table, false),
               Ankole.Attrs.get(attrs, :xml)
             ),
           do: {:ok, page}
    end
  end

  def destination_root_ids(actor, attrs) do
    parent = Ankole.Attrs.get(attrs, :parent_id)
    owner = Ankole.Attrs.get(attrs, :private_owner_uid)

    cond do
      parent ->
        Nodes.root_ids([parent])

      owner == Ankole.Principals.authority_uid(Ankole.AuthZ.Actor.uid(actor)) ->
        case Nodes.private_root(owner) do
          {:ok, root} ->
            [root.id]

          {:error, :not_found} ->
            case Nodes.ensure_private_root_in_tx(owner) do
              {:ok, root} -> [root.id]
              _ -> []
            end
        end

      true ->
        []
    end
  end

  defp destination_root_in_tx(actor, attrs) do
    parent = Ankole.Attrs.get(attrs, :parent_id)
    owner = Ankole.Attrs.get(attrs, :private_owner_uid)

    cond do
      parent && owner ->
        {:error, :invalid_parent}

      parent ->
        Nodes.fetch(parent)

      owner == Ankole.Principals.authority_uid(Ankole.AuthZ.Actor.uid(actor)) ->
        Nodes.ensure_private_root_in_tx(owner)

      owner ->
        {:error, :forbidden}

      true ->
        Nodes.ensure_public_root_in_tx()
    end
  end

  def ensure_properties_in_tx(id, attrs \\ %{}) do
    with {:ok, node} <- Nodes.fetch(id) do
      Ankole.Ash.create(
        Properties,
        :ensure,
        Map.merge(%{id: id, created_at: node.created_at, updated_at: node.updated_at}, attrs)
      )
    end
  end

  def update_properties_in_tx(page, action, attrs) do
    with {:ok, properties} <- ensure_properties_in_tx(page.id),
         {:ok, _} <- Ankole.Ash.update(properties, action, attrs),
         do: fetch(page.id)
  end

  def update(%Ankole.AuthZ.Actor{} = actor, id, attrs, authority \\ nil) do
    authority = authority || actor.turn_authority

    Access.write_tree(authority, fn -> update_in_tx(actor, id, attrs) end,
      root_ids: fn -> Nodes.root_ids([id]) end,
      after_commit: &committed_page/1
    )
  end

  @doc false
  def update_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    lock_tree()

    with {:ok, page} <- lock(id),
         {:ok, _} <- AuthZ.authorize_locked_in_tx(actor, page, "node_edit"),
         :ok <- check_title_base(page, attrs),
         {:ok, children_view} <- merge_children_view(page.children_view, attrs) do
      changes =
        Map.new([:title, :icon], fn key ->
          value = Ankole.Attrs.get(attrs, key, Map.get(page, key))

          value =
            if key == :title and is_binary(value),
              do: Ankole.Files.Path.strip_bidi_and_controls(value),
              else: value

          {key, value}
        end)

      identity_edited? =
        Enum.any?(changes, fn {key, value} -> Map.fetch!(page, key) != value end)

      now = DateTime.utc_now(:microsecond)

      updated_at =
        if identity_edited? or Ankole.Attrs.get(attrs, :children_view, :missing) == :missing,
          do: now,
          else: page.updated_at

      with :ok <- record_document_edit(page, changes, actor, now),
           :ok <- rename_from_title_in_tx(page, attrs) do
        # An unchanged value is not sent, so a legacy title above the length limit allows icon edits.
        update_properties_in_tx(
          page,
          :edit,
          changes
          |> Map.filter(fn {key, value} -> Map.fetch!(page, key) != value end)
          |> Map.put(:children_view, children_view)
          |> Map.put(:updated_at, updated_at)
        )
      end
    end
  end

  def rename_from_drive_in_tx(actor, id, name) do
    with {:ok, page} <- fetch(id),
         now = DateTime.utc_now(:microsecond),
         :ok <- record_document_edit(page, %{title: name}, actor, now),
         {:ok, _} <- update_properties_in_tx(page, :edit, %{title: name, updated_at: now}),
         do: :ok
  end

  defp rename_from_title_in_tx(page, attrs) do
    case Ankole.Attrs.get(attrs, :title, :missing) do
      :missing ->
        :ok

      title ->
        with {:ok, node} <- Nodes.fetch(page.id),
             {:ok, _} <-
               Nodes.update_in_tx(node, :rename, %{
                 name: Nodes.available_name(node.parent_id, Nodes.name_from_title(title), node.id)
               }),
             do: :ok
    end
  end

  defp check_title_base(page, attrs) do
    if Ankole.Attrs.get(attrs, :title, :missing) == :missing or
         Ankole.Attrs.get(attrs, :expected_title) == page.title do
      :ok
    else
      {:error, {:title_conflict, page.title}}
    end
  end

  defp merge_children_view(current, attrs) do
    case Ankole.Attrs.get(attrs, :children_view, :missing) do
      :missing ->
        {:ok, current || %{}}

      nil ->
        {:error, :invalid_request}

      patch ->
        with {:ok, normalized} <- normalize_children_view(patch) do
          {:ok, Map.merge(current || %{}, normalized)}
        end
    end
  end

  defp normalize_children_view(nil), do: {:ok, %{}}

  defp normalize_children_view(map) when is_map(map) do
    {:ok,
     Map.new(map, fn {key, value} ->
       {to_string(key), normalize_children_view_value(value)}
     end)}
  end

  defp normalize_children_view(_invalid), do: {:error, :invalid_request}

  defp normalize_children_view_value(value)
       when is_atom(value) and value not in [true, false, nil],
       do: Atom.to_string(value)

  defp normalize_children_view_value(value) when is_list(value),
    do: Enum.map(value, &normalize_children_view_value/1)

  defp normalize_children_view_value(value), do: value

  defp record_document_edit(%{type: :doc} = page, changes, actor, now) do
    if Enum.any?(changes, fn {key, value} -> Map.fetch!(page, key) != value end) do
      content =
        PageContent
        |> Ash.Query.filter(page_id == ^page.id)
        |> Ankole.Ash.read_one!(not_found_error?: true)

      with :ok <- History.checkpoint_in_tx(page, content, now),
           :ok <- Ankole.Pod.Documents.Insights.edit_in_tx(page.id, AuthZ.Actor.uid(actor), now),
           {:ok, _} <-
             Ankole.Ash.update(content, :attribute_edit, %{
               updated_by: ActorRef.from_actor(actor),
               updated_at: now
             }),
           do: :ok
    else
      :ok
    end
  end

  defp record_document_edit(_page, _changes, _actor, _now), do: :ok

  def move(%Ankole.AuthZ.Actor{} = actor, id, attrs, authority \\ nil) do
    authority = authority || actor.turn_authority

    Access.write_tree(authority, fn -> move_in_tx(actor, id, attrs) end,
      root_ids: fn -> Nodes.root_ids([id]) ++ destination_root_ids(actor, attrs) end,
      after_commit: &committed_tree/1
    )
  end

  @doc false
  def move_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    lock_tree()

    with {:ok, page} <- lock(id),
         {:ok, parent} <- destination_root_in_tx(actor, attrs),
         undo = previous_location(page),
         old_anchor = page.acl_anchor_id,
         :ok <- materialize_positions(parent.id),
         {:ok, position} <- move_position(page, parent.id, nil, attrs),
         {:ok, moved} <- Nodes.move_in_tx(actor, id, %{parent_id: parent.id}),
         {:ok, page} <- update_properties_in_tx(page, :position, %{position: position}) do
      {:ok, %{page: page, undo: undo, access_changed: moved.acl_anchor_id != old_anchor}}
    end
  end

  defp materialize_positions(parent_id) do
    siblings = siblings(parent_id, nil, nil)

    if Enum.any?(siblings, &is_nil(&1.position)) do
      Enum.zip(siblings, Position.sequence(length(siblings)))
      |> Enum.reduce_while(:ok, fn {sibling, position}, :ok ->
        case update_properties_in_tx(sibling, :position, %{position: position}) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      :ok
    end
  end

  defp previous_location(page) do
    location = Map.take(page, [:parent_id, :private_owner_uid])

    siblings = siblings(page.parent_id, page.private_owner_uid, nil)
    index = Enum.find_index(siblings, &(&1.id == page.id))
    next = index && Enum.at(siblings, index + 1)
    previous = if index && index > 0, do: Enum.at(siblings, index - 1)

    cond do
      next -> Map.put(location, :before_id, next.id)
      previous -> Map.put(location, :after_id, previous.id)
      true -> location
    end
  end

  # One anchor names the sibling next to the moved page. Without an anchor the
  # page goes last. An anchor outside the destination is a stale view.
  defp move_position(page, parent, owner, attrs) do
    after_id = Ankole.Attrs.get(attrs, :after_id)
    before_id = Ankole.Attrs.get(attrs, :before_id)

    if is_nil(after_id) and is_nil(before_id) do
      {:ok, next_position(parent, owner)}
    else
      siblings = siblings(parent, owner, page.id)
      anchor = Enum.find_index(siblings, &(&1.id in [after_id, before_id]))

      cond do
        after_id && before_id -> {:error, :invalid_position}
        is_nil(anchor) -> {:error, :position_conflict}
        after_id -> place(siblings, anchor + 1)
        true -> place(siblings, anchor)
      end
    end
  end

  defp next_position(parent, owner) do
    last = Page |> in_destination(parent, owner) |> Ankole.Ash.max!(:position)

    case Position.between(last, nil) do
      {:ok, position} -> position
      :error -> last <> "V"
    end
  end

  defp place(siblings, index) do
    lower = if index > 0, do: Enum.at(siblings, index - 1).position
    upper = if upper = Enum.at(siblings, index), do: upper.position

    case Position.between(lower, upper) do
      {:ok, position} -> {:ok, position}
      :error -> renumber(siblings, index)
    end
  end

  # Equal or foreign keys have no key between them. Renumber the destination,
  # which is already serialized by the tree lock.
  defp renumber(siblings, index) do
    {before, rest} = Enum.split(siblings, index)
    keys = Position.sequence(length(siblings) + 1)

    (before ++ [:moved] ++ rest)
    |> Enum.zip(keys)
    |> Enum.reduce({:ok, nil}, fn
      {:moved, key}, {:ok, _} ->
        {:ok, key}

      {sibling, key}, result ->
        {:ok, _} = update_properties_in_tx(sibling, :position, %{position: key})
        result
    end)
  end

  defp siblings(parent, owner, moving_id) do
    query = Ash.Query.filter(Page, is_nil(deleted_at))
    query = if moving_id, do: Ash.Query.filter(query, id != ^moving_id), else: query

    query
    |> in_destination(parent, owner)
    |> Ash.Query.sort(position: :asc_nils_last, name: :asc, id: :asc)
    |> Ankole.Ash.read!()
  end

  defp in_destination(query, parent, owner) do
    query =
      if parent,
        do: Ash.Query.filter(query, parent_id == ^parent),
        else: Ash.Query.filter(query, is_nil(parent_id))

    if owner,
      do: Ash.Query.filter(query, private_owner_uid == ^owner),
      else: Ash.Query.filter(query, is_nil(private_owner_uid))
  end

  def delete(%Ankole.AuthZ.Actor{} = actor, id, authority \\ nil) do
    authority = authority || actor.turn_authority

    Access.write_tree(authority, fn -> delete_in_tx(actor, id) end,
      root_ids: fn -> Nodes.root_ids([id]) end,
      after_commit: &committed_access_tree/1
    )
  end

  @doc false
  def delete_in_tx(actor, id) do
    with {:ok, node} <- Nodes.trash_in_tx(actor, id), do: fetch(node.id)
  end

  def delete_embeds(%Ankole.AuthZ.Actor{} = actor, parent_id, child_ids, authority \\ nil) do
    authority = authority || actor.turn_authority

    with {:ok, _} <-
           Access.write_tree(
             authority,
             fn -> delete_embeds_in_tx(actor, parent_id, child_ids) end,
             root_ids: fn -> Nodes.root_ids([parent_id]) end,
             after_commit: fn pages ->
               Enum.each(pages, &committed_access_tree/1)
             end
           ) do
      {:ok, nil}
    end
  end

  @doc false
  def delete_embeds_in_tx(%Ankole.AuthZ.Actor{} = actor, parent_id, child_ids) do
    lock_tree()

    with {:ok, parent} <- authorize(actor, parent_id, "node_edit") do
      parent_id = parent.id

      child_ids
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn child_id, {:ok, pages} ->
        case lock(child_id) do
          {:ok, %Page{parent_id: ^parent_id, deleted_at: nil} = child} ->
            case delete_embedded_child(actor, child) do
              {:ok, page} -> {:cont, {:ok, [page | pages]}}
              error -> {:halt, error}
            end

          _reference ->
            {:cont, {:ok, pages}}
        end
      end)
    end
  end

  defp delete_embedded_child(%Ankole.AuthZ.Actor{} = actor, child) do
    action =
      if child.inherit_permissions and child.created_by == ActorRef.from_actor(actor),
        do: "node_edit",
        else: "node_manage"

    with {:ok, _} <- Access.authorize(actor, child, action),
         {:ok, child} <-
           Nodes.fetch(child.id)
           |> then(fn {:ok, node} ->
             Access.update_anchor_in_tx(node, :trash, %{
               deleted_at: DateTime.utc_now(:microsecond)
             })
           end),
         :ok <- schedule_purge(child),
         do: {:ok, child}
  end

  def restore(%Ankole.AuthZ.Actor{} = actor, id, authority \\ nil) do
    authority = authority || actor.turn_authority

    Access.write_tree(authority, fn -> restore_in_tx(actor, id) end,
      root_ids: fn -> Nodes.root_ids([id]) end,
      after_commit: &committed_access_tree/1
    )
  end

  @doc false
  def restore_in_tx(actor, id) do
    with {:ok, node} <- Nodes.restore_in_tx(actor, id), do: fetch(node.id)
  end

  def purge(%Ankole.AuthZ.Actor{} = actor, id, authority \\ nil) do
    authority = authority || actor.turn_authority

    Access.write_tree(authority, fn -> purge_in_tx(actor, id) end,
      root_ids: fn -> Nodes.root_ids([id]) end,
      after_commit: &committed_tree/1
    )
  end

  @doc false
  def purge_in_tx(actor, id) do
    with {:ok, node} <- Nodes.purge_in_tx(actor, id), do: fetch(node.id)
  end

  def get(%Ankole.AuthZ.Actor{} = actor, id) do
    with {:ok, detail} <- Repo.transact_top_level(fn -> get_in_tx(actor, id) end) do
      {:ok, Map.put(detail, :source_conversation, source_status(actor, detail.page))}
    end
  end

  @doc false
  def get_in_tx(%Ankole.AuthZ.Actor{} = actor, id) do
    with {:ok, page} <- lock(id, :share),
         {:ok, reachable} <- Access.reachable_anchors(actor, trash_page_id: page.id),
         {:ok, page} <- Access.authorize_with_permissions(actor, page, reachable: reachable),
         {:ok, content} <-
           PageContent |> Ash.Query.filter(page_id == ^page.id) |> Ankole.Ash.read_one(),
         {:ok, ancestors} <- Queries.readable_ancestors_in_tx(actor, page, reachable) do
      {:ok,
       %{
         page: page,
         ancestors: ancestors,
         content: content,
         role: page.role,
         actions: page.actions,
         child_count: Queries.visible_child_count_in_tx(actor, page, reachable)
       }}
    end
  end

  def state(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    uid = Ankole.AuthZ.Actor.uid(actor)

    with :ok <- state_flags(attrs) do
      changes =
        Enum.reduce([{:favorite, :favorited_at}, {:visited, :visited_at}], %{}, fn {input, field},
                                                                                   acc ->
          case Ankole.Attrs.get(attrs, input, :missing) do
            :missing -> acc
            true -> Map.put(acc, field, DateTime.utc_now(:microsecond))
            false -> Map.put(acc, field, nil)
          end
        end)

      changes =
        case Ankole.Attrs.get(attrs, :hide_visits, :missing) do
          :missing -> changes
          hidden -> Map.put(changes, :hide_visits, hidden)
        end

      if changes == %{} do
        Repo.transact_repeatable_read_only(fn ->
          with {:ok, _} <- authorize(actor, id, "node_view"),
               {:ok, state} <-
                 PageUserState
                 |> Ash.Query.filter(principal_uid == ^uid and page_id == ^id)
                 |> Ankole.Ash.read_one(),
               do: {:ok, state || %PageUserState{principal_uid: uid, page_id: id}}
        end)
      else
        Repo.transact_top_level(fn ->
          with {:ok, page} <- lock(id),
               {:ok, _} <- AuthZ.authorize_locked_in_tx(actor, page, "node_view", trash: false),
               :ok <- Ankole.Pod.Documents.Insights.visit_in_tx(page, uid, changes[:visited_at]),
               do: save_state_in_tx(uid, id, changes)
        end)
      end
    end
  end

  @doc """
  Saves one person's page flags in the caller's transaction.

  The upsert changes only the supplied fields. A row without flags is removed.
  """
  def save_state_in_tx(principal_uid, page_id, changes) do
    with {:ok, node} <- Nodes.fetch(page_id),
         {:ok, _} <-
           if(node.kind == :file, do: {:ok, nil}, else: ensure_properties_in_tx(page_id)),
         {:ok, updated} <-
           Ankole.Ash.create(
             PageUserState,
             :put,
             Map.merge(changes, %{principal_uid: principal_uid, page_id: page_id}),
             upsert_fields: Map.keys(changes)
           ) do
      if is_nil(updated.favorited_at) and is_nil(updated.visited_at) and
           is_nil(updated.comments_read_at) and is_nil(updated.edited_at) and
           not updated.hide_visits do
        {:ok, _} = Ankole.Ash.destroy(updated, :remove_empty)
      end

      {:ok, updated}
    end
  end

  defp state_flags(attrs) when is_map(attrs) do
    if Enum.all?(
         [:favorite, :visited, :hide_visits],
         &(Ankole.Attrs.get(attrs, &1, :missing) in [:missing, true, false])
       ),
       do: :ok,
       else: {:error, :invalid_request}
  end

  defp state_flags(_attrs), do: {:error, :invalid_request}

  @doc "Locks one page row in the caller's transaction."
  def lock(id, mode \\ :update) do
    with {:ok, _} <- Nodes.lock(id, mode), do: fetch(id)
  end

  defdelegate lock_tree(), to: Nodes

  defdelegate broadcast(id), to: Ankole.Files, as: :broadcast_node

  def broadcast_comments(id) do
    Phoenix.PubSub.broadcast(Ankole.PubSub, "pod-page:" <> id, {:comments_committed, id})
  end

  def broadcast_access do
    Phoenix.PubSub.broadcast(Ankole.PubSub, "drive-access:" <> Repo.tenant_id!(), :recheck_access)
  end

  @doc "Publishes a committed tree or permission change, and the changed page."
  def committed(%{page: page}), do: committed(page)

  def committed(result) do
    Access.broadcast_change()
    committed_page(result)
  end

  def committed_tree(%{page: page, undo: undo} = result) do
    if result[:access_changed], do: Access.broadcast_change(), else: broadcast_access()

    content_event(
      {:tree_changed, Enum.uniq([directory_location(page), directory_location(undo)]), page.id,
       false}
    )

    broadcast(page.id)
  end

  def committed_tree(%Page{} = page) do
    broadcast_access()
    publish_tree(page)
  end

  def committed_tree(%{page: page}), do: committed_tree(page)

  @doc false
  def committed_access_tree(page) do
    Access.broadcast_change()
    publish_tree(page)
  end

  defp publish_tree(page) do
    content_event(
      {:tree_changed, [directory_location(page)], page.id, not is_nil(page.deleted_at)}
    )

    broadcast(page.id)
  end

  defp directory_location(page), do: Map.take(page, [:parent_id, :private_owner_uid])

  defp content_event(event),
    do: Phoenix.PubSub.broadcast(Ankole.PubSub, "drive-content:" <> Repo.tenant_id!(), event)

  @doc "Publishes a committed change of one page."
  def committed_page(%Page{id: id}) do
    Ankole.Files.node_committed(%{id: id})
  end

  def committed_page(_result), do: :ok

  defp destination(actor, nil, nil) do
    with {:ok, bits} <- Access.space_bits(actor),
         true <- Bitwise.band(bits, 4) != 0,
         do: :ok,
         else: (_ -> {:error, :forbidden})
  end

  defp initial_content(%{type: :doc} = page, uid, _skip, xml) do
    with {:ok, parsed} <- Ankole.Kernel.page_validate(xml || "<page />"),
         {:ok, info} <- Ankole.Kernel.page_comment_info(parsed.xml),
         :ok <- Ankole.Pod.Comments.validate_marks_in_tx(page.id, info.ids),
         {:ok, content} <-
           Ankole.Ash.create(PageContent, :create_in_tx, %{
             page_id: page.id,
             content: parsed.xml,
             plain_text: parsed.plain_text,
             updated_by: ActorRef.from_writer(uid, Repo.tenant_id!(), []),
             updated_at: page.updated_at
           }),
         do: History.checkpoint_in_tx(page, content, page.created_at, :created)
  end

  defp initial_content(%{type: :base} = page, uid, false, nil) do
    with {:ok, _} <- Ankole.Pod.Bases.init_default_table_in_tx(page, uid), do: :ok
  end

  defp initial_content(_page, _uid, _skip, nil), do: :ok
  defp initial_content(_page, _uid, _skip, _xml), do: {:error, :invalid_request}

  defp source_message(_uid, nil), do: {:ok, nil}

  defp source_message(%Ankole.AuthZ.Actor{} = actor, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %Ankole.Conversations.Message{} = message} <-
           Ankole.Conversations.get_message(id),
         {:ok, _} <- source_conversation(actor, message.conversation_id),
         do: {:ok, message},
         else: (_ -> {:error, :not_found})
  end

  defp source_status(_uid, %{saved_from_message_id: nil}), do: nil

  defp source_status(%Ankole.AuthZ.Actor{} = actor, page) do
    case Ankole.Conversations.get_message!(page.saved_from_message_id) do
      nil ->
        %{deleted: true}

      message ->
        case source_conversation(actor, message.conversation_id) do
          {:ok, conversation} ->
            %{
              id: conversation.id,
              title: conversation.title,
              message_id: message.id,
              deleted: false
            }

          _ ->
            nil
        end
    end
  end

  defp source_conversation(%Ankole.AuthZ.Actor{} = actor, id) do
    uid = Ankole.AuthZ.Actor.uid(actor)

    with {:ok, principal} <- Access.principal(actor) do
      if principal.type == :agent do
        Ankole.Conversations.Target.conversation_for_agent_in_tx(uid, id)
      else
        Ankole.Conversations.visible_native_conversation(actor, id)
      end
    end
  end

  defp schedule_purge(page), do: Nodes.schedule_purge(page)
end
