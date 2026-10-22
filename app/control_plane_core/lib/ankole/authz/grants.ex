defmodule Ankole.AuthZ.Grants do
  @moduledoc """
  Permission grant writes that run in the caller's transaction.

  Each write locks the Pod tree first, because Pod access reads grants.
  """

  require Ash.Query

  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Input
  alias Ankole.AuthZ.Store

  @console_admin_resource_pattern "**"
  @console_admin_actions ~w(read update delete reset decrypt sync)

  def create_permission_grant(repo, attrs) do
    :ok = Ankole.Repo.require_transaction(repo)
    Ankole.Pod.Pages.lock_tree()

    with {:ok, attrs} <- grant_attrs(repo, attrs) do
      Ankole.Ash.create(Grant, :create_in_tx, attrs)
    end
  end

  def upsert_permission_grant(repo, attrs) do
    :ok = Ankole.Repo.require_transaction(repo)
    Ankole.Pod.Pages.lock_tree()

    with {:ok, attrs} <- grant_attrs(repo, attrs) do
      Ankole.Ash.create(Grant, :upsert_in_tx, attrs,
        upsert_identity: permission_grant_identity(attrs)
      )
    end
  end

  def update_permission_grant(repo, %Grant{} = grant, attrs) do
    :ok = Ankole.Repo.require_transaction(repo)
    Ankole.Pod.Pages.lock_tree()

    with {:ok, attrs} <- grant_attrs(repo, attrs) do
      Ankole.Ash.update(grant, :update_in_tx, attrs)
    end
  end

  def delete_permission_grant(repo, id) do
    :ok = Ankole.Repo.require_transaction(repo)
    Ankole.Pod.Pages.lock_tree()

    with {:ok, id} <- Ecto.UUID.cast(id),
         %Grant{} = grant <- Grant |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!() do
      Ankole.Ash.destroy(grant, :delete_in_tx)
    else
      _not_found -> {:error, :not_found}
    end
  end

  def upsert_console_admin_grants(repo, %Group{} = admin_group) do
    Enum.reduce_while(@console_admin_actions, {:ok, []}, fn action, {:ok, acc} ->
      case upsert_permission_grant(repo, %{
             group_id: admin_group.id,
             resource_pattern: @console_admin_resource_pattern,
             action: action,
             description: "Built-in console administrator grant",
             metadata: %{"built_in" => "console_admin"}
           }) do
        {:ok, grant} -> {:cont, {:ok, [grant | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, grants} -> {:ok, Enum.reverse(grants)}
      {:error, _reason} = error -> error
    end
  end

  defp grant_attrs(repo, attrs) do
    attrs = Input.grant_attrs(attrs)

    case Input.fetch_attr(attrs, :group_name) do
      {:ok, group_name} ->
        with {:ok, group} <- Store.fetch_group(repo, group_name) do
          {:ok, attrs |> Map.delete(:group_name) |> Map.put(:group_id, group.id)}
        end

      :error ->
        {:ok, attrs}
    end
  end

  defp permission_grant_identity(attrs) do
    case Ankole.PrincipalKey.normalize_optional(Map.get(attrs, :principal_uid)) do
      {:ok, uid} when is_binary(uid) -> :principal_rule
      _not_principal_owned -> :group_rule
    end
  end
end
