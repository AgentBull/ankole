defmodule Ankole.AuthZ do
  @moduledoc """
  Authorization state boundary for Principal groups and permission grants.

  The control plane owns PostgreSQL state and snapshot assembly. The kernel owns
  deterministic rule evaluation over explicit snapshots.

  This module is the AuthZ domain. A write that locks a group, a Principal, or
  the Pod tree is a generic action that owns its transaction. `Ankole.AuthZ.Store`
  and `Ankole.AuthZ.Grants` give the same steps to another domain's action.
  """
  use Ankole.Ash.Domain

  import Ecto.Query, only: [from: 2]
  require Ash.Query
  require Ash.Sort

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

  resources do
    resource Group do
      define(:get_group, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_groups, action: :read)
      define(:create_group, action: :create_in_tx)
      define(:profile_group, action: :profile_in_tx)
    end

    resource Membership do
      define(:list_memberships, action: :read)
    end

    resource Grant do
      define(:get_grant, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_grants, action: :read)
      define(:delete_grant, action: :delete_in_tx)
    end

    resource ExternalBinding do
      define(:list_external_bindings, action: :read)
      define(:bind_external_binding, action: :bind_in_tx)
    end
  end

  @type decision :: map()
  @type decision_result :: :ok | {:error, term()}

  @computed_preview_group_id "preview"

  def administrator_recovery_required? do
    admin_group_name = Root.admin_group_name()

    members =
      Ash.Query.filter(Membership, group.name == ^admin_group_name and group.built_in == true)

    exists?(members) and
      not exists?(
        Ash.Query.filter(members, principal.type == :human and principal.status == :active)
      )
  end

  @doc false
  def recover_admin_in_tx(repo, uid) do
    case Store.lock_built_in_admin_group_for_update(repo, Root.admin_group_name()) do
      %Group{} = group ->
        active_admin_exists =
          Membership
          |> Ash.Query.filter(
            group_id == ^group.id and principal.type == :human and principal.status == :active
          )
          |> exists?()

        with false <- active_admin_exists,
             {:ok, principal} <- Store.fetch_principal_for_update(repo, uid),
             :ok <- Store.ensure_active_human(principal),
             {:ok, _} <- Store.insert_membership(repo, group.id, principal.uid) do
          {:ok, principal}
        else
          true -> {:error, :active_admin_exists}
          error -> error
        end

      nil ->
        {:error, :setup_not_complete}
    end
  end

  @doc """
  Lists the permission rules that must be approved before Human restoration.
  Remove unwanted grants or memberships through AuthZ, then request a new review.
  """
  def restoration_review(uid) do
    with {:ok, principal} <- Principals.get_principal(uid) do
      static_ids =
        Repo.all(
          from m in Membership, where: m.principal_uid == ^principal.uid, select: m.group_id
        )

      groups =
        Repo.all(
          from g in Group,
            where: g.id in ^static_ids or g.kind == :computed,
            order_by: g.id,
            select: %{
              id: g.id,
              name: g.name,
              domain: fragment("?::text", g.domain),
              kind: fragment("?::text", g.kind),
              condition: g.computed_condition
            }
        )

      group_ids = Enum.map(groups, & &1.id)

      grants =
        Repo.all(
          from g in Grant,
            where: g.principal_uid == ^principal.uid or g.group_id in ^group_ids,
            order_by: g.id,
            select: %{
              id: g.id,
              principal_uid: g.principal_uid,
              group_id: g.group_id,
              resource_pattern: g.resource_pattern,
              action: g.action,
              condition: g.condition
            }
        )

      permissions = %{
        "principal" => %{
          uid: principal.uid,
          display_name: principal.display_name,
          avatar_url: principal.avatar_url,
          access_version: principal.access_version
        },
        "groups" => groups,
        "grants" => grants
      }

      fingerprint =
        :crypto.hash(:sha256, :erlang.term_to_binary(permissions, [:deterministic]))
        |> Base.url_encode64(padding: false)

      {:ok, %{fingerprint: fingerprint, permissions: permissions}}
    end
  end

  @doc """
  Lists Principal groups ordered by name.
  """
  @spec list_principal_groups() :: [Group.t()]
  def list_principal_groups do
    Group
    |> Ash.Query.sort(name: :asc)
    |> Ankole.Ash.read!()
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
    Ankole.Ash.create(Group, :create_in_tx, Input.group_create_attrs(attrs))
  end

  @doc """
  Updates mutable group fields.
  """
  @spec update_principal_group(Group.t(), map()) :: {:ok, Group.t()} | {:error, term()}
  def update_principal_group(%Group{} = group, attrs) when is_map(attrs) do
    Ankole.Ash.update(group, :profile_in_tx, Input.group_update_attrs(group, attrs))
  end

  @doc """
  Deletes an operator-defined group when no grants still refer to it.
  """
  @spec delete_principal_group(String.t() | Group.t()) :: {:ok, Group.t()} | {:error, term()}
  def delete_principal_group(%Group{} = group), do: delete_principal_group(group.id)

  def delete_principal_group(id_or_name) do
    Ankole.Ash.run_action(Group, :delete_operator_group, %{id_or_name: id_or_name})
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
        |> Ash.Query.filter(group_id == ^group.id)
        |> Ash.Query.load(:principal)
        |> Ash.Query.sort([
          {Ash.Sort.expr_sort(principal.display_name, :string), :asc},
          principal_uid: :asc
        ])
        |> Ankole.Ash.read!()
        |> Enum.map(fn %Membership{principal: principal} = membership ->
          %{membership: membership, principal: principal}
        end)

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
        principal.uid
        |> static_groups_query()
        |> Ash.Query.sort(name: :asc)
        |> Ankole.Ash.read!()

      {:ok, groups}
    end
  end

  @doc """
  Lists every group one Principal currently belongs to, including computed
  groups, ordered by group name.

  Membership is resolved against the current relations at call time: static
  groups through their membership rows and computed groups through their CEL
  condition. Brain audience scopes depend on this live resolution instead of
  write-time snapshots.
  """
  @spec list_current_groups_for_principal(String.t()) :: {:ok, [Group.t()]} | {:error, term()}
  def list_current_groups_for_principal(principal_uid) do
    with {:ok, principal} <- Principals.get_principal(principal_uid) do
      static = principal.uid |> static_groups_query() |> Ankole.Ash.read!()

      computed =
        Group
        |> Ash.Query.filter(kind == :computed)
        |> Ankole.Ash.read!()
        |> Enum.filter(&computed_group_member?(principal, &1))

      {:ok, Enum.sort_by(static ++ computed, & &1.name)}
    end
  end

  @doc """
  Returns whether a Principal currently belongs to one group.

  Static groups check their membership rows; computed groups evaluate their
  CEL condition against the current Principal.
  """
  @spec principal_in_group?(String.t(), Group.t()) :: boolean()
  def principal_in_group?(principal_uid, %Group{kind: :static} = group) do
    case Principals.normalize_uid(principal_uid) do
      {:ok, uid} ->
        Membership
        |> Ash.Query.filter(group_id == ^group.id and principal_uid == ^uid)
        |> exists?()

      {:error, _reason} ->
        false
    end
  end

  def principal_in_group?(principal_uid, %Group{kind: :computed} = group) do
    case Principals.get_principal(principal_uid) do
      {:ok, principal} -> computed_group_member?(principal, group)
      {:error, _reason} -> false
    end
  end

  @doc """
  Returns whether every listed Principal currently belongs to one group.

  A static group answers with one membership query over the whole list, so a
  per-hit disclosure check over a large present-member set stays one round
  trip; a computed group evaluates its CEL condition per Principal.
  """
  @spec all_in_group?([String.t()], Group.t()) :: boolean()
  def all_in_group?([], %Group{}), do: true

  def all_in_group?(principal_uids, %Group{kind: :static} = group) do
    normalized =
      for uid <- principal_uids, {:ok, normalized} <- [Principals.normalize_uid(uid)] do
        normalized
      end

    if length(normalized) != length(principal_uids) do
      false
    else
      unique = Enum.uniq(normalized)

      matched =
        Membership
        |> Ash.Query.filter(group_id == ^group.id and principal_uid in ^unique)
        |> Ash.Query.select([:principal_uid])
        |> Ankole.Ash.read!()
        |> length()

      matched == length(unique)
    end
  end

  def all_in_group?(principal_uids, %Group{} = group) do
    Enum.all?(principal_uids, &principal_in_group?(&1, group))
  end

  defp static_groups_query(principal_uid) do
    Ash.Query.filter(Group, exists(memberships, principal_uid == ^principal_uid))
  end

  defp computed_group_member?(%Principal{} = principal, %Group{} = group) do
    is_binary(group.computed_condition) and
      principal
      |> Snapshot.build_condition_preview_snapshot(group.id, group.computed_condition)
      |> Decision.preview_computed_membership?(group.id)
  end

  @doc """
  Counts stored members and owned grants per Principal group, defaulting to zero.
  """
  @spec summarize_principal_groups() :: %{
          String.t() => %{member_count: non_neg_integer(), grant_count: non_neg_integer()}
        }
  def summarize_principal_groups do
    Group
    |> Ash.Query.filter(member_count > 0 or grant_count > 0)
    |> Ash.Query.load([:member_count, :grant_count])
    |> Ankole.Ash.read!()
    |> Map.new(fn group ->
      {group.id, %{member_count: group.member_count, grant_count: group.grant_count}}
    end)
  end

  @doc """
  Looks up one permission grant by id.
  """
  @spec get_permission_grant(String.t()) :: {:ok, Grant.t()} | {:error, :not_found}
  def get_permission_grant(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Grant{} = grant <- get_grant!(uuid) do
      {:ok, grant}
    else
      _missing -> {:error, :not_found}
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
    Ankole.Ash.run_action(Group, :add_member, %{
      principal_uid: principal_uid,
      group: group_id_or_name
    })
  end

  @doc """
  Removes a Principal from a static group.
  """
  @spec remove_principal_from_group(String.t(), String.t()) :: {:ok, :deleted} | {:error, term()}
  def remove_principal_from_group(principal_uid, group_id_or_name) do
    Ankole.Ash.run_action(Group, :remove_member, %{
      principal_uid: principal_uid,
      group: group_id_or_name
    })
  end

  @doc """
  Inserts or updates an external subject to group binding.
  """
  @spec upsert_external_binding(map()) :: {:ok, ExternalBinding.t()} | {:error, term()}
  def upsert_external_binding(attrs) when is_map(attrs) do
    Ankole.Ash.run_action(ExternalBinding, :upsert_binding, %{attrs: attrs})
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
    Ankole.Ash.run_action(Membership, :sync_external_directory_memberships, %{
      provider: provider,
      principal_uid: principal_uid,
      external_ids: external_ids,
      opts: opts
    })
  end

  @doc false
  @spec external_directory_group_index(String.t()) :: {:ok, map()} | {:error, term()}
  def external_directory_group_index(provider) when is_binary(provider) do
    Store.external_directory_group_index(Repo, provider)
  end

  @doc false
  @spec replace_static_group_members(String.t(), :directory | :im_group | :signal_source, [
          String.t()
        ]) ::
          {:ok, %{synced_principal_uids: [String.t()], removed_memberships: non_neg_integer()}}
          | {:error, term()}
  def replace_static_group_members(group_id, expected_domain, principal_uids)
      when is_binary(group_id) and is_list(principal_uids) do
    Ankole.Ash.run_action(Group, :replace_static_members, %{
      group_id: group_id,
      expected_domain: expected_domain,
      principal_uids: principal_uids
    })
  end

  @doc false
  @spec apply_static_group_member_delta(
          String.t(),
          :directory | :im_group | :signal_source,
          [String.t()],
          [String.t()]
        ) ::
          {:ok,
           %{
             added_principal_uids: [String.t()],
             removed_principal_uids: [String.t()],
             removed_memberships: non_neg_integer()
           }}
          | {:error, term()}
  def apply_static_group_member_delta(group_id, expected_domain, added_uids, removed_uids)
      when is_binary(group_id) and is_list(added_uids) and is_list(removed_uids) do
    Ankole.Ash.run_action(Group, :apply_static_member_delta, %{
      group_id: group_id,
      expected_domain: expected_domain,
      added_uids: added_uids,
      removed_uids: removed_uids
    })
  end

  @doc """
  Ensures a convention-named synced group exists and the principal is a member.

  `group_attrs` must carry `:name`, `:display_name`, `:domain`, and optional
  `:metadata`. Membership only accumulates here; removal stays with the flow
  that owns the group's lifecycle.
  """
  @spec ensure_synced_group_member(map(), String.t()) :: :ok | {:error, term()}
  def ensure_synced_group_member(group_attrs, principal_uid)
      when is_map(group_attrs) and is_binary(principal_uid) do
    with {:ok, uid} <- Principals.normalize_uid(principal_uid) do
      case synced_member?(group_attrs, uid) do
        true ->
          :ok

        false ->
          # The caller's requested domain, not the fetched group's own:
          # `ensure_synced_group` is fetch-or-create by name, so a
          # pre-existing same-named group of another domain must fail the
          # domain check as `{:error, :group_domain_mismatch}` — passing
          # `group.domain` back in would make that check a tautology (and a
          # non-synced domain would miss `add_synced_group_member`'s guard
          # and raise out of the transaction).
          # Staged: Conversations identity admission still calls this function
          # in its transaction. Change it to a generic action when that caller
          # uses `ensure_synced_group_member_in_tx/3`.
          Repo.transact(fn repo ->
            with :ok <- ensure_synced_group_member_in_tx(repo, group_attrs, uid),
                 do: {:ok, :ensured}
          end)
          |> case do
            {:ok, :ensured} -> :ok
            {:error, _reason} = error -> error
          end
      end
    end
  end

  # Domain-qualified on purpose: a membership in a same-named group of
  # another domain must not satisfy this check — it falls through to the
  # transaction, whose domain assertion rejects the collision.
  defp synced_member?(group_attrs, principal_uid) do
    name = group_attrs |> Map.fetch!(:name) |> String.downcase()
    domain = Map.fetch!(group_attrs, :domain)

    Membership
    |> Ash.Query.filter(
      group.name == ^name and group.domain == ^domain and principal_uid == ^principal_uid
    )
    |> exists?()
  end

  @doc false
  def ensure_synced_group_member_in_tx(repo, group_attrs, principal_uid) do
    with {:ok, uid} <- Principals.normalize_uid(principal_uid) do
      if synced_member?(group_attrs, uid) do
        :ok
      else
        with {:ok, group} <- Store.ensure_synced_group(repo, group_attrs),
             {:ok, _membership} <-
               Store.add_synced_group_member(
                 repo,
                 group.id,
                 Map.fetch!(group_attrs, :domain),
                 uid
               ),
             do: :ok
      end
    end
  end

  @doc """
  Inserts a permission grant.
  """
  @spec create_permission_grant(map()) :: {:ok, Grant.t()} | {:error, term()}
  def create_permission_grant(attrs) when is_map(attrs) do
    # Staged: a Pod test holds this write in its own transaction. Change it to a
    # generic action when that caller uses `Ankole.AuthZ.Grants.create_permission_grant/2`.
    Repo.transact(fn repo -> Grants.create_permission_grant(repo, attrs) end)
  end

  @doc """
  Inserts or updates a permission grant by its natural owner/resource/action/condition key.
  """
  @spec upsert_permission_grant(map()) :: {:ok, Grant.t()} | {:error, term()}
  def upsert_permission_grant(attrs) when is_map(attrs) do
    Ankole.Ash.run_action(Grant, :upsert_permission_grant, %{attrs: attrs})
  end

  @doc """
  Updates a permission grant by id.
  """
  @spec update_permission_grant(String.t() | Grant.t(), map()) ::
          {:ok, Grant.t()} | {:error, term()}
  def update_permission_grant(%Grant{} = grant, attrs) when is_map(attrs) do
    Ankole.Ash.run_action(Grant, :update_permission_grant, %{grant: grant, attrs: attrs})
  end

  def update_permission_grant(id, attrs) when is_binary(id) and is_map(attrs) do
    case get_permission_grant(id) do
      {:ok, grant} -> update_permission_grant(grant, attrs)
      {:error, :not_found} = error -> error
    end
  end

  @doc """
  Deletes a permission grant by id.
  """
  @spec delete_permission_grant(String.t()) :: {:ok, Grant.t()} | {:error, term()}
  def delete_permission_grant(id) do
    Ankole.Ash.run_action(Grant, :delete_permission_grant, %{id: id})
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
  Returns the raw kernel decision for a batch authorization request.
  """
  @spec authorize_all_decision(String.t(), String.t(), [String.t()], map()) ::
          {:ok, decision()} | {:error, term()}
  def authorize_all_decision(principal_uid, resource, actions, context \\ %{}) do
    Decision.authorize_all_decision(principal_uid, resource, actions, context)
  end

  @doc """
  Evaluates independent resource/action checks with one authorization snapshot.

  Each check has `:resource` and `:action`. Optional `:grant_ids` restricts
  the check to those grants; an empty list denies it. Results keep input order.
  """
  @spec authorize_checks(String.t(), [map()], map()) :: {:ok, [boolean()]} | {:error, term()}
  def authorize_checks(principal_uid, checks, context \\ %{}) do
    Decision.authorize_checks(principal_uid, checks, context)
  end

  defdelegate site_admin?(uid), to: Root

  @doc false
  @spec root_init_admin(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def root_init_admin(principal_uid, repo) do
    Root.root_init_admin(repo, principal_uid)
  end

  @doc false
  @spec ensure_can_disable_principal(String.t(), term()) :: :ok | {:error, term()}
  def ensure_can_disable_principal(principal_uid, repo) do
    Store.ensure_can_disable_principal(principal_uid, repo, Root.admin_group_name())
  end

  defp list_ordered_grants(owner_filter) do
    Grant
    |> Ash.Query.do_filter(owner_filter)
    |> Ash.Query.sort(resource_pattern: :asc, action: :asc)
    |> Ankole.Ash.read!()
  end

  defp exists?(query),
    do: query |> Ash.Query.limit(1) |> Ankole.Ash.read!() |> Enum.any?()
end
