defmodule Ankole.Pod.Access do
  @moduledoc false
  import Ecto.Query
  alias Ankole.{AuthZ, Principals, Repo}
  alias Ankole.AuthZ.{Grant, Root}
  import Bitwise
  alias Ankole.Pod.Page
  alias Ankole.Sessions.{JobTurnRef, RunRef}

  @actions ~w(page_view page_edit page_manage)
  @roles %{"view" => ["page_view"], "edit" => ~w(page_view page_edit), "manage" => @actions}

  def page_actions, do: @actions

  def actions(role) when is_binary(role) or is_atom(role), do: Map.fetch(@roles, to_string(role))
  def actions(_role), do: :error

  @doc "Keeps an Agent's current turn locked through the durable Pod write."
  def write_transaction(authority, fun)

  def write_transaction(nil, fun), do: Repo.transact(fun)

  def write_transaction({ref, uid}, fun)
      when (is_struct(ref, RunRef) or is_struct(ref, JobTurnRef)) and ref.agent_uid == uid do
    Repo.transact(fn repo ->
      with {:ok, :authorized} <-
             Ankole.AgentWorkers.WorkerRouteAuth.authorize_turn_in_tx(
               repo,
               ref,
               uid,
               :write,
               lock: true
             ),
           do: fun.(repo)
    end)
  end

  def write_transaction(_authority, _fun), do: {:error, :worker_not_assigned_to_turn}

  def principal(uid) do
    with {:ok, %{status: :active} = principal} <- Principals.get_principal(uid),
         true <- principal.tenant_id == Repo.tenant_id!(),
         do: {:ok, principal},
         else: (_ -> {:error, :forbidden})
  end

  def space_group, do: AuthZ.get_principal_group("all_humans")

  @doc "Sets the initial policy inside the new tenant's creation transaction."
  def initialize_space(repo) do
    with :ok <- Repo.require_transaction(repo),
         {:ok, group} <- Root.ensure_all_humans_group(repo) do
      put_role(%{group_id: group.id}, "pod:space:**", "manage")
    end
  end

  def ensure_private(uid) do
    put_role(%{principal_uid: uid}, "pod:private:#{uid}:**", "manage")
  end

  def authorize(uid, page, action, opts \\ []) when action in @actions do
    with {:ok, path} <- visible_path(uid, page, opts),
         :ok <- decide(uid, path, action) do
      {:ok, page}
    else
      {:error, {:forbidden, _action}} -> {:error, :forbidden}
      error -> error
    end
  end

  def authorize_with_role(uid, page) do
    with {:ok, path} <- visible_path(uid, page, []),
         :ok <- decide(uid, path, "page_view") do
      {:ok, %{page | role: role_on_path(uid, path)}}
    else
      {:error, {:forbidden, _}} -> {:error, :forbidden}
      error -> error
    end
  end

  defp visible_path(uid, page, opts) do
    with {:ok, _} <- principal(uid),
         {:ok, path} <- path(page),
         :ok <- visible_state(path, Keyword.get(opts, :trash, false)),
         do: {:ok, path}
  end

  def path(%Page{parent_id: nil} = page), do: {:ok, [page]}

  def path(%Page{} = page) do
    result =
      Repo.query!(
        """
        WITH RECURSIVE ancestors AS (
          SELECT p.* FROM pages p WHERE p.tenant_id = $1::text::uuid AND p.id = $2::text::uuid
          UNION
          SELECT p.* FROM pages p JOIN ancestors a ON p.id = a.parent_id
            WHERE p.tenant_id = $1::text::uuid
        ) SELECT * FROM ancestors
        """,
        [Repo.tenant_id!(), page.parent_id]
      )

    parents =
      Map.new(result.rows, fn row ->
        parent = Repo.load(Page, {result.columns, row})
        {parent.id, parent}
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

  def resource(path) do
    boundary =
      path
      |> Enum.with_index()
      |> Enum.filter(fn {p, _} -> not p.inherit_permissions end)
      |> List.last()

    case boundary do
      {_, index} ->
        "pod:restricted:" <> Enum.map_join(Enum.drop(path, index), ":", & &1.id) <> ":page"

      nil ->
        root = hd(path)

        prefix =
          if root.private_owner_uid,
            do: "pod:private:#{root.private_owner_uid}:",
            else: "pod:space:"

        prefix <> Enum.map_join(path, ":", & &1.id) <> ":page"
    end
  end

  @doc "Checks the source permission before validating a move's destination and tree."
  def authorize_move_source(uid, page) do
    case authorize(uid, page, "page_manage") do
      {:error, :forbidden} -> authorize(uid, page, "page_edit")
      result -> result
    end
  end

  @doc """
  Allows editors to move a subtree only when every subject keeps the same page actions.
  The caller must hold the Pod tree lock and the moving page's row lock.
  """
  def authorize_move(uid, page, parent_id, private_owner_uid) do
    case authorize(uid, page, "page_manage") do
      {:ok, _} ->
        {:ok, page}

      {:error, :forbidden} ->
        # Every grant writer, including ordinary space-update grants and
        # cascade cleanup, now takes this tenant's tree lock before its rows.
        with {:ok, _} <- authorize(uid, page, "page_edit"),
             {:ok, before} <- path(page),
             {:ok, after_move} <- moved_path(page, parent_id, private_owner_uid),
             true <- move_preserves_permissions?(before, after_move) do
          {:ok, page}
        else
          false -> {:error, :move_requires_manage}
          error -> error
        end

      error ->
        error
    end
  end

  defp moved_path(page, nil, owner),
    do: {:ok, [%{page | parent_id: nil, private_owner_uid: owner}]}

  defp moved_path(page, parent_id, nil) do
    with {:ok, parent_id} <- Ecto.UUID.cast(parent_id),
         %Page{} = parent <- Repo.get(Page, parent_id),
         {:ok, ancestors} <- path(parent) do
      {:ok, ancestors ++ [%{page | parent_id: parent_id, private_owner_uid: nil}]}
    else
      _ -> {:error, :not_found}
    end
  end

  defp moved_path(_page, _parent_id, _owner), do: {:error, :invalid_parent}

  defp move_preserves_permissions?(before, after_move) do
    if resource(before) == resource(after_move) and
         space_fallback?(before) == space_fallback?(after_move) do
      true
    else
      grants = Repo.all(from g in Grant, where: g.action in ^@actions)
      {canonical, opaque} = Enum.split_with(grants, &canonical_grant?/1)

      if opaque == [] do
        # Every inheriting descendant adds the same direct grants on both sides;
        # a restricted descendant resets both paths at the same boundary.
        same_policy?(before, after_move, canonical)
      else
        subtree_preserves_permissions?(before, after_move, canonical, opaque)
      end
    end
  end

  defp canonical_grant?(%{condition: "true", resource_pattern: pattern}) do
    pattern == "pod:space:**" or
      Regex.match?(~r/^pod:private:[a-z0-9_-]+:\*\*$/, pattern) or
      Regex.match?(~r/^pod:\*\*:[0-9a-f-]{36}:\*\*$/, pattern)
  end

  defp canonical_grant?(_grant), do: false

  defp same_policy?(before, after_move, grants) do
    space_fallback?(before) == space_fallback?(after_move) and
      canonical_policy(before, grants) == canonical_policy(after_move, grants)
  end

  defp canonical_policy(path, grants) do
    resource = resource(path)
    ids = MapSet.new(String.split(resource, ":"))

    for grant <- grants,
        canonical_matches?(grant.resource_pattern, resource, ids),
        into: MapSet.new(),
        do: grant_owner_action(grant)
  end

  defp canonical_matches?("pod:space:**", resource, _ids),
    do: String.starts_with?(resource, "pod:space:")

  defp canonical_matches?("pod:private:" <> pattern, resource, _ids),
    do: String.starts_with?(resource, "pod:private:" <> String.trim_trailing(pattern, "**"))

  defp canonical_matches?("pod:**:" <> pattern, _resource, ids),
    do: MapSet.member?(ids, String.trim_trailing(pattern, ":**"))

  defp grant_owner_action(grant),
    do: {grant.principal_uid, grant.group_id, grant.action}

  defp space_fallback?(path),
    do: is_nil(hd(path).private_owner_uid) and Enum.all?(path, & &1.inherit_permissions)

  defp subtree_preserves_permissions?(before, after_move, canonical, opaque) do
    root_id = List.last(before).id

    rows =
      Repo.query!(
        """
        WITH RECURSIVE subtree AS (
          SELECT id, parent_id FROM pages WHERE tenant_id = $1::text::uuid AND id = $2::text::uuid
          UNION ALL SELECT c.id, c.parent_id FROM pages c JOIN subtree s ON c.parent_id = s.id
            WHERE c.tenant_id = $1::text::uuid
        ) SELECT id::text FROM subtree
        """,
        [Repo.tenant_id!(), root_id]
      ).rows

    pages = Repo.all(from p in Page, where: p.id in ^Enum.map(rows, &hd/1))
    children = Enum.group_by(pages, & &1.parent_id)
    subtree_policy?(before, after_move, children, canonical, opaque)
  end

  defp subtree_policy?(before, after_move, children, canonical, opaque) do
    old_resource = resource(before)
    new_resource = resource(after_move)

    preserved =
      old_resource == new_resource or
        (space_fallback?(before) == space_fallback?(after_move) and
           same_opaque_policy?(before, after_move, canonical, opaque))

    preserved and
      Enum.all?(Map.get(children, List.last(before).id, []), fn child ->
        subtree_policy?(before ++ [child], after_move ++ [child], children, canonical, opaque)
      end)
  end

  defp same_opaque_policy?(before, after_move, canonical, opaque) do
    with {:ok, old_policy} <- opaque_policy(before, canonical, opaque),
         {:ok, new_policy} <- opaque_policy(after_move, canonical, opaque),
         do: old_policy == new_policy,
         else: (_ -> false)
  end

  defp opaque_policy(path, canonical, opaque) do
    resource = resource(path)

    Enum.reduce_while(opaque, {:ok, canonical_policy(path, canonical)}, fn grant, {:ok, policy} ->
      case Ankole.Kernel.authz_match_resource_pattern(grant.resource_pattern, resource) do
        false ->
          {:cont, {:ok, policy}}

        true when grant.condition == "true" ->
          {:cont, {:ok, MapSet.put(policy, grant_owner_action(grant))}}

        # CEL can read the resource. Equal source text does not prove equal
        # results for every Principal when the resource changes.
        _ ->
          {:halt, :unproven}
      end
    end)
  end

  defp role_on_path(uid, path) do
    Enum.find(["manage", "edit", "view"], fn role ->
      {:ok, actions} = actions(role)
      decide(uid, path, List.last(actions)) == :ok
    end)
  end

  @doc "Reads effective page actions and root ownership in one traversal of the page tree."
  def navigation(uid) do
    with {:ok, _} <- principal(uid),
         {:ok, groups} <- AuthZ.list_current_groups_for_principal(uid) do
      group_ids = Enum.map(groups, & &1.id)

      grants =
        Repo.all(
          from g in Grant,
            where:
              g.action in ^@actions and
                (g.principal_uid == ^uid or g.group_id in ^group_ids)
        )

      if Enum.all?(grants, &canonical_grant?/1),
        do: canonical_navigation(uid, grants),
        else: evaluated_navigation(uid, grants)
    end
  end

  defp canonical_navigation(uid, grants) do
    starts = Enum.reduce(grants, %{space: 0, private: %{}, shared: %{}}, &grant_start/2)
    space = if AuthZ.allowed?(uid, "pod:space", "update"), do: 7, else: starts.space

    result =
      Repo.query!(
        """
        WITH RECURSIVE tree AS (
          SELECT p.id, p.private_owner_uid AS root_owner,
            p.deleted_at IS NOT NULL AS deleted, false AS ancestor_deleted,
            COALESCE(($2::jsonb ->> p.id::text)::integer, 0) AS direct_actions,
            COALESCE(($2::jsonb ->> p.id::text)::integer, 0) |
              CASE WHEN NOT p.inherit_permissions THEN 0
                WHEN p.private_owner_uid IS NULL THEN $4::integer
                ELSE COALESCE(($3::jsonb ->> p.private_owner_uid)::integer, 0) END AS actions
          FROM pages p WHERE p.tenant_id = $1::text::uuid AND p.parent_id IS NULL
          UNION ALL
          SELECT c.id, t.root_owner, c.deleted_at IS NOT NULL,
            t.ancestor_deleted OR t.deleted,
            COALESCE(($2::jsonb ->> c.id::text)::integer, 0),
            COALESCE(($2::jsonb ->> c.id::text)::integer, 0) |
              CASE WHEN c.inherit_permissions THEN t.actions ELSE 0 END
          FROM tree t JOIN pages c ON c.parent_id = t.id AND c.tenant_id = $1::text::uuid
        ) SELECT id::text, root_owner, deleted, ancestor_deleted, direct_actions, actions FROM tree
        """,
        [
          Repo.tenant_id!(),
          starts.shared,
          starts.private,
          space
        ]
      )

    {:ok,
     Map.new(result.rows, fn [id, owner, deleted, ancestor_deleted, direct, actions] ->
       {id,
        %{
          root_private_owner_uid: owner,
          deleted: deleted,
          ancestor_deleted: ancestor_deleted,
          directly_shared: band(direct, 1) != 0,
          actions: actions,
          role: role_for_actions(actions)
        }}
     end)}
  end

  defp evaluated_navigation(uid, grants) do
    entries = Repo.all(Page) |> navigation_entries() |> Map.to_list()

    direct_grants =
      grants
      |> Enum.filter(&(&1.action == "page_view"))
      |> Enum.group_by(& &1.resource_pattern, & &1.id)

    checks =
      Enum.flat_map(entries, fn {id, entry} ->
        Enum.map(@actions, &%{resource: entry.resource, action: &1}) ++
          [
            %{
              resource: entry.resource,
              action: "page_view",
              grant_ids: Map.get(direct_grants, "pod:**:#{id}:**", [])
            }
          ]
      end)

    with {:ok, [space | allowed]} <-
           AuthZ.authorize_checks(uid, [
             %{resource: "pod:space", action: "update"} | checks
           ]) do
      navigation =
        entries
        |> Enum.zip(Enum.chunk_every(allowed, 4))
        |> Map.new(fn {entry, allowed} -> evaluated_navigation_entry(entry, allowed, space) end)

      {:ok, navigation}
    end
  end

  defp evaluated_navigation_entry({id, entry}, [view, edit, manage, direct], space) do
    actions =
      if space and entry.space_fallback do
        7
      else
        @actions
        |> Enum.zip([view, edit, manage])
        |> Enum.reduce(0, fn {action, allowed}, bits ->
          if allowed, do: bor(bits, action_bit(action)), else: bits
        end)
      end

    {id,
     entry
     |> Map.drop([:resource, :space_fallback])
     |> Map.merge(%{
       directly_shared: direct,
       actions: actions,
       role: role_for_actions(actions)
     })}
  end

  defp navigation_entries(pages) do
    children = Enum.group_by(pages, & &1.parent_id)

    Enum.reduce(Map.get(children, nil, []), %{}, fn root, entries ->
      add_navigation_entry(root, children, [], entries)
    end)
  end

  defp add_navigation_entry(page, children, ancestors, entries) do
    reversed_path = [page | ancestors]
    path = Enum.reverse(reversed_path)

    entry = %{
      resource: resource(path),
      root_private_owner_uid: hd(path).private_owner_uid,
      deleted: not is_nil(page.deleted_at),
      ancestor_deleted: Enum.any?(ancestors, & &1.deleted_at),
      space_fallback: space_fallback?(path)
    }

    Enum.reduce(Map.get(children, page.id, []), Map.put(entries, page.id, entry), fn child,
                                                                                     entries ->
      add_navigation_entry(child, children, reversed_path, entries)
    end)
  end

  defp role_for_actions(actions) do
    cond do
      band(actions, 4) != 0 -> "manage"
      band(actions, 2) != 0 -> "edit"
      band(actions, 1) != 0 -> "view"
      true -> nil
    end
  end

  defp action_bit("page_view"), do: 1
  defp action_bit("page_edit"), do: 2
  defp action_bit("page_manage"), do: 4

  def put_role(owner, pattern, role) do
    with {:ok, wanted} <- actions(role) do
      grants =
        Repo.all(from g in Grant, where: g.resource_pattern == ^pattern and g.action in ^@actions)

      Enum.each(grants, fn grant ->
        if owner_match?(owner, grant) and grant.action not in wanted,
          do: AuthZ.delete_permission_grant(grant.id)
      end)

      Enum.reduce_while(wanted, :ok, fn action, :ok ->
        case AuthZ.upsert_permission_grant(
               Map.merge(owner, %{resource_pattern: pattern, action: action, condition: "true"})
             ) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      :error -> {:error, :invalid_role}
    end
  end

  def page_grants(id),
    do:
      Repo.all(
        from g in Grant, where: g.resource_pattern == ^"pod:**:#{id}:**" and g.action in ^@actions
      )

  def remove_grants(grants), do: Enum.each(grants, &AuthZ.delete_permission_grant(&1.id))

  defp owner_match?(%{principal_uid: uid}, grant), do: grant.principal_uid == uid
  defp owner_match?(%{group_id: id}, grant), do: grant.group_id == id

  defp grant_start(%{resource_pattern: "pod:space:**", action: action}, starts),
    do: %{starts | space: bor(starts.space, action_bit(action))}

  defp grant_start(%{resource_pattern: pattern, action: action}, starts) do
    bit = action_bit(action)

    cond do
      match = Regex.run(~r/^pod:private:([^:]+):\*\*$/, pattern) ->
        %{starts | private: Map.update(starts.private, Enum.at(match, 1), bit, &bor(&1, bit))}

      match = Regex.run(~r/^pod:\*\*:([0-9a-f-]{36}):\*\*$/, pattern) ->
        %{starts | shared: Map.update(starts.shared, Enum.at(match, 1), bit, &bor(&1, bit))}

      true ->
        starts
    end
  end

  defp visible_state(_path, true), do: :ok

  defp visible_state(path, false) do
    if Enum.any?(path, & &1.deleted_at), do: {:error, :not_found}, else: :ok
  end

  defp decide(uid, path, action) do
    case AuthZ.authorize(uid, resource(path), action) do
      :ok ->
        :ok

      error ->
        if is_nil(hd(path).private_owner_uid) and Enum.all?(path, & &1.inherit_permissions),
          do: AuthZ.authorize(uid, "pod:space", "update"),
          else: error
    end
  end
end
