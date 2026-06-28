defmodule Ankole.AuthZ.Grants do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Input
  alias Ankole.AuthZ.Store

  @console_admin_resource_pattern "**"
  @console_admin_actions ~w(read update delete reset decrypt)

  def create_permission_grant(repo, attrs) do
    with {:ok, attrs} <- grant_attrs(repo, attrs) do
      %Grant{}
      |> Grant.changeset(attrs)
      |> repo.insert()
    end
  end

  def upsert_permission_grant(repo, attrs) do
    with {:ok, attrs} <- grant_attrs(repo, attrs),
         changeset <- Grant.changeset(%Grant{}, attrs),
         {:ok, normalized} <- Changeset.apply_action(changeset, :insert) do
      repo.insert(changeset,
        on_conflict: permission_grant_upsert_update(normalized),
        conflict_target: permission_grant_upsert_target(normalized),
        returning: true
      )
    end
  end

  def update_permission_grant(repo, %Grant{} = grant, attrs) do
    with {:ok, attrs} <- grant_attrs(repo, attrs) do
      grant
      |> Grant.changeset(attrs)
      |> repo.update()
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

  def console_admin_grants_ready?(repo, admin_group_id) do
    actions =
      Grant
      |> where(
        [grant],
        grant.group_id == ^admin_group_id and
          grant.resource_pattern == ^@console_admin_resource_pattern and
          grant.action in ^@console_admin_actions and grant.condition == "true"
      )
      |> select([grant], grant.action)
      |> repo.all()
      |> MapSet.new()

    Enum.all?(@console_admin_actions, &MapSet.member?(actions, &1))
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

  defp permission_grant_upsert_update(%Grant{} = grant) do
    [
      set: [
        description: grant.description,
        metadata: grant.metadata,
        updated_at: DateTime.utc_now(:microsecond)
      ]
    ]
  end

  defp permission_grant_upsert_target(%Grant{principal_uid: principal_uid})
       when is_binary(principal_uid) do
    {:unsafe_fragment,
     "(principal_uid, resource_pattern, action, condition) WHERE principal_uid IS NOT NULL"}
  end

  defp permission_grant_upsert_target(%Grant{group_id: group_id}) when is_binary(group_id) do
    {:unsafe_fragment,
     "(group_id, resource_pattern, action, condition) WHERE group_id IS NOT NULL"}
  end
end
