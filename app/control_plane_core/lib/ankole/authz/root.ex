defmodule Ankole.AuthZ.Root do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.AuthZ.Store
  alias Ankole.AuthZ.Root
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @admin_group_name "siteadmin"
  @all_humans_group_name "all_humans"
  @all_humans_condition ~s(principal.type == "human" && principal.status == "active")

  @doc """
  Returns true when the principal is an active human member of the built-in admin group.
  """
  @spec site_admin?(String.t()) :: boolean()
  def site_admin?(principal_uid) do
    # `type == :human` deliberately excludes agent principals: agents never get
    # operator admin even if added to the group. `status == :active` denies a
    # suspended/disabled human without having to scrub group memberships. A
    # malformed uid normalizes to an error and is treated as "not admin".
    with {:ok, principal_uid} <- Principals.normalize_uid(principal_uid),
         {:ok, tenant} <- Ankole.Tenants.privileged() do
      admin_group_name = Root.admin_group_name()

      Repo.with_tenant(tenant.id, fn ->
        Repo.exists?(
          from membership in Membership,
            join: group in Group,
            on: group.id == membership.group_id,
            join: principal in Principal,
            on: principal.uid == membership.principal_uid,
            where:
              membership.principal_uid == ^principal_uid and group.name == ^admin_group_name and
                group.built_in == true and group.kind == :static and principal.type == :human and
                principal.status == :active and principal.tenant_id == ^tenant.id
        )
      end)
    else
      {:error, _reason} -> false
    end
  end

  def admin_group_name, do: @admin_group_name

  # Runs inside the caller's transaction. Admin writes take the group lock
  # before the principal lock, in that one installation-wide order.
  def root_init_admin(repo, principal_uid) do
    with %Group{} = admin_group <- Store.fetch_group_by_name(repo, @admin_group_name),
         {:ok, admin_group} <- Store.lock_group(repo, admin_group.id),
         {:ok, principal} <- Store.fetch_principal_for_update(repo, principal_uid),
         :ok <- Store.ensure_active_human(principal),
         {:ok, membership} <- ensure_root_membership(repo, admin_group, principal.uid) do
      {:ok, %{admin_group: admin_group, membership: membership}}
    else
      nil -> {:error, :site_admin_group_missing}
      error -> error
    end
  end

  def ensure_site_admin_group(repo) do
    upsert_builtin_group(repo, %{
      name: @admin_group_name,
      display_name: "Site Administrators",
      kind: :static,
      built_in: true,
      computed_condition: nil,
      description: "Root operators for this Ankole installation",
      metadata: %{}
    })
  end

  def ensure_all_humans_group(repo) do
    upsert_builtin_group(repo, %{
      name: @all_humans_group_name,
      display_name: "All Humans",
      kind: :computed,
      built_in: true,
      computed_condition: @all_humans_condition,
      description: "Computed group for active human Principals",
      metadata: %{}
    })
  end

  defp ensure_root_membership(repo, %Group{} = admin_group, principal_uid) do
    case lock_admin_memberships(repo, admin_group.id) do
      [] ->
        Store.insert_membership(repo, admin_group.id, principal_uid)

      [%Membership{principal_uid: ^principal_uid} = membership] ->
        {:ok, membership}

      [_membership | _rest] ->
        {:error, :root_init_closed}
    end
  end

  defp lock_admin_memberships(repo, admin_group_id) do
    repo.all(
      from membership in Membership,
        where: membership.group_id == ^admin_group_id,
        order_by: [asc: membership.principal_uid],
        lock: "FOR UPDATE"
    )
  end

  defp upsert_builtin_group(repo, attrs) do
    case Store.fetch_group_by_name(repo, attrs.name) do
      %Group{} = group ->
        case builtin_shape_matches?(group, attrs) do
          true -> {:ok, group}
          false -> {:error, {:built_in_group_conflict, attrs.name}}
        end

      nil ->
        create_builtin_group(repo, attrs)
    end
  end

  defp create_builtin_group(repo, attrs) do
    %Group{}
    |> Group.changeset(attrs)
    |> repo.insert(on_conflict: :nothing, conflict_target: [:tenant_id, :name])
    |> case do
      {:ok, _group} -> upsert_builtin_group(repo, attrs)
      {:error, %Changeset{} = changeset} -> {:error, changeset}
    end
  end

  defp builtin_shape_matches?(%Group{} = group, attrs) do
    group.kind == attrs.kind and group.built_in == true and
      group.computed_condition == attrs.computed_condition
  end
end
