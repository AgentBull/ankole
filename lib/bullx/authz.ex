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
  alias BullX.Principals.ActivationCode
  alias BullX.Principals.Principal
  alias BullX.Repo

  require Logger

  @admin_group_name "admin"
  @all_humans_group_name "all_humans"
  @all_humans_condition ~s(principal.type == "human" && principal.status == "active")
  @bootstrap_metadata_key "bootstrap"

  @type authz_error :: :forbidden | :not_found | :principal_disabled | :invalid_request

  @spec authorize(Principal.t() | Ecto.UUID.t(), String.t(), String.t()) ::
          :ok | {:error, authz_error()}
  def authorize(principal, resource, action), do: authorize(principal, resource, action, %{})

  @spec authorize(Principal.t() | Ecto.UUID.t(), String.t(), String.t(), map()) ::
          :ok | {:error, authz_error()}
  def authorize(principal, resource, action, context) do
    with {:ok, request} <- Request.build(principal, resource, action, context),
         {:ok, principal} <- load_active_principal(request.principal_id) do
      request
      |> Request.with_principal(principal)
      |> authorize_request()
    end
  end

  @spec authorize_permission(Principal.t() | Ecto.UUID.t(), String.t()) ::
          :ok | {:error, authz_error()}
  def authorize_permission(principal, permission_key),
    do: authorize_permission(principal, permission_key, %{})

  @spec authorize_permission(Principal.t() | Ecto.UUID.t(), String.t(), map()) ::
          :ok | {:error, authz_error()}
  def authorize_permission(principal, permission_key, context) do
    with {:ok, resource, action} <- Request.split_permission_key(permission_key) do
      authorize(principal, resource, action, context)
    end
  end

  @spec allowed?(Principal.t() | Ecto.UUID.t(), String.t(), String.t()) :: boolean()
  def allowed?(principal, resource, action), do: allowed?(principal, resource, action, %{})

  @spec allowed?(Principal.t() | Ecto.UUID.t(), String.t(), String.t(), map()) :: boolean()
  def allowed?(principal, resource, action, context) do
    case authorize(principal, resource, action, context) do
      :ok -> true
      _error -> false
    end
  end

  @spec list_principal_groups(Principal.t() | Ecto.UUID.t()) ::
          {:ok, [PrincipalGroup.t()]} | {:error, :not_found | :invalid_request}
  def list_principal_groups(principal_or_id) do
    with {:ok, principal} <- fetch_principal(principal_or_id, :invalid_request) do
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

  @spec add_principal_to_group(Principal.t() | Ecto.UUID.t(), PrincipalGroup.t() | Ecto.UUID.t()) ::
          :ok | {:error, :not_found | :invalid_request | :computed_group}
  def add_principal_to_group(principal_or_id, group_or_id) do
    with {:ok, principal} <- fetch_principal(principal_or_id, :invalid_request),
         {:ok, group} <- fetch_group(group_or_id),
         :ok <- ensure_static_membership_group(group) do
      attrs = %{principal_id: principal.id, group_id: group.id}

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
          Principal.t() | Ecto.UUID.t(),
          PrincipalGroup.t() | Ecto.UUID.t()
        ) ::
          :ok
          | {:error, :not_found | :last_admin_member | :last_active_human_admin | :computed_group}
  def remove_principal_from_group(principal_or_id, group_or_id) do
    with {:ok, principal} <- fetch_principal(principal_or_id, :not_found),
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

  @spec ensure_can_disable_principal(Principal.t() | Ecto.UUID.t()) ::
          :ok | {:error, :not_found | :invalid_request | :last_active_human_admin}
  def ensure_can_disable_principal(principal_or_id) do
    transaction(fn ->
      with {:ok, principal} <- fetch_principal_for_update(principal_or_id, :invalid_request) do
        ensure_can_disable_loaded_principal(principal)
      end
    end)
  end

  @spec reconcile_bootstrap_admin_membership() :: :ok | {:error, term()}
  def reconcile_bootstrap_admin_membership do
    transaction(fn ->
      with {:ok, _all_humans, _all_humans_status} <- ensure_built_in_all_humans_group(),
           {:ok, group, _status} <- ensure_built_in_admin_group() do
        bootstrap_admin_principals()
        |> Enum.reduce_while(:ok, fn principal, :ok ->
          case insert_membership(principal.id, group.id) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end
    end)
  end

  @doc false
  @spec grant_bootstrap_admin(Principal.t() | Ecto.UUID.t()) :: :ok | {:error, term()}
  def grant_bootstrap_admin(principal_or_id) do
    case bootstrap_storage_ready?() do
      true ->
        with {:ok, principal} <- fetch_principal(principal_or_id, :not_found) do
          grant_bootstrap_admin_to_loaded_principal(principal)
        end

      false ->
        Logger.warning("BullX.AuthZ bootstrap admin handoff skipped because tables do not exist")
        :ok
    end
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

  @doc false
  @spec bootstrap_storage_ready?() :: boolean()
  def bootstrap_storage_ready? do
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
      ),
      EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = current_schema() AND table_name = 'activation_codes'
      )
    """

    case Ecto.Adapters.SQL.query(Repo, query, []) do
      {:ok, %{rows: [row]}} -> Enum.all?(row)
      {:error, reason} -> log_table_check_error(reason)
    end
  end

  defp authorize_request(%Request{principal: %Principal{} = principal} = request) do
    group_ids = effective_principal_group_ids(principal)
    grants = list_candidate_grants(request.principal_id, group_ids, request.action)

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
        "id" => principal.id,
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
        "id" => principal.id,
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

  defp static_principal_groups(%Principal{id: principal_id}) do
    Repo.all(
      from membership in PrincipalGroupMembership,
        join: group in assoc(membership, :group),
        where: membership.principal_id == ^principal_id,
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

  defp list_candidate_grants(principal_id, group_ids, action) do
    Repo.all(
      from grant in PermissionGrant,
        where:
          grant.action == ^action and
            (grant.principal_id == ^principal_id or grant.group_id in ^group_ids)
    )
  end

  defp load_active_principal(principal_id) do
    case Repo.get(Principal, principal_id) do
      nil -> {:error, :not_found}
      %Principal{status: :active} = principal -> {:ok, principal}
      %Principal{status: :disabled} -> {:error, :principal_disabled}
    end
  end

  defp fetch_principal(%Principal{id: id}, invalid_error), do: fetch_principal(id, invalid_error)

  defp fetch_principal(id, invalid_error) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(Principal, uuid) do
          nil -> {:error, :not_found}
          principal -> {:ok, principal}
        end

      :error ->
        {:error, invalid_error}
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
      case lock_principal_for_update(principal.id) do
        nil ->
          {:error, :not_found}

        locked_principal ->
          case lock_group_for_update(group_id) do
            nil ->
              {:error, :not_found}

            group ->
              with :ok <- ensure_membership_exists_for_update(locked_principal.id, group.id),
                   :ok <- ensure_not_last_admin_member(group, locked_principal.id),
                   :ok <- ensure_not_last_active_human_admin(group, locked_principal.id) do
                delete_membership(locked_principal.id, group.id)
              end
          end
      end
    end)
  end

  defp remove_membership(%Principal{} = principal, %PrincipalGroup{} = group) do
    delete_membership(principal.id, group.id)
  end

  defp ensure_can_disable_loaded_principal(%Principal{status: :disabled}), do: :ok
  defp ensure_can_disable_loaded_principal(%Principal{type: :agent}), do: :ok

  defp ensure_can_disable_loaded_principal(%Principal{type: :human, id: principal_id}) do
    case lock_admin_group_for_update() do
      nil ->
        :ok

      group ->
        case lock_membership_for_update(principal_id, group.id) do
          %PrincipalGroupMembership{} -> ensure_not_last_active_human_admin(group, principal_id)
          nil -> :ok
        end
    end
  end

  defp fetch_principal_for_update(%Principal{id: id}, invalid_error),
    do: fetch_principal_for_update(id, invalid_error)

  defp fetch_principal_for_update(id, invalid_error) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case lock_principal_for_update(uuid) do
          nil -> {:error, :not_found}
          principal -> {:ok, principal}
        end

      :error ->
        {:error, invalid_error}
    end
  end

  defp fetch_principal_for_update(_principal, invalid_error), do: {:error, invalid_error}

  defp lock_principal_for_update(principal_id) do
    Repo.one(
      from principal in Principal, where: principal.id == ^principal_id, lock: "FOR UPDATE"
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

  defp ensure_membership_exists_for_update(principal_id, group_id) do
    case lock_membership_for_update(principal_id, group_id) do
      %PrincipalGroupMembership{} -> :ok
      nil -> {:error, :not_found}
    end
  end

  defp ensure_not_last_admin_member(%PrincipalGroup{id: group_id}, principal_id) do
    remaining = locked_admin_member_count_excluding(group_id, principal_id)

    case remaining do
      0 -> {:error, :last_admin_member}
      _count -> :ok
    end
  end

  defp ensure_not_last_active_human_admin(%PrincipalGroup{id: group_id}, principal_id) do
    remaining = active_human_admin_count_excluding(group_id, principal_id)

    case remaining do
      0 -> {:error, :last_active_human_admin}
      _count -> :ok
    end
  end

  defp active_human_admin_count_excluding(group_id, principal_id) do
    Repo.all(
      from(membership in PrincipalGroupMembership,
        join: principal in Principal,
        on: principal.id == membership.principal_id,
        where:
          membership.group_id == ^group_id and membership.principal_id != ^principal_id and
            principal.type == :human and principal.status == :active,
        lock: "FOR UPDATE",
        select: principal.id
      )
    )
    |> length()
  end

  defp locked_admin_member_count_excluding(group_id, principal_id) do
    Repo.all(
      from membership in PrincipalGroupMembership,
        where: membership.group_id == ^group_id and membership.principal_id != ^principal_id,
        lock: "FOR UPDATE",
        select: membership.principal_id
    )
    |> length()
  end

  defp lock_membership_for_update(principal_id, group_id) do
    Repo.one(
      from membership in PrincipalGroupMembership,
        where: membership.principal_id == ^principal_id and membership.group_id == ^group_id,
        lock: "FOR UPDATE"
    )
  end

  defp delete_membership(principal_id, group_id) do
    {count, _rows} =
      Repo.delete_all(
        from membership in PrincipalGroupMembership,
          where: membership.principal_id == ^principal_id and membership.group_id == ^group_id
      )

    case count do
      0 -> {:error, :not_found}
      _count -> :ok
    end
  end

  defp insert_membership(principal_id, group_id) do
    %{principal_id: principal_id, group_id: group_id}
    |> then(&PrincipalGroupMembership.changeset(%PrincipalGroupMembership{}, &1))
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, _membership} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp grant_bootstrap_admin_to_loaded_principal(%Principal{type: :human} = principal) do
    transaction(fn ->
      with {:ok, _all_humans, _all_humans_status} <- ensure_built_in_all_humans_group(),
           {:ok, group, _status} <- ensure_built_in_admin_group() do
        insert_membership(principal.id, group.id)
      end
    end)
  end

  defp grant_bootstrap_admin_to_loaded_principal(%Principal{}), do: :ok

  defp bootstrap_admin_principals do
    Repo.all(
      from code in ActivationCode,
        join: principal in Principal,
        on: principal.id == code.used_by_principal_id,
        where:
          not is_nil(code.used_by_principal_id) and
            fragment("? ->> ?", code.metadata, ^@bootstrap_metadata_key) == "true" and
            principal.type == :human,
        select: principal
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
    Logger.warning("BullX.AuthZ bootstrap table check failed: #{inspect(reason)}")
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
