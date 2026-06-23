defmodule Ankole.AuthZ do
  @moduledoc """
  Authorization state boundary for Principal groups and permission grants.

  The control plane owns PostgreSQL state and snapshot assembly. The kernel owns
  deterministic rule evaluation over explicit snapshots.
  """

  alias Ecto.Adapters.SQL
  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ankole.AuthZ.ExternalBinding
  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.Kernel, as: AnkoleKernel
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  require Logger

  @admin_group_name "admin"
  @all_humans_group_name "all_humans"
  @all_humans_condition ~s(principal.type == "human" && principal.status == "active")
  @resource_glob_metacharacters ~r/[\*\?\[\]\{\}]/
  @max_json_integer 9_223_372_036_854_775_807
  @min_json_integer -9_223_372_036_854_775_808

  @group_fields [:name, :display_name, :kind, :computed_condition, :description, :metadata]
  @binding_fields [:provider, :external_id, :group_id, :metadata]
  @grant_fields [
    :principal_uid,
    :group_id,
    :resource_pattern,
    :action,
    :condition,
    :description,
    :metadata
  ]

  @type decision :: map()
  @type decision_result :: :ok | {:error, term()}

  @doc """
  Lists Principal groups ordered by name.
  """
  @spec list_principal_groups() :: [Group.t()]
  def list_principal_groups do
    Group
    |> order_by([group], asc: group.name)
    |> Repo.all()
  end

  @doc """
  Looks up a Principal group by UUID or name.
  """
  @spec get_principal_group(String.t()) :: {:ok, Group.t()} | {:error, :not_found}
  def get_principal_group(id_or_name) do
    fetch_group(Repo, id_or_name)
  end

  @doc """
  Creates an operator-defined Principal group.
  """
  @spec create_principal_group(map()) :: {:ok, Group.t()} | {:error, term()}
  def create_principal_group(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> take_attrs(@group_fields)
      |> Map.put(:built_in, false)

    %Group{}
    |> Group.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates mutable group fields.
  """
  @spec update_principal_group(Group.t(), map()) :: {:ok, Group.t()} | {:error, term()}
  def update_principal_group(%Group{} = group, attrs) when is_map(attrs) do
    attrs =
      case group.built_in do
        true ->
          attrs
          |> drop_attrs([:name, :kind, :built_in, :computed_condition])
          |> take_attrs(@group_fields)

        false ->
          take_attrs(attrs, @group_fields)
      end

    group
    |> Group.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an operator-defined group when no grants still refer to it.
  """
  @spec delete_principal_group(String.t() | Group.t()) :: {:ok, Group.t()} | {:error, term()}
  def delete_principal_group(%Group{} = group), do: delete_principal_group(group.id)

  def delete_principal_group(id_or_name) do
    Repo.transact(fn repo ->
      with {:ok, group} <- fetch_group_for_update(repo, id_or_name),
           :ok <- ensure_operator_group(group),
           :ok <- ensure_group_has_no_grants(repo, group.id) do
        repo.delete(group)
      end
    end)
  end

  @doc """
  Adds a Principal to a static group.
  """
  @spec add_principal_to_group(String.t(), String.t()) :: {:ok, Membership.t()} | {:error, term()}
  def add_principal_to_group(principal_uid, group_id_or_name) do
    Repo.transact(fn repo ->
      with {:ok, group} <- fetch_group_for_update(repo, group_id_or_name),
           :ok <- ensure_static_group(group),
           {:ok, principal_uid} <- Principals.normalize_uid(principal_uid),
           :ok <- ensure_principal_exists(repo, principal_uid) do
        %Membership{}
        |> Membership.changeset(%{group_id: group.id, principal_uid: principal_uid})
        |> repo.insert(on_conflict: :nothing, conflict_target: [:principal_uid, :group_id])
      end
    end)
  end

  @doc """
  Removes a Principal from a static group.
  """
  @spec remove_principal_from_group(String.t(), String.t()) :: {:ok, :deleted} | {:error, term()}
  def remove_principal_from_group(principal_uid, group_id_or_name) do
    Repo.transact(fn repo ->
      with {:ok, group} <- fetch_group(repo, group_id_or_name),
           :ok <- ensure_static_group(group),
           {:ok, principal_uid} <- Principals.normalize_uid(principal_uid) do
        remove_membership(repo, principal_uid, group)
      end
    end)
  end

  @doc """
  Inserts or updates an external subject to group binding.
  """
  @spec upsert_external_binding(map()) :: {:ok, ExternalBinding.t()} | {:error, term()}
  def upsert_external_binding(attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      with {:ok, attrs} <- binding_attrs(repo, attrs) do
        %ExternalBinding{}
        |> ExternalBinding.changeset(attrs)
        |> repo.insert(
          conflict_target: [:provider, :external_id],
          on_conflict: {:replace, [:group_id, :metadata, :updated_at]},
          returning: true
        )
      end
    end)
  end

  @doc """
  Returns group ids bound to a provider-scoped external subject.
  """
  @spec external_group_ids(String.t(), String.t()) :: [String.t()]
  def external_group_ids(provider, external_id) do
    with {:ok, provider} <- normalize_provider(provider),
         {:ok, external_id} <- normalize_required_text(external_id) do
      ExternalBinding
      |> join(:inner, [binding], group in Group, on: group.id == binding.group_id)
      |> where(
        [binding, group],
        binding.provider == ^provider and binding.external_id == ^external_id and
          group.kind == :static
      )
      |> select([binding, _group], binding.group_id)
      |> Repo.all()
    else
      {:error, _reason} -> []
    end
  end

  @doc """
  Inserts a permission grant.
  """
  @spec create_permission_grant(map()) :: {:ok, Grant.t()} | {:error, term()}
  def create_permission_grant(attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      with {:ok, attrs} <- grant_attrs(repo, attrs) do
        %Grant{}
        |> Grant.changeset(attrs)
        |> repo.insert()
      end
    end)
  end

  @doc """
  Inserts or updates a permission grant by its natural owner/resource/action/condition key.
  """
  @spec upsert_permission_grant(map()) :: {:ok, Grant.t()} | {:error, term()}
  def upsert_permission_grant(attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      with {:ok, attrs} <- grant_attrs(repo, attrs),
           changeset <- Grant.changeset(%Grant{}, attrs),
           {:ok, normalized} <- Changeset.apply_action(changeset, :insert) do
        repo.insert(changeset,
          on_conflict: permission_grant_upsert_update(normalized),
          conflict_target: permission_grant_upsert_target(normalized),
          returning: true
        )
      end
    end)
  end

  @doc """
  Updates a permission grant by id.
  """
  @spec update_permission_grant(String.t() | Grant.t(), map()) ::
          {:ok, Grant.t()} | {:error, term()}
  def update_permission_grant(%Grant{} = grant, attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      with {:ok, attrs} <- grant_attrs(repo, attrs) do
        grant
        |> Grant.changeset(attrs)
        |> repo.update()
      end
    end)
  end

  def update_permission_grant(id, attrs) when is_binary(id) and is_map(attrs) do
    case Repo.get(Grant, id) do
      %Grant{} = grant -> update_permission_grant(grant, attrs)
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Deletes a permission grant by id.
  """
  @spec delete_permission_grant(String.t()) :: {:ok, Grant.t()} | {:error, term()}
  def delete_permission_grant(id) do
    case Repo.get(Grant, id) do
      %Grant{} = grant -> Repo.delete(grant)
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Authorizes one exact action on one concrete resource.
  """
  @spec authorize(String.t(), String.t(), String.t(), map()) :: decision_result()
  def authorize(principal_uid, resource, action, context \\ %{}) do
    with {:ok, decision} <- authorize_decision(principal_uid, resource, action, context) do
      decision_result(decision)
    end
  end

  @doc """
  Authorizes a compact `<resource>:<action>` permission key.
  """
  @spec authorize_permission(String.t(), String.t()) :: decision_result()
  @spec authorize_permission(String.t(), String.t(), map()) :: decision_result()
  def authorize_permission(principal_uid, permission, context \\ %{}) do
    with {:ok, resource, action} <- split_permission_key(permission) do
      authorize(principal_uid, resource, action, context)
    end
  end

  @doc """
  Returns true when one exact action is allowed.
  """
  @spec allowed?(String.t(), String.t(), String.t()) :: boolean()
  @spec allowed?(String.t(), String.t(), String.t(), map()) :: boolean()
  def allowed?(principal_uid, resource, action, context \\ %{}) do
    case authorize(principal_uid, resource, action, context) do
      :ok -> true
      _error -> false
    end
  end

  @doc """
  Returns the raw kernel decision for one exact action.
  """
  @spec authorize_decision(String.t(), String.t(), String.t(), map()) ::
          {:ok, decision()} | {:error, term()}
  def authorize_decision(principal_uid, resource, action, context \\ %{}) do
    with {:ok, snapshot} <- build_authorization_snapshot(principal_uid, resource, action, context),
         {:ok, decision} <- kernel_decision(AnkoleKernel.authz_authorize(snapshot)) do
      emit_diagnostics(decision)
      {:ok, decision}
    end
  end

  @doc """
  Authorizes every requested action against one concrete resource.
  """
  @spec authorize_all(String.t(), String.t(), [String.t()], map()) :: decision_result()
  def authorize_all(principal_uid, resource, actions, context \\ %{}) do
    with {:ok, decision} <- authorize_all_decision(principal_uid, resource, actions, context) do
      decision_result(decision)
    end
  end

  @doc """
  Returns the raw kernel decision for a batch authorization request.
  """
  @spec authorize_all_decision(String.t(), String.t(), [String.t()], map()) ::
          {:ok, decision()} | {:error, term()}
  def authorize_all_decision(principal_uid, resource, actions, context \\ %{}) do
    with {:ok, snapshot} <-
           build_authorization_batch_snapshot(principal_uid, resource, actions, context),
         {:ok, decision} <- kernel_decision(AnkoleKernel.authz_authorize_all(snapshot)) do
      emit_diagnostics(decision)
      {:ok, decision}
    end
  end

  @doc """
  Builds the explicit kernel snapshot for one authorization request.
  """
  @spec build_authorization_snapshot(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def build_authorization_snapshot(principal_uid, resource, action, context \\ %{}) do
    with {:ok, [action]} <- normalize_actions([action]),
         {:ok, snapshot} <-
           load_authorization_snapshot(Repo, principal_uid, resource, [action], context) do
      {:ok, Map.put(snapshot, "action", action)}
    end
  end

  @doc """
  Builds the explicit kernel snapshot for a batch authorization request.
  """
  @spec build_authorization_batch_snapshot(String.t(), String.t(), [String.t()], map()) ::
          {:ok, map()} | {:error, term()}
  def build_authorization_batch_snapshot(principal_uid, resource, actions, context \\ %{}) do
    with {:ok, actions} <- normalize_actions(actions),
         {:ok, snapshot} <-
           load_authorization_snapshot(Repo, principal_uid, resource, actions, context) do
      {:ok, Map.put(snapshot, "actions", actions)}
    end
  end

  @doc """
  Returns true once AuthZ storage is ready and the built-in groups exist.
  """
  @spec root_initialized?() :: boolean()
  def root_initialized? do
    storage_ready?() and built_in_admin_group_ready?(Repo) and
      built_in_all_humans_group_ready?(Repo)
  end

  @doc """
  Returns `:ok` while the first root admin claim is still open.
  """
  @spec ensure_root_init_open() :: :ok | {:error, :root_init_closed}
  def ensure_root_init_open do
    ensure_root_init_open(Repo)
  end

  @doc """
  Initializes built-in AuthZ groups and assigns the first active human admin.
  """
  @spec root_init_admin(String.t()) :: {:ok, map()} | {:error, term()}
  def root_init_admin(principal_uid) do
    Repo.transact(fn repo ->
      with {:ok, principal} <- fetch_principal_for_update(repo, principal_uid),
           :ok <- ensure_active_human(principal),
           {:ok, built_ins} <- ensure_builtin_groups(repo),
           {:ok, admin_group} <- lock_group(repo, built_ins.admin_group.id),
           :ok <- ensure_root_init_open(repo, admin_group.id),
           {:ok, membership} <- insert_membership(repo, admin_group.id, principal.uid) do
        {:ok,
         %{
           admin_group: admin_group,
           all_humans_group: built_ins.all_humans_group,
           membership: membership
         }}
      end
    end)
  end

  @doc """
  Ensures disabling a Principal will not strand the installation without a root admin.
  """
  @spec ensure_can_disable_principal(String.t()) :: :ok | {:error, term()}
  def ensure_can_disable_principal(principal_uid) do
    Repo.transact(fn repo -> ensure_can_disable_principal(principal_uid, repo) end)
  end

  @doc false
  @spec ensure_can_disable_principal(String.t(), term()) :: :ok | {:error, term()}
  def ensure_can_disable_principal(principal_uid, repo) do
    with {:ok, principal_uid} <- Principals.normalize_uid(principal_uid),
         {:ok, principal} <- fetch_principal_for_update(repo, principal_uid) do
      case principal do
        %Principal{type: :human, status: :active} ->
          ensure_disabling_keeps_active_human_admin(repo, principal.uid)

        %Principal{} ->
          :ok
      end
    end
  end

  defp load_authorization_snapshot(repo, principal_uid, resource, actions, context) do
    with {:ok, principal_uid} <- Principals.normalize_uid(principal_uid),
         {:ok, resource} <- normalize_resource(resource),
         {:ok, context} <- normalize_context(context),
         {:ok, principal} <- fetch_principal(repo, principal_uid) do
      static_group_ids = static_group_ids(repo, principal.uid)
      computed_groups = computed_group_snapshots(repo)
      candidate_group_ids = static_group_ids ++ Enum.map(computed_groups, & &1["id"])
      grants = grant_snapshots(repo, principal.uid, candidate_group_ids, actions)

      {:ok,
       %{
         "principal" => principal_snapshot(principal),
         "staticGroupIds" => static_group_ids,
         "computedGroups" => computed_groups,
         "grants" => grants,
         "resource" => resource,
         "context" => context
       }}
    end
  end

  defp principal_snapshot(%Principal{} = principal) do
    %{
      "uid" => principal.uid,
      "type" => Atom.to_string(principal.type),
      "status" => Atom.to_string(principal.status),
      "displayName" => principal.display_name,
      "avatarUrl" => principal.avatar_url
    }
  end

  defp computed_group_snapshots(repo) do
    Group
    |> where([group], group.kind == :computed)
    |> select([group], %{id: group.id, computed_condition: group.computed_condition})
    |> repo.all()
    |> Enum.map(fn group ->
      %{"id" => group.id, "condition" => group.computed_condition || "false"}
    end)
  end

  defp static_group_ids(repo, principal_uid) do
    Membership
    |> join(:inner, [membership], group in Group, on: group.id == membership.group_id)
    |> where(
      [membership, group],
      membership.principal_uid == ^principal_uid and group.kind == :static
    )
    |> select([membership, _group], membership.group_id)
    |> repo.all()
  end

  defp grant_snapshots(repo, principal_uid, [], actions) do
    Grant
    |> where([grant], grant.action in ^actions)
    |> where([grant], grant.principal_uid == ^principal_uid)
    |> repo.all()
    |> Enum.map(&grant_snapshot/1)
  end

  defp grant_snapshots(repo, principal_uid, candidate_group_ids, actions) do
    Grant
    |> where([grant], grant.action in ^actions)
    |> where(
      [grant],
      grant.principal_uid == ^principal_uid or grant.group_id in ^candidate_group_ids
    )
    |> repo.all()
    |> Enum.map(&grant_snapshot/1)
  end

  defp grant_snapshot(%Grant{} = grant) do
    %{
      "id" => grant.id,
      "principalUid" => grant.principal_uid,
      "groupId" => grant.group_id,
      "resourcePattern" => grant.resource_pattern,
      "action" => grant.action,
      "condition" => grant.condition
    }
  end

  defp decision_result(%{"status" => "allow"}), do: :ok
  defp decision_result(%{"status" => "principal_disabled"}), do: {:error, :principal_disabled}
  defp decision_result(%{"status" => "invalid_request"}), do: {:error, :invalid_request}

  defp decision_result(%{"status" => "deny", "deniedAction" => action}),
    do: {:error, {:forbidden, action}}

  defp decision_result(%{"status" => "deny"}), do: {:error, :forbidden}
  defp decision_result(_decision), do: {:error, :invalid_decision}

  defp kernel_decision(%{} = decision), do: {:ok, decision}
  defp kernel_decision({:error, reason}), do: {:error, reason}
  defp kernel_decision(_decision), do: {:error, :invalid_decision}

  defp binding_attrs(repo, attrs) do
    attrs = take_attrs(attrs, [:group_name | @binding_fields])

    with {:ok, attrs} <- resolve_group_name(repo, attrs),
         :ok <- ensure_binding_static_group(repo, attrs) do
      {:ok, attrs}
    end
  end

  defp grant_attrs(repo, attrs) do
    attrs = take_attrs(attrs, [:group_name | @grant_fields])

    case fetch_attr(attrs, :group_name) do
      {:ok, group_name} ->
        with {:ok, group} <- fetch_group(repo, group_name) do
          {:ok, attrs |> Map.delete(:group_name) |> Map.put(:group_id, group.id)}
        end

      :error ->
        {:ok, attrs}
    end
  end

  defp resolve_group_name(repo, attrs) do
    case fetch_attr(attrs, :group_name) do
      {:ok, group_name} ->
        with {:ok, group} <- fetch_group(repo, group_name) do
          {:ok, attrs |> Map.delete(:group_name) |> Map.put(:group_id, group.id)}
        end

      :error ->
        {:ok, attrs}
    end
  end

  defp ensure_binding_static_group(repo, attrs) do
    case fetch_attr(attrs, :group_id) do
      {:ok, group_id} ->
        with {:ok, group} <- fetch_group(repo, group_id) do
          ensure_static_group(group)
        end

      :error ->
        :ok
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

  defp ensure_builtin_groups(repo) do
    with {:ok, admin_group} <-
           upsert_builtin_group(repo, %{
             name: @admin_group_name,
             display_name: "Administrators",
             kind: :static,
             built_in: true,
             computed_condition: nil,
             description: "Root operators for this Ankole installation",
             metadata: %{}
           }),
         {:ok, all_humans_group} <-
           upsert_builtin_group(repo, %{
             name: @all_humans_group_name,
             display_name: "All Humans",
             kind: :computed,
             built_in: true,
             computed_condition: @all_humans_condition,
             description: "Computed group for active human Principals",
             metadata: %{}
           }) do
      {:ok, %{admin_group: admin_group, all_humans_group: all_humans_group}}
    end
  end

  defp upsert_builtin_group(repo, attrs) do
    case fetch_group_by_name(repo, attrs.name) do
      %Group{} = group ->
        case builtin_shape_matches?(group, attrs) do
          true -> {:ok, group}
          false -> {:error, {:built_in_group_conflict, attrs.name}}
        end

      nil ->
        create_builtin_group(repo, attrs)
    end
  end

  defp create_builtin_group(repo, attrs) do
    %Group{}
    |> Group.changeset(attrs)
    |> repo.insert()
    |> case do
      {:ok, group} -> {:ok, group}
      {:error, %Changeset{} = changeset} -> built_in_group_insert_error(repo, changeset, attrs)
    end
  end

  defp builtin_shape_matches?(%Group{} = group, attrs) do
    group.kind == attrs.kind and group.built_in == true and
      group.computed_condition == attrs.computed_condition
  end

  defp built_in_group_insert_error(repo, %Changeset{} = changeset, attrs) do
    case unique_conflict?(changeset, :name) do
      true -> upsert_builtin_group(repo, attrs)
      false -> {:error, changeset}
    end
  end

  defp unique_conflict?(%Changeset{} = changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      {_field, _error} -> false
    end)
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

    case SQL.query(Repo, query, []) do
      {:ok, %{rows: [row]}} ->
        Enum.all?(row)

      {:error, reason} ->
        Logger.debug("AuthZ root_initialized table check failed: #{inspect(reason)}")
        false
    end
  end

  defp built_in_admin_group_ready?(repo) do
    repo.exists?(
      from group in Group,
        where:
          group.name == ^@admin_group_name and group.built_in == true and group.kind == :static and
            is_nil(group.computed_condition)
    )
  end

  defp built_in_all_humans_group_ready?(repo) do
    repo.exists?(
      from group in Group,
        where:
          group.name == ^@all_humans_group_name and group.built_in == true and
            group.kind == :computed and group.computed_condition == ^@all_humans_condition
    )
  end

  defp insert_membership(repo, group_id, principal_uid) do
    %Membership{}
    |> Membership.changeset(%{group_id: group_id, principal_uid: principal_uid})
    |> repo.insert(on_conflict: :nothing, conflict_target: [:principal_uid, :group_id])
  end

  defp ensure_root_init_open(repo) do
    case fetch_built_in_admin_group_by_name(repo) do
      %Group{} = admin_group -> ensure_root_init_open(repo, admin_group.id)
      nil -> :ok
    end
  end

  defp ensure_root_init_open(repo, admin_group_id) do
    case admin_member_exists?(repo, admin_group_id) do
      true -> {:error, :root_init_closed}
      false -> :ok
    end
  end

  defp admin_member_exists?(repo, admin_group_id) do
    repo.exists?(from membership in Membership, where: membership.group_id == ^admin_group_id)
  end

  defp remove_membership(
         repo,
         principal_uid,
         %Group{name: @admin_group_name, built_in: true} = group
       ) do
    with {:ok, principal} <- fetch_principal_for_update(repo, principal_uid),
         {:ok, locked_group} <- lock_group(repo, group.id),
         :ok <- ensure_membership_exists_for_update(repo, principal.uid, locked_group.id),
         :ok <- ensure_not_last_admin_member(repo, locked_group.id, principal.uid),
         :ok <- ensure_removing_keeps_active_human_admin(repo, locked_group.id, principal) do
      delete_membership(repo, principal.uid, locked_group.id)
    end
  end

  defp remove_membership(repo, principal_uid, %Group{} = group) do
    delete_membership(repo, principal_uid, group.id)
  end

  defp ensure_disabling_keeps_active_human_admin(repo, principal_uid) do
    case lock_built_in_admin_group_for_update(repo) do
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

  defp ensure_principal_exists(repo, principal_uid) do
    case repo.get(Principal, principal_uid) do
      %Principal{} -> :ok
      nil -> {:error, :principal_not_found}
    end
  end

  defp fetch_principal(repo, principal_uid) do
    case repo.get(Principal, principal_uid) do
      %Principal{} = principal -> {:ok, principal}
      nil -> {:error, :not_found}
    end
  end

  defp fetch_principal_for_update(repo, principal_uid) do
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

  defp ensure_active_human(%Principal{type: :human, status: :active}), do: :ok
  defp ensure_active_human(%Principal{type: :agent}), do: {:error, :not_human}
  defp ensure_active_human(%Principal{status: :disabled}), do: {:error, :principal_disabled}

  defp fetch_group(repo, id_or_name) when is_binary(id_or_name) do
    case fetch_group_by_id_or_name(repo, id_or_name) do
      %Group{} = group -> {:ok, group}
      nil -> {:error, :not_found}
    end
  end

  defp fetch_group(_repo, _id_or_name), do: {:error, :not_found}

  defp fetch_group_for_update(repo, id_or_name) when is_binary(id_or_name) do
    case repo.one(group_by_id_or_name_query(id_or_name, lock: "FOR UPDATE")) do
      %Group{} = group -> {:ok, group}
      nil -> {:error, :not_found}
    end
  end

  defp fetch_group_for_update(_repo, _id_or_name), do: {:error, :not_found}

  defp fetch_group_by_id_or_name(repo, id_or_name) do
    repo.one(group_by_id_or_name_query(id_or_name))
  end

  defp fetch_group_by_name(repo, name) do
    repo.one(from group in Group, where: group.name == ^name)
  end

  defp fetch_built_in_admin_group_by_name(repo) do
    repo.one(
      from group in Group,
        where: group.name == ^@admin_group_name and group.built_in == true
    )
  end

  defp lock_built_in_admin_group_for_update(repo) do
    repo.one(
      from group in Group,
        where: group.name == ^@admin_group_name and group.built_in == true,
        lock: "FOR UPDATE"
    )
  end

  defp lock_group(repo, group_id) do
    case repo.one(from group in Group, where: group.id == ^group_id, lock: "FOR UPDATE") do
      %Group{} = group -> {:ok, group}
      nil -> {:error, :not_found}
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

  defp ensure_static_group(%Group{kind: :static}), do: :ok
  defp ensure_static_group(%Group{kind: :computed}), do: {:error, :computed_group}

  defp ensure_operator_group(%Group{built_in: false}), do: :ok
  defp ensure_operator_group(%Group{built_in: true}), do: {:error, :built_in_group}

  defp ensure_group_has_no_grants(repo, group_id) do
    case repo.exists?(from grant in Grant, where: grant.group_id == ^group_id) do
      true -> {:error, :group_has_grants}
      false -> :ok
    end
  end

  defp normalize_actions(actions) when is_list(actions) do
    normalized =
      Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, acc} ->
        case normalize_required_text(action) do
          {:ok, action} ->
            case String.contains?(action, ":") do
              true -> {:halt, {:error, :invalid_request}}
              false -> {:cont, {:ok, [action | acc]}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case normalized do
      {:ok, []} -> {:error, :invalid_request}
      {:ok, actions} -> {:ok, Enum.reverse(actions)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_actions(_actions), do: {:error, :invalid_request}

  defp normalize_resource(resource) do
    with {:ok, resource} <- normalize_required_text(resource) do
      case Regex.match?(@resource_glob_metacharacters, resource) do
        true -> {:error, :invalid_request}
        false -> {:ok, resource}
      end
    end
  end

  defp normalize_context(context) when is_map(context) do
    case normalize_json_value(context) do
      {:ok, %{} = normalized} -> {:ok, normalized}
      {:ok, _value} -> {:error, :invalid_request}
      :error -> {:error, :invalid_request}
    end
  end

  defp normalize_context(_context), do: {:error, :invalid_request}

  defp normalize_provider(value) do
    with {:ok, text} <- normalize_required_text(value) do
      provider = String.downcase(text)

      case Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, provider) do
        true -> {:ok, provider}
        false -> {:error, :invalid_provider}
      end
    end
  end

  defp normalize_required_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_request}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_required_text(_value), do: {:error, :invalid_request}

  defp split_permission_key(permission) when is_binary(permission) do
    case String.split(permission, ":") do
      [_single] ->
        {:error, :invalid_request}

      parts when length(parts) >= 2 ->
        {action, resource_parts} = List.pop_at(parts, length(parts) - 1)
        resource = Enum.join(resource_parts, ":")

        with {:ok, resource} <- normalize_resource(resource),
             {:ok, [action]} <- normalize_actions([action]) do
          {:ok, resource, action}
        end
    end
  end

  defp split_permission_key(_permission), do: {:error, :invalid_request}

  defp normalize_json_value(nil), do: {:ok, nil}
  defp normalize_json_value(value) when is_boolean(value), do: {:ok, value}
  defp normalize_json_value(value) when is_binary(value), do: {:ok, value}
  defp normalize_json_value(value) when is_float(value), do: {:ok, value}

  defp normalize_json_value(value)
       when is_integer(value) and value >= @min_json_integer and value <= @max_json_integer,
       do: {:ok, value}

  defp normalize_json_value(value) when is_integer(value), do: :error

  defp normalize_json_value(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalize_json_value(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp normalize_json_value(%_struct{}), do: :error

  defp normalize_json_value(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, val}, {:ok, acc} ->
      with {:ok, key} <- normalize_json_key(key),
           {:ok, val} <- normalize_json_value(val) do
        {:cont, {:ok, Map.put(acc, key, val)}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  defp normalize_json_value(_value), do: :error

  defp normalize_json_key(key) when is_binary(key), do: {:ok, key}

  defp normalize_json_key(key) when is_atom(key) and not is_boolean(key) and key != nil do
    {:ok, Atom.to_string(key)}
  end

  defp normalize_json_key(_key), do: :error

  defp emit_diagnostics(%{"diagnostics" => diagnostics}) when is_list(diagnostics) do
    Enum.each(diagnostics, &emit_diagnostic/1)
  end

  defp emit_diagnostics(_decision), do: :ok

  defp emit_diagnostic(%{} = diagnostic) do
    metadata = %{
      kind: diagnostic["kind"],
      id: diagnostic["id"],
      action: diagnostic["action"],
      resource_pattern: diagnostic["resourcePattern"],
      reason: diagnostic["reason"]
    }

    Logger.error("AuthZ invalid persisted data: #{inspect(metadata)}")
    :telemetry.execute([:ankole, :authz, :invalid_persisted_data], %{count: 1}, metadata)
  end

  defp emit_diagnostic(_diagnostic), do: :ok

  defp take_attrs(attrs, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case fetch_attr(attrs, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp drop_attrs(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      acc
      |> Map.delete(key)
      |> Map.delete(Atom.to_string(key))
    end)
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end
end
