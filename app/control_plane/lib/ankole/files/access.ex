defmodule Ankole.Files.Access do
  @moduledoc "Owns Drive authorization, its request context, and the ACL anchor graph."
  import Bitwise
  require Ash.Query
  alias Ankole.{AuthZ, Repo}
  alias Ankole.AuthZ.{Actor, Grants, Root}
  alias Ankole.Files.Schemas.Node, as: Page
  alias Ankole.Files.Nodes, as: Pages

  @actions ~w(node_view node_contribute node_edit node_manage node_comment)
  @roles %{
    "view" => ["node_view"],
    "contribute" => ~w(node_view node_contribute node_comment),
    "edit" => ~w(node_view node_contribute node_edit node_comment),
    "manage" => @actions
  }
  def page_actions, do: @actions
  def actions(role) when is_binary(role) or is_atom(role), do: Map.fetch(@roles, to_string(role))
  def actions(_role), do: :error

  def canonical_role_actions?(role, actions) when is_list(actions) do
    case actions(role) do
      {:ok, expected} -> Enum.sort(Enum.uniq(actions)) == Enum.sort(expected)
      :error -> false
    end
  end

  @doc "Publishes a committed authorization change to open pages and cached directories."
  def broadcast_change do
    Phoenix.PubSub.broadcast(Ankole.PubSub, "drive-access:" <> Repo.tenant_id!(), :recheck_access)

    Phoenix.PubSub.broadcast(
      Ankole.PubSub,
      "drive-content:" <> Repo.tenant_id!(),
      :access_changed
    )
  end

  def write(authority, fun, opts \\ []) when is_function(fun, 0) do
    with :ok <- AuthZ.validate_turn_authority(authority) do
      with_deadline(opts, fn ->
        Repo.transact_top_level(
          fn ->
            if Keyword.get(opts, :shared_tree, false), do: Pages.lock_tree(shared: true)
            roots = Keyword.get(opts, :root_ids, [])
            Pages.lock_roots(if is_function(roots, 0), do: roots.(), else: roots)
            with :ok <- AuthZ.authorize_turn_in_tx(authority), do: fun.()
          end,
          Keyword.drop(opts, [:root_ids, :shared_tree])
        )
      end)
    end
  end

  @doc "Locks the tree, resolves current root IDs, then locks roots before turn authority and rows."
  def write_tree(authority, fun, opts \\ []) when is_function(fun, 0) do
    with :ok <- AuthZ.validate_turn_authority(authority) do
      with_deadline(opts, fn ->
        Repo.transact_top_level(
          fn ->
            Pages.lock_tree()
            roots = Keyword.get(opts, :root_ids, [])
            Pages.lock_roots(if is_function(roots, 0), do: roots.(), else: roots)
            with :ok <- AuthZ.authorize_turn_in_tx(authority), do: fun.()
          end,
          Keyword.delete(opts, :root_ids)
        )
      end)
    end
  end

  def deadline,
    do: Process.get({__MODULE__, :deadline}, System.monotonic_time(:millisecond) + 13_000)

  defp with_deadline(opts, fun) do
    previous =
      Process.put(
        {__MODULE__, :deadline},
        System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 15_000) - 2_000
      )

    try do
      fun.()
    after
      if previous,
        do: Process.put({__MODULE__, :deadline}, previous),
        else: Process.delete({__MODULE__, :deadline})
    end
  end

  def principal(%Actor{principal: principal} = actor) do
    with :ok <- Ankole.AuthZ.Checks.ActorGuardrail.check(actor, :drive),
         do: {:ok, principal},
         else: (_ -> {:error, :forbidden})
  end

  def collaborator_scope(%Actor{} = actor) do
    with :ok <- Ankole.AuthZ.Checks.ActorGuardrail.check(actor, :drive),
         do:
           {:ok,
            if(
              actor.principal.membership == :guest,
              do: :shared,
              else: :all
            )}
  end

  def space_group, do: AuthZ.get_principal_group("all_humans")

  def initialize_space do
    with :ok <- Repo.require_transaction(),
         {:ok, _} <- Pages.ensure_public_root_in_tx(),
         {:ok, group} <- Root.ensure_all_humans_group(),
         do: put_role(%{group_id: group.id}, "drive:space:**", "manage")
  end

  def ensure_private(uid),
    do: put_role(%{principal_uid: uid}, "drive:private:#{uid}:**", "manage")

  @doc "Builds a Site Console actor for one verified administrative operation."
  def admin_actor(%Actor{} = actor, action)
      when action in ["read", "update", "delete"] do
    actor = %{actor | authn: Map.put(actor.authn, "drive_admin_action", action)}
    with :ok <- administrative_authorization(actor), do: {:ok, actor}
  end

  defp administrative_authorization(%Actor{authn: %{"drive_admin_action" => action}} = actor)
       when action in ["read", "update", "delete"] do
    with :ok <- Ankole.AuthZ.Checks.ActorGuardrail.check(actor, :site_console),
         {:ok, tenant_id} <- Ankole.Tenants.privileged_id() do
      Repo.with_tenant(tenant_id, fn -> AuthZ.authorize(actor, "site_console:drive", action) end)
    end
  end

  defp administrative_authorization(_actor), do: :not_administrative

  def authorize(uid, page, action, opts \\ []) when action in @actions do
    opts = authorization_options(action, opts)

    with :ok <- visible_state(page, opts) do
      case administrative_authorization(uid) do
        :ok ->
          {:ok, page}

        :not_administrative ->
          with {:ok, reachable} <- reachable_anchors(uid, page_options(page, opts)),
               do: authorize_bits(page, action, reachable)

        error ->
          error
      end
    end
  end

  def authorize_reachable(page, action, reachable, opts \\ []) when action in @actions do
    opts = authorization_options(action, opts)
    with :ok <- visible_state(page, opts), do: authorize_bits(page, action, reachable)
  end

  defp authorize_bits(page, action, reachable) do
    if band(page_bits(page, reachable), action_bit(action)) != 0,
      do: {:ok, page},
      else: {:error, :forbidden}
  end

  defp authorization_options(action, opts) do
    if action == "node_view" and not Keyword.has_key?(opts, :trash),
      do: Keyword.put(opts, :trash, :self),
      else: opts
  end

  defp page_options(page, opts) do
    opts = Keyword.put(opts, :target_ids, [page.acl_anchor_id])

    if Keyword.get(opts, :trash, false),
      do: Keyword.put(opts, :trash_page_id, page.id),
      else: opts
  end

  defp reachable_for(uid, opts) do
    case Keyword.fetch(opts, :reachable) do
      {:ok, reachable} -> {:ok, reachable}
      :error -> reachable_anchors(uid, opts)
    end
  end

  def authorize_with_permissions(uid, page, opts \\ []) do
    opts = authorization_options("node_view", opts)

    with :ok <- visible_state(page, opts),
         {:ok, reachable} <- reachable_for(uid, page_options(page, opts)),
         bits = page_bits(page, reachable),
         true <- band(bits, 1) != 0,
         do: {:ok, Ankole.Files.Access.Graph.project_permissions(page, bits)},
         else: (
           false -> {:error, :forbidden}
           error -> error
         )
  end

  defp visible_state(page, opts) do
    case Keyword.get(opts, :trash, false) do
      true ->
        :ok

      :self ->
        with {:ok, path} <- path(page) do
          if Enum.any?(Enum.drop(path, -1), & &1.deleted_at), do: {:error, :not_found}, else: :ok
        end

      _ ->
        with {:ok, path} <- path(page) do
          if Enum.any?(path, & &1.deleted_at), do: {:error, :not_found}, else: :ok
        end
    end
  end

  defdelegate page_bits(page, reachable), to: Ankole.Files.Access.Graph
  defdelegate role_for_actions(bits), to: Ankole.Files.Access.Graph
  defdelegate action_bit(action), to: Ankole.Files.Access.Graph
  defdelegate visibility_ids(reachable, bit \\ 1), to: Ankole.Files.Access.Graph

  def directly_shared_ids(uid, reachable, opts \\ []) do
    with {:ok, {snapshot, evaluated}} <- context_snapshot(uid, opts) do
      groups = MapSet.new(evaluated["effectiveGroupIDs"])
      satisfied = MapSet.new(evaluated["satisfiedGrantIDs"])
      candidates = grants(action: "node_view", target_node_id: [is_nil: false])
      sources = source_pages(candidates)

      ids =
        Enum.flat_map(candidates, fn grant ->
          subject =
            cond do
              grant.principal_uid ->
                grant.principal_uid == snapshot["principal"]["uid"]

              grant.group_id ->
                MapSet.member?(groups, grant.group_id)

              grant.source_node_id ->
                case Map.fetch(sources, grant.source_node_id) do
                  {:ok, page} ->
                    band(page_bits(page, reachable), action_bit(grant.source_action)) != 0

                  _ ->
                    false
                end
            end

          if subject and (grant.condition == "true" or MapSet.member?(satisfied, grant.id)),
            do: [grant.target_node_id],
            else: []
        end)

      {:ok, Enum.uniq(ids)}
    end
  end

  defp source_pages(grants) do
    ids = grants |> Enum.map(& &1.source_node_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    Page |> Ash.Query.filter(id in ^ids) |> Ankole.Ash.read!() |> Map.new(&{&1.id, &1})
  end

  defdelegate context_snapshot(actor, opts \\ []), to: Ankole.Files.Access.Graph
  defdelegate space_bits(actor), to: Ankole.Files.Access.Graph
  defdelegate reachable_anchors(actor, opts \\ []), to: Ankole.Files.Access.Graph
  defdelegate reachable_trashed(actor, page_ids, opts \\ []), to: Ankole.Files.Access.Graph

  defdelegate path(node), to: Pages

  def anchor_attributes(attrs, old \\ nil) do
    parent_id = Map.get(attrs, :parent_id, old && old.parent_id)
    parent_anchor = if parent_id, do: (Pages.fetch(parent_id) |> elem(1)).acl_anchor_id
    id = Map.get(attrs, :id, old && old.id)

    inherit =
      Map.get(attrs, :inherit_permissions, if(old, do: old.inherit_permissions, else: true))

    local = Map.get(attrs, :has_local_acl, if(old, do: old.has_local_acl, else: false))
    deleted = Map.get(attrs, :deleted_at, old && old.deleted_at)
    anchor = is_nil(parent_id) or not inherit or local or not is_nil(deleted)

    Map.merge(attrs, %{
      acl_anchor_id: if(anchor, do: id, else: parent_anchor),
      parent_anchor_id: if(anchor, do: parent_anchor)
    })
  end

  @doc "Updates a page and its inherited ACL anchors in the caller's transaction."
  def update_anchor_in_tx(page, action, attrs) do
    anchored = anchor_attributes(attrs, page)

    with {:ok, updated} <- Pages.update_in_tx(page, action, anchored) do
      reanchor_after_change(page, updated)
      {:ok, updated}
    end
  end

  def refresh_anchor_in_tx(nil), do: :ok

  def refresh_anchor_in_tx(id) do
    Pages.lock_tree()

    case Pages.lock(id) do
      {:ok, page} ->
        local = grants(target_node_id: id) != []
        attrs = anchor_attributes(%{has_local_acl: local}, page)

        with {:ok, updated} <- Pages.update_in_tx(page, :anchor, attrs) do
          reanchor_after_change(page, updated)
          :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end

  def reanchor_after_change(old, updated) do
    if old.acl_anchor_id != updated.acl_anchor_id,
      do: reanchor_pass_through_children(updated.id, updated.acl_anchor_id),
      else: :ok
  end

  def reanchor_pass_through_children(page_id, anchor_id) do
    Repo.query!(
      """
      WITH RECURSIVE affected_children AS (
        SELECT c.id, c.is_acl_anchor FROM drive_nodes c
        WHERE c.tenant_id = $1::text::uuid AND c.parent_id = $2::text::uuid
        UNION ALL
        SELECT c.id, c.is_acl_anchor FROM affected_children ac
        JOIN drive_nodes c ON c.tenant_id = $1::text::uuid AND c.parent_id = ac.id
        WHERE NOT ac.is_acl_anchor
      )
      UPDATE drive_nodes target
      SET acl_anchor_id = CASE WHEN ac.is_acl_anchor THEN target.id ELSE $3::text::uuid END,
          parent_anchor_id = CASE WHEN ac.is_acl_anchor THEN $3::text::uuid ELSE NULL END
      FROM affected_children ac
      WHERE target.tenant_id = $1::text::uuid AND target.id = ac.id
      """,
      [Repo.tenant_id!(), page_id, anchor_id]
    )

    :ok
  end

  def authorize_move_source(actor, page) do
    case administrative_authorization(actor) do
      :ok -> {:ok, page}
      :not_administrative -> authorize_move_source_acl(actor, page)
      error -> error
    end
  end

  def authorize_move(actor, page, parent_id, owner) do
    case administrative_authorization(actor) do
      :ok -> {:ok, page}
      :not_administrative -> authorize_move_acl(actor, page, parent_id, owner)
      error -> error
    end
  end

  defp authorize_move_source_acl(uid, page) do
    with :ok <- visible_state(page, []),
         {:ok, reachable} <- reachable_anchors(uid, target_ids: [page.acl_anchor_id]) do
      if band(page_bits(page, reachable), 12) != 0,
        do: {:ok, page},
        else: {:error, :forbidden}
    end
  end

  defp authorize_move_acl(uid, page, parent_id, private_owner_uid) do
    with :ok <- visible_state(page, []),
         {:ok, reachable} <- reachable_anchors(uid, target_ids: [page.acl_anchor_id]) do
      if band(page_bits(page, reachable), 8) != 0 do
        {:ok, page}
      else
        with {:ok, _} <- authorize_bits(page, "node_edit", reachable),
             {:ok, before} <- path(page),
             {:ok, after_move} <- moved_path(page, parent_id, private_owner_uid),
             true <- move_preserves_permissions?(page, before, after_move),
             do: {:ok, page},
             else: (
               false -> {:error, :move_requires_manage}
               error -> error
             )
      end
    end
  end

  defp moved_path(page, nil, owner),
    do: {:ok, [%{page | parent_id: nil, private_owner_uid: owner}]}

  defp moved_path(page, parent_id, nil) do
    with {:ok, parent} <- Pages.fetch(parent_id),
         {:ok, parents} <- path(parent),
         do: {:ok, parents ++ [%{page | parent_id: parent_id, private_owner_uid: nil}]}
  end

  defp move_preserves_permissions?(page, before, after_move) do
    old_owner = hd(before).private_owner_uid
    new_owner = hd(after_move).private_owner_uid
    old_parent = Enum.at(before, -2)
    new_parent = Enum.at(after_move, -2)

    cond do
      old_owner != new_owner or
          Map.get(hd(before), :conversation_id) != Map.get(hd(after_move), :conversation_id) ->
        false

      not page.inherit_permissions ->
        true

      old_parent && new_parent && old_parent.acl_anchor_id == new_parent.acl_anchor_id ->
        true

      true ->
        grants = grants(action: [in: @actions])
        before_policy = symbolic_incoming(before, grants, page.id)
        after_policy = symbolic_incoming(after_move, grants, page.id)
        before_policy != :unproven and before_policy == after_policy
    end
  end

  defp symbolic_incoming(path, grants, moving_id) do
    case Enum.at(path, -2) do
      nil -> symbolic_root(hd(path), grants)
      parent -> symbolic_page(parent, :container, grants, moving_id)
    end
  end

  defp symbolic_page(page, scope, grants, moving_id) do
    with {:ok, graph} <- symbolic_graph([{page, scope}], grants, moving_id, %{}) do
      symbolic_fixed_point(graph, Map.new(graph, fn {key, node} -> {key, node.seeds} end))
      |> Map.fetch!({page.id, scope})
    else
      _ -> :unproven
    end
  end

  defp symbolic_graph([], _grants, _moving, graph), do: {:ok, graph}

  defp symbolic_graph([{page, scope} | pending], grants, moving, graph) do
    key = {page.id, scope}

    cond do
      page.id == moving ->
        :unproven

      Map.has_key?(graph, key) ->
        symbolic_graph(pending, grants, moving, graph)

      true ->
        local =
          Enum.filter(
            grants,
            &(&1.target_node_id == page.id and (scope == :self or &1.target_scope == "container"))
          )

        baseline = if is_nil(page.parent_id), do: symbolic_root(page, grants), else: MapSet.new()

        cond do
          visible_state(page, []) != :ok ->
            symbolic_graph(
              pending,
              grants,
              moving,
              Map.put(graph, key, %{seeds: MapSet.new(), dependencies: []})
            )

          baseline == :unproven or Enum.any?(local, &(&1.condition != "true")) ->
            :unproven

          true ->
            seeds =
              Enum.reduce(Enum.filter(local, &is_nil(&1.source_node_id)), baseline, fn grant,
                                                                                       atoms ->
                MapSet.put(
                  atoms,
                  {{grant.principal_uid, grant.group_id}, action_bit(grant.action)}
                )
              end)

            dependencies =
              for grant <- local,
                  grant.source_node_id,
                  do:
                    {{grant.source_node_id, :self},
                     {action_bit(grant.source_action), action_bit(grant.action)}}

            dependencies =
              if page.parent_id && page.inherit_permissions,
                do: [{{page.parent_id, :container}, :identity} | dependencies],
                else: dependencies

            pages =
              Enum.map(dependencies, fn {{id, next_scope}, _} ->
                {:ok, dependency} = Pages.fetch(id)
                {dependency, next_scope}
              end)

            symbolic_graph(
              pages ++ pending,
              grants,
              moving,
              Map.put(graph, key, %{seeds: seeds, dependencies: dependencies})
            )
        end
    end
  end

  defp symbolic_fixed_point(graph, previous) do
    next =
      Map.new(graph, fn {key, node} ->
        atoms =
          Enum.reduce(node.dependencies, node.seeds, fn {source, mapping}, atoms ->
            inherited =
              case mapping do
                :identity ->
                  Map.fetch!(previous, source)

                {required, granted} ->
                  MapSet.new(
                    for {subject, bit} <- Map.fetch!(previous, source),
                        bit == required,
                        do: {subject, granted}
                  )
              end

            MapSet.union(atoms, inherited)
          end)

        {key, atoms}
      end)

    if next == previous, do: next, else: symbolic_fixed_point(graph, next)
  end

  defp symbolic_root(root, grants) do
    baseline =
      cond do
        Map.get(root, :conversation_id) -> nil
        root.private_owner_uid -> "drive:private:#{root.private_owner_uid}:**"
        root.inherit_permissions -> "drive:space:**"
        true -> nil
      end

    selected = Enum.filter(grants, &(not is_nil(baseline) and &1.resource_pattern == baseline))

    if Enum.any?(selected, &(&1.condition != "true")) do
      :unproven
    else
      policy = MapSet.new(selected, &{{&1.principal_uid, &1.group_id}, action_bit(&1.action)})

      if baseline == "drive:space:**",
        do: Enum.reduce([1, 2, 4, 8, 16], policy, &MapSet.put(&2, {:space_admin_fallback, &1})),
        else: policy
    end
  end

  def access_provenance(uid, id),
    do: Repo.transact_repeatable_read_only(fn -> access_provenance_in_tx(uid, id) end)

  def access_provenance_in_tx(uid, id, opts \\ []) do
    with {:ok, page} <- Pages.fetch(id),
         {:ok, reachable} <- reachable_for(uid, opts),
         {:ok, _} <- authorize_reachable(page, "node_manage", reachable) do
      grants = page_grants(id)
      sources = source_pages(grants)

      entries =
        Enum.map(grants, fn grant ->
          source =
            if grant.source_node_id do
              case Map.fetch(sources, grant.source_node_id) do
                {:ok, source} ->
                  visible = band(page_bits(source, reachable), 1) != 0

                  %{
                    id: source.id,
                    accessible: visible,
                    title: if(visible, do: source.name),
                    icon: nil
                  }

                _ ->
                  %{id: grant.source_node_id, accessible: false, title: nil, icon: nil}
              end
            end

          %{grant: grant, source_page: source}
        end)

      {:ok, entries}
    end
  end

  def put_role(owner, pattern, role, opts \\ %{}) do
    with {:ok, wanted} <- actions(role) do
      grants(
        resource_pattern: pattern,
        action: [in: @actions],
        condition: Map.get(opts, :condition, "true")
      )
      |> Enum.filter(&(owner_match?(owner, &1) and &1.action not in wanted))
      |> remove_grants()

      attrs_list =
        Enum.map(wanted, fn action ->
          Map.merge(
            owner,
            Map.merge(%{resource_pattern: pattern, action: action, condition: "true"}, opts)
          )
        end)

      case Grants.upsert_permission_grants(attrs_list) do
        {:ok, _grants} -> :ok
        {:error, _reason} = error -> error
      end
    else
      :error -> {:error, :invalid_role}
    end
  end

  def page_grants(id), do: grants(target_node_id: id, action: [in: @actions])

  def remove_grants(grants) do
    Enum.each(grants, fn grant -> {:ok, _} = Grants.delete_permission_grant(grant.id) end)
  end

  def grants(filter), do: Ankole.AuthZ.list_grants!(query: [filter: filter])
  defp owner_match?(%{principal_uid: uid}, grant), do: grant.principal_uid == uid
  defp owner_match?(%{group_id: id}, grant), do: grant.group_id == id

  defp owner_match?(%{source_node_id: id, source_action: action}, grant),
    do: grant.source_node_id == id and grant.source_action == action
end
