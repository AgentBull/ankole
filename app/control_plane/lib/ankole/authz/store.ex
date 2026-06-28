defmodule Ankole.AuthZ.Store do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.AuthZ.ExternalBinding
  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Input
  alias Ankole.AuthZ.Membership
  alias Ankole.Principals
  alias Ankole.Principals.Principal

  def delete_operator_group(repo, id_or_name) do
    with {:ok, group} <- fetch_group_for_update(repo, id_or_name),
         :ok <- ensure_operator_group(group),
         :ok <- ensure_group_has_no_grants(repo, group.id) do
      repo.delete(group)
    end
  end

  def add_principal_to_group(repo, principal_uid, group_id_or_name) do
    with {:ok, group} <- fetch_group_for_update(repo, group_id_or_name),
         :ok <- ensure_static_group(group),
         {:ok, principal_uid} <- Principals.normalize_uid(principal_uid),
         :ok <- ensure_principal_exists(repo, principal_uid) do
      insert_membership(repo, group.id, principal_uid)
    end
  end

  def remove_principal_from_group(repo, principal_uid, group_id_or_name, admin_group_name) do
    with {:ok, group} <- fetch_group(repo, group_id_or_name),
         :ok <- ensure_static_group(group),
         {:ok, principal_uid} <- Principals.normalize_uid(principal_uid) do
      remove_membership(repo, principal_uid, group, admin_group_name)
    end
  end

  def upsert_external_binding(repo, attrs) do
    with {:ok, attrs} <- binding_attrs(repo, attrs) do
      %ExternalBinding{}
      |> ExternalBinding.changeset(attrs)
      |> repo.insert(
        conflict_target: [:provider, :external_id],
        on_conflict: {:replace, [:group_id, :metadata, :updated_at]},
        returning: true
      )
    end
  end

  def external_group_ids(repo, provider, external_id) do
    with {:ok, provider} <- Input.normalize_provider(provider),
         {:ok, external_id} <- Input.normalize_required_text(external_id) do
      ExternalBinding
      |> join(:inner, [binding], group in Group, on: group.id == binding.group_id)
      |> where(
        [binding, group],
        binding.provider == ^provider and binding.external_id == ^external_id and
          group.kind == :static
      )
      |> select([binding, _group], binding.group_id)
      |> repo.all()
    else
      {:error, _reason} -> []
    end
  end

  def ensure_can_disable_principal(principal_uid, repo, admin_group_name) do
    with {:ok, principal_uid} <- Principals.normalize_uid(principal_uid),
         {:ok, principal} <- fetch_principal_for_update(repo, principal_uid) do
      case principal do
        %Principal{type: :human, status: :active} ->
          ensure_disabling_keeps_active_human_admin(repo, principal.uid, admin_group_name)

        %Principal{} ->
          :ok
      end
    end
  end

  def insert_membership(repo, group_id, principal_uid) do
    %Membership{}
    |> Membership.changeset(%{group_id: group_id, principal_uid: principal_uid})
    |> repo.insert(on_conflict: :nothing, conflict_target: [:principal_uid, :group_id])
  end

  def ensure_principal_exists(repo, principal_uid) do
    case repo.get(Principal, principal_uid) do
      %Principal{} -> :ok
      nil -> {:error, :principal_not_found}
    end
  end

  def fetch_principal(repo, principal_uid) do
    case repo.get(Principal, principal_uid) do
      %Principal{} = principal -> {:ok, principal}
      nil -> {:error, :not_found}
    end
  end

  def fetch_principal_for_update(repo, principal_uid) do
    with {:ok, normalized_uid} <- Principals.normalize_uid(principal_uid) do
      case repo.one(
             from principal in Principal,
               where: principal.uid == ^normalized_uid,
               lock: "FOR UPDATE"
           ) do
        %Principal{} = principal -> {:ok, principal}
        nil -> {:error, :not_found}
      end
    end
  end

  def ensure_active_human(%Principal{type: :human, status: :active}), do: :ok
  def ensure_active_human(%Principal{type: :agent}), do: {:error, :not_human}
  def ensure_active_human(%Principal{status: :disabled}), do: {:error, :principal_disabled}

  def fetch_group(repo, id_or_name) when is_binary(id_or_name) do
    case fetch_group_by_id_or_name(repo, id_or_name) do
      %Group{} = group -> {:ok, group}
      nil -> {:error, :not_found}
    end
  end

  def fetch_group(_repo, _id_or_name), do: {:error, :not_found}

  def fetch_group_for_update(repo, id_or_name) when is_binary(id_or_name) do
    case repo.one(group_by_id_or_name_query(id_or_name, lock: "FOR UPDATE")) do
      %Group{} = group -> {:ok, group}
      nil -> {:error, :not_found}
    end
  end

  def fetch_group_for_update(_repo, _id_or_name), do: {:error, :not_found}

  def fetch_group_by_id_or_name(repo, id_or_name) do
    repo.one(group_by_id_or_name_query(id_or_name))
  end

  def fetch_group_by_name(repo, name) do
    repo.one(from group in Group, where: group.name == ^name)
  end

  def lock_built_in_admin_group_for_update(repo, admin_group_name) do
    repo.one(
      from group in Group,
        where: group.name == ^admin_group_name and group.built_in == true,
        lock: "FOR UPDATE"
    )
  end

  def lock_group(repo, group_id) do
    case repo.one(from group in Group, where: group.id == ^group_id, lock: "FOR UPDATE") do
      %Group{} = group -> {:ok, group}
      nil -> {:error, :not_found}
    end
  end

  def ensure_static_group(%Group{kind: :static}), do: :ok
  def ensure_static_group(%Group{kind: :computed}), do: {:error, :computed_group}

  def ensure_operator_group(%Group{built_in: false}), do: :ok
  def ensure_operator_group(%Group{built_in: true}), do: {:error, :built_in_group}

  def ensure_group_has_no_grants(repo, group_id) do
    case repo.exists?(from grant in Grant, where: grant.group_id == ^group_id) do
      true -> {:error, :group_has_grants}
      false -> :ok
    end
  end

  defp binding_attrs(repo, attrs) do
    attrs = Input.binding_attrs(attrs)

    with {:ok, attrs} <- resolve_group_name(repo, attrs),
         :ok <- ensure_binding_static_group(repo, attrs) do
      {:ok, attrs}
    end
  end

  defp resolve_group_name(repo, attrs) do
    case Input.fetch_attr(attrs, :group_name) do
      {:ok, group_name} ->
        with {:ok, group} <- fetch_group(repo, group_name) do
          {:ok, attrs |> Map.delete(:group_name) |> Map.put(:group_id, group.id)}
        end

      :error ->
        {:ok, attrs}
    end
  end

  defp ensure_binding_static_group(repo, attrs) do
    case Input.fetch_attr(attrs, :group_id) do
      {:ok, group_id} ->
        with {:ok, group} <- fetch_group(repo, group_id) do
          ensure_static_group(group)
        end

      :error ->
        :ok
    end
  end

  defp remove_membership(
         repo,
         principal_uid,
         %Group{name: group_name, built_in: true} = group,
         admin_group_name
       )
       when group_name == admin_group_name do
    with {:ok, principal} <- fetch_principal_for_update(repo, principal_uid),
         {:ok, locked_group} <- lock_group(repo, group.id),
         :ok <- ensure_membership_exists_for_update(repo, principal.uid, locked_group.id),
         :ok <- ensure_not_last_admin_member(repo, locked_group.id, principal.uid),
         :ok <- ensure_removing_keeps_active_human_admin(repo, locked_group.id, principal) do
      delete_membership(repo, principal.uid, locked_group.id)
    end
  end

  defp remove_membership(repo, principal_uid, %Group{} = group, _admin_group_name) do
    delete_membership(repo, principal_uid, group.id)
  end

  defp ensure_disabling_keeps_active_human_admin(repo, principal_uid, admin_group_name) do
    case lock_built_in_admin_group_for_update(repo, admin_group_name) do
      %Group{} = admin_group ->
        case lock_membership_for_update(repo, principal_uid, admin_group.id) do
          %Membership{} -> ensure_not_last_active_human_admin(repo, admin_group.id, principal_uid)
          nil -> :ok
        end

      nil ->
        :ok
    end
  end

  defp ensure_membership_exists_for_update(repo, principal_uid, group_id) do
    case lock_membership_for_update(repo, principal_uid, group_id) do
      %Membership{} -> :ok
      nil -> {:error, :not_found}
    end
  end

  defp ensure_not_last_admin_member(repo, group_id, principal_uid) do
    case locked_admin_member_count_excluding(repo, group_id, principal_uid) do
      0 -> {:error, :last_admin_member}
      _count -> :ok
    end
  end

  defp ensure_not_last_active_human_admin(repo, group_id, principal_uid) do
    case active_human_admin_count_excluding(repo, group_id, principal_uid) do
      0 -> {:error, :last_active_human_admin}
      _count -> :ok
    end
  end

  defp ensure_removing_keeps_active_human_admin(
         repo,
         group_id,
         %Principal{type: :human, status: :active} = principal
       ) do
    ensure_not_last_active_human_admin(repo, group_id, principal.uid)
  end

  defp ensure_removing_keeps_active_human_admin(_repo, _group_id, %Principal{}), do: :ok

  defp active_human_admin_count_excluding(repo, group_id, principal_uid) do
    Membership
    |> join(:inner, [membership], principal in Principal,
      on: principal.uid == membership.principal_uid
    )
    |> where(
      [membership, principal],
      membership.group_id == ^group_id and membership.principal_uid != ^principal_uid and
        principal.type == :human and principal.status == :active
    )
    |> lock("FOR UPDATE")
    |> select([_membership, principal], principal.uid)
    |> repo.all()
    |> length()
  end

  defp locked_admin_member_count_excluding(repo, group_id, principal_uid) do
    Membership
    |> where(
      [membership],
      membership.group_id == ^group_id and membership.principal_uid != ^principal_uid
    )
    |> lock("FOR UPDATE")
    |> select([membership], membership.principal_uid)
    |> repo.all()
    |> length()
  end

  defp lock_membership_for_update(repo, principal_uid, group_id) do
    repo.one(
      from membership in Membership,
        where: membership.principal_uid == ^principal_uid and membership.group_id == ^group_id,
        lock: "FOR UPDATE"
    )
  end

  defp delete_membership(repo, principal_uid, group_id) do
    {count, _rows} =
      repo.delete_all(
        from membership in Membership,
          where: membership.group_id == ^group_id and membership.principal_uid == ^principal_uid
      )

    case count do
      0 -> {:error, :not_found}
      _count -> {:ok, :deleted}
    end
  end

  defp group_by_id_or_name_query(id_or_name, opts \\ []) do
    lock_clause = Keyword.get(opts, :lock)
    name = id_or_name |> String.trim() |> String.downcase()

    query =
      case Ecto.UUID.cast(id_or_name) do
        {:ok, uuid} -> where(Group, [group], group.id == ^uuid or group.name == ^name)
        :error -> where(Group, [group], group.name == ^name)
      end

    maybe_lock(query, lock_clause)
  end

  defp maybe_lock(query, nil), do: query
  defp maybe_lock(query, "FOR UPDATE"), do: lock(query, "FOR UPDATE")
end
