defmodule Ankole.AuthZ.Recovery do
  @moduledoc false
  require Ash.Query
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.AuthZ.Root
  alias Ankole.AuthZ.Store
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
    :ok = Ankole.Files.lock_tree_in_tx()

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
    :ok = Ankole.Files.lock_tree_in_tx()

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
end
