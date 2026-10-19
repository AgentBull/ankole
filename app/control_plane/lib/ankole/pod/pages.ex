defmodule Ankole.Pod.Pages do
  @moduledoc "Owns the tenant's page tree, page permissions, and navigation."
  import Ecto.Query
  alias Ankole.{ActorRef, AuthZ, Repo}
  alias Ankole.Pod.{Access, Page, PageContent, PageUserState}

  @doc "Checks the active Principal and the page's inherited AuthZ permission."
  def authorize(uid, id, action) do
    with {:ok, page} <- fetch(id), do: Access.authorize(uid, page, action)
  end

  def fetch(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Page{} = page <- Repo.get(Page, id),
         do: {:ok, page},
         else: (_ -> {:error, :not_found})
  end

  def create(uid, attrs, authority \\ nil) when is_map(attrs) do
    mutate(authority, fn ->
      lock_tree()

      with {:ok, principal} <- Access.principal(uid),
           {:ok, _} <- Access.ensure_space(),
           :ok <-
             destination(
               uid,
               Ankole.Attrs.get(attrs, :parent_id),
               Ankole.Attrs.get(attrs, :private_owner_uid)
             ),
           {:ok, source} <- source_message(uid, Ankole.Attrs.get(attrs, :saved_from_message_id)) do
        now = DateTime.utc_now(:microsecond)

        attrs = %{
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
          created_by: ActorRef.from_principal(principal),
          created_at: now,
          updated_at: now
        }

        with {:ok, page} <- Repo.insert(Page.changeset(%Page{}, attrs)),
             :ok <- initial_content(page, uid) do
          {:ok, page}
        end
      end
    end)
  end

  def update(uid, id, attrs, authority \\ nil) do
    mutate(
      authority,
      fn ->
        with {:ok, page} <- lock(id), {:ok, _} <- Access.authorize(uid, page, "page_edit") do
          changes =
            Map.new([:title, :icon], fn key ->
              {key, Ankole.Attrs.get(attrs, key, Map.get(page, key))}
            end)

          Repo.update(
            Page.changeset(page, Map.put(changes, :updated_at, DateTime.utc_now(:microsecond)))
          )
        end
      end,
      access: false
    )
  end

  def move(uid, id, attrs, authority \\ nil) do
    mutate(authority, fn ->
      lock_tree()

      with {:ok, page} <- lock(id),
           {:ok, _} <- Access.authorize_move_source(uid, page),
           parent = Ankole.Attrs.get(attrs, :parent_id),
           owner = Ankole.Attrs.get(attrs, :private_owner_uid),
           :ok <- destination(uid, parent, owner, false),
           :ok <- no_cycle(page, parent),
           {:ok, _} <- Access.authorize_move(uid, page, parent, owner),
           # Recheck the destination after the complete subtree policy proof.
           :ok <- destination(uid, parent, owner, false) do
        Repo.update(
          Page.changeset(page, %{
            parent_id: parent,
            private_owner_uid: owner,
            position: Ankole.Attrs.get(attrs, :position, next_position(parent, owner)),
            updated_at: DateTime.utc_now(:microsecond)
          })
        )
      end
    end)
  end

  def delete(uid, id, authority \\ nil) do
    mutate(authority, fn ->
      lock_tree()

      with {:ok, page} <- lock(id),
           {:ok, _} <- Access.authorize(uid, page, "page_manage"),
           {:ok, page} <-
             Repo.update(Page.changeset(page, %{deleted_at: DateTime.utc_now(:microsecond)})),
           :ok <- schedule_purge(page) do
        {:ok, page}
      end
    end)
  end

  def delete_embed(uid, parent_id, child_id, authority \\ nil) do
    mutate(authority, fn ->
      lock_tree()

      with {:ok, parent} <- authorize(uid, parent_id, "page_edit") do
        parent_id = parent.id

        case lock(child_id) do
          {:ok, %Page{parent_id: ^parent_id} = child} -> delete_embedded_child(uid, child)
          _reference -> {:ok, nil}
        end
      end
    end)
  end

  defp delete_embedded_child(uid, child) do
    with {:ok, _} <- Access.authorize(uid, child, "page_manage"),
         {:ok, child} <-
           Repo.update(Page.changeset(child, %{deleted_at: DateTime.utc_now(:microsecond)})),
         :ok <- schedule_purge(child),
         do: {:ok, nil}
  end

  def restore(uid, id, authority \\ nil) do
    mutate(authority, fn ->
      lock_tree()

      with {:ok, page} <- lock(id),
           {:ok, _} <- Access.authorize(uid, page, "page_manage", trash: true),
           true <- not is_nil(page.deleted_at),
           true <- is_nil(page.purge_started_at),
           {:ok, path} <- Access.path(page),
           true <- Enum.all?(Enum.drop(path, -1), &is_nil(&1.deleted_at)) do
        Repo.update(Page.changeset(page, %{deleted_at: nil}))
      else
        false -> {:error, :cannot_restore}
        error -> error
      end
    end)
  end

  def list(uid, opts \\ %{}) do
    scope = Ankole.Attrs.get(opts, :scope, "all")

    with {:ok, navigation} <- Access.navigation(uid) do
      visible =
        navigation
        |> Enum.filter(fn {_id, item} ->
          not item.deleted and not item.ancestor_deleted and
            Bitwise.band(item.actions, 1) != 0
        end)
        |> Map.new()

      ids =
        if scope == "trash" do
          for {id, item} <- navigation,
              item.deleted and not item.ancestor_deleted and
                Bitwise.band(item.actions, 4) != 0,
              do: id
        else
          Map.keys(visible)
        end

      query = from(p in Page, where: p.id in ^ids, order_by: [asc: p.position, asc: p.id])
      pages = query |> filter_search(Ankole.Attrs.get(opts, :query)) |> Repo.all()

      states =
        Repo.all(from s in PageUserState, where: s.principal_uid == ^uid)
        |> Map.new(&{&1.page_id, &1})

      pages = Enum.filter(pages, &in_scope?(&1, uid, scope, visible, states, navigation))
      pages = Enum.map(pages, &%{&1 | role: navigation[&1.id].role})

      pages =
        case scope do
          "trash" -> Enum.sort_by(pages, & &1.deleted_at, {:desc, DateTime})
          "recent" -> Enum.sort_by(pages, &states[&1.id].visited_at, {:desc, DateTime})
          "favorites" -> Enum.sort_by(pages, &states[&1.id].favorited_at, {:desc, DateTime})
          _ -> pages
        end

      {:ok, pages}
    end
  end

  def get(uid, id) do
    with {:ok, detail} <-
           Repo.transact(fn _repo ->
             with {:ok, page} <- __MODULE__.lock(id, :share),
                  {:ok, page} <- Access.authorize_with_role(uid, page) do
               {:ok, %{page: page, content: Repo.get(PageContent, page.id), role: page.role}}
             end
           end) do
      {:ok, Map.put(detail, :source_conversation, source_status(uid, detail.page))}
    end
  end

  def state(uid, id, attrs) do
    with :ok <- state_flags(attrs),
         {:ok, _} <- authorize(uid, id, "page_view") do
      Repo.transact(fn _repo ->
        state =
          Repo.get_by(PageUserState, principal_uid: uid, page_id: id) ||
            %PageUserState{principal_uid: uid, page_id: id}

        changes =
          Enum.reduce([{:favorite, :favorited_at}, {:visited, :visited_at}], %{}, fn {input,
                                                                                      field},
                                                                                     acc ->
            case Ankole.Attrs.get(attrs, input, :missing) do
              :missing -> acc
              true -> Map.put(acc, field, DateTime.utc_now(:microsecond))
              false -> Map.put(acc, field, nil)
            end
          end)

        Repo.insert_or_update(PageUserState.changeset(state, changes))
      end)
    end
  end

  defp state_flags(attrs) when is_map(attrs) do
    if Enum.all?(
         [:favorite, :visited],
         &(Ankole.Attrs.get(attrs, &1, :missing) in [:missing, true, false])
       ),
       do: :ok,
       else: {:error, :invalid_request}
  end

  defp state_flags(_attrs), do: {:error, :invalid_request}

  def sharing(uid, id) do
    with {:ok, page} <- authorize(uid, id, "page_manage") do
      {:ok,
       %{
         inherit_permissions: page.inherit_permissions,
         sharing_version: sharing_version(page),
         subjects: sharing_subjects(),
         grants: grouped_grants(Access.page_grants(id)),
         members:
           Ankole.Principals.list_active_principals()
           |> Enum.map(&Map.take(&1, [:uid, :display_name, :type])),
         groups: AuthZ.list_principal_groups() |> Enum.map(&Map.take(&1, [:id, :name]))
       }}
    end
  end

  def subjects(uid) do
    with {:ok, _} <- Access.principal(uid), do: {:ok, sharing_subjects()}
  end

  def set_sharing(uid, id, attrs, authority \\ nil) do
    mutate(authority, fn ->
      lock_tree()

      with {:ok, page} <- lock(id),
           {:ok, _} <- Access.authorize(uid, page, "page_manage"),
           :ok <- sharing_cas(page, Ankole.Attrs.get(attrs, :sharing_version)),
           {:ok, grants} <- normalize_grants(Ankole.Attrs.get(attrs, :grants, :unchanged)),
           {:ok, page} <-
             Repo.update(
               Page.changeset(page, %{
                 inherit_permissions:
                   Ankole.Attrs.get(attrs, :inherit_permissions, page.inherit_permissions)
               })
             ),
           :ok <- replace_grants(id, grants),
           :ok <- retain_manager(uid, page) do
        {:ok, page}
      end
    end)
  end

  def space(uid) do
    with {:ok, _} <- Access.principal(uid),
         {:ok, group} <- Access.ensure_space(),
         {:ok, grants} <- AuthZ.list_group_grants(group.id) do
      actions = for g <- grants, g.resource_pattern == "pod:space:**", do: g.action

      role =
        cond do
          "page_manage" in actions -> "manage"
          "page_edit" in actions -> "edit"
          true -> "view"
        end

      agent_grants =
        Repo.all(
          from(grant in Ankole.AuthZ.Grant,
            where:
              grant.resource_pattern == "pod:space:**" and not is_nil(grant.principal_uid) and
                grant.action in ~w(page_view page_edit page_manage)
          )
        )

      agents = agent_grants |> grouped_grants() |> Enum.filter(&(&1.kind == :agent))
      {:ok, %{role: role, can_manage: AuthZ.allowed?(uid, "pod:space", "update"), agents: agents}}
    end
  end

  def set_space(uid, role, authority \\ nil) do
    mutate(authority, fn ->
      lock_tree()

      with :ok <- AuthZ.authorize(uid, "pod:space", "update"),
           {:ok, group} <- Access.ensure_space(),
           :ok <- Access.put_role(%{group_id: group.id}, "pod:space:**", role),
           do: {:ok, %{role: role}}
    end)
  end

  def space_agent(uid, agent_uid, role, authority \\ nil) do
    mutate(authority, fn ->
      lock_tree()

      with :ok <- AuthZ.authorize(uid, "pod:space", "update"),
           {:ok, %{type: :agent}} <- Ankole.Principals.get_principal(agent_uid),
           :ok <- Access.put_role(%{principal_uid: agent_uid}, "pod:space:**", role),
           do: {:ok, %{principal_uid: agent_uid, role: role}},
           else: (error -> error)
    end)
  end

  def remove_space_agent(uid, agent_uid, authority \\ nil) do
    mutate(authority, fn ->
      lock_tree()

      with :ok <- AuthZ.authorize(uid, "pod:space", "update") do
        Repo.all(
          from(g in Ankole.AuthZ.Grant,
            where:
              g.principal_uid == ^agent_uid and g.resource_pattern == "pod:space:**" and
                g.action in ~w(page_view page_edit page_manage)
          )
        )
        |> Access.remove_grants()

        {:ok, %{principal_uid: agent_uid}}
      end
    end)
  end

  def versions(uid, ids) when is_list(ids) do
    with {:ok, navigation} <- Access.navigation(uid),
         do: {:ok, page_versions(ids, navigation)}
  end

  def versions(_uid, _ids), do: {:error, :invalid_request}

  def reconcile_versions(uid, page_ids, table_ids)
      when is_list(page_ids) and is_list(table_ids) do
    with {:ok, navigation} <- Access.navigation(uid) do
      pages = page_versions(page_ids, navigation)
      table_ids = for id <- Enum.uniq(table_ids), {:ok, id} <- [Ecto.UUID.cast(id)], do: id
      visible = for {id, item} <- navigation, visible?(item), do: id

      tables =
        Repo.all(
          from t in Ankole.Pod.DbTable,
            where: t.id in ^table_ids and t.page_id in ^visible,
            select: %{id: t.id, data_version: t.data_version}
        )

      {:ok,
       %{
         pages: Enum.map(pages, fn {id, revision} -> %{id: id, revision: revision} end),
         tables: tables
       }}
    end
  end

  def reconcile_versions(_uid, _page_ids, _table_ids), do: {:error, :invalid_request}

  defp page_versions(ids, navigation) do
    visible = for id <- Enum.uniq(ids), item = navigation[id], item && visible?(item), do: id
    Map.new(Repo.all(from p in Page, where: p.id in ^visible, select: {p.id, p.revision}))
  end

  defp visible?(item),
    do: not item.deleted and not item.ancestor_deleted and Bitwise.band(item.actions, 1) != 0

  def lock(id, mode \\ :update) when mode in [:update, :share] do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      query = from(p in Page, where: p.id == ^id)

      query =
        if mode == :share,
          do: from(p in query, lock: "FOR SHARE"),
          else: from(p in query, lock: "FOR UPDATE")

      case Repo.one(query) do
        %Page{} = page -> {:ok, page}
        nil -> {:error, :not_found}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Locks tree changes before page, table, or permission rows in the transaction."
  def lock_tree do
    :ok = Repo.require_transaction(Repo)
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["pod-tree:" <> Repo.tenant_id!()])
    :ok
  end

  def broadcast(id) do
    Phoenix.PubSub.broadcast(Ankole.PubSub, "pod-page:" <> id, {:page_committed, id})
  end

  def broadcast_access do
    Phoenix.PubSub.broadcast(Ankole.PubSub, "pod-access:" <> Repo.tenant_id!(), :recheck_access)
  end

  defp mutate(authority, fun, opts \\ []) do
    nested? = Repo.in_transaction?()
    result = Access.write_transaction(authority, fn _repo -> fun.() end)

    if not nested? and match?({:ok, _}, result) do
      if Keyword.get(opts, :access, true), do: broadcast_access()
      if match?({:ok, %Page{}}, result), do: broadcast(elem(result, 1).id)
    end

    result
  end

  defp destination(uid, parent, owner, initialize_private \\ true)

  defp destination(uid, nil, nil, _initialize_private) do
    case AuthZ.authorize(uid, "pod:space:page", "page_edit") do
      :ok -> :ok
      _ -> AuthZ.authorize(uid, "pod:space", "update")
    end
  end

  defp destination(uid, nil, uid, initialize_private) do
    with {:ok, %{type: :human}} <- Access.principal(uid) do
      # Creating a Private root initializes its owner grant. A move must not
      # create grants while proving that its permissions remain unchanged.
      if initialize_private, do: Access.ensure_private(uid), else: :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp destination(_uid, nil, _owner, _initialize_private), do: {:error, :forbidden}

  defp destination(uid, parent, nil, _initialize_private) do
    with {:ok, %{type: :doc}} <- authorize(uid, parent, "page_edit"),
         do: :ok,
         else: (
           {:ok, _} -> {:error, :invalid_parent}
           error -> error
         )
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
    query = from(p in Page, order_by: [desc: p.position], limit: 1, select: p.position)

    query =
      if parent,
        do: from(p in query, where: p.parent_id == ^parent),
        else: from(p in query, where: is_nil(p.parent_id))

    query =
      if owner,
        do: from(p in query, where: p.private_owner_uid == ^owner),
        else: from(p in query, where: is_nil(p.private_owner_uid))

    (Repo.one(query) || "") <> "U"
  end

  defp initial_content(%{type: :doc} = page, uid) do
    with {:ok, parsed} <- Ankole.Kernel.page_validate("<page />"),
         {:ok, _} <-
           Repo.insert(
             PageContent.changeset(%PageContent{}, %{
               page_id: page.id,
               content: parsed.xml,
               plain_text: parsed.plain_text,
               updated_by: ActorRef.from_writer(uid, Repo.tenant_id!(), []),
               updated_at: page.updated_at
             })
           ),
         do: :ok
  end

  defp initial_content(_page, _uid), do: :ok

  defp filter_search(query, term) when is_binary(term) and term != "" do
    term = "%" <> Repo.escape_like(term) <> "%"

    from(p in query,
      left_join: c in PageContent,
      on: c.page_id == p.id,
      where: ilike(p.title, ^term) or ilike(c.plain_text, ^term)
    )
  end

  defp filter_search(query, _term), do: query

  defp in_scope?(page, _uid, "space", _visible, _states, navigation),
    do: is_nil(navigation[page.id].root_private_owner_uid)

  defp in_scope?(page, uid, "private", _visible, _states, navigation),
    do: navigation[page.id].root_private_owner_uid == uid

  defp in_scope?(page, uid, "shared", visible, _states, navigation),
    do:
      navigation[page.id].root_private_owner_uid != uid and
        navigation[page.id].directly_shared and
        (is_nil(page.parent_id) or not Map.has_key?(visible, page.parent_id))

  defp in_scope?(page, _uid, "recent", _visible, states, _navigation),
    do: states[page.id] != nil and states[page.id].visited_at != nil

  defp in_scope?(page, _uid, "favorites", _visible, states, _navigation),
    do: states[page.id] != nil and states[page.id].favorited_at != nil

  defp in_scope?(_page, _uid, _scope, _visible, _states, _navigation), do: true

  defp sharing_version(page) do
    grants =
      Access.page_grants(page.id)
      |> Enum.map(&{&1.principal_uid, &1.group_id, &1.action, &1.condition})
      |> Enum.sort()

    :crypto.hash(:sha256, :erlang.term_to_binary({page.inherit_permissions, grants}))
    |> Base.encode16(case: :lower)
  end

  defp sharing_cas(_page, nil), do: {:error, :sharing_conflict}

  defp sharing_cas(page, expected) do
    if expected == sharing_version(page), do: :ok, else: {:error, :sharing_conflict}
  end

  defp normalize_grants(:unchanged), do: {:ok, :unchanged}

  defp normalize_grants(grants) when is_list(grants) do
    Enum.reduce_while(grants, {:ok, []}, fn
      grant, {:ok, acc} when is_map(grant) ->
        owner =
          Map.new(
            for key <- [:principal_uid, :group_id],
                Ankole.Attrs.get(grant, key),
                do: {key, Ankole.Attrs.get(grant, key)}
          )

        with true <- map_size(owner) == 1,
             {:ok, _} <- Access.actions(Ankole.Attrs.get(grant, :role)) do
          {:cont, {:ok, [{owner, Ankole.Attrs.get(grant, :role)} | acc]}}
        else
          _ -> {:halt, {:error, :invalid_grants}}
        end

      _, _ ->
        {:halt, {:error, :invalid_grants}}
    end)
  end

  defp normalize_grants(_), do: {:error, :invalid_grants}
  defp replace_grants(_id, :unchanged), do: :ok

  defp replace_grants(id, grants) do
    Access.page_grants(id) |> Access.remove_grants()

    Enum.reduce_while(grants, :ok, fn {owner, role}, :ok ->
      case Access.put_role(owner, "pod:**:#{id}:**", role) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp retain_manager(uid, %{inherit_permissions: false} = page),
    do: Access.put_role(%{principal_uid: uid}, "pod:**:#{page.id}:**", "manage")

  defp retain_manager(_uid, _page), do: :ok

  defp sharing_subjects do
    principals =
      Enum.map(Ankole.Principals.list_active_principals(), fn principal ->
        %{principal_uid: principal.uid, name: principal.display_name, kind: principal.type}
      end)

    groups =
      Enum.map(AuthZ.list_principal_groups(), &%{group_id: &1.id, name: &1.name, kind: :group})

    principals ++ groups
  end

  defp grouped_grants(grants) do
    subjects = sharing_subjects()

    grants
    |> Enum.group_by(&{&1.principal_uid, &1.group_id})
    |> Enum.map(fn {{uid, group}, grants} ->
      actions = Enum.map(grants, & &1.action)

      role =
        cond do
          "page_manage" in actions -> "manage"
          "page_edit" in actions -> "edit"
          true -> "view"
        end

      subject =
        Enum.find(subjects, fn subject ->
          (uid && Map.get(subject, :principal_uid) == uid) ||
            (group && Map.get(subject, :group_id) == group)
        end) || %{}

      Map.merge(Map.take(subject, [:name, :kind]), %{
        principal_uid: uid,
        group_id: group,
        role: role
      })
    end)
  end

  defp source_message(_uid, nil), do: {:ok, nil}

  defp source_message(uid, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Ankole.Conversations.Message{} = message <-
           Repo.get_by(Ankole.Conversations.Message, id: id),
         {:ok, _} <- source_conversation(uid, message.conversation_id),
         do: {:ok, message},
         else: (_ -> {:error, :not_found})
  end

  defp source_status(_uid, %{saved_from_message_id: nil}), do: nil

  defp source_status(uid, page) do
    case Repo.get_by(Ankole.Conversations.Message, id: page.saved_from_message_id) do
      nil ->
        %{deleted: true}

      message ->
        case source_conversation(uid, message.conversation_id) do
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

  defp source_conversation(uid, id) do
    with {:ok, principal} <- Access.principal(uid) do
      if principal.type == :agent do
        Ankole.Conversations.Target.conversation_for_agent_in_tx(Repo, uid, id)
      else
        with {:ok, %{conversation: conversation}} <- Ankole.Conversations.get(uid, id),
             do: {:ok, conversation}
      end
    end
  end

  @doc false
  def schedule_purge(page) do
    case Ankole.Pod.Config.trash_retention_days() do
      {:ok, days} ->
        Ankole.Job.schedule_in_tx(
          Repo,
          Ankole.Pod.Jobs.PurgePage,
          %{tenant_id: Repo.tenant_id!(), page_id: page.id},
          DateTime.add(page.deleted_at, days * 86_400, :second)
        )

      error ->
        error
    end
  end
end
