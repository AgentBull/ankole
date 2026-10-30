defmodule Ankole.Pod.Pages.Sharing do
  @moduledoc "Owns page sharing and Space access settings."
  import Bitwise
  alias Ankole.{AuthZ, Repo}
  alias Ankole.Pod.{Access, Pages}
  alias Ankole.Pod.Pages.Collaborators

  @subject_keys [
    :principal_uid,
    :group_id,
    :name,
    :kind,
    :avatar_url,
    :subtitle,
    :membership,
    :group_domain,
    :group_slug,
    :built_in
  ]

  def sharing(%Ankole.AuthZ.Actor{} = actor, id) do
    Repo.transact_repeatable_read_only(fn -> sharing_in_tx(actor, id) end)
  end

  @doc false
  def sharing_in_tx(%Ankole.AuthZ.Actor{} = actor, id) do
    with {:ok, reachable} <- Access.reachable_anchors(actor),
         {:ok, page} <- Pages.fetch(id),
         {:ok, path} <- Access.path(page),
         {:ok, can_manage} <- authorize_sharing_read(path, page, reachable),
         {:ok, collab_scope} <- Access.collaborator_scope(actor),
         catalog = Collaborators.catalog(include_internal: true),
         picker = Enum.reject(catalog, &Collaborators.internal_picker_subject?/1),
         {:ok, visible_subjects} <-
           Collaborators.subjects_in_tx(actor,
             reachable: reachable,
             subjects: picker,
             context_page_id: page.id
           ),
         {:ok, provenance} <- sharing_provenance(actor, id, reachable, can_manage) do
      scope_kind = scope_kind(path)
      visible_uids = visible_uid_set(visible_subjects)
      space_role = if collab_scope == :all, do: space_default_role()
      page_grants = Access.page_grants(id)
      ancestor_grants = load_ancestor_grants(path)

      all_subjects =
        catalog_with_referenced_principals(catalog, page_grants, path, ancestor_grants)

      grants =
        page_grants
        |> grouped_grants(provenance, all_subjects, scope_kind)
        |> filter_grants_for_caller(can_manage, collab_scope, visible_uids)
        |> Enum.map(fn grant ->
          grant
          |> Collaborators.redact_subject_pii(collab_scope)
          |> Map.delete(:disabled)
        end)

      inherited =
        path
        |> inherited_grants(
          scope_kind,
          collab_scope,
          visible_uids,
          all_subjects,
          space_role,
          ancestor_grants,
          can_manage
        )
        |> Enum.map(fn entry ->
          entry
          |> Collaborators.redact_subject_pii(collab_scope)
          |> Map.delete(:disabled)
        end)

      {:ok,
       %{
         can_manage: can_manage,
         scope_kind: scope_kind,
         space_name: Collaborators.current_space_name(),
         space_role: space_role,
         inherit_permissions: page.inherit_permissions,
         sharing_version: sharing_version(page, page_grants),
         subjects: if(can_manage, do: visible_subjects, else: []),
         inherited: inherited,
         grants: grants
       }}
    end
  end

  def subjects(%Ankole.AuthZ.Actor{} = actor) do
    Repo.transact_repeatable_read_only(fn -> Collaborators.subjects_in_tx(actor) end)
  end

  def set_sharing(%Ankole.AuthZ.Actor{} = actor, id, attrs, authority \\ nil) do
    authority = authority || actor.turn_authority

    Access.write_tree(authority, fn -> set_sharing_in_tx(actor, id, attrs) end,
      after_commit: &Pages.committed/1
    )
  end

  @doc false
  def set_sharing_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    Pages.lock_tree()

    with {:ok, ctx} <- sharing_write_context(actor, id),
         :ok <-
           sharing_cas(ctx.page, ctx.existing_grants, Ankole.Attrs.get(attrs, :sharing_version)),
         {:ok, grants} <- normalize_full_grants(Ankole.Attrs.get(attrs, :grants, :unchanged), ctx),
         {:ok, page} <-
           Access.update_anchor_in_tx(ctx.page, :sharing, %{
             inherit_permissions:
               Ankole.Attrs.get(attrs, :inherit_permissions, ctx.page.inherit_permissions)
           }),
         :ok <- replace_grants(page.id, ctx.existing_grants, grants),
         :ok <- retain_manager(actor, page) do
      Pages.fetch(page.id)
    end
  end

  def update_sharing(%Ankole.AuthZ.Actor{} = actor, id, attrs, authority \\ nil) do
    authority = authority || actor.turn_authority

    with {:ok, page} <-
           Access.write_tree(authority, fn -> update_sharing_in_tx(actor, id, attrs) end,
             after_commit: &Pages.committed/1
           ),
         {:ok, sharing} <- sharing(actor, page.id) do
      {:ok, %{page: page, sharing: sharing}}
    end
  end

  @doc false
  def update_sharing_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) when is_map(attrs) do
    Pages.lock_tree()

    with :ok <- require_sharing_changes(attrs),
         {:ok, ctx} <- sharing_write_context(actor, id),
         {:ok, upserts} <- normalize_upsert_grants(Ankole.Attrs.get(attrs, :upserts, []), ctx),
         {:ok, removes} <- normalize_removes(Ankole.Attrs.get(attrs, :removes, [])),
         {:ok, page} <- maybe_update_inherit(ctx.page, attrs),
         :ok <- apply_removes(page.id, removes),
         :ok <- apply_upserts(page.id, upserts),
         :ok <- retain_manager(actor, page) do
      Pages.fetch(page.id)
    end
  end

  def update_sharing_in_tx(_actor, _id, _attrs), do: {:error, :invalid_request}

  def space(%Ankole.AuthZ.Actor{} = actor) do
    Repo.transact_repeatable_read_only(fn -> space_in_snapshot(actor) end)
  end

  defp space_in_snapshot(%Ankole.AuthZ.Actor{} = actor) do
    with {:ok, _} <- Access.principal(actor),
         {:ok, subjects} <- Collaborators.subjects_in_tx(actor),
         {:ok, group} <- Access.space_group() do
      role = space_group_role(group.id)

      agent_grants =
        Access.grants(
          resource_pattern: "pod:space:**",
          principal_uid: [is_nil: false],
          action: [in: Access.page_actions()]
        )

      agent_uids = for %{kind: :agent, principal_uid: uid} <- subjects, do: uid

      agents =
        agent_grants
        |> Enum.filter(&(&1.principal_uid in agent_uids))
        |> grouped_grants([], subjects, :space)
        |> Enum.map(&Map.delete(&1, :disabled))

      {:ok,
       %{
         role: role,
         can_manage: AuthZ.allowed?(actor, "tenant_console:pod_space", "update"),
         agents: agents
       }}
    end
  end

  def set_space(%Ankole.AuthZ.Actor{} = actor, role, authority \\ nil) do
    authority = authority || actor.turn_authority

    Access.write_tree(authority, fn -> set_space_in_tx(actor, role) end,
      after_commit: &Pages.committed/1
    )
  end

  @doc false
  def set_space_in_tx(%Ankole.AuthZ.Actor{} = actor, role) do
    Pages.lock_tree()

    with :ok <- AuthZ.authorize(actor, "tenant_console:pod_space", "update"),
         {:ok, group} <- Access.space_group(),
         :ok <- Access.put_role(%{group_id: group.id}, "pod:space:**", role),
         do: {:ok, %{role: role}}
  end

  def space_agent(%Ankole.AuthZ.Actor{} = actor, agent_uid, role, authority \\ nil) do
    authority = authority || actor.turn_authority

    Access.write_tree(authority, fn -> space_agent_in_tx(actor, agent_uid, role) end,
      after_commit: &Pages.committed/1
    )
  end

  @doc false
  def space_agent_in_tx(%Ankole.AuthZ.Actor{} = actor, agent_uid, role) do
    Pages.lock_tree()

    with :ok <- AuthZ.authorize(actor, "tenant_console:pod_space", "update"),
         {:ok, %{type: :agent}} <- Ankole.Principals.get_principal(agent_uid),
         :ok <- Access.put_role(%{principal_uid: agent_uid}, "pod:space:**", role) do
      {:ok, %{principal_uid: agent_uid, role: role}}
    else
      {:ok, _principal} -> {:error, :invalid_principal}
      error -> error
    end
  end

  def remove_space_agent(%Ankole.AuthZ.Actor{} = actor, agent_uid, authority \\ nil) do
    authority = authority || actor.turn_authority

    Access.write_tree(authority, fn -> remove_space_agent_in_tx(actor, agent_uid) end,
      after_commit: &Pages.committed/1
    )
  end

  @doc false
  def remove_space_agent_in_tx(%Ankole.AuthZ.Actor{} = actor, agent_uid) do
    Pages.lock_tree()

    with :ok <- AuthZ.authorize(actor, "tenant_console:pod_space", "update") do
      Access.grants(
        principal_uid: agent_uid,
        resource_pattern: "pod:space:**",
        action: [in: Access.page_actions()]
      )
      |> Access.remove_grants()

      {:ok, %{principal_uid: agent_uid}}
    end
  end

  defp sharing_provenance(actor, id, reachable, true),
    do: Access.access_provenance_in_tx(actor, id, reachable: reachable)

  defp sharing_provenance(_actor, _id, _reachable, false), do: {:ok, []}

  defp scope_kind([root | _]), do: if(root.private_owner_uid, do: :private, else: :space)

  defp authorize_sharing_read(path, page, reachable) do
    if Enum.any?(path, & &1.deleted_at) do
      {:error, :not_found}
    else
      bits = Access.page_bits(page, reachable)
      can_manage = band(bits, Access.action_bit("page_manage")) != 0
      can_view = band(bits, Access.action_bit("page_view")) != 0
      if can_manage or can_view, do: {:ok, can_manage}, else: {:error, :forbidden}
    end
  end

  defp space_default_role do
    case Access.space_group() do
      {:ok, group} -> space_group_role(group.id)
      _ -> "view"
    end
  end

  defp space_group_role(group_id) do
    {:ok, grants} = AuthZ.list_group_grants(group_id)

    actions =
      for grant <- grants,
          grant.resource_pattern == "pod:space:**" and grant.condition == "true",
          do: grant.action

    cond do
      "page_manage" in actions -> "manage"
      "page_edit" in actions -> "edit"
      "page_write_records" in actions or "page_comment" in actions -> "contribute"
      true -> "view"
    end
  end

  defp require_sharing_changes(attrs) do
    inherit = Ankole.Attrs.get(attrs, :inherit_permissions, :missing)
    upserts = Ankole.Attrs.get(attrs, :upserts, [])
    removes = Ankole.Attrs.get(attrs, :removes, [])

    if inherit in [true, false] or (is_list(upserts) and upserts != []) or
         (is_list(removes) and removes != []) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp maybe_visible_subjects(actor, :shared, page_id),
    do: Collaborators.subjects_in_tx(actor, context_page_id: page_id)

  defp maybe_visible_subjects(_actor, _scope, _page_id), do: {:ok, []}

  defp maybe_update_inherit(page, attrs) do
    case Ankole.Attrs.get(attrs, :inherit_permissions, :missing) do
      :missing ->
        {:ok, page}

      value when is_boolean(value) ->
        if value == page.inherit_permissions do
          {:ok, page}
        else
          Access.update_anchor_in_tx(page, :sharing, %{inherit_permissions: value})
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp sharing_write_context(actor, id) do
    with {:ok, page} <- Pages.lock(id),
         {:ok, _} <- AuthZ.authorize_locked_in_tx(actor, page, "page_manage"),
         {:ok, path} <- Access.path(page),
         {:ok, collab_scope} <- Access.collaborator_scope(actor),
         {:ok, visible_subjects} <- maybe_visible_subjects(actor, collab_scope, page.id) do
      existing_grants = Access.page_grants(id)

      {:ok,
       %{
         page: page,
         scope_kind: scope_kind(path),
         existing_grants: existing_grants,
         collab_scope: collab_scope,
         visible_uids: visible_uid_set(visible_subjects),
         preserved_uids: MapSet.new(),
         preserved_group_ids: MapSet.new()
       }}
    end
  end

  defp with_preserved_shared_owners(%{collab_scope: :shared, existing_grants: existing} = ctx) do
    %{
      ctx
      | preserved_uids:
          MapSet.new(for grant <- existing, grant.principal_uid, do: grant.principal_uid),
        preserved_group_ids: MapSet.new(for grant <- existing, grant.group_id, do: grant.group_id)
    }
  end

  defp with_preserved_shared_owners(ctx), do: ctx

  defp normalize_upsert_grants(nil, _ctx), do: {:ok, []}

  defp normalize_upsert_grants(upserts, ctx) when is_list(upserts),
    do: normalize_grant_entries(upserts, ctx, :upsert)

  defp normalize_upsert_grants(_, _ctx), do: {:error, :invalid_grants}

  defp normalize_full_grants(:unchanged, _ctx), do: {:ok, :unchanged}

  defp normalize_full_grants(grants, ctx) when is_list(grants) do
    with {:ok, entries} <-
           normalize_grant_entries(grants, with_preserved_shared_owners(ctx), :full) do
      {:ok, Enum.flat_map(entries, &expand_grant_attrs(ctx.page.id, &1))}
    end
  end

  defp normalize_full_grants(_, _ctx), do: {:error, :invalid_grants}

  defp expand_grant_attrs(page_id, %{
         owner: owner,
         actions: actions,
         target_scope: scope,
         condition: condition
       }) do
    suffix = if scope == "container", do: "**", else: "page"

    base =
      Map.merge(owner, %{
        resource_pattern: "pod:**:#{page_id}:#{suffix}",
        condition: condition
      })

    Enum.map(actions, &Map.put(base, :action, &1))
  end

  defp normalize_grant_entries(items, ctx, mode) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case normalize_grant_entry(item, ctx, mode) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp normalize_grant_entry(item, ctx, mode) when is_map(item) do
    owner_keys =
      case mode do
        :upsert -> [:principal_uid, :group_id]
        :full -> [:principal_uid, :group_id, :source_page_id]
      end

    owner =
      Map.new(
        for key <- owner_keys,
            value = Ankole.Attrs.get(item, key),
            value,
            do: {key, value}
      )

    scope = (Ankole.Attrs.get(item, :target_scope) || "container") |> to_string()
    condition = if mode == :full, do: Ankole.Attrs.get(item, :condition) || "true", else: "true"

    with true <- map_size(owner) == 1,
         true <- scope in ["container", "self"],
         true <- is_binary(condition),
         {:ok, role, actions} <- resolve_grant_actions(item, mode),
         {:ok, owner} <- validate_grant_owner(owner, item, actions, scope, condition, mode, ctx),
         true <- meaningful_actions?(ctx.page, scope, actions) do
      {:ok,
       %{
         owner: owner,
         role: role,
         actions: actions,
         target_scope: scope,
         condition: condition
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_grants}
    end
  end

  defp normalize_grant_entry(_item, _ctx, _mode), do: {:error, :invalid_grants}

  defp validate_grant_owner(
         %{principal_uid: uid} = owner,
         _item,
         actions,
         scope,
         condition,
         mode,
         ctx
       ) do
    preserving_or_narrowing? =
      mode == :full and
        MapSet.subset?(
          MapSet.new(actions),
          existing_principal_actions(ctx.existing_grants, uid, scope, condition)
        )

    if preserving_or_narrowing? do
      with {:ok, _principal} <- Ankole.Principals.get_principal(uid),
           true <- peer_allowed_for_caller?(ctx, {:principal, uid}) do
        {:ok, owner}
      else
        _ -> {:error, :invalid_grants}
      end
    else
      with {:ok, principal} <- Ankole.Principals.get_principal(uid),
           {:ok, _} <- Access.principal(Ankole.AuthZ.Actor.new(principal)),
           :ok <- check_private_guest(principal, ctx),
           true <- peer_allowed_for_caller?(ctx, {:principal, uid}) do
        {:ok, owner}
      else
        {:error, :guest_forbidden_in_private} = error -> error
        _ -> {:error, :invalid_grants}
      end
    end
  end

  defp validate_grant_owner(%{group_id: id}, _item, _actions, _scope, _condition, _mode, ctx) do
    with {:ok, group} <- AuthZ.get_principal_group(id),
         true <- peer_allowed_for_caller?(ctx, {:group, group.id}) do
      {:ok, %{group_id: group.id}}
    else
      _ -> {:error, :invalid_grants}
    end
  end

  defp validate_grant_owner(
         %{source_page_id: _source_id} = owner,
         item,
         _actions,
         _scope,
         _condition,
         _mode,
         _ctx
       ) do
    source_action = Ankole.Attrs.get(item, :source_action)

    if source_action in Access.page_actions() do
      {:ok, Map.put(owner, :source_action, source_action)}
    else
      {:error, :invalid_grants}
    end
  end

  defp existing_principal_actions(existing_grants, uid, scope, condition) do
    MapSet.new(
      for grant <- existing_grants,
          grant.principal_uid == uid and
            is_nil(grant.group_id) and
            is_nil(grant.source_page_id) and
            (grant.target_scope || "container") == scope and
            grant.condition == condition,
          do: grant.action
    )
  end

  defp peer_allowed_for_caller?(%{collab_scope: :shared} = ctx, {:principal, uid}),
    do: MapSet.member?(ctx.visible_uids, uid) or MapSet.member?(ctx.preserved_uids, uid)

  defp peer_allowed_for_caller?(%{collab_scope: :shared} = ctx, {:group, group_id}),
    do: MapSet.member?(ctx.preserved_group_ids, group_id)

  defp peer_allowed_for_caller?(_ctx, _target), do: true

  defp check_private_guest(%{membership: :guest}, %{scope_kind: :private}),
    do: {:error, :guest_forbidden_in_private}

  defp check_private_guest(_principal, _ctx), do: :ok

  defp resolve_grant_actions(item, :upsert) do
    role = Ankole.Attrs.get(item, :role)

    case Access.actions(role) do
      {:ok, actions} -> {:ok, to_string(role), actions}
      :error -> {:error, :invalid_grants}
    end
  end

  defp resolve_grant_actions(item, :full) do
    case grant_actions(item) do
      {:ok, actions} -> {:ok, nil, actions}
      :error -> {:error, :invalid_grants}
    end
  end

  defp normalize_removes(nil), do: {:ok, []}

  defp normalize_removes(removes) when is_list(removes) do
    removes
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case normalize_remove(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp normalize_removes(_), do: {:error, :invalid_grants}

  defp normalize_remove(item) when is_map(item) do
    uid = Ankole.Attrs.get(item, :principal_uid)
    group_id = Ankole.Attrs.get(item, :group_id)
    source_page_id = Ankole.Attrs.get(item, :source_page_id)
    source_action = Ankole.Attrs.get(item, :source_action)
    scope = (Ankole.Attrs.get(item, :target_scope) || "") |> to_string()
    condition = Ankole.Attrs.get(item, :condition) || "true"
    owners = Enum.count([uid, group_id, source_page_id], &(not is_nil(&1)))

    if owners == 1 and scope in ["container", "self"] and is_binary(condition) do
      {:ok,
       %{
         principal_uid: uid,
         group_id: group_id,
         source_page_id: source_page_id,
         source_action: source_action,
         target_scope: scope,
         condition: condition
       }}
    else
      {:error, :invalid_grants}
    end
  end

  defp normalize_remove(_), do: {:error, :invalid_grants}

  defp apply_removes(_page_id, []), do: :ok

  defp apply_removes(page_id, removes) do
    existing = Access.page_grants(page_id)

    matching =
      Enum.filter(existing, fn grant ->
        Enum.any?(removes, &grant_matches_remove?(grant, &1))
      end)

    Access.remove_grants(matching)
    :ok
  end

  defp grant_matches_remove?(grant, target) do
    grant.principal_uid == target.principal_uid and
      grant.group_id == target.group_id and
      grant.source_page_id == target.source_page_id and
      grant.source_action == target.source_action and
      (grant.target_scope || "container") == target.target_scope and
      grant.condition == target.condition
  end

  defp apply_upserts(_page_id, []), do: :ok

  defp apply_upserts(page_id, upserts) do
    Enum.reduce_while(upserts, :ok, fn %{owner: owner, role: role, target_scope: scope}, :ok ->
      suffix = if scope == "container", do: "**", else: "page"
      opposite_suffix = if scope == "container", do: "page", else: "**"

      Access.grants(
        resource_pattern: "pod:**:#{page_id}:#{opposite_suffix}",
        action: [in: Access.page_actions()],
        condition: "true"
      )
      |> Enum.filter(&upsert_owner_match?(owner, &1))
      |> Access.remove_grants()

      case Access.put_role(owner, "pod:**:#{page_id}:#{suffix}", role) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp upsert_owner_match?(%{principal_uid: uid}, grant),
    do: grant.principal_uid == uid and is_nil(grant.group_id) and is_nil(grant.source_page_id)

  defp upsert_owner_match?(%{group_id: id}, grant),
    do: grant.group_id == id and is_nil(grant.principal_uid) and is_nil(grant.source_page_id)

  defp sharing_version(page, raw_grants) do
    grants =
      raw_grants
      |> Enum.map(
        &{&1.principal_uid, &1.group_id, &1.source_page_id, &1.source_action, &1.target_scope,
         &1.action, &1.condition}
      )
      |> Enum.sort()

    :crypto.hash(:sha256, :erlang.term_to_binary({page.inherit_permissions, grants}))
    |> Base.encode16(case: :lower)
  end

  defp sharing_cas(_page, _grants, nil), do: {:error, :sharing_conflict}

  defp sharing_cas(page, grants, expected) do
    if expected == sharing_version(page, grants), do: :ok, else: {:error, :sharing_conflict}
  end

  defp meaningful_actions?(%{type: :doc}, "self", actions) do
    "page_write_records" not in actions or
      "page_comment" in actions or
      "page_edit" in actions or
      "page_manage" in actions
  end

  defp meaningful_actions?(%{type: type}, "self", actions) when type in [:file, :applet] do
    ("page_write_records" not in actions and "page_comment" not in actions) or
      "page_edit" in actions or
      "page_manage" in actions
  end

  defp meaningful_actions?(_page, _scope, _actions), do: true

  defp grant_actions(grant) do
    role = Ankole.Attrs.get(grant, :role)

    case Ankole.Attrs.get(grant, :actions) do
      nil ->
        Access.actions(role)

      [_ | _] = actions ->
        actions =
          Enum.map(actions, fn
            action when is_atom(action) -> Atom.to_string(action)
            action -> action
          end)

        role_matches? = is_nil(role) or Access.canonical_role_actions?(role, actions)

        if role_matches? and Enum.all?(actions, &(&1 in Access.page_actions())),
          do: {:ok, Enum.uniq(actions)},
          else: :error

      _ ->
        :error
    end
  end

  defp replace_grants(_id, _existing_grants, :unchanged), do: :ok

  defp replace_grants(_id, existing_grants, grants) do
    deduped = Enum.uniq_by(grants, &desired_grant_key/1)
    desired_keys = MapSet.new(deduped, &desired_grant_key/1)
    existing_keys = MapSet.new(existing_grants, &existing_grant_key/1)

    to_remove =
      Enum.reject(existing_grants, &MapSet.member?(desired_keys, existing_grant_key(&1)))

    to_create =
      Enum.reject(deduped, &MapSet.member?(existing_keys, desired_grant_key(&1)))

    if to_remove != [] do
      Access.remove_grants(to_remove)
    end

    Enum.reduce_while(to_create, :ok, fn attrs, :ok ->
      case Ankole.AuthZ.Grants.create_permission_grant(attrs) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp existing_grant_key(grant) do
    {
      grant.principal_uid,
      grant.group_id,
      grant.source_page_id,
      grant.source_action,
      grant.target_scope || "container",
      grant.action,
      grant.condition
    }
  end

  defp desired_grant_key(attrs) do
    scope = if String.ends_with?(attrs.resource_pattern, ":**"), do: "container", else: "self"

    {
      Map.get(attrs, :principal_uid),
      Map.get(attrs, :group_id),
      Map.get(attrs, :source_page_id),
      Map.get(attrs, :source_action),
      scope,
      attrs.action,
      attrs.condition
    }
  end

  defp retain_manager(%Ankole.AuthZ.Actor{} = actor, %{inherit_permissions: false, id: id}) do
    {:ok, page} = Pages.fetch(id)

    subjects =
      [Ankole.AuthZ.Actor.primary(actor), Ankole.AuthZ.Actor.interactive(actor)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&Ankole.AuthZ.Actor.uid/1)

    Enum.reduce_while(subjects, :ok, fn subject, :ok ->
      case Access.authorize(subject, page, "page_manage") do
        {:ok, _} ->
          {:cont, :ok}

        _ ->
          uid = Ankole.AuthZ.Actor.uid(subject)

          case Access.put_role(%{principal_uid: uid}, "pod:**:#{page.id}:**", "manage") do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp retain_manager(_actor, _page), do: :ok

  defp visible_uid_set(subjects) do
    MapSet.new(
      for subject <- subjects, uid = Map.get(subject, :principal_uid), not is_nil(uid), do: uid
    )
  end

  defp load_ancestor_grants(path) do
    {_root_index, ancestors} = inheritance_chain(path)

    case Enum.map(ancestors, & &1.id) do
      [] ->
        []

      ancestor_ids ->
        Access.grants(
          target_page_id: [in: ancestor_ids],
          target_scope: "container",
          condition: "true",
          source_page_id: [is_nil: true],
          action: [in: Access.page_actions()]
        )
    end
  end

  defp catalog_with_referenced_principals(catalog, page_grants, path, ancestor_grants) do
    known_uids =
      MapSet.new(
        for subject <- catalog, uid = Map.get(subject, :principal_uid), not is_nil(uid), do: uid
      )

    root_owner = hd(path).private_owner_uid

    referenced_uids =
      ([root_owner] ++
         Enum.map(page_grants, & &1.principal_uid) ++
         Enum.map(ancestor_grants, & &1.principal_uid))
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(known_uids, &1)))
      |> Enum.uniq()

    extra_subjects =
      if referenced_uids == [] do
        []
      else
        Ankole.Principals.list_principals!(
          query: [
            filter: [uid: [in: referenced_uids], type: [in: [:human, :agent]]],
            load: [:human_user, :agent]
          ]
        )
        |> Enum.map(fn principal ->
          principal
          |> Collaborators.principal_subject()
          |> Map.put(:disabled, principal.status != :active)
        end)
      end

    catalog ++ extra_subjects
  end

  defp inherited_grants(
         path,
         scope_kind,
         collab_scope,
         visible_uids,
         catalog,
         space_role,
         ancestor_grants,
         can_manage
       ) do
    {root_index, _ancestors} = inheritance_chain(path)
    root = hd(path)

    baseline =
      cond do
        root_index != 0 ->
          []

        scope_kind == :private ->
          private_owner_inherited(
            root.private_owner_uid,
            collab_scope,
            visible_uids,
            catalog,
            can_manage
          )

        root.inherit_permissions and collab_scope == :all ->
          space_inherited(catalog, space_role || "view")

        true ->
          []
      end

    ancestor_rows =
      ancestor_inherited(
        ancestor_grants,
        scope_kind,
        collab_scope,
        visible_uids,
        catalog,
        root.private_owner_uid,
        can_manage
      )

    baseline ++ ancestor_rows
  end

  defp inheritance_chain(path) do
    last = length(path) - 1
    root_index = walk_inheritance_start(path, last)

    ancestors =
      if root_index < last, do: Enum.slice(path, root_index, last - root_index), else: []

    {root_index, ancestors}
  end

  defp walk_inheritance_start(_path, 0), do: 0

  defp walk_inheritance_start(path, index) do
    if Enum.at(path, index).inherit_permissions do
      walk_inheritance_start(path, index - 1)
    else
      index
    end
  end

  defp private_owner_inherited(owner_uid, collab_scope, visible_uids, catalog, can_manage) do
    if collab_scope == :shared and not MapSet.member?(visible_uids, owner_uid) do
      []
    else
      subject = find_subject(catalog, owner_uid, nil)

      if not can_manage and Map.get(subject, :disabled, false) do
        []
      else
        [Map.merge(subject, %{origin: :private_owner, role: "manage"})]
      end
    end
  end

  defp space_inherited(catalog, space_role) do
    pod_admin =
      Enum.find(catalog, &(&1.kind == :group and &1.built_in and &1.group_slug == "pod_admin"))

    all_humans =
      Enum.find(catalog, &(&1.kind == :group and &1.built_in and &1.group_slug == "all_humans"))

    agent_grants =
      Access.grants(
        resource_pattern: "pod:space:**",
        principal_uid: [is_nil: false],
        condition: "true",
        action: [in: Access.page_actions()]
      )

    agents_by_uid =
      Map.new(
        for subject <- catalog,
            subject.kind == :agent and not Map.get(subject, :disabled, false),
            do: {subject.principal_uid, subject}
      )

    agent_rows =
      agent_grants
      |> Enum.filter(&Map.has_key?(agents_by_uid, &1.principal_uid))
      |> Enum.group_by(& &1.principal_uid)
      |> Enum.map(fn {uid, grants} ->
        bits = Enum.reduce(grants, 0, &bor(Access.action_bit(&1.action), &2))

        Map.merge(Map.fetch!(agents_by_uid, uid), %{
          origin: :space_agent,
          role: Access.role_for_actions(bits)
        })
      end)
      |> Enum.sort_by(&{&1.name, &1.principal_uid})

    admin_rows =
      if pod_admin, do: [Map.merge(pod_admin, %{origin: :space_admin, role: "manage"})], else: []

    default_rows =
      if all_humans,
        do: [Map.merge(all_humans, %{origin: :space_default, role: space_role})],
        else: []

    admin_rows ++ default_rows ++ agent_rows
  end

  defp ancestor_inherited(
         [],
         _scope_kind,
         _collab_scope,
         _visible_uids,
         _catalog,
         _owner_uid,
         _can_manage
       ),
       do: []

  defp ancestor_inherited(
         ancestor_grants,
         scope_kind,
         collab_scope,
         visible_uids,
         catalog,
         private_owner_uid,
         can_manage
       ) do
    ancestor_grants
    |> Enum.group_by(&{&1.principal_uid, &1.group_id})
    |> Enum.flat_map(fn {{uid, group_id}, grants} ->
      subject = find_subject(catalog, uid, group_id)
      bits = Enum.reduce(grants, 0, &bor(Access.action_bit(&1.action), &2))

      skip? =
        (scope_kind == :private and uid == private_owner_uid) or
          (scope_kind == :private and subject.membership == :guest) or
          (not can_manage and (Map.get(subject, :disabled, false) or band(bits, 1) == 0)) or
          (collab_scope == :shared and (is_nil(uid) or not MapSet.member?(visible_uids, uid)))

      if skip? do
        []
      else
        [Map.merge(subject, %{origin: :ancestor, role: Access.role_for_actions(bits)})]
      end
    end)
    |> Enum.sort_by(&{&1.name, &1.principal_uid || &1.group_id})
  end

  defp filter_grants_for_caller(grants, true, :all, _visible_uids), do: grants

  defp filter_grants_for_caller(grants, true, :shared, visible_uids) do
    Enum.map(grants, fn grant ->
      cond do
        grant.kind == :userset ->
          grant

        grant.principal_uid && MapSet.member?(visible_uids, grant.principal_uid) ->
          grant

        true ->
          Map.merge(grant, %{
            name: grant.principal_uid || grant.group_id || "Restricted",
            avatar_url: nil,
            subtitle: nil
          })
      end
    end)
  end

  defp filter_grants_for_caller(grants, false, collab_scope, visible_uids) do
    Enum.filter(grants, fn grant ->
      visible? =
        collab_scope == :all or
          (not is_nil(grant.principal_uid) and MapSet.member?(visible_uids, grant.principal_uid))

      active_view_grant? =
        not Map.get(grant, :disabled, false) and
          not grant.inactive_in_private and
          is_nil(grant.source_page_id) and
          grant.condition == "true" and
          (grant.rule_kind == :role or "page_view" in grant.actions)

      active_view_grant? and visible?
    end)
  end

  defp find_subject(catalog, uid, group_id) do
    found =
      Enum.find(
        catalog,
        &((uid && &1.principal_uid == uid) || (group_id && &1.group_id == group_id))
      )

    if found do
      found
      |> Map.take(@subject_keys)
      |> Map.put(:disabled, Map.get(found, :disabled, false))
    else
      %{
        principal_uid: uid,
        group_id: group_id,
        name: uid || group_id || "Restricted",
        kind: if(group_id, do: :group, else: :human),
        avatar_url: nil,
        subtitle: nil,
        membership: nil,
        group_domain: nil,
        group_slug: nil,
        built_in: nil,
        disabled: false
      }
    end
  end

  defp grouped_grants(grants, provenance, subjects, scope_kind) do
    grants
    |> Enum.group_by(
      &{&1.principal_uid, &1.group_id, &1.source_page_id, &1.source_action, &1.target_scope,
       &1.condition}
    )
    |> Enum.map(fn {{uid, group, source, source_action, scope, condition}, items} ->
      bits = Enum.reduce(items, 0, &bor(Access.action_bit(&1.action), &2))
      actions = items |> Enum.map(& &1.action) |> Enum.sort()
      role = Access.role_for_actions(bits)
      subject = find_subject(subjects, uid, group)

      source_page =
        Enum.find_value(provenance, fn entry ->
          if entry.grant.source_page_id == source, do: entry.source_page
        end)

      rule_kind =
        if is_nil(source) and condition == "true" and (not is_nil(uid) or not is_nil(group)) and
             Access.canonical_role_actions?(role, actions) do
          :role
        else
          :advanced
        end

      inactive_in_private = scope_kind == :private and subject.membership == :guest

      Map.merge(subject, %{
        principal_uid: uid,
        group_id: group,
        source_page_id: source,
        source_action: source_action,
        target_scope: scope || "container",
        condition: condition,
        actions: actions,
        source_page: source_page,
        role: role,
        rule_kind: rule_kind,
        inactive_in_private: inactive_in_private
      })
      |> then(fn grant ->
        if source do
          Map.merge(grant, %{
            kind: :userset,
            name: (source_page && source_page.title) || "Restricted page"
          })
        else
          grant
        end
      end)
    end)
    |> Enum.sort_by(
      &{&1.kind, &1.name, &1.principal_uid || "", &1.group_id || "", &1.source_page_id || "",
       &1.source_action || "", &1.target_scope, &1.condition}
    )
  end
end
