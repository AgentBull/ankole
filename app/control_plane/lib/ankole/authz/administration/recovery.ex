defmodule Ankole.AuthZ.Recovery do
  @moduledoc false
  import Ecto.Query, only: [from: 2]
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
    with {:ok, principal} <- Principals.get_principal(uid) do
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

      userset_grants =
        Repo.all(
          from g in Grant,
            where: not is_nil(g.source_page_id),
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
end
