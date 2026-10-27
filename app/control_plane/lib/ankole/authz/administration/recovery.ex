defmodule Ankole.AuthZ.Recovery do
  @moduledoc false
  import Ecto.Query, only: [from: 2, dynamic: 1, dynamic: 2]
  require Ash.Query
  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.AuthZ.Root
  alias Ankole.AuthZ.Store
  alias Ankole.Principals
  alias Ankole.Repo

  def administrator_recovery_required? do
    admin_group_name = Root.admin_group_name()

    members =
      Ash.Query.filter(Membership, group.name == ^admin_group_name and group.built_in == true)

    Ankole.Ash.exists?(members) and
      not Ankole.Ash.exists?(
        Ash.Query.filter(
          members,
          principal.type == :human and principal.membership == :member and
            principal.status == :active
        )
      )
  end

  @doc false
  def recover_admin_in_tx(uid) do
    :ok = Ankole.Pod.Pages.lock_tree()

    case Store.lock_built_in_admin_group_for_update(Root.admin_group_name()) do
      %Group{} = group ->
        active_admin_exists =
          Membership
          |> Ash.Query.filter(
            group_id == ^group.id and principal.type == :human and principal.membership == :member and
              principal.status == :active
          )
          |> Ankole.Ash.exists?()

        with false <- active_admin_exists,
             {:ok, principal} <- Store.fetch_principal_for_update(uid),
             :ok <- Store.ensure_active_human(principal),
             {:ok, _} <- Store.insert_membership(group.id, principal.uid),
             {:ok, pod_group} <- Root.ensure_pod_admin_group(),
             {:ok, _} <- Ankole.AuthZ.Grants.upsert_pod_admin_grants(pod_group),
             {:ok, _} <- Store.insert_membership(pod_group.id, principal.uid) do
          {:ok, principal}
        else
          true -> {:error, :active_admin_exists}
          error -> error
        end

      nil ->
        {:error, :setup_not_complete}
    end
  end

  def recover_pod_admin_in_tx(uid) do
    :ok = Repo.require_transaction()
    :ok = Ankole.Pod.Pages.lock_tree()

    with {:ok, group} <- Root.ensure_pod_admin_group(),
         {:ok, _} <- Store.lock_group(group.id),
         members <-
           Membership
           |> Ash.Query.filter(group_id == ^group.id and principal.status == :active)
           |> Ash.Query.load(:principal)
           |> Ankole.Ash.read!(),
         {:ok, policy} <- Ankole.Principals.PodLoginPolicy.get(),
         false <-
           Enum.any?(
             members,
             &Ankole.Principals.PodLoginPolicy.has_allowed_binding?(policy, &1.principal)
           ),
         {:ok, principal} <- Store.fetch_principal_for_update(uid),
         :ok <- Store.ensure_active_human(principal),
         true <- Ankole.Principals.PodLoginPolicy.has_allowed_binding?(policy, principal),
         {:ok, _} <- Ankole.AuthZ.Grants.upsert_pod_admin_grants(group),
         {:ok, _} <- Store.insert_membership(group.id, principal.uid) do
      {:ok, principal}
    else
      true -> {:error, :active_admin_exists}
      false -> {:error, :no_login_method}
      error -> error
    end
  end

  @doc """
  Lists the permission rules that must be approved before Human restoration.
  Remove unwanted grants or memberships through AuthZ, then request a new review.
  """
  def restoration_review(uid) do
    with {:ok, principal} <- Principals.get_principal(uid),
         {:ok, userset_sources} <- potential_userset_sources(principal) do
      userset_grants =
        Repo.all(
          from g in Grant,
            join: page in Ankole.Pod.Page,
            on: page.id == g.source_page_id,
            where: ^userset_sources,
            where: is_nil(page.deleted_at),
            order_by: g.id,
            select: %{
              id: g.id,
              source_page_id: g.source_page_id,
              source_action: g.source_action,
              target_page_id: g.target_page_id,
              target_scope: g.target_scope,
              resource_pattern: g.resource_pattern,
              action: g.action,
              condition: g.condition
            }
        )

      static_ids =
        Repo.all(
          from m in Membership, where: m.principal_uid == ^principal.uid, select: m.group_id
        )

      groups =
        Repo.all(
          from g in Group,
            where: g.id in ^static_ids or g.kind == :computed,
            order_by: g.id,
            select: %{
              id: g.id,
              name: g.name,
              domain: fragment("?::text", g.domain),
              kind: fragment("?::text", g.kind),
              condition: g.computed_condition
            }
        )

      group_ids = Enum.map(groups, & &1.id)

      grants =
        Repo.all(
          from g in Grant,
            where: g.principal_uid == ^principal.uid or g.group_id in ^group_ids,
            order_by: g.id,
            select: %{
              id: g.id,
              principal_uid: g.principal_uid,
              group_id: g.group_id,
              resource_pattern: g.resource_pattern,
              action: g.action,
              condition: g.condition
            }
        )

      permissions = %{
        "principal" => %{
          uid: principal.uid,
          display_name: principal.display_name,
          avatar_url: principal.avatar_url,
          access_version: principal.access_version
        },
        "groups" => groups,
        "grants" => grants,
        "userset_grants" => userset_grants
      }

      fingerprint =
        :crypto.hash(:sha256, :erlang.term_to_binary(permissions, [:deterministic]))
        |> Base.url_encode64(padding: false)

      {:ok, %{fingerprint: fingerprint, permissions: permissions}}
    end
  end

  defp potential_userset_sources(principal) do
    alias Ankole.Pod.Access

    with {:ok, snapshot} <- Ankole.AuthZ.Snapshot.build_pod_context_snapshot(principal.uid) do
      # Review every permission the restored member could receive, including
      # conditional rules. This preview does not change the stored Principal.
      snapshot =
        snapshot
        |> put_in(["principal", "status"], "active")
        |> Map.update!(
          "computedGroups",
          &Enum.map(&1, fn group -> Map.put(group, "condition", "true") end)
        )
        |> Map.update!(
          "grants",
          &Enum.map(&1, fn grant -> Map.put(grant, "condition", "true") end)
        )

      evaluated = Ankole.Kernel.authz_evaluate_pod_context(snapshot)
      actor = Ankole.AuthZ.Actor.new(%{principal | status: :active})

      with {:ok, reachable} <- Access.reachable_anchors(actor, context: {snapshot, evaluated}) do
        sources =
          Enum.reduce(Access.page_actions(), dynamic(false), fn action, filter ->
            {containers, pages} = Access.visibility_ids(reachable, Access.action_bit(action))

            dynamic(
              [g, page],
              ^filter or
                (g.source_action == ^action and
                   ((page.is_acl_anchor and page.id in ^pages) or
                      (not page.is_acl_anchor and page.acl_anchor_id in ^containers)))
            )
          end)

        {:ok, sources}
      end
    end
  end
end
