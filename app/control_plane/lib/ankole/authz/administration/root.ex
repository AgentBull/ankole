defmodule Ankole.AuthZ.Root do
  @moduledoc false

  require Ash.Query

  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.AuthZ.Store
  alias Ankole.AuthZ.Root
  alias Ankole.Principals
  alias Ankole.Repo

  @admin_group_name "siteadmin"
  @all_humans_group_name "all_humans"
  @all_humans_condition ~s(principal.type == "human" && principal.membership == "member" && principal.status == "active")

  @doc """
  Returns true when the principal is an active human member of the built-in admin group.
  """
  @spec site_admin?(String.t()) :: boolean()
  def site_admin?(principal_uid) do
    # `type == :human` deliberately excludes agent principals: agents never get
    # operator admin even if added to the group. `status == :active` denies a
    # suspended/disabled human without having to scrub group memberships. A
    # malformed uid normalizes to an error and is treated as "not admin".
    site_admin_membership?(principal_uid, true)
  end

  @doc """
  Returns true when the principal is a human member of the built-in admin group,
  including principals whose access is currently disabled.
  """
  @spec site_admin_member?(String.t()) :: boolean()
  def site_admin_member?(principal_uid), do: site_admin_membership?(principal_uid, false)

  defp site_admin_membership?(principal_uid, active_only?) do
    with {:ok, principal_uid} <- Principals.normalize_uid(principal_uid),
         {:ok, tenant} <- Ankole.Tenants.privileged() do
      admin_group_name = Root.admin_group_name()

      Repo.with_tenant(tenant.id, fn ->
        query =
          Membership
          |> Ash.Query.filter(
            principal_uid == ^principal_uid and group.name == ^admin_group_name and
              group.built_in == true and group.kind == :static and principal.type == :human and
              principal.membership == :member
          )

        query =
          if active_only?,
            do: Ash.Query.filter(query, principal.status == :active),
            else: query

        Ankole.Ash.exists?(query)
      end)
    else
      {:error, _reason} -> false
    end
  end

  def admin_group_name, do: @admin_group_name
  def pod_admin_group_name, do: "pod_admin"

  def pod_admin?(uid) do
    Membership
    |> Ash.Query.filter(
      principal_uid == ^uid and group.name == "pod_admin" and
        group.built_in == true and principal.type == :human and principal.status == :active and
        principal.membership == :member
    )
    |> Ankole.Ash.exists?()
  end

  # Runs inside the caller's transaction. Admin writes take the group lock
  # before the principal lock, in that one installation-wide order.
  def root_init_admin(principal_uid) do
    with {:ok, pod_group} <- ensure_pod_admin_group(),
         {:ok, _} <- Ankole.AuthZ.Grants.upsert_pod_admin_grants(pod_group),
         %Group{} = admin_group <- Store.fetch_group_by_name(@admin_group_name),
         {:ok, admin_group} <- Store.lock_group(admin_group.id),
         {:ok, principal} <- Store.fetch_principal_for_update(principal_uid),
         :ok <- Store.ensure_active_human(principal),
         {:ok, membership} <- ensure_root_membership(admin_group, principal.uid),
         {:ok, _} <- Store.insert_membership(pod_group.id, principal.uid) do
      {:ok, %{admin_group: admin_group, membership: membership}}
    else
      nil -> {:error, :site_admin_group_missing}
      error -> error
    end
  end

  def ensure_site_admin_group do
    upsert_builtin_group(%{
      name: @admin_group_name,
      display_name: "Site Administrators",
      kind: :static,
      built_in: true,
      computed_condition: nil,
      description: "Root operators for this Ankole installation",
      metadata: %{}
    })
  end

  def ensure_pod_admin_group do
    upsert_builtin_group(%{
      name: "pod_admin",
      display_name: "Pod Administrators",
      kind: :static,
      built_in: true,
      computed_condition: nil,
      description: "Administrators of this Pod",
      metadata: %{}
    })
  end

  def add_pod_admin_in_tx(uid) do
    :ok = Repo.require_transaction()
    Store.add_principal_to_group_by_name(uid, "pod_admin", @admin_group_name)
  end

  @doc """
  Deletes the site administration group and its grants in the selected tenant.

  It runs in the caller's transaction, after the transfer of site
  administration to another tenant.
  """
  def delete_site_admin_group_in_tx do
    Ankole.Files.lock_tree_in_tx()

    case Group
         |> Ash.Query.filter(name == ^@admin_group_name and built_in == true)
         |> Ankole.Ash.read_one!() do
      nil ->
        :ok

      group ->
        with :ok <- Ankole.AuthZ.Grants.delete_group_grants_in_tx(group.id),
             {:ok, _group} <- Ankole.Ash.destroy(group, :delete_in_tx),
             do: :ok
    end
  end

  def ensure_all_humans_group do
    upsert_builtin_group(%{
      name: @all_humans_group_name,
      display_name: "All Humans",
      kind: :computed,
      built_in: true,
      computed_condition: @all_humans_condition,
      description: "Computed group for active human Principals",
      metadata: %{}
    })
  end

  defp ensure_root_membership(%Group{} = admin_group, principal_uid) do
    case lock_admin_memberships(admin_group.id) do
      [] ->
        Store.insert_membership(admin_group.id, principal_uid)

      [%Membership{principal_uid: ^principal_uid} = membership] ->
        {:ok, membership}

      [_membership | _rest] ->
        {:error, :root_init_closed}
    end
  end

  defp lock_admin_memberships(admin_group_id) do
    Membership
    |> Ash.Query.filter(group_id == ^admin_group_id)
    |> Ash.Query.sort(principal_uid: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!()
  end

  defp upsert_builtin_group(attrs) do
    case Store.fetch_group_by_name(attrs.name) do
      %Group{} = group ->
        case builtin_shape_matches?(group, attrs) do
          true -> {:ok, group}
          false -> {:error, {:built_in_group_conflict, attrs.name}}
        end

      nil ->
        create_builtin_group(attrs)
    end
  end

  defp create_builtin_group(attrs) do
    Ankole.Ash.create(Group, :ensure_in_tx, attrs)
    |> case do
      {:ok, _group} -> upsert_builtin_group(attrs)
      {:error, _reason} = error -> error
    end
  end

  defp builtin_shape_matches?(%Group{} = group, attrs) do
    group.kind == attrs.kind and group.built_in == true and
      group.computed_condition == attrs.computed_condition
  end
end
