defmodule Ankole.Pod.Pages.Sharing do
  @moduledoc "Owns page sharing, collaborator visibility, and Space access settings."
  require Ash.Query
  alias Ankole.{AuthZ, Repo}
  alias Ankole.Pod.{Access, Page, Pages}

  def sharing(%Ankole.AuthZ.Actor{} = actor, id) do
    Repo.transact_repeatable_read_only(fn ->
      with {:ok, reachable} <- Access.reachable_anchors(actor),
           {:ok, page} <- Pages.fetch(id),
           {:ok, _} <- Access.authorize_reachable(page, "page_manage", reachable),
           {:ok, provenance} <- Access.access_provenance_in_tx(actor, id, reachable: reachable),
           {:ok, subjects} <- sharing_subjects(actor, reachable: reachable) do
        {:ok,
         %{
           inherit_permissions: page.inherit_permissions,
           sharing_version: sharing_version(page),
           subjects: subjects,
           grants: grouped_grants(Access.page_grants(id), provenance)
         }}
      end
    end)
  end

  def subjects(%Ankole.AuthZ.Actor{} = actor) do
    Repo.transact_repeatable_read_only(fn -> sharing_subjects(actor) end)
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

    with {:ok, page} <- Pages.lock(id),
         {:ok, _} <- AuthZ.authorize_locked_in_tx(actor, page, "page_manage"),
         :ok <- sharing_cas(page, Ankole.Attrs.get(attrs, :sharing_version)),
         {:ok, grants} <- normalize_grants(Ankole.Attrs.get(attrs, :grants, :unchanged), page.id),
         {:ok, page} <-
           Access.update_anchor_in_tx(page, :sharing, %{
             inherit_permissions:
               Ankole.Attrs.get(attrs, :inherit_permissions, page.inherit_permissions)
           }),
         :ok <- replace_grants(page.id, grants),
         :ok <- retain_manager(actor, page) do
      Pages.fetch(page.id)
    end
  end

  def space(%Ankole.AuthZ.Actor{} = actor) do
    Repo.transact_repeatable_read_only(fn -> space_in_snapshot(actor) end)
  end

  defp space_in_snapshot(%Ankole.AuthZ.Actor{} = actor) do
    with {:ok, _} <- Access.principal(actor),
         {:ok, subjects} <- sharing_subjects(actor),
         {:ok, group} <- Access.space_group(),
         {:ok, grants} <- AuthZ.list_group_grants(group.id) do
      actions =
        for g <- grants,
            g.resource_pattern == "pod:space:**" and g.condition == "true",
            do: g.action

      role =
        cond do
          "page_manage" in actions -> "manage"
          "page_edit" in actions -> "edit"
          "page_write_records" in actions -> "contribute"
          true -> "view"
        end

      agent_grants =
        Access.grants(
          resource_pattern: "pod:space:**",
          principal_uid: [is_nil: false],
          action: [in: Access.page_actions()]
        )

      agent_uids = for %{kind: :agent, principal_uid: actor} <- subjects, do: actor

      agents =
        agent_grants
        |> grouped_grants()
        |> Enum.filter(&(&1.kind == :agent and &1.principal_uid in agent_uids))

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

  defp sharing_version(page) do
    grants =
      Access.page_grants(page.id)
      |> Enum.map(
        &{&1.principal_uid, &1.group_id, &1.source_page_id, &1.source_action, &1.target_scope,
         &1.action, &1.condition}
      )
      |> Enum.sort()

    :crypto.hash(:sha256, :erlang.term_to_binary({page.inherit_permissions, grants}))
    |> Base.encode16(case: :lower)
  end

  defp sharing_cas(_page, nil), do: {:error, :sharing_conflict}

  defp sharing_cas(page, expected) do
    if expected == sharing_version(page), do: :ok, else: {:error, :sharing_conflict}
  end

  defp normalize_grants(:unchanged, _id), do: {:ok, :unchanged}

  defp normalize_grants(grants, id) when is_list(grants) do
    Enum.reduce_while(grants, {:ok, []}, fn grant, {:ok, acc} ->
      if is_map(grant) do
        owner =
          Map.new(
            for key <- [:principal_uid, :group_id, :source_page_id],
                value = Ankole.Attrs.get(grant, key),
                value,
                do: {key, value}
          )

        source_action = Ankole.Attrs.get(grant, :source_action)
        scope = (Ankole.Attrs.get(grant, :target_scope) || "container") |> to_string()
        condition = Ankole.Attrs.get(grant, :condition) || "true"

        with true <- map_size(owner) == 1,
             true <- scope in ["container", "self"],
             true <-
               not Map.has_key?(owner, :source_page_id) or source_action in Access.page_actions(),
             :ok <- eligible_collaborator(owner),
             {:ok, actions} <- grant_actions(grant) do
          owner =
            if Map.has_key?(owner, :source_page_id),
              do: Map.put(owner, :source_action, source_action),
              else: owner

          suffix = if scope == "container", do: "**", else: "page"

          attrs =
            Map.merge(owner, %{resource_pattern: "pod:**:#{id}:#{suffix}", condition: condition})

          {:cont, {:ok, Enum.map(actions, &Map.put(attrs, :action, &1)) ++ acc}}
        else
          _ -> {:halt, {:error, :invalid_grants}}
        end
      else
        {:halt, {:error, :invalid_grants}}
      end
    end)
  end

  defp normalize_grants(_, _id), do: {:error, :invalid_grants}

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

        role_matches? =
          is_nil(role) or
            case Access.actions(role) do
              {:ok, expected} -> Enum.sort(Enum.uniq(actions)) == Enum.sort(expected)
              :error -> false
            end

        if role_matches? and Enum.all?(actions, &(&1 in Access.page_actions())),
          do: {:ok, Enum.uniq(actions)},
          else: :error

      _ ->
        :error
    end
  end

  defp eligible_collaborator(%{principal_uid: uid}) do
    with {:ok, principal} <- Ankole.Principals.get_principal(uid),
         {:ok, _} <- Access.principal(Ankole.AuthZ.Actor.new(principal)),
         do: :ok
  end

  defp eligible_collaborator(_), do: :ok
  defp replace_grants(_id, :unchanged), do: :ok

  defp replace_grants(id, grants) do
    Access.page_grants(id) |> Access.remove_grants()

    Enum.reduce_while(grants, :ok, fn attrs, :ok ->
      case Ankole.AuthZ.Grants.create_permission_grant(attrs) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp retain_manager(%Ankole.AuthZ.Actor{} = actor, %{inherit_permissions: false} = page) do
    uid = Ankole.AuthZ.Actor.uid(actor)
    Access.put_role(%{principal_uid: uid}, "pod:**:#{page.id}:**", "manage")
  end

  defp retain_manager(_uid, _page), do: :ok

  defp sharing_subjects(%Ankole.AuthZ.Actor{} = actor, opts \\ []) do
    uid = Ankole.AuthZ.Actor.uid(actor)

    with {:ok, scope} <- Access.collaborator_scope(actor) do
      subjects = all_subjects()

      if scope == :shared do
        result =
          case Keyword.fetch(opts, :reachable) do
            {:ok, reachable} -> {:ok, reachable}
            :error -> Access.reachable_anchors(actor)
          end

        with {:ok, reachable} <- result do
          {containers, own} = Access.visibility_ids(reachable)
          grants = Access.grants(target_page_id: [is_nil: false], principal_uid: [is_nil: false])
          targets = Enum.map(grants, & &1.target_page_id)

          pages =
            Page
            |> Ash.Query.filter(id in ^targets and (acl_anchor_id in ^containers or id in ^own))
            |> Ash.Query.select([:id, :acl_anchor_id, :is_acl_anchor])
            |> Ankole.Ash.read!()
            |> Map.new(&{&1.id, &1})

          collaborators =
            grants
            |> Enum.filter(&Map.has_key?(pages, &1.target_page_id))
            |> Enum.group_by(& &1.principal_uid, &Map.fetch!(pages, &1.target_page_id))

          {:ok,
           Enum.filter(subjects, fn subject ->
             candidate = Map.get(subject, :principal_uid)

             candidate == uid or
               shares_visible_page?(actor, candidate, Map.get(collaborators, candidate, []))
           end)}
        end
      else
        {:ok, subjects}
      end
    end
  end

  defp shares_visible_page?(_caller, _uid, []), do: false

  defp shares_visible_page?(caller, uid, pages) do
    {:ok, principal} = Ankole.Principals.get_principal(uid)
    actor = Ankole.AuthZ.Actor.new(principal, authn: Map.take(caller.authn, ["ip", "surface"]))
    targets = Enum.map(pages, & &1.acl_anchor_id) |> Enum.uniq()

    case Access.reachable_anchors(actor, target_ids: targets) do
      {:ok, reachable} ->
        Enum.any?(pages, &(Bitwise.band(Access.page_bits(&1, reachable), 1) != 0))

      {:error, _} ->
        false
    end
  end

  defp all_subjects do
    principals =
      Enum.map(Ankole.Principals.list_active_principals(), fn principal ->
        %{principal_uid: principal.uid, name: principal.display_name, kind: principal.type}
      end)

    groups =
      Enum.map(AuthZ.list_principal_groups(), &%{group_id: &1.id, name: &1.name, kind: :group})

    principals ++ groups
  end

  defp grouped_grants(grants, provenance \\ []) do
    subjects = all_subjects()

    grants
    |> Enum.group_by(
      &{&1.principal_uid, &1.group_id, &1.source_page_id, &1.source_action, &1.target_scope,
       &1.condition}
    )
    |> Enum.map(fn {{uid, group, source, source_action, scope, condition}, grants} ->
      bits = Enum.reduce(grants, 0, &Bitwise.bor(Access.action_bit(&1.action), &2))

      subject =
        Enum.find(
          subjects,
          &((uid && Map.get(&1, :principal_uid) == uid) ||
              (group && Map.get(&1, :group_id) == group))
        ) || %{}

      source_page =
        Enum.find_value(provenance, fn entry ->
          if entry.grant.source_page_id == source, do: entry.source_page
        end)

      Map.merge(Map.take(subject, [:name, :kind]), %{
        principal_uid: uid,
        group_id: group,
        source_page_id: source,
        source_action: source_action,
        target_scope: scope || "container",
        condition: condition,
        actions: grants |> Enum.map(& &1.action) |> Enum.sort(),
        source_page: source_page,
        role: Access.role_for_actions(bits)
      })
      |> then(fn grant ->
        if source,
          do:
            Map.merge(grant, %{
              kind: :userset,
              name: (source_page && source_page.title) || "Restricted page"
            }),
          else: grant
      end)
    end)
  end
end
