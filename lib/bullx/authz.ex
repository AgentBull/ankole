defmodule BullX.AuthZ do
  @moduledoc """
  Principal-centered authorization boundary.

  AuthZ consumes existing active Principals, static Principal groups, and
  permission grants. It does not create, authenticate, activate, or bind
  Principals.
  """

  import Ecto.Query

  alias BullX.AuthZ.Cedar
  alias BullX.AuthZ.PermissionGrant
  alias BullX.AuthZ.PrincipalGroup
  alias BullX.AuthZ.PrincipalGroupMembership
  alias BullX.AuthZ.Request
  alias BullX.Principals.ActivationCode
  alias BullX.Principals.Principal
  alias BullX.Repo

  require Logger

  @admin_group_name "admin"
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
      groups =
        Repo.all(
          from membership in PrincipalGroupMembership,
            join: group in assoc(membership, :group),
            where: membership.principal_id == ^principal.id,
            order_by: [asc: group.name],
            select: group
        )

      {:ok, groups}
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
          :ok | {:error, :not_found | :invalid_request}
  def add_principal_to_group(principal_or_id, group_or_id) do
    with {:ok, principal} <- fetch_principal(principal_or_id, :invalid_request),
         {:ok, group} <- fetch_group(group_or_id) do
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
        ) :: :ok | {:error, :not_found | :last_admin_member | :last_active_human_admin}
  def remove_principal_from_group(principal_or_id, group_or_id) do
    with {:ok, principal} <- fetch_principal(principal_or_id, :not_found),
         {:ok, group} <- fetch_group(group_or_id) do
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
      with {:ok, principal} <- fetch_principal(principal_or_id, :invalid_request) do
        ensure_can_disable_loaded_principal(principal)
      end
    end)
  end

  @spec reconcile_bootstrap_admin_membership() :: :ok | {:error, term()}
  def reconcile_bootstrap_admin_membership do
    transaction(fn ->
      with {:ok, group, _status} <- ensure_built_in_admin_group() do
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
    case Repo.get_by(PrincipalGroup, name: @admin_group_name) do
      nil -> create_built_in_admin_group()
      %PrincipalGroup{built_in: true} = group -> {:ok, group, :existing}
      %PrincipalGroup{} = group -> {:error, {:conflicting_admin_group, group}}
    end
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

  defp authorize_request(%Request{} = request) do
    group_ids = principal_group_ids(request.principal_id)
    grants = list_candidate_grants(request.principal_id, group_ids, request.action)

    case any_loaded_grant_allows?(grants, request) do
      true -> :ok
      false -> {:error, :forbidden}
    end
  end

  defp any_loaded_grant_allows?(grants, request) do
    loaded_grants = Enum.map(grants, &loaded_grant/1)

    case Cedar.eval_loaded_grants(request, loaded_grants) do
      {:ok, allowed?, invalid_grants} ->
        emit_invalid_persisted_conditions(invalid_grants, grants)
        allowed?

      {:error, _reason} ->
        false
    end
  end

  defp loaded_grant(%PermissionGrant{} = grant) do
    {grant.id, grant.resource_pattern, grant.condition}
  end

  defp emit_invalid_persisted_conditions(invalid_grants, grants) do
    grants_by_id = Map.new(grants, &{&1.id, &1})

    Enum.each(invalid_grants, fn {grant_id, reason} ->
      grant = Map.fetch!(grants_by_id, grant_id)

      Logger.error(
        "BullX.AuthZ invalid persisted condition grant_id=#{inspect(grant_id)} reason=#{inspect(reason)}"
      )

      :telemetry.execute(
        [:bullx, :authz, :invalid_persisted_data],
        %{count: 1},
        %{
          kind: :condition,
          id: grant.id,
          action: grant.action,
          resource_pattern: grant.resource_pattern,
          reason: reason
        }
      )
    end)
  end

  defp principal_group_ids(principal_id) do
    Repo.all(
      from membership in PrincipalGroupMembership,
        where: membership.principal_id == ^principal_id,
        select: membership.group_id
    )
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

  defp group_has_grants?(%PrincipalGroup{id: group_id}) do
    Repo.exists?(from grant in PermissionGrant, where: grant.group_id == ^group_id, select: 1)
  end

  defp remove_membership(%Principal{} = principal, %PrincipalGroup{
         id: group_id,
         built_in: true,
         name: @admin_group_name
       }) do
    transaction(fn ->
      case lock_group_for_update(group_id) do
        nil ->
          {:error, :not_found}

        group ->
          with :ok <- ensure_membership_exists(principal.id, group.id),
               :ok <- ensure_not_last_admin_member(group, principal.id),
               :ok <- ensure_not_last_active_human_admin(group, principal.id) do
            delete_membership(principal.id, group.id)
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
        case admin_member?(group.id, principal_id) do
          true -> ensure_not_last_active_human_admin(group, principal_id)
          false -> :ok
        end
    end
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

  defp ensure_membership_exists(principal_id, group_id) do
    case membership_exists?(principal_id, group_id) do
      true -> :ok
      false -> {:error, :not_found}
    end
  end

  defp ensure_not_last_admin_member(%PrincipalGroup{id: group_id}, principal_id) do
    remaining =
      Repo.aggregate(
        from(membership in PrincipalGroupMembership,
          where: membership.group_id == ^group_id and membership.principal_id != ^principal_id
        ),
        :count
      )

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
    Repo.aggregate(
      from(membership in PrincipalGroupMembership,
        join: principal in Principal,
        on: principal.id == membership.principal_id,
        where:
          membership.group_id == ^group_id and membership.principal_id != ^principal_id and
            principal.type == :human and principal.status == :active
      ),
      :count
    )
  end

  defp membership_exists?(principal_id, group_id) do
    Repo.exists?(
      from membership in PrincipalGroupMembership,
        where: membership.principal_id == ^principal_id and membership.group_id == ^group_id,
        select: 1
    )
  end

  defp admin_member?(group_id, principal_id), do: membership_exists?(principal_id, group_id)

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
      with {:ok, group, _status} <- ensure_built_in_admin_group() do
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

  defp create_built_in_admin_group do
    attrs = %{
      name: @admin_group_name,
      description: "Built-in administrators group.",
      built_in: true
    }

    %PrincipalGroup{}
    |> PrincipalGroup.system_create_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, group} -> {:ok, group, :created}
      {:error, changeset} -> admin_group_insert_error(changeset)
    end
  end

  defp admin_group_insert_error(%Ecto.Changeset{} = changeset) do
    case unique_conflict?(changeset, :name) do
      true -> ensure_built_in_admin_group()
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
