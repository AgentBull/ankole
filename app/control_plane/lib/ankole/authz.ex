defmodule Ankole.AuthZ do
  @moduledoc """
  Authorization state boundary for Principal groups and permission grants.

  The control plane owns PostgreSQL state and snapshot assembly. The kernel owns
  deterministic rule evaluation over explicit snapshots.
  """

  import Ecto.Query, warn: false

  alias Ankole.AuthZ.Decision
  alias Ankole.AuthZ.ExternalBinding
  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Grants
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Input
  alias Ankole.AuthZ.Membership
  alias Ankole.AuthZ.Root
  alias Ankole.AuthZ.Snapshot
  alias Ankole.AuthZ.Store
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @type decision :: map()
  @type decision_result :: :ok | {:error, term()}

  @computed_preview_group_id "preview"

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
    Store.fetch_group(Repo, id_or_name)
  end

  @doc """
  Creates an operator-defined Principal group.
  """
  @spec create_principal_group(map()) :: {:ok, Group.t()} | {:error, term()}
  def create_principal_group(attrs) when is_map(attrs) do
    %Group{}
    |> Group.changeset(Input.group_create_attrs(attrs))
    |> Repo.insert()
  end

  @doc """
  Updates mutable group fields.
  """
  @spec update_principal_group(Group.t(), map()) :: {:ok, Group.t()} | {:error, term()}
  def update_principal_group(%Group{} = group, attrs) when is_map(attrs) do
    group
    |> Group.changeset(Input.group_update_attrs(group, attrs))
    |> Repo.update()
  end

  @doc """
  Deletes an operator-defined group when no grants still refer to it.
  """
  @spec delete_principal_group(String.t() | Group.t()) :: {:ok, Group.t()} | {:error, term()}
  def delete_principal_group(%Group{} = group), do: delete_principal_group(group.id)

  def delete_principal_group(id_or_name) do
    Repo.transact(fn repo -> Store.delete_operator_group(repo, id_or_name) end)
  end

  @doc """
  Lists static members of a Principal group with their Principal display fields.

  Members are ordered by Principal display name. Computed groups derive
  membership at authorization time and have no stored rows to list.
  """
  @spec list_group_members(String.t()) ::
          {:ok, [%{membership: Membership.t(), principal: Principal.t()}]}
          | {:error, :not_found | :computed_group}
  def list_group_members(id_or_name) do
    with {:ok, group} <- Store.fetch_group(Repo, id_or_name),
         :ok <- Store.ensure_static_group(group) do
      members =
        Membership
        |> join(:inner, [membership], principal in Principal,
          on: principal.uid == membership.principal_uid
        )
        |> where([membership, _principal], membership.group_id == ^group.id)
        |> order_by([_membership, principal], asc: principal.display_name, asc: principal.uid)
        |> select([membership, principal], %{membership: membership, principal: principal})
        |> Repo.all()

      {:ok, members}
    end
  end

  @doc """
  Lists permission grants owned by a Principal group ordered by pattern and action.
  """
  @spec list_group_grants(String.t()) :: {:ok, [Grant.t()]} | {:error, :not_found}
  def list_group_grants(id_or_name) do
    with {:ok, group} <- Store.fetch_group(Repo, id_or_name) do
      {:ok, list_ordered_grants(group_id: group.id)}
    end
  end

  @doc """
  Lists permission grants owned directly by one Principal ordered by pattern and action.
  """
  @spec list_principal_grants(String.t()) :: {:ok, [Grant.t()]} | {:error, term()}
  def list_principal_grants(principal_uid) do
    with {:ok, principal} <- Principals.get_principal(principal_uid) do
      {:ok, list_ordered_grants(principal_uid: principal.uid)}
    end
  end

  @doc """
  Lists the static groups one Principal belongs to, ordered by group name.
  """
  @spec list_principal_group_memberships(String.t()) :: {:ok, [Group.t()]} | {:error, term()}
  def list_principal_group_memberships(principal_uid) do
    with {:ok, principal} <- Principals.get_principal(principal_uid) do
      groups =
        Group
        |> join(:inner, [group], membership in Membership, on: membership.group_id == group.id)
        |> where([_group, membership], membership.principal_uid == ^principal.uid)
        |> order_by([group, _membership], asc: group.name)
        |> Repo.all()

      {:ok, groups}
    end
  end

  @doc """
  Counts stored members and owned grants per Principal group, defaulting to zero.
  """
  @spec summarize_principal_groups() :: %{
          String.t() => %{member_count: non_neg_integer(), grant_count: non_neg_integer()}
        }
  def summarize_principal_groups do
    member_counts =
      Membership
      |> group_by([membership], membership.group_id)
      |> select([membership], {membership.group_id, count(membership.principal_uid)})
      |> Repo.all()
      |> Map.new()

    grant_counts =
      Grant
      |> where([grant], not is_nil(grant.group_id))
      |> group_by([grant], grant.group_id)
      |> select([grant], {grant.group_id, count(grant.id)})
      |> Repo.all()
      |> Map.new()

    Map.new(Map.keys(member_counts) ++ Map.keys(grant_counts), fn group_id ->
      {group_id,
       %{
         member_count: Map.get(member_counts, group_id, 0),
         grant_count: Map.get(grant_counts, group_id, 0)
       }}
    end)
  end

  @doc """
  Looks up one permission grant by id.
  """
  @spec get_permission_grant(String.t()) :: {:ok, Grant.t()} | {:error, :not_found}
  def get_permission_grant(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id) do
      case Repo.get(Grant, uuid) do
        %Grant{} = grant -> {:ok, grant}
        nil -> {:error, :not_found}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Evaluates a computed group condition against every active Principal.

  Returns the Principals that would belong to a computed group with the given
  condition, ordered by display name. The condition is validated before
  evaluation so invalid CEL returns an error instead of an empty list.
  """
  @spec preview_computed_group_members(String.t()) :: {:ok, [Principal.t()]} | {:error, term()}
  def preview_computed_group_members(condition) do
    with :ok <- Input.validate_condition_syntax(condition) do
      members =
        Principals.list_active_principals()
        |> Enum.filter(fn principal ->
          principal
          |> Snapshot.build_condition_preview_snapshot(@computed_preview_group_id, condition)
          |> Decision.preview_computed_membership?(@computed_preview_group_id)
        end)
        |> Enum.sort_by(fn principal -> {principal.display_name, principal.uid} end)

      {:ok, members}
    end
  end

  @doc """
  Adds a Principal to a static group.
  """
  @spec add_principal_to_group(String.t(), String.t()) :: {:ok, Membership.t()} | {:error, term()}
  def add_principal_to_group(principal_uid, group_id_or_name) do
    Repo.transact(fn repo ->
      Store.add_principal_to_group(repo, principal_uid, group_id_or_name, Root.admin_group_name())
    end)
  end

  @doc """
  Removes a Principal from a static group.
  """
  @spec remove_principal_from_group(String.t(), String.t()) :: {:ok, :deleted} | {:error, term()}
  def remove_principal_from_group(principal_uid, group_id_or_name) do
    Repo.transact(fn repo ->
      Store.remove_principal_from_group(
        repo,
        principal_uid,
        group_id_or_name,
        Root.admin_group_name()
      )
    end)
  end

  @doc """
  Inserts or updates an external subject to group binding.
  """
  @spec upsert_external_binding(map()) :: {:ok, ExternalBinding.t()} | {:error, term()}
  def upsert_external_binding(attrs) when is_map(attrs) do
    Repo.transact(fn repo -> Store.upsert_external_binding(repo, attrs) end)
  end

  @doc """
  Returns group ids bound to a provider-scoped external group of a specific kind.
  """
  @spec external_group_ids(String.t(), atom() | String.t(), String.t()) :: [String.t()]
  def external_group_ids(provider, external_kind, external_id) do
    Store.external_group_ids(Repo, provider, external_kind, external_id)
  end

  @doc """
  Reconciles one Principal's identity-provider-owned department group memberships.

  The provider binding table maps external department ids to directory-domain
  Principal groups. Manual operator groups and mismatched external bindings are
  left untouched.
  """
  @spec sync_external_directory_group_memberships(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, %{synced_group_ids: [String.t()], removed_memberships: non_neg_integer()}}
          | {:error, term()}
  def sync_external_directory_group_memberships(provider, principal_uid, external_ids, opts \\ [])
      when is_binary(provider) and is_list(external_ids) do
    Repo.transact(fn repo ->
      Store.sync_external_directory_group_memberships(
        repo,
        provider,
        principal_uid,
        external_ids,
        opts
      )
    end)
  end

  @doc false
  @spec external_directory_group_index(String.t()) :: {:ok, map()} | {:error, term()}
  def external_directory_group_index(provider) when is_binary(provider) do
    Store.external_directory_group_index(Repo, provider)
  end

  @doc false
  @spec replace_static_group_members(String.t(), :directory | :im_group, [String.t()]) ::
          {:ok, %{synced_principal_uids: [String.t()], removed_memberships: non_neg_integer()}}
          | {:error, term()}
  def replace_static_group_members(group_id, expected_domain, principal_uids)
      when is_binary(group_id) and is_list(principal_uids) do
    Repo.transact(fn repo ->
      Store.replace_static_group_members(repo, group_id, expected_domain, principal_uids)
    end)
  end

  @doc false
  @spec clear_static_group_members(String.t(), :directory | :im_group) ::
          {:ok, %{removed_memberships: non_neg_integer()}} | {:error, term()}
  def clear_static_group_members(group_id, expected_domain) when is_binary(group_id) do
    Repo.transact(fn repo ->
      Store.clear_static_group_members(repo, group_id, expected_domain)
    end)
  end

  @doc """
  Inserts a permission grant.
  """
  @spec create_permission_grant(map()) :: {:ok, Grant.t()} | {:error, term()}
  def create_permission_grant(attrs) when is_map(attrs) do
    Repo.transact(fn repo -> Grants.create_permission_grant(repo, attrs) end)
  end

  @doc """
  Inserts or updates a permission grant by its natural owner/resource/action/condition key.
  """
  @spec upsert_permission_grant(map()) :: {:ok, Grant.t()} | {:error, term()}
  def upsert_permission_grant(attrs) when is_map(attrs) do
    Repo.transact(fn repo -> Grants.upsert_permission_grant(repo, attrs) end)
  end

  @doc """
  Updates a permission grant by id.
  """
  @spec update_permission_grant(String.t() | Grant.t(), map()) ::
          {:ok, Grant.t()} | {:error, term()}
  def update_permission_grant(%Grant{} = grant, attrs) when is_map(attrs) do
    Repo.transact(fn repo -> Grants.update_permission_grant(repo, grant, attrs) end)
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
      Decision.result(decision)
    end
  end

  @doc """
  Authorizes a compact `<resource>:<action>` permission key.
  """
  @spec authorize_permission(String.t(), String.t()) :: decision_result()
  @spec authorize_permission(String.t(), String.t(), map()) :: decision_result()
  def authorize_permission(principal_uid, permission, context \\ %{}) do
    with {:ok, resource, action} <- Input.split_permission_key(permission) do
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
    Decision.authorize_decision(principal_uid, resource, action, context)
  end

  @doc """
  Authorizes every requested action against one concrete resource.
  """
  @spec authorize_all(String.t(), String.t(), [String.t()], map()) :: decision_result()
  def authorize_all(principal_uid, resource, actions, context \\ %{}) do
    with {:ok, decision} <- authorize_all_decision(principal_uid, resource, actions, context) do
      Decision.result(decision)
    end
  end

  @doc """
  Returns the raw kernel decision for a batch authorization request.
  """
  @spec authorize_all_decision(String.t(), String.t(), [String.t()], map()) ::
          {:ok, decision()} | {:error, term()}
  def authorize_all_decision(principal_uid, resource, actions, context \\ %{}) do
    Decision.authorize_all_decision(principal_uid, resource, actions, context)
  end

  @doc """
  Builds the explicit kernel snapshot for one authorization request.
  """
  @spec build_authorization_snapshot(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def build_authorization_snapshot(principal_uid, resource, action, context \\ %{}) do
    Snapshot.build_authorization_snapshot(principal_uid, resource, action, context)
  end

  @doc """
  Builds the explicit kernel snapshot for a batch authorization request.
  """
  @spec build_authorization_batch_snapshot(String.t(), String.t(), [String.t()], map()) ::
          {:ok, map()} | {:error, term()}
  def build_authorization_batch_snapshot(principal_uid, resource, actions, context \\ %{}) do
    Snapshot.build_authorization_batch_snapshot(principal_uid, resource, actions, context)
  end

  @doc """
  Returns true once AuthZ storage is ready and the built-in groups exist.
  """
  @spec root_initialized?() :: boolean()
  defdelegate root_initialized?, to: Root

  @doc """
  Ensures the built-in admin group has the coarse console grants.
  """
  @spec ensure_console_admin_grants() :: :ok | {:error, term()}
  defdelegate ensure_console_admin_grants, to: Root

  @doc """
  Returns `:ok` while the first root admin claim is still open.
  """
  @spec ensure_root_init_open() :: :ok | {:error, :root_init_closed}
  defdelegate ensure_root_init_open, to: Root

  @doc """
  Initializes built-in AuthZ groups and assigns the first active human admin.
  """
  @spec root_init_admin(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate root_init_admin(principal_uid), to: Root

  @doc """
  Ensures disabling a Principal will not strand the installation without a root admin.
  """
  @spec ensure_can_disable_principal(String.t()) :: :ok | {:error, term()}
  def ensure_can_disable_principal(principal_uid) do
    Repo.transact(fn repo ->
      Store.ensure_can_disable_principal(principal_uid, repo, Root.admin_group_name())
    end)
  end

  @doc false
  @spec ensure_can_disable_principal(String.t(), term()) :: :ok | {:error, term()}
  def ensure_can_disable_principal(principal_uid, repo) do
    Store.ensure_can_disable_principal(principal_uid, repo, Root.admin_group_name())
  end

  defp list_ordered_grants(owner_filter) do
    Grant
    |> where(^owner_filter)
    |> order_by([grant], asc: grant.resource_pattern, asc: grant.action)
    |> Repo.all()
  end
end
