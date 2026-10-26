defmodule Ankole.Pod.Access do
  @moduledoc "Owns Pod authorization, its request context, and the ACL anchor graph."
  import Bitwise
  require Ash.Query
  alias Ankole.{AuthZ, Repo}
  alias Ankole.AuthZ.{Actor, Grants, Root}
  alias Ankole.Pod.{Page, Pages}
  alias Ankole.Sessions.{JobTurnRef, RunRef}
  alias Ankole.AutomationJobs.AttemptRef

  @actions ~w(page_view page_write_records page_edit page_manage)
  @roles %{
    "view" => ["page_view"],
    "contribute" => ~w(page_view page_write_records),
    "edit" => ~w(page_view page_write_records page_edit),
    "manage" => @actions
  }
  def page_actions, do: @actions
  def actions(role) when is_binary(role) or is_atom(role), do: Map.fetch(@roles, to_string(role))
  def actions(_role), do: :error

  def write(authority, fun, opts \\ []) when is_function(fun, 0) do
    with :ok <- validate_authority_shape(authority) do
      with_deadline(opts, fn ->
        Repo.transact_top_level(fn -> with :ok <- writer_in_tx(authority), do: fun.() end, opts)
      end)
    end
  end

  def write_tree(authority, fun, opts \\ []) when is_function(fun, 0) do
    with :ok <- validate_authority_shape(authority) do
      with_deadline(opts, fn ->
        Repo.transact_top_level(
          fn ->
            Pages.lock_tree()
            with :ok <- writer_in_tx(authority), do: fun.()
          end,
          opts
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

  defp validate_authority_shape(nil), do: :ok

  defp validate_authority_shape({ref, uid})
       when (is_struct(ref, RunRef) or is_struct(ref, JobTurnRef)) and ref.agent_uid == uid,
       do: :ok

  defp validate_authority_shape({%AttemptRef{agent_uid: uid}, uid}), do: :ok

  defp validate_authority_shape(_), do: {:error, :worker_not_assigned_to_turn}
  defp writer_in_tx(nil), do: :ok

  defp writer_in_tx({%AttemptRef{} = ref, uid}) do
    with {:ok, _actor} <-
           Ankole.AutomationJobs.authorize_attempt_actor_in_tx(ref, %{worker_id: uid}),
         do: :ok
  end

  defp writer_in_tx({ref, uid}) do
    case Ankole.AgentWorkers.WorkerRouteAuth.authorize_turn_in_tx(ref, uid, :write, lock: true) do
      {:ok, :authorized} -> :ok
      error -> error
    end
  end

  def principal(%Actor{principal: principal} = actor) do
    with :ok <- Ankole.AuthZ.Checks.ActorGuardrail.check(actor, :pod),
         do: {:ok, principal},
         else: (_ -> {:error, :forbidden})
  end

  def collaborator_scope(%Actor{} = actor) do
    with :ok <- Ankole.AuthZ.Checks.ActorGuardrail.check(actor, :pod),
         do:
           {:ok,
            if(
              actor.principal.membership == :guest or
                (actor.interactive_principal && actor.interactive_principal.membership == :guest),
              do: :shared,
              else: :all
            )}
  end

  def space_group, do: AuthZ.get_principal_group("all_humans")

  def initialize_space do
    with :ok <- Repo.require_transaction(),
         {:ok, group} <- Root.ensure_all_humans_group(),
         do: put_role(%{group_id: group.id}, "pod:space:**", "manage")
  end

  def ensure_private(uid), do: put_role(%{principal_uid: uid}, "pod:private:#{uid}:**", "manage")

  def authorize(uid, page, action, opts \\ []) when action in @actions do
    with :ok <- visible_state(page, opts),
         {:ok, reachable} <- reachable_anchors(uid, page_options(page, opts)) do
      authorize_bits(page, action, reachable)
    end
  end

  def authorize_reachable(page, action, reachable, opts \\ []) when action in @actions do
    with :ok <- visible_state(page, opts), do: authorize_bits(page, action, reachable)
  end

  defp authorize_bits(page, action, reachable) do
    if band(page_bits(page, reachable), action_bit(action)) != 0,
      do: {:ok, page},
      else: {:error, :forbidden}
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

  def authorize_with_permissions(uid, page) do
    with :ok <- visible_state(page, []),
         {:ok, reachable} <- reachable_anchors(uid, target_ids: [page.acl_anchor_id]),
         bits = page_bits(page, reachable),
         true <- band(bits, 1) != 0,
         do: {:ok, Ankole.Pod.Access.Graph.project_permissions(page, bits)},
         else: (
           false -> {:error, :forbidden}
           error -> error
         )
  end

  defp visible_state(page, opts) do
    if Keyword.get(opts, :trash, false) do
      :ok
    else
      with {:ok, path} <- path(page) do
        if Enum.any?(path, & &1.deleted_at), do: {:error, :not_found}, else: :ok
      end
    end
  end

  defdelegate page_bits(page, reachable), to: Ankole.Pod.Access.Graph
  defdelegate role_for_actions(bits), to: Ankole.Pod.Access.Graph
  defdelegate action_bit(action), to: Ankole.Pod.Access.Graph
  defdelegate visibility_ids(reachable, bit \\ 1), to: Ankole.Pod.Access.Graph

  def directly_shared_ids(uid, reachable, opts \\ []) do
    with {:ok, {snapshot, evaluated}} <- context_snapshot(uid, opts) do
      groups = MapSet.new(evaluated["effectiveGroupIDs"])
      satisfied = MapSet.new(evaluated["satisfiedGrantIDs"])
      candidates = grants(action: "page_view", target_page_id: [is_nil: false])
      sources = source_pages(candidates)

      ids =
        Enum.flat_map(candidates, fn grant ->
          subject =
            cond do
              grant.principal_uid ->
                grant.principal_uid == snapshot["principal"]["uid"]

              grant.group_id ->
                MapSet.member?(groups, grant.group_id)

              grant.source_page_id ->
                case Map.fetch(sources, grant.source_page_id) do
                  {:ok, page} ->
                    band(page_bits(page, reachable), action_bit(grant.source_action)) != 0

                  _ ->
                    false
                end
            end

          if subject and (grant.condition == "true" or MapSet.member?(satisfied, grant.id)),
            do: [grant.target_page_id],
            else: []
        end)

      {:ok, Enum.uniq(ids)}
    end
  end

  defp source_pages(grants) do
    ids = grants |> Enum.map(& &1.source_page_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    Page |> Ash.Query.filter(id in ^ids) |> Ankole.Ash.read!() |> Map.new(&{&1.id, &1})
  end

  defdelegate context_snapshot(actor, opts \\ []), to: Ankole.Pod.Access.Graph
  defdelegate space_bits(actor), to: Ankole.Pod.Access.Graph
  defdelegate reachable_anchors(actor, opts \\ []), to: Ankole.Pod.Access.Graph
  defdelegate reachable_trashed(actor, page_ids, opts \\ []), to: Ankole.Pod.Access.Graph

  def path(%{parent_id: nil} = page), do: {:ok, [page]}

  def path(%{parent_id: parent_id} = page) do
    result =
      Repo.query!(
        """
        WITH RECURSIVE ancestors AS (
          SELECT p.id, p.parent_id, p.private_owner_uid, p.inherit_permissions, p.deleted_at, p.acl_anchor_id, p.is_acl_anchor
            FROM pages p WHERE p.tenant_id = $1::text::uuid AND p.id = $2::text::uuid
          UNION
          SELECT p.id, p.parent_id, p.private_owner_uid, p.inherit_permissions, p.deleted_at, p.acl_anchor_id, p.is_acl_anchor
            FROM pages p JOIN ancestors a ON p.id = a.parent_id
            WHERE p.tenant_id = $1::text::uuid
        ) SELECT id::text, parent_id::text, private_owner_uid, inherit_permissions, deleted_at, acl_anchor_id::text, is_acl_anchor
          FROM ancestors
        """,
        [Repo.tenant_id!(), parent_id]
      )

    parents =
      Map.new(result.rows, fn [id, parent_id, owner, inherit, deleted_at, anchor_id, anchor] ->
        {id,
         %{
           id: id,
           parent_id: parent_id,
           private_owner_uid: owner,
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
    anchored = if action == :restore, do: Map.delete(anchored, :deleted_at), else: anchored

    with {:ok, updated} <- Ankole.Ash.update(page, action, anchored) do
      reanchor_after_change(page, updated)
      {:ok, updated}
    end
  end

  def refresh_anchor_in_tx(nil), do: :ok

  def refresh_anchor_in_tx(id) do
    Pages.lock_tree()

    case Pages.lock(id) do
      {:ok, page} ->
        local = grants(target_page_id: id) != []
        attrs = anchor_attributes(%{has_local_acl: local}, page)

        with {:ok, updated} <- Ankole.Ash.update(page, :anchor, attrs) do
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
        SELECT c.id, c.is_acl_anchor FROM pages c
        WHERE c.tenant_id = $1::text::uuid AND c.parent_id = $2::text::uuid
        UNION ALL
        SELECT c.id, c.is_acl_anchor FROM affected_children ac
        JOIN pages c ON c.tenant_id = $1::text::uuid AND c.parent_id = ac.id
        WHERE NOT ac.is_acl_anchor
      )
      UPDATE pages target
      SET acl_anchor_id = CASE WHEN ac.is_acl_anchor THEN target.id ELSE $3::text::uuid END,
          parent_anchor_id = CASE WHEN ac.is_acl_anchor THEN $3::text::uuid ELSE NULL END
      FROM affected_children ac
      WHERE target.tenant_id = $1::text::uuid AND target.id = ac.id
      """,
      [Repo.tenant_id!(), page_id, anchor_id]
    )

    :ok
  end

  def authorize_move_source(uid, page) do
    with :ok <- visible_state(page, []),
         {:ok, reachable} <- reachable_anchors(uid, target_ids: [page.acl_anchor_id]) do
      if band(page_bits(page, reachable), 12) != 0,
        do: {:ok, page},
        else: {:error, :forbidden}
    end
  end

  def authorize_move(uid, page, parent_id, private_owner_uid) do
    with :ok <- visible_state(page, []),
         {:ok, reachable} <- reachable_anchors(uid, target_ids: [page.acl_anchor_id]) do
      if band(page_bits(page, reachable), 8) != 0 do
        {:ok, page}
      else
        with {:ok, _} <- authorize_bits(page, "page_edit", reachable),
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
      old_owner != new_owner ->
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
            &(&1.target_page_id == page.id and (scope == :self or &1.target_scope == "container"))
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
              Enum.reduce(Enum.filter(local, &is_nil(&1.source_page_id)), baseline, fn grant,
                                                                                       atoms ->
                MapSet.put(
                  atoms,
                  {{grant.principal_uid, grant.group_id}, action_bit(grant.action)}
                )
              end)

            dependencies =
              for grant <- local,
                  grant.source_page_id,
                  do:
                    {{grant.source_page_id, :self},
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
        root.private_owner_uid -> "pod:private:#{root.private_owner_uid}:**"
        root.inherit_permissions -> "pod:space:**"
        true -> nil
      end

    selected = Enum.filter(grants, &(not is_nil(baseline) and &1.resource_pattern == baseline))

    if Enum.any?(selected, &(&1.condition != "true")) do
      :unproven
    else
      policy = MapSet.new(selected, &{{&1.principal_uid, &1.group_id}, action_bit(&1.action)})

      if baseline == "pod:space:**",
        do: Enum.reduce([1, 2, 4, 8], policy, &MapSet.put(&2, {:space_admin_fallback, &1})),
        else: policy
    end
  end

  def access_provenance(uid, id),
    do: Repo.transact_repeatable_read_only(fn -> access_provenance_in_tx(uid, id) end)

  def access_provenance_in_tx(uid, id, opts \\ []) do
    with {:ok, page} <- Pages.fetch(id),
         {:ok, reachable} <- reachable_for(uid, opts),
         {:ok, _} <- authorize_reachable(page, "page_manage", reachable) do
      grants = page_grants(id)
      sources = source_pages(grants)

      entries =
        Enum.map(grants, fn grant ->
          source =
            if grant.source_page_id do
              case Map.fetch(sources, grant.source_page_id) do
                {:ok, source} ->
                  visible = band(page_bits(source, reachable), 1) != 0

                  %{
                    id: source.id,
                    accessible: visible,
                    title: if(visible, do: source.title),
                    icon: if(visible, do: source.icon)
                  }

                _ ->
                  %{id: grant.source_page_id, accessible: false, title: nil, icon: nil}
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

      Enum.reduce_while(wanted, :ok, fn action, :ok ->
        attrs =
          Map.merge(
            owner,
            Map.merge(%{resource_pattern: pattern, action: action, condition: "true"}, opts)
          )

        case Grants.upsert_permission_grant(attrs) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      :error -> {:error, :invalid_role}
    end
  end

  def page_grants(id), do: grants(target_page_id: id, action: [in: @actions])

  def remove_grants(grants) do
    Enum.each(grants, fn grant -> {:ok, _} = Grants.delete_permission_grant(grant.id) end)
  end

  def grants(filter), do: Ankole.AuthZ.list_grants!(query: [filter: filter])
  defp owner_match?(%{principal_uid: uid}, grant), do: grant.principal_uid == uid
  defp owner_match?(%{group_id: id}, grant), do: grant.group_id == id

  defp owner_match?(%{source_page_id: id, source_action: action}, grant),
    do: grant.source_page_id == id and grant.source_action == action
end
