defmodule BullX.AuthZ do
  @moduledoc """
  Principal-centered authorization boundary.

  AuthZ consumes existing active Principals, static Principal groups, computed
  Principal groups, and permission grants. It does not create, authenticate,
  activate, or bind Principals.
  """

  import Ecto.Query

  alias BullX.AuthZ.CEL
  alias BullX.AuthZ.PermissionGrant
  alias BullX.AuthZ.PrincipalGroup
  alias BullX.AuthZ.PrincipalGroupMembership
  alias BullX.AuthZ.Request
  alias BullX.Principals.Principal
  alias BullX.Repo

  require Logger

  @admin_group_name "admin"
  @all_humans_group_name "all_humans"
  @all_humans_condition ~s(principal.type == "human" && principal.status == "active")

  @type authz_error :: :forbidden | :not_found | :principal_disabled | :invalid_request

  @spec authorize(Principal.t() | String.t(), String.t(), String.t()) ::
          :ok | {:error, authz_error()}
  def authorize(principal, resource, action), do: authorize(principal, resource, action, %{})

  @spec authorize(Principal.t() | String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, authz_error()}
  def authorize(principal, resource, action, context) do
    with {:ok, request} <- Request.build(principal, resource, action, context),
         {:ok, principal} <- load_active_principal(request.principal_uid) do
      request
      |> Request.with_principal(principal)
      |> authorize_request()
    end
  end

  @spec authorize_permission(Principal.t() | String.t(), String.t()) ::
          :ok | {:error, authz_error()}
  def authorize_permission(principal, permission_key),
    do: authorize_permission(principal, permission_key, %{})

  @spec authorize_permission(Principal.t() | String.t(), String.t(), map()) ::
          :ok | {:error, authz_error()}
  def authorize_permission(principal, permission_key, context) do
    with {:ok, resource, action} <- Request.split_permission_key(permission_key) do
      authorize(principal, resource, action, context)
    end
  end

  @spec allowed?(Principal.t() | String.t(), String.t(), String.t()) :: boolean()
  def allowed?(principal, resource, action), do: allowed?(principal, resource, action, %{})

  @spec allowed?(Principal.t() | String.t(), String.t(), String.t(), map()) :: boolean()
  def allowed?(principal, resource, action, context) do
    case authorize(principal, resource, action, context) do
      :ok -> true
      _error -> false
    end
  end

  @spec list_principal_groups(Principal.t() | String.t()) ::
          {:ok, [PrincipalGroup.t()]} | {:error, :not_found | :invalid_request}
  def list_principal_groups(principal_or_uid) do
    with {:ok, principal} <- fetch_principal(principal_or_uid, :invalid_request) do
      {:ok, list_effective_principal_groups(principal)}
    end
  end

  @spec create_principal_group(map()) ::
          {:ok, PrincipalGroup.t()} | {:error, Ecto.Changeset.t()}
  def create_principal_group(attrs) do
    %PrincipalGroup{}
    |> PrincipalGroup.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec update_principal_group(PrincipalGroup.t() | Ecto.UUID.t(), map()) ::
          {:ok, PrincipalGroup.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def update_principal_group(%PrincipalGroup{} = group, attrs) do
    group
    |> PrincipalGroup.update_changeset(attrs)
    |> Repo.update()
  end

  def update_principal_group(id, attrs) when is_binary(id) do
    with {:ok, group} <- fetch_group(id) do
      update_principal_group(group, attrs)
    end
  end

  def update_principal_group(_group, _attrs), do: {:error, :not_found}

  @spec delete_principal_group(PrincipalGroup.t() | Ecto.UUID.t()) ::
          :ok | {:error, :not_found | :built_in_group | :group_has_grants}
  def delete_principal_group(%PrincipalGroup{built_in: true}), do: {:error, :built_in_group}

  def delete_principal_group(%PrincipalGroup{} = group) do
    case group_has_grants?(group) do
      true ->
        {:error, :group_has_grants}

      false ->
        Repo.delete!(group)
        :ok
    end
  end

  def delete_principal_group(id) when is_binary(id) do
    with {:ok, group} <- fetch_group(id) do
      delete_principal_group(group)
    end
  end

  def delete_principal_group(_group), do: {:error, :not_found}

  @spec add_principal_to_group(Principal.t() | String.t(), PrincipalGroup.t() | Ecto.UUID.t()) ::
          :ok | {:error, :not_found | :invalid_request | :computed_group}
  def add_principal_to_group(principal_or_uid, group_or_id) do
    with {:ok, principal} <- fetch_principal(principal_or_uid, :invalid_request),
         {:ok, group} <- fetch_group(group_or_id),
         :ok <- ensure_static_membership_group(group) do
      attrs = %{principal_uid: principal.uid, group_id: group.id}

      %PrincipalGroupMembership{}
      |> PrincipalGroupMembership.changeset(attrs)
      |> Repo.insert(on_conflict: :nothing)
      |> case do
        {:ok, _membership} -> :ok
        {:error, _changeset} -> {:error, :not_found}
      end
    end
  end

  @spec remove_principal_from_group(
          Principal.t() | String.t(),
          PrincipalGroup.t() | Ecto.UUID.t()
        ) ::
          :ok
          | {:error, :not_found | :last_admin_member | :last_active_human_admin | :computed_group}
  def remove_principal_from_group(principal_or_uid, group_or_id) do
    with {:ok, principal} <- fetch_principal(principal_or_uid, :not_found),
         {:ok, group} <- fetch_group(group_or_id),
         :ok <- ensure_static_membership_group(group) do
      remove_membership(principal, group)
    end
  end

  @spec create_permission_grant(map()) ::
          {:ok, PermissionGrant.t()} | {:error, Ecto.Changeset.t()}
  def create_permission_grant(attrs) do
    %PermissionGrant{}
    |> PermissionGrant.changeset(attrs)
    |> Repo.insert()
  end

  @spec upsert_permission_grant(map()) ::
          {:ok, PermissionGrant.t()} | {:error, Ecto.Changeset.t()}
  def upsert_permission_grant(attrs) do
    changeset = PermissionGrant.changeset(%PermissionGrant{}, attrs)

    with {:ok, grant} <- Ecto.Changeset.apply_action(changeset, :insert) do
      Repo.insert(changeset,
        on_conflict: permission_grant_upsert_update(grant),
        conflict_target: permission_grant_upsert_target(grant),
        returning: true
      )
    end
  end

  @spec update_permission_grant(PermissionGrant.t() | Ecto.UUID.t(), map()) ::
          {:ok, PermissionGrant.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def update_permission_grant(%PermissionGrant{} = grant, attrs) do
    grant
    |> PermissionGrant.changeset(attrs)
    |> Repo.update()
  end

  def update_permission_grant(id, attrs) when is_binary(id) do
    with {:ok, grant} <- fetch_grant(id) do
      update_permission_grant(grant, attrs)
    end
  end

  def update_permission_grant(_grant, _attrs), do: {:error, :not_found}

  @spec delete_permission_grant(PermissionGrant.t() | Ecto.UUID.t()) ::
          :ok | {:error, :not_found}
  def delete_permission_grant(%PermissionGrant{} = grant) do
    Repo.delete!(grant)
    :ok
  end

  def delete_permission_grant(id) when is_binary(id) do
    with {:ok, grant} <- fetch_grant(id) do
      delete_permission_grant(grant)
    end
  end

  def delete_permission_grant(_grant), do: {:error, :not_found}

  @spec ensure_can_disable_principal(Principal.t() | String.t()) ::
          :ok | {:error, :not_found | :invalid_request | :last_active_human_admin}
  def ensure_can_disable_principal(principal_or_uid) do
    transaction(fn ->
      with {:ok, principal} <- fetch_principal_for_update(principal_or_uid, :invalid_request) do
        ensure_can_disable_loaded_principal(principal)
      end
    end)
  end

  @doc false
  @spec root_initialized?() :: boolean()
  def root_initialized? do
    storage_ready?() and built_in_group_exists?(@admin_group_name) and
      built_in_group_exists?(@all_humans_group_name)
  end

  @doc false
  @spec ensure_root_init_open() :: :ok | {:error, :root_init_closed}
  def ensure_root_init_open do
    case admin_member_exists?() do
      true -> {:error, :root_init_closed}
      false -> :ok
    end
  end

  @doc false
  @spec root_init_admin(Principal.t() | String.t()) :: :ok | {:error, term()}
  def root_init_admin(principal_or_uid) do
    transaction(fn ->
      with {:ok, principal} <- fetch_principal_for_update(principal_or_uid, :not_found),
           :ok <- ensure_root_init_human(principal),
           {:ok, _all_humans, _all_humans_status} <- ensure_built_in_all_humans_group(),
           {:ok, group, _status} <- ensure_built_in_admin_group(),
           %PrincipalGroup{} = group <- lock_group_for_update(group.id),
           :ok <- ensure_root_init_open_for_group(group) do
        insert_membership(principal.uid, group.id)
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc false
  @spec ensure_built_in_admin_group() ::
          {:ok, PrincipalGroup.t(), :created | :existing}
          | {:error, {:conflicting_admin_group, PrincipalGroup.t()}}
          | {:error, Ecto.Changeset.t()}
  def ensure_built_in_admin_group do
    ensure_built_in_group(
      %{
        name: @admin_group_name,
        kind: :static,
        description: "Built-in administrators group.",
        built_in: true
      },
      :conflicting_admin_group
    )
  end

  @doc false
  @spec ensure_built_in_all_humans_group() ::
          {:ok, PrincipalGroup.t(), :created | :existing}
          | {:error, {:conflicting_all_humans_group, PrincipalGroup.t()}}
          | {:error, Ecto.Changeset.t()}
  def ensure_built_in_all_humans_group do
    ensure_built_in_group(
      %{
        name: @all_humans_group_name,
        kind: :computed,
        description: "Built-in computed group for all active Human Principals.",
        computed_condition: @all_humans_condition,
        built_in: true
      },
      :conflicting_all_humans_group
    )
  end

  defp storage_ready? do
    query = """
    SELECT
      EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = current_schema() AND table_name = 'principal_groups'
      ),
      EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = current_schema() AND table_name = 'principal_group_memberships'
      ),
      EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = current_schema() AND table_name = 'permission_grants'
      ),
      EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = current_schema() AND table_name = 'principals'
      )
    """

    case Ecto.Adapters.SQL.query(Repo, query, []) do
      {:ok, %{rows: [row]}} -> Enum.all?(row)
      {:error, reason} -> log_table_check_error(reason)
    end
  end

  defp authorize_request(%Request{principal: %Principal{} = principal} = request) do
    group_ids = effective_principal_group_ids(principal)
    grants = list_candidate_grants(request.principal_uid, group_ids, request.action)

    case any_loaded_grant_allows?(grants, request) do
      true -> :ok
      false -> {:error, :forbidden}
    end
  end

  defp any_loaded_grant_allows?(grants, request) do
    loaded_grants = Enum.map(grants, &loaded_grant/1)

    case CEL.evaluate_grants(cel_env(request), loaded_grants) do
      {:allow, invalid_grants} ->
        emit_invalid_persisted_data(invalid_grants, grants)
        true

      {:deny, invalid_grants} ->
        emit_invalid_persisted_data(invalid_grants, grants)
        false

      {:error, _reason} ->
        false
    end
  end

  defp loaded_grant(%PermissionGrant{} = grant) do
    %CEL.LoadedGrant{
      id: grant.id,
      resource_pattern: grant.resource_pattern,
      condition: grant.condition
    }
  end

  defp cel_env(%Request{principal: %Principal{} = principal} = request) do
    %CEL.Env{
      principal: %{
        "uid" => principal.uid,
        "type" => Atom.to_string(principal.type),
        "status" => Atom.to_string(principal.status)
      },
      action: request.action,
      resource: request.resource,
      context: %{"request" => request.context}
    }
  end

  defp principal_env(%Principal{} = principal) do
    %CEL.PrincipalEnv{
      principal: %{
        "uid" => principal.uid,
        "type" => Atom.to_string(principal.type),
        "status" => Atom.to_string(principal.status)
      }
    }
  end

  defp emit_invalid_persisted_data(invalid_grants, grants) do
    grants_by_id = Map.new(grants, &{&1.id, &1})

    invalid_grants
    |> Enum.filter(&persisted_data_diagnostic?/1)
    |> Enum.each(fn %CEL.InvalidGrant{} = invalid_grant ->
      grant = Map.fetch!(grants_by_id, invalid_grant.id)

      Logger.error(
        "BullX.AuthZ invalid persisted grant grant_id=#{inspect(invalid_grant.id)} kind=#{inspect(invalid_grant.kind)} reason=#{inspect(invalid_grant.reason)}"
      )

      :telemetry.execute(
        [:bullx, :authz, :invalid_persisted_data],
        %{count: 1},
        %{
          kind: invalid_grant.kind,
          id: grant.id,
          action: grant.action,
          resource_pattern: grant.resource_pattern,
          reason: invalid_grant.reason
        }
      )
    end)
  end

  defp emit_invalid_persisted_computed_groups(invalid_groups) do
    Enum.each(invalid_groups, fn %CEL.InvalidComputedGroup{} = invalid_group ->
      Logger.error(
        "BullX.AuthZ invalid persisted computed_group group_id=#{inspect(invalid_group.id)} kind=#{inspect(invalid_group.kind)} reason=#{inspect(invalid_group.reason)}"
      )

      :telemetry.execute(
        [:bullx, :authz, :invalid_persisted_data],
        %{count: 1},
        %{
          kind: computed_group_diagnostic_kind(invalid_group.kind),
          id: invalid_group.id,
          action: nil,
          resource_pattern: nil,
          reason: invalid_group.reason
        }
      )
    end)
  end

  defp persisted_data_diagnostic?(%CEL.InvalidGrant{kind: :resource_pattern}), do: true
  defp persisted_data_diagnostic?(%CEL.InvalidGrant{kind: :condition_compile}), do: true
  defp persisted_data_diagnostic?(%CEL.InvalidGrant{kind: :condition_result_type}), do: true
  defp persisted_data_diagnostic?(%CEL.InvalidGrant{}), do: false

  defp computed_group_diagnostic_kind(:condition_compile),
    do: :computed_group_condition_compile

  defp computed_group_diagnostic_kind(:condition_execution),
    do: :computed_group_condition_execution

  defp computed_group_diagnostic_kind(:condition_result_type),
    do: :computed_group_condition_result_type

  defp list_effective_principal_groups(%Principal{} = principal) do
    (static_principal_groups(principal) ++ computed_principal_groups(principal))
    |> Enum.sort_by(& &1.name)
  end

  defp effective_principal_group_ids(%Principal{} = principal) do
    principal
    |> list_effective_principal_groups()
    |> Enum.map(& &1.id)
  end

  defp static_principal_groups(%Principal{uid: principal_uid}) do
    Repo.all(
      from membership in PrincipalGroupMembership,
        join: group in assoc(membership, :group),
        where: membership.principal_uid == ^principal_uid,
        where: group.kind == :static,
        select: group
    )
  end

  defp computed_principal_groups(%Principal{} = principal) do
    groups = Repo.all(from group in PrincipalGroup, where: group.kind == :computed)
    loaded_groups = Enum.map(groups, &loaded_computed_group/1)

    case CEL.evaluate_computed_groups(principal_env(principal), loaded_groups) do
      {:ok, group_ids, invalid_groups} ->
        emit_invalid_persisted_computed_groups(invalid_groups)

        groups_by_id = Map.new(groups, &{&1.id, &1})
        Enum.map(group_ids, &Map.fetch!(groups_by_id, &1))

      {:error, _reason} ->
        []
    end
  end

  defp loaded_computed_group(%PrincipalGroup{} = group) do
    %CEL.LoadedComputedGroup{
      id: group.id,
      condition: group.computed_condition
    }
  end

  defp list_candidate_grants(principal_uid, group_ids, action) do
    Repo.all(
      from grant in PermissionGrant,
        where:
          grant.action == ^action and
            (grant.principal_uid == ^principal_uid or grant.group_id in ^group_ids)
    )
  end

  defp permission_grant_upsert_update(%PermissionGrant{} = grant) do
    [
      set: [
        description: grant.description,
        metadata: grant.metadata,
        updated_at: DateTime.utc_now(:microsecond)
      ]
    ]
  end

  defp permission_grant_upsert_target(%PermissionGrant{principal_uid: principal_uid})
       when is_binary(principal_uid) do
    {:unsafe_fragment,
     "(principal_uid, resource_pattern, action, condition) WHERE principal_uid IS NOT NULL"}
  end

  defp permission_grant_upsert_target(%PermissionGrant{group_id: group_id})
       when is_binary(group_id) do
    {:unsafe_fragment,
     "(group_id, resource_pattern, action, condition) WHERE group_id IS NOT NULL"}
  end

  defp load_active_principal(principal_uid) do
    case Repo.get_by(Principal, uid: principal_uid) do
      nil -> {:error, :not_found}
      %Principal{status: :active} = principal -> {:ok, principal}
      %Principal{status: :disabled} -> {:error, :principal_disabled}
    end
  end

  defp fetch_principal(%Principal{uid: uid}, invalid_error),
    do: fetch_principal(uid, invalid_error)

  defp fetch_principal(uid, _invalid_error) when is_binary(uid) do
    case Repo.get_by(Principal, uid: uid) do
      nil -> {:error, :not_found}
      principal -> {:ok, principal}
    end
  end

  defp fetch_principal(_principal, invalid_error), do: {:error, invalid_error}

  defp fetch_group(%PrincipalGroup{} = group), do: {:ok, group}

  defp fetch_group(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(PrincipalGroup, uuid) do
          nil -> {:error, :not_found}
          group -> {:ok, group}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp fetch_group(_group), do: {:error, :not_found}

  defp fetch_grant(%PermissionGrant{} = grant), do: {:ok, grant}

  defp fetch_grant(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(PermissionGrant, uuid) do
          nil -> {:error, :not_found}
          grant -> {:ok, grant}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp fetch_grant(_grant), do: {:error, :not_found}

  defp ensure_static_membership_group(%PrincipalGroup{kind: :computed}),
    do: {:error, :computed_group}

  defp ensure_static_membership_group(%PrincipalGroup{}), do: :ok

  defp group_has_grants?(%PrincipalGroup{id: group_id}) do
    Repo.exists?(from grant in PermissionGrant, where: grant.group_id == ^group_id, select: 1)
  end

  defp remove_membership(%Principal{} = principal, %PrincipalGroup{
         id: group_id,
         built_in: true,
         name: @admin_group_name
       }) do
    transaction(fn ->
      case lock_principal_for_update(principal.uid) do
        nil ->
          {:error, :not_found}

        locked_principal ->
          case lock_group_for_update(group_id) do
            nil ->
              {:error, :not_found}

            group ->
              with :ok <- ensure_membership_exists_for_update(locked_principal.uid, group.id),
                   :ok <- ensure_not_last_admin_member(group, locked_principal.uid),
                   :ok <- ensure_not_last_active_human_admin(group, locked_principal.uid) do
                delete_membership(locked_principal.uid, group.id)
              end
          end
      end
    end)
  end

  defp remove_membership(%Principal{} = principal, %PrincipalGroup{} = group) do
    delete_membership(principal.uid, group.id)
  end

  defp ensure_can_disable_loaded_principal(%Principal{status: :disabled}), do: :ok
  defp ensure_can_disable_loaded_principal(%Principal{type: :agent}), do: :ok

  defp ensure_can_disable_loaded_principal(%Principal{type: :human, uid: principal_uid}) do
    case lock_admin_group_for_update() do
      nil ->
        :ok

      group ->
        case lock_membership_for_update(principal_uid, group.id) do
          %PrincipalGroupMembership{} -> ensure_not_last_active_human_admin(group, principal_uid)
          nil -> :ok
        end
    end
  end

  defp fetch_principal_for_update(%Principal{uid: uid}, invalid_error),
    do: fetch_principal_for_update(uid, invalid_error)

  defp fetch_principal_for_update(uid, _invalid_error) when is_binary(uid) do
    case lock_principal_for_update(uid) do
      nil -> {:error, :not_found}
      principal -> {:ok, principal}
    end
  end

  defp fetch_principal_for_update(_principal, invalid_error), do: {:error, invalid_error}

  defp lock_principal_for_update(principal_uid) do
    Repo.one(
      from principal in Principal, where: principal.uid == ^principal_uid, lock: "FOR UPDATE"
    )
  end

  defp lock_group_for_update(group_id) do
    Repo.one(from group in PrincipalGroup, where: group.id == ^group_id, lock: "FOR UPDATE")
  end

  defp lock_admin_group_for_update do
    Repo.one(
      from group in PrincipalGroup,
        where: group.name == ^@admin_group_name and group.built_in == true,
        lock: "FOR UPDATE"
    )
  end

  defp ensure_membership_exists_for_update(principal_uid, group_id) do
    case lock_membership_for_update(principal_uid, group_id) do
      %PrincipalGroupMembership{} -> :ok
      nil -> {:error, :not_found}
    end
  end

  defp ensure_not_last_admin_member(%PrincipalGroup{id: group_id}, principal_uid) do
    remaining = locked_admin_member_count_excluding(group_id, principal_uid)

    case remaining do
      0 -> {:error, :last_admin_member}
      _count -> :ok
    end
  end

  defp ensure_not_last_active_human_admin(%PrincipalGroup{id: group_id}, principal_uid) do
    remaining = active_human_admin_count_excluding(group_id, principal_uid)

    case remaining do
      0 -> {:error, :last_active_human_admin}
      _count -> :ok
    end
  end

  defp active_human_admin_count_excluding(group_id, principal_uid) do
    Repo.all(
      from(membership in PrincipalGroupMembership,
        join: principal in Principal,
        on: principal.uid == membership.principal_uid,
        where:
          membership.group_id == ^group_id and membership.principal_uid != ^principal_uid and
            principal.type == :human and principal.status == :active,
        lock: "FOR UPDATE",
        select: principal.uid
      )
    )
    |> length()
  end

  defp locked_admin_member_count_excluding(group_id, principal_uid) do
    Repo.all(
      from membership in PrincipalGroupMembership,
        where: membership.group_id == ^group_id and membership.principal_uid != ^principal_uid,
        lock: "FOR UPDATE",
        select: membership.principal_uid
    )
    |> length()
  end

  defp lock_membership_for_update(principal_uid, group_id) do
    Repo.one(
      from membership in PrincipalGroupMembership,
        where: membership.principal_uid == ^principal_uid and membership.group_id == ^group_id,
        lock: "FOR UPDATE"
    )
  end

  defp delete_membership(principal_uid, group_id) do
    {count, _rows} =
      Repo.delete_all(
        from membership in PrincipalGroupMembership,
          where: membership.principal_uid == ^principal_uid and membership.group_id == ^group_id
      )

    case count do
      0 -> {:error, :not_found}
      _count -> :ok
    end
  end

  defp insert_membership(principal_uid, group_id) do
    %{principal_uid: principal_uid, group_id: group_id}
    |> then(&PrincipalGroupMembership.changeset(%PrincipalGroupMembership{}, &1))
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, _membership} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp ensure_root_init_human(%Principal{type: :human, status: :active}), do: :ok

  defp ensure_root_init_human(%Principal{type: :human, status: :disabled}),
    do: {:error, :principal_disabled}

  defp ensure_root_init_human(%Principal{}), do: {:error, :not_human}

  defp ensure_root_init_open_for_group(%PrincipalGroup{} = group) do
    case admin_member_exists?(group.id) do
      true -> {:error, :root_init_closed}
      false -> :ok
    end
  end

  defp admin_member_exists? do
    case Repo.get_by(PrincipalGroup, name: @admin_group_name) do
      %PrincipalGroup{id: group_id} -> admin_member_exists?(group_id)
      nil -> false
    end
  end

  defp admin_member_exists?(group_id) when is_binary(group_id) do
    Repo.exists?(
      from membership in PrincipalGroupMembership,
        where: membership.group_id == ^group_id,
        select: 1
    )
  end

  defp built_in_group_exists?(name) do
    Repo.exists?(
      from group in PrincipalGroup,
        where: group.name == ^name and group.built_in == true,
        select: 1
    )
  end

  defp ensure_built_in_group(%{name: name, kind: kind} = attrs, conflict_tag) do
    case Repo.get_by(PrincipalGroup, name: name) do
      nil ->
        create_built_in_group(attrs, conflict_tag)

      %PrincipalGroup{built_in: true, kind: ^kind} = group ->
        case built_in_group_matches?(group, attrs) do
          true -> {:ok, group, :existing}
          false -> {:error, {conflict_tag, group}}
        end

      %PrincipalGroup{} = group ->
        {:error, {conflict_tag, group}}
    end
  end

  defp create_built_in_group(attrs, conflict_tag) do
    %PrincipalGroup{}
    |> PrincipalGroup.system_create_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, group} ->
        {:ok, group, :created}

      {:error, changeset} ->
        built_in_group_insert_error(changeset, attrs, conflict_tag)
    end
  end

  defp built_in_group_matches?(%PrincipalGroup{kind: :static, computed_condition: nil}, %{
         kind: :static
       }),
       do: true

  defp built_in_group_matches?(%PrincipalGroup{kind: :computed} = group, %{
         kind: :computed,
         computed_condition: condition
       }),
       do: group.computed_condition == condition

  defp built_in_group_matches?(%PrincipalGroup{}, _attrs), do: false

  defp built_in_group_insert_error(%Ecto.Changeset{} = changeset, attrs, conflict_tag) do
    case unique_conflict?(changeset, :name) do
      true -> ensure_built_in_group(attrs, conflict_tag)
      false -> {:error, changeset}
    end
  end

  defp unique_conflict?(%Ecto.Changeset{} = changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      {_other_field, _error} -> false
    end)
  end

  defp log_table_check_error(reason) do
    Logger.warning("BullX.AuthZ table check failed: #{inspect(reason)}")
    false
  end

  defp transaction(fun) when is_function(fun, 0) do
    case Repo.transaction(fn ->
           case fun.() do
             {:error, reason} -> Repo.rollback(reason)
             other -> other
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
