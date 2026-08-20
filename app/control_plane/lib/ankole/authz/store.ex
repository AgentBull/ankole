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

  @max_external_directory_ancestor_depth 100

  def delete_operator_group(repo, id_or_name) do
    with {:ok, group} <- fetch_group_for_update(repo, id_or_name),
         :ok <- ensure_operator_group(group),
         :ok <- ensure_group_has_no_grants(repo, group.id) do
      repo.delete(group)
    end
  end

  def add_principal_to_group(repo, principal_uid, group_id_or_name, admin_group_name) do
    with {:ok, group} <- fetch_group_for_update(repo, group_id_or_name),
         :ok <- ensure_static_group(group),
         :ok <- ensure_operator_domain(group),
         {:ok, principal} <- fetch_principal_for_update(repo, principal_uid),
         :ok <- ensure_group_accepts_principal(group, principal, admin_group_name) do
      insert_membership(repo, group.id, principal.uid)
    end
  end

  def remove_principal_from_group(repo, principal_uid, group_id_or_name, admin_group_name) do
    with {:ok, group} <- fetch_group(repo, group_id_or_name),
         :ok <- ensure_static_group(group),
         :ok <- ensure_operator_domain(group),
         {:ok, principal_uid} <- Principals.normalize_uid(principal_uid) do
      remove_membership(repo, principal_uid, group, admin_group_name)
    end
  end

  def add_synced_group_member(repo, group_id, expected_domain, principal_uid)
      when expected_domain in [:directory, :im_group, :signal_source] do
    with {:ok, group} <- lock_group(repo, group_id),
         :ok <- ensure_static_group(group),
         :ok <- ensure_group_domain(group, expected_domain),
         {:ok, principal} <- fetch_principal_for_update(repo, principal_uid) do
      insert_membership(repo, group.id, principal.uid)
    end
  end

  def remove_synced_group_member(repo, group_id, expected_domain, principal_uid)
      when expected_domain in [:directory, :im_group, :signal_source] do
    with {:ok, group} <- lock_group(repo, group_id),
         :ok <- ensure_static_group(group),
         :ok <- ensure_group_domain(group, expected_domain),
         {:ok, principal_uid} <- Principals.normalize_uid(principal_uid) do
      delete_membership(repo, principal_uid, group.id)
    end
  end

  def upsert_external_binding(repo, attrs) do
    with {:ok, attrs} <- binding_attrs(repo, attrs) do
      %ExternalBinding{}
      |> ExternalBinding.changeset(attrs)
      |> repo.insert(
        conflict_target: [:provider, :external_kind, :external_id],
        on_conflict: {:replace, [:group_id, :metadata, :updated_at]},
        returning: true
      )
    end
  end

  def external_group_ids(repo, provider, external_kind, external_id) do
    with {:ok, provider} <- Input.normalize_provider(provider),
         {:ok, external_kind} <- normalize_external_kind(external_kind),
         expected_domain <- external_kind_domain(external_kind),
         {:ok, external_id} <- Input.normalize_required_text(external_id) do
      ExternalBinding
      |> join(:inner, [binding], group in Group, on: group.id == binding.group_id)
      |> where(
        [binding, group],
        binding.provider == ^provider and binding.external_kind == ^external_kind and
          binding.external_id == ^external_id and group.domain == ^expected_domain and
          group.kind == :static
      )
      |> select([binding, _group], binding.group_id)
      |> repo.all()
    else
      {:error, _reason} -> []
    end
  end

  def replace_static_group_members(repo, group_id, expected_domain, principal_uids)
      when expected_domain in [:directory, :im_group, :signal_source] and is_list(principal_uids) do
    with {:ok, group} <- lock_group(repo, group_id),
         :ok <- ensure_static_group(group),
         :ok <- ensure_group_domain(group, expected_domain),
         {:ok, principal_uids} <- normalize_principal_uids(principal_uids) do
      existing_uids =
        Membership
        |> where([membership], membership.group_id == ^group.id)
        |> select([membership], membership.principal_uid)
        |> repo.all()

      stale_uids = existing_uids -- principal_uids

      with :ok <- insert_group_memberships(repo, group.id, principal_uids) do
        removed_memberships = delete_group_memberships(repo, group.id, stale_uids)

        {:ok,
         %{
           synced_principal_uids: principal_uids,
           removed_memberships: removed_memberships
         }}
      end
    end
  end

  def clear_static_group_members(repo, group_id, expected_domain)
      when expected_domain in [:directory, :im_group, :signal_source] do
    with {:ok, group} <- lock_group(repo, group_id),
         :ok <- ensure_static_group(group),
         :ok <- ensure_group_domain(group, expected_domain) do
      {removed_memberships, _rows} =
        repo.delete_all(from membership in Membership, where: membership.group_id == ^group.id)

      {:ok, %{removed_memberships: removed_memberships}}
    end
  end

  def external_directory_group_index(repo, provider) do
    with {:ok, provider} <- Input.normalize_provider(provider) do
      {:ok, build_external_directory_group_index(repo, provider, "department")}
    end
  end

  def sync_external_directory_group_memberships(
        repo,
        provider,
        principal_uid,
        external_ids,
        opts \\ []
      )
      when is_list(external_ids) and is_list(opts) do
    with {:ok, provider} <- Input.normalize_provider(provider),
         {:ok, external_ids} <- normalize_external_ids(external_ids),
         {:ok, principal} <- fetch_principal_for_update(repo, principal_uid),
         {:ok, directory_index} <- directory_group_index(repo, provider, "department", opts) do
      managed_group_ids = directory_index.managed_group_ids

      desired_group_ids =
        desired_external_directory_group_ids(external_ids, directory_index)

      stale_group_ids = managed_group_ids -- desired_group_ids

      with :ok <- insert_principal_memberships(repo, desired_group_ids, principal.uid) do
        removed_memberships = delete_memberships(repo, principal.uid, stale_group_ids)

        {:ok,
         %{
           synced_group_ids: desired_group_ids,
           removed_memberships: removed_memberships
         }}
      end
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

  # Fetch-or-create for convention-named synced groups. The re-read after an
  # insert conflict is deliberate: the app-side UUIDv7 in the conflicting
  # changeset never matches the winning row.
  def ensure_synced_group(repo, attrs) when is_map(attrs) do
    name = attrs |> Map.fetch!(:name) |> String.downcase()

    case repo.get_by(Group, name: name) do
      %Group{} = group ->
        {:ok, group}

      nil ->
        changeset = Group.changeset(%Group{}, Map.put(attrs, :name, name))

        case repo.insert(changeset, on_conflict: :nothing, conflict_target: [:name]) do
          {:ok, _maybe_stale} ->
            case repo.get_by(Group, name: name) do
              %Group{} = group -> {:ok, group}
              nil -> {:error, :group_not_found}
            end

          {:error, _reason} = error ->
            error
        end
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

  defp ensure_group_accepts_principal(
         %Group{name: group_name, built_in: true},
         %Principal{} = principal,
         admin_group_name
       )
       when group_name == admin_group_name do
    ensure_active_human(principal)
  end

  defp ensure_group_accepts_principal(%Group{}, %Principal{}, _admin_group_name), do: :ok

  def ensure_operator_group(%Group{built_in: false}), do: :ok
  def ensure_operator_group(%Group{built_in: true}), do: {:error, :built_in_group}

  def ensure_operator_domain(%Group{domain: :operator}), do: :ok
  def ensure_operator_domain(%Group{}), do: {:error, :group_domain_mismatch}

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
          with :ok <- ensure_static_group(group) do
            ensure_binding_group_domain(group, attrs)
          end
        end

      :error ->
        :ok
    end
  end

  defp ensure_binding_group_domain(group, attrs) do
    case Input.fetch_attr(attrs, :external_kind) do
      {:ok, :directory_department} -> ensure_group_domain(group, :directory)
      {:ok, "directory_department"} -> ensure_group_domain(group, :directory)
      {:ok, :im_group} -> ensure_group_domain(group, :im_group)
      {:ok, "im_group"} -> ensure_group_domain(group, :im_group)
      {:ok, _kind} -> {:error, :invalid_external_kind}
      :error -> {:error, :missing_external_kind}
    end
  end

  defp ensure_group_domain(%Group{domain: domain}, domain), do: :ok
  defp ensure_group_domain(%Group{}, _domain), do: {:error, :group_domain_mismatch}

  defp normalize_external_kind(kind) when kind in [:directory_department, :im_group],
    do: {:ok, kind}

  defp normalize_external_kind("directory_department"), do: {:ok, :directory_department}
  defp normalize_external_kind("im_group"), do: {:ok, :im_group}
  defp normalize_external_kind(_kind), do: {:error, :invalid_external_kind}

  defp external_kind_domain(:directory_department), do: :directory
  defp external_kind_domain(:im_group), do: :im_group

  defp normalize_external_ids(external_ids) do
    external_ids
    |> Enum.reduce_while({:ok, []}, fn external_id, {:ok, acc} ->
      case Input.normalize_required_text(external_id) do
        {:ok, external_id} -> {:cont, {:ok, [external_id | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, external_ids} ->
        {:ok, external_ids |> Enum.reverse() |> Enum.uniq()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp directory_group_index(repo, provider, kind, opts) do
    case Keyword.get(opts, :directory_group_index) do
      %{provider: ^provider, kind: ^kind} = index -> {:ok, index}
      nil -> {:ok, build_external_directory_group_index(repo, provider, kind)}
      _index -> {:error, :invalid_directory_group_index}
    end
  end

  defp build_external_directory_group_index(repo, provider, kind) do
    bindings_by_external_id =
      directory_group_bindings(repo, provider, kind)
      |> Map.new(fn binding -> {binding.external_id, binding} end)

    %{
      provider: provider,
      kind: kind,
      managed_group_ids:
        bindings_by_external_id
        |> Map.values()
        |> Enum.map(& &1.group_id)
        |> Enum.uniq()
        |> Enum.sort(),
      bindings_by_external_id: bindings_by_external_id
    }
  end

  defp directory_group_bindings(repo, provider, kind) do
    ExternalBinding
    |> join(:inner, [binding], group in Group, on: group.id == binding.group_id)
    |> external_directory_group_scope(provider, kind)
    |> select([binding, group], %{
      external_id: binding.external_id,
      group_id: group.id,
      metadata: binding.metadata
    })
    |> order_by([binding, _group], asc: binding.external_id)
    |> repo.all()
  end

  defp desired_external_directory_group_ids([], _directory_index), do: []

  defp desired_external_directory_group_ids(external_ids, %{
         bindings_by_external_id: bindings_by_external_id
       }) do
    external_ids
    |> Enum.flat_map(&expand_external_directory_ids(&1, bindings_by_external_id))
    |> Enum.map(fn external_id ->
      case Map.get(bindings_by_external_id, external_id) do
        %{group_id: group_id} -> group_id
        nil -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp external_directory_group_scope(queryable, provider, "department") do
    queryable
    |> where(
      [binding, group],
      binding.provider == ^provider and binding.external_kind == :directory_department and
        group.domain == :directory and group.kind == :static and group.built_in == false
    )
  end

  defp insert_group_memberships(repo, group_id, principal_uids) when is_binary(group_id) do
    Enum.reduce_while(principal_uids, :ok, fn principal_uid, :ok ->
      case insert_membership(repo, group_id, principal_uid) do
        {:ok, _membership} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_principal_memberships(repo, group_ids, principal_uid) do
    Enum.reduce_while(group_ids, :ok, fn group_id, :ok ->
      case insert_membership(repo, group_id, principal_uid) do
        {:ok, _membership} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_principal_uids(principal_uids) do
    principal_uids
    |> Enum.reduce_while({:ok, []}, fn principal_uid, {:ok, acc} ->
      case Principals.normalize_uid(principal_uid) do
        {:ok, uid} -> {:cont, {:ok, [uid | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, uids} -> {:ok, uids |> Enum.reverse() |> Enum.uniq() |> Enum.sort()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_group_memberships(_repo, _group_id, []), do: 0

  defp delete_group_memberships(repo, group_id, principal_uids) do
    {count, _rows} =
      repo.delete_all(
        from membership in Membership,
          where: membership.group_id == ^group_id and membership.principal_uid in ^principal_uids
      )

    count
  end

  defp expand_external_directory_ids(external_id, bindings_by_external_id) do
    do_expand_external_directory_ids(
      external_id,
      bindings_by_external_id,
      MapSet.new(),
      [],
      @max_external_directory_ancestor_depth
    )
  end

  defp do_expand_external_directory_ids(nil, _bindings_by_external_id, _visited, acc, _depth),
    do: acc

  defp do_expand_external_directory_ids(_external_id, _bindings_by_external_id, _visited, acc, 0),
    do: acc

  defp do_expand_external_directory_ids(external_id, bindings_by_external_id, visited, acc, depth) do
    case MapSet.member?(visited, external_id) do
      true ->
        acc

      false ->
        binding = Map.get(bindings_by_external_id, external_id)
        visited = MapSet.put(visited, external_id)

        do_expand_external_directory_ids(
          parent_external_id(binding),
          bindings_by_external_id,
          visited,
          [external_id | acc],
          depth - 1
        )
    end
  end

  defp parent_external_id(%{metadata: metadata}) when is_map(metadata) do
    value =
      Map.get(metadata, "parentExternalID") ||
        get_in(metadata, ["external_directory", "parentExternalID"]) ||
        get_in(metadata, ["external_directory", "parent_external_id"])

    normalize_parent_external_id(value)
  end

  defp parent_external_id(_binding), do: nil

  defp normalize_parent_external_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_parent_external_id(_value), do: nil

  defp delete_memberships(_repo, _principal_uid, []), do: 0

  defp delete_memberships(repo, principal_uid, group_ids) do
    {count, _rows} =
      repo.delete_all(
        from membership in Membership,
          where: membership.principal_uid == ^principal_uid and membership.group_id in ^group_ids
      )

    count
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
