defmodule Ankole.AuthZ.Root do
  @moduledoc false

  require Ash.Query

  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.AuthZ.Store
  alias Ankole.AuthZ.Root
  alias Ankole.Principals
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
        Membership
        |> Ash.Query.filter(
          principal_uid == ^principal_uid and group.name == ^admin_group_name and
            group.built_in == true and group.kind == :static and principal.type == :human and
            principal.status == :active
        )
        |> Ankole.Ash.exists?()
      end)
    else
      {:error, _reason} -> false
    end
  end

  def admin_group_name, do: @admin_group_name

  # Runs inside the caller's transaction. Admin writes take the group lock
  # before the principal lock, in that one installation-wide order.
  def root_init_admin(principal_uid) do
    with %Group{} = admin_group <- Store.fetch_group_by_name(@admin_group_name),
         {:ok, admin_group} <- Store.lock_group(admin_group.id),
         {:ok, principal} <- Store.fetch_principal_for_update(principal_uid),
         :ok <- Store.ensure_active_human(principal),
         {:ok, membership} <- ensure_root_membership(admin_group, principal.uid) do
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

  @doc """
  Deletes the site administration group and its grants in the selected tenant.

  It runs in the caller's transaction, after the transfer of site
  administration to another tenant.
  """
  def delete_site_admin_group_in_tx do
    Ankole.Pod.Pages.lock_tree()

    case Group
         |> Ash.Query.filter(name == ^@admin_group_name and built_in == true)
         |> Ankole.Ash.read_one!() do
      nil ->
        :ok

      group ->
        with {:ok, _grants} <-
               Grant
               |> Ash.Query.filter(group_id == ^group.id)
               |> Ankole.Ash.destroy_where(:delete_in_tx),
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
