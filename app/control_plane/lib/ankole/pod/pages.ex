defmodule Ankole.Pod.Pages do
  @moduledoc """
  Owns the tenant's page tree, page details, and personal page state.

  Each operation that changes the tree or reads under a page lock runs in a
  top-level transaction. The `*_in_tx` functions run in the caller's
  transaction and do not publish.
  """
  require Ash.Query
  alias Ankole.{ActorRef, AuthZ, Repo}
  alias Ankole.Pod.{Access, Page, PageContent, PageUserState, Position}
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
    {anchors, own} = Access.visibility_ids(reachable, 8)

    Page
    |> Ash.Query.filter(
      id in ^ids and is_nil(deleted_at) and (acl_anchor_id in ^anchors or id in ^own)
    )
    |> Ash.Query.select([:id])
    |> Ankole.Ash.read!()
    |> MapSet.new(& &1.id)
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
      after_commit: &committed_tree/1
    )
  end

  @doc "Creates a page in the caller's transaction."
  def create_in_tx(%Ankole.AuthZ.Actor{} = actor, attrs) when is_map(attrs) do
    uid = Ankole.AuthZ.Actor.uid(actor)
    lock_tree()

    with {:ok, principal} <- Access.principal(actor),
         {:ok, _} <- Access.space_group(),
         :ok <-
           destination(
             actor,
             Ankole.Attrs.get(attrs, :parent_id),
             Ankole.Attrs.get(attrs, :private_owner_uid)
           ),
         {:ok, source} <- source_message(actor, Ankole.Attrs.get(attrs, :saved_from_message_id)),
         {:ok, children_view} <-
           normalize_children_view(Ankole.Attrs.get(attrs, :children_view, %{})) do
      now = DateTime.utc_now(:microsecond)

      skip_default_table = Ankole.Attrs.get(attrs, :skip_default_table, false)
      xml = Ankole.Attrs.get(attrs, :xml)

      attrs = %{
        id: Ankole.Ecto.UUIDv7.autogenerate(),
        type: Ankole.Attrs.get(attrs, :type, "doc"),
        title: Ankole.Attrs.get(attrs, :title, ""),
        icon: Ankole.Attrs.get(attrs, :icon),
        parent_id: Ankole.Attrs.get(attrs, :parent_id),
        private_owner_uid: Ankole.Attrs.get(attrs, :private_owner_uid),
        position:
          Ankole.Attrs.get(
            attrs,
            :position,
            next_position(
              Ankole.Attrs.get(attrs, :parent_id),
              Ankole.Attrs.get(attrs, :private_owner_uid)
            )
          ),
        saved_from_message_id: source && source.id,
        children_view: children_view,
        created_by: ActorRef.from_principal(principal),
        created_at: now,
        updated_at: now
      }

      attrs = Access.anchor_attributes(attrs)

      with {:ok, page} <- Ankole.Ash.create(Page, :create_in_tx, attrs),
           :ok <- initial_content(page, uid, skip_default_table, xml) do
        {:ok, page}
      end
    end
  end

  def update(%Ankole.AuthZ.Actor{} = actor, id, attrs, authority \\ nil) do
    authority = authority || actor.turn_authority

    Access.write(authority, fn -> update_in_tx(actor, id, attrs) end,
      after_commit: &committed_page/1
    )
  end

  @doc false
  def update_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    with {:ok, page} <- lock(id),
         {:ok, _} <- AuthZ.authorize_locked_in_tx(actor, page, "page_edit"),
         :ok <- check_title_base(page, attrs),
         {:ok, children_view} <- merge_children_view(page.children_view, attrs) do
      changes =
        Map.new([:title, :icon], fn key ->
          {key, Ankole.Attrs.get(attrs, key, Map.get(page, key))}
        end)

      identity_edited? =
        Enum.any?(changes, fn {key, value} -> Map.fetch!(page, key) != value end)

      now = DateTime.utc_now(:microsecond)

      updated_at =
        if identity_edited? or Ankole.Attrs.get(attrs, :children_view, :missing) == :missing,
          do: now,
          else: page.updated_at

      with :ok <- record_document_edit(page, changes, actor, now) do
        Ankole.Ash.update(
          page,
          :edit,
          changes
          |> Map.put(:children_view, children_view)
          |> Map.put(:updated_at, updated_at)
        )
      end
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
      after_commit: &committed_tree/1
    )
  end

  @doc false
  def move_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    lock_tree()

    with {:ok, page} <- lock(id),
         {:ok, _} <- Access.authorize_move_source(actor, page),
         parent = Ankole.Attrs.get(attrs, :parent_id),
         owner = Ankole.Attrs.get(attrs, :private_owner_uid),
         :ok <- destination(actor, parent, owner, false),
         :ok <- no_cycle(page, parent),
         {:ok, _} <- Access.authorize_move(actor, page, parent, owner),
         :ok <- destination(actor, parent, owner),
         undo = previous_location(page),
         {:ok, position} <- move_position(page, parent, owner, attrs),
         {:ok, moved} <-
           Access.update_anchor_in_tx(page, :move, %{
             parent_id: parent,
             private_owner_uid: owner,
             position: position,
             updated_at: DateTime.utc_now(:microsecond)
           }) do
      access_changed =
        page.acl_anchor_id != moved.acl_anchor_id or
          page.parent_anchor_id != moved.parent_anchor_id or
          page.private_owner_uid != moved.private_owner_uid

      {:ok, %{page: moved, undo: undo, access_changed: access_changed}}
    end
  end

  defp previous_location(page) do
    location = Map.take(page, [:parent_id, :private_owner_uid])

    query =
      Page
      |> in_destination(page.parent_id, page.private_owner_uid)
      |> Ash.Query.filter(is_nil(deleted_at) and id != ^page.id)
      |> Ash.Query.select([:id])
      |> Ash.Query.limit(1)

    next =
      query
      |> Ash.Query.filter(
        position > ^page.position or (position == ^page.position and id > ^page.id)
      )
      |> Ash.Query.sort(position: :asc, id: :asc)
      |> Ankole.Ash.read_one!()

    if next do
      Map.put(location, :before_id, next.id)
    else
      previous =
        query
        |> Ash.Query.filter(
          position < ^page.position or (position == ^page.position and id < ^page.id)
        )
        |> Ash.Query.sort(position: :desc, id: :desc)
        |> Ankole.Ash.read_one!()

      if previous, do: Map.put(location, :after_id, previous.id), else: location
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
        {:ok, _} = Ankole.Ash.update(sibling, :position, %{position: key})
        result
    end)
  end

  defp siblings(parent, owner, moving_id) do
    Page
    |> Ash.Query.filter(id != ^moving_id and is_nil(deleted_at))
    |> in_destination(parent, owner)
    |> Ash.Query.sort(position: :asc, id: :asc)
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
      after_commit: &committed_access_tree/1
    )
  end

  @doc false
  def delete_in_tx(%Ankole.AuthZ.Actor{} = actor, id) do
    lock_tree()

    with {:ok, page} <- lock(id),
         {:ok, _} <- AuthZ.authorize_locked_in_tx(actor, page, "page_manage"),
         {:ok, page} <-
           Access.update_anchor_in_tx(page, :trash, %{deleted_at: DateTime.utc_now(:microsecond)}),
         :ok <- schedule_purge(page) do
      {:ok, page}
    end
  end

  def delete_embeds(%Ankole.AuthZ.Actor{} = actor, parent_id, child_ids, authority \\ nil) do
    authority = authority || actor.turn_authority

    with {:ok, _} <-
           Access.write_tree(
             authority,
             fn -> delete_embeds_in_tx(actor, parent_id, child_ids) end,
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

    with {:ok, parent} <- authorize(actor, parent_id, "page_edit") do
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
        do: "page_edit",
        else: "page_manage"

    with {:ok, _} <- Access.authorize(actor, child, action),
         {:ok, child} <-
           Access.update_anchor_in_tx(child, :trash, %{deleted_at: DateTime.utc_now(:microsecond)}),
         :ok <- schedule_purge(child),
         do: {:ok, child}
  end

  def restore(%Ankole.AuthZ.Actor{} = actor, id, authority \\ nil) do
    authority = authority || actor.turn_authority

    Access.write_tree(authority, fn -> restore_in_tx(actor, id) end,
      after_commit: &committed_access_tree/1
    )
  end

  @doc false
  def restore_in_tx(%Ankole.AuthZ.Actor{} = actor, id) do
    lock_tree()

    with {:ok, page} <- lock(id),
         {:ok, _} <- AuthZ.authorize_locked_in_tx(actor, page, "page_manage", trash: true),
         true <- not is_nil(page.deleted_at),
         true <- is_nil(page.purge_started_at),
         {:ok, path} <- Access.path(page),
         true <- Enum.all?(Enum.drop(path, -1), &is_nil(&1.deleted_at)) do
      Access.update_anchor_in_tx(page, :restore, %{deleted_at: nil})
    else
      false -> {:error, :cannot_restore}
      error -> error
    end
  end

  def purge(%Ankole.AuthZ.Actor{} = actor, id, authority \\ nil) do
    authority = authority || actor.turn_authority

    Access.write_tree(authority, fn -> purge_in_tx(actor, id) end,
      after_commit: &committed_tree/1
    )
  end

  @doc false
  def purge_in_tx(%Ankole.AuthZ.Actor{} = actor, id) do
    lock_tree()

    with {:ok, page} <- lock(id),
         {:ok, _} <- AuthZ.authorize_locked_in_tx(actor, page, "page_manage", trash: :self),
         true <- not is_nil(page.deleted_at),
         true <- is_nil(page.purge_started_at),
         {:ok, page} <- Ankole.Ash.update(page, :begin_purge, %{}),
         :ok <-
           Ankole.Job.schedule_in_tx(
             Ankole.Pod.Jobs.PurgePage,
             %{tenant_id: Repo.tenant_id!(), page_id: page.id},
             DateTime.utc_now(:microsecond)
           ) do
      {:ok, page}
    else
      false -> {:error, :cannot_purge}
      error -> error
    end
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
          with {:ok, _} <- authorize(actor, id, "page_view"),
               {:ok, state} <-
                 PageUserState
                 |> Ash.Query.filter(principal_uid == ^uid and page_id == ^id)
                 |> Ankole.Ash.read_one(),
               do: {:ok, state || %PageUserState{principal_uid: uid, page_id: id}}
        end)
      else
        Repo.transact_top_level(fn ->
          with {:ok, page} <- lock(id),
               {:ok, _} <- AuthZ.authorize_locked_in_tx(actor, page, "page_view", trash: false),
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
    with {:ok, updated} <-
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
  def lock(id, mode \\ :update) when mode in [:update, :share] do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Page{} = page <-
           Page
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.lock(if(mode == :share, do: "FOR SHARE", else: :for_update))
           |> Ankole.Ash.read_one!() do
      {:ok, page}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Locks tree changes before page, table, or permission rows in the transaction."
  def lock_tree do
    :ok = Repo.require_transaction(Repo)
    Ankole.AdvisoryLock.lock!(Repo, "pod-tree:" <> Repo.tenant_id!())
    :ok
  end

  def broadcast(id) do
    Phoenix.PubSub.broadcast(Ankole.PubSub, "pod-page:" <> id, {:page_committed, id})
  end

  def broadcast_comments(id) do
    Phoenix.PubSub.broadcast(Ankole.PubSub, "pod-page:" <> id, {:comments_committed, id})
  end

  def broadcast_access do
    Phoenix.PubSub.broadcast(Ankole.PubSub, "pod-access:" <> Repo.tenant_id!(), :recheck_access)
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

  defp committed_access_tree(page) do
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
    do: Phoenix.PubSub.broadcast(Ankole.PubSub, "pod-content:" <> Repo.tenant_id!(), event)

  @doc "Publishes a committed change of one page."
  def committed_page(%Page{id: id}) do
    broadcast(id)
    content_event({:page_updated, id})
  end

  def committed_page(_result), do: :ok

  defp destination(uid, parent, owner, initialize_private \\ true)

  defp destination(%Ankole.AuthZ.Actor{} = actor, nil, nil, _initialize_private) do
    with {:ok, bits} <- Access.space_bits(actor),
         true <- Bitwise.band(bits, 4) != 0,
         do: :ok,
         else: (_ -> {:error, :forbidden})
  end

  defp destination(%Ankole.AuthZ.Actor{} = actor, nil, owner, initialize_private) do
    with true <- Ankole.AuthZ.Actor.uid(actor) == owner,
         {:ok, %{type: :human, membership: :member}} <- Access.principal(actor) do
      # Creating a Private root initializes its owner grant. A move must not
      # create grants while proving that its permissions remain unchanged.
      if initialize_private, do: Access.ensure_private(Ankole.AuthZ.Actor.uid(actor)), else: :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp destination(%Ankole.AuthZ.Actor{} = actor, parent, nil, _initialize_private) do
    with {:ok, _parent} <- authorize(actor, parent, "page_edit"), do: :ok
  end

  defp destination(_uid, _parent, _owner, _initialize_private), do: {:error, :invalid_parent}

  defp no_cycle(page, parent_id) do
    if parent_id do
      with {:ok, parent} <- fetch(parent_id), {:ok, path} <- Access.path(parent) do
        if Enum.any?(path, &(&1.id == page.id)), do: {:error, :cycle}, else: :ok
      end
    else
      :ok
    end
  end

  defp next_position(parent, owner) do
    last =
      Page
      |> in_destination(parent, owner)
      |> Ankole.Ash.max!(:position)

    case Position.between(last, nil) do
      {:ok, position} -> position
      :error -> last <> "V"
    end
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

  defp schedule_purge(page) do
    case Ankole.Pod.Config.trash_retention_days() do
      {:ok, days} ->
        Ankole.Job.schedule_in_tx(
          Ankole.Pod.Jobs.PurgePage,
          %{tenant_id: Repo.tenant_id!(), page_id: page.id},
          # With 0 retention the job first checks after a day and keeps the page while it stays 0.
          DateTime.add(page.deleted_at, max(days, 1) * 86_400, :second)
        )

      error ->
        error
    end
  end
end
