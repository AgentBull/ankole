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

  def create_permission_grant(attrs) do
    :ok = Ankole.Repo.require_transaction()
    Ankole.Pod.Pages.lock_tree()

    with {:ok, attrs} <- grant_attrs(attrs) do
      Ankole.Ash.create(Grant, :create_in_tx, attrs)
    end
  end

  def upsert_permission_grant(attrs) do
    :ok = Ankole.Repo.require_transaction()
    Ankole.Pod.Pages.lock_tree()

    with {:ok, attrs} <- grant_attrs(attrs) do
      Ankole.Ash.create(Grant, :upsert_in_tx, attrs,
        upsert_identity: permission_grant_identity(attrs)
      )
    end
  end

  def update_permission_grant(%Grant{} = grant, attrs) do
    :ok = Ankole.Repo.require_transaction()
    Ankole.Pod.Pages.lock_tree()

    with {:ok, attrs} <- grant_attrs(attrs) do
      Ankole.Ash.update(grant, :update_in_tx, attrs)
    end
  end

  def delete_permission_grant(id) do
    :ok = Ankole.Repo.require_transaction()
    Ankole.Pod.Pages.lock_tree()

    with {:ok, id} <- Ecto.UUID.cast(id),
         %Grant{} = grant <- Grant |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!() do
      Ankole.Ash.destroy(grant, :delete_in_tx)
    else
      _not_found -> {:error, :not_found}
    end
  end

  @doc """
  Creates a grant for the Console operator. The Pod writes the grants of its
  page actions, so the operator cannot create one.
  """
  def create_operator_grant(attrs) do
    with :ok <- refuse_page_action(Map.get(attrs, :action)) do
      create_permission_grant(attrs)
    end
  end

  @doc """
  Updates a grant for the Console operator. A Pod page grant keeps the resource
  pattern, the action, and the condition that the Pod wrote; only its
  description can change.
  """
  def update_operator_grant(id, attrs) do
    with {:ok, grant} <- fetch_grant(id),
         :ok <- refuse_page_action(Map.get(attrs, :action)),
         :ok <- keep_page_grant(grant, attrs) do
      update_permission_grant(grant, attrs)
    end
  end

  @doc "Deletes a grant for the Console operator. A Pod page grant is refused."
  def delete_operator_grant(id) do
    with {:ok, grant} <- fetch_grant(id) do
      if page_action?(grant.action),
        do: {:error, :page_grant},
        else: delete_permission_grant(grant.id)
    end
  end

  def upsert_console_admin_grants(%Group{} = admin_group) do
    Enum.reduce_while(@console_admin_actions, {:ok, []}, fn action, {:ok, acc} ->
      case upsert_permission_grant(%{
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

  defp grant_attrs(attrs) do
    attrs = Input.grant_attrs(attrs)

    case Input.fetch_attr(attrs, :group_name) do
      {:ok, group_name} ->
        with {:ok, group} <- Store.fetch_group(group_name) do
          {:ok, attrs |> Map.delete(:group_name) |> Map.put(:group_id, group.id)}
        end

      :error ->
        {:ok, attrs}
    end
  end

  defp fetch_grant(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Grant{} = grant <- Grant |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!() do
      {:ok, grant}
    else
      _not_found -> {:error, Ankole.Errors.Invalid.NotFound.exception(resource: Grant, id: id)}
    end
  end

  defp page_action?(action), do: action in Ankole.Pod.Access.page_actions()

  defp refuse_page_action(action) do
    if page_action?(action),
      do: {:error, invalid_argument(:action, "#{action} is written by the Pod")},
      else: :ok
  end

  defp keep_page_grant(%Grant{action: action}, attrs) do
    with true <- page_action?(action),
         [_ | _] = fields <-
           Enum.filter([:resource_pattern, :action, :condition], &Map.has_key?(attrs, &1)) do
      {:error, Enum.map(fields, &invalid_argument(&1, "cannot change on a Pod page grant"))}
    else
      _no_change -> :ok
    end
  end

  defp invalid_argument(field, message),
    do: Ash.Error.Changes.InvalidArgument.exception(field: field, message: message)

  defp permission_grant_identity(attrs) do
    case Ankole.PrincipalKey.normalize_optional(Map.get(attrs, :principal_uid)) do
      {:ok, uid} when is_binary(uid) -> :principal_rule
      _not_principal_owned -> :group_rule
    end
  end
end
