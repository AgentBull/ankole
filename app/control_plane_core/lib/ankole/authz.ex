defmodule Ankole.AuthZ do
  @moduledoc """
  Authorization state boundary for Principal groups and permission grants.

  The control plane owns PostgreSQL state and snapshot assembly. The kernel owns
  deterministic rule evaluation over explicit snapshots.

  This module is the AuthZ domain. A write that locks a group, a Principal, or
  the Pod tree is a generic action that owns its transaction. `Ankole.AuthZ.Store`
  and `Ankole.AuthZ.Grants` give the same steps to another domain's action.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  import Ecto.Query, only: [from: 2]
  require Ash.Query
  require Ash.Sort

  alias Ankole.AuthZ.Decision
  alias Ankole.AuthZ.ExternalBinding
  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Input
  alias Ankole.AuthZ.Membership
  alias Ankole.AuthZ.Root
  alias Ankole.AuthZ.Snapshot
  alias Ankole.AuthZ.Store
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  json_api do
    authorize?(false)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/principal-groups", Group do
        index(:console_list, name: "list_principal_groups", derive_sort?: false)
        post(:create, name: "create_principal_group")

        route(:post, "/computed-member-previews", :preview_computed_members,
          name: "preview_computed_principal_group_members"
        )

        get(:read, route: "/:name", name: "get_principal_group")
        patch(:update, route: "/:name", name: "update_principal_group")
        delete(:delete_operator_group, route: "/:name", name: "delete_principal_group")
        route(:get, "/:name/members", :list_members, name: "list_principal_group_members")

        route(:put, "/:name/members/:principal_uid", :add_member,
          name: "add_principal_group_member"
        )

        route(:delete, "/:name/members/:principal_uid", :remove_member,
          name: "remove_principal_group_member"
        )
      end

      base_route "/principal-groups/:name/grants", Grant do
        index(:of_group, name: "list_principal_group_grants", derive_sort?: false)
      end

      base_route "/principals/:uid/groups", Group do
        index(:of_principal, name: "list_groups_of_principal", derive_sort?: false)
      end

      base_route "/principals/:uid/grants", Grant do
        index(:of_principal, name: "list_grants_of_principal", derive_sort?: false)
      end

      base_route "/permission-grants", Grant do
        post(:create_operator_grant, name: "create_permission_grant")
        get(:by_id, name: "get_permission_grant")
        patch(:update_operator_grant, name: "update_permission_grant")
        delete(:delete_operator_grant, name: "delete_permission_grant")
      end
    end
  end

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

  @group_conflicts %{
    built_in_group: {:conflict, "Built-in groups cannot be changed or deleted.", []},
    computed_group: {:conflict, "A computed group gets its members from its condition.", []},
    group_domain_mismatch: {:conflict, "Directory sync manages the members of this group.", []},
    group_has_grants: {:conflict, "Delete the permission grants of this group first.", []},
    last_admin_member: {:conflict, "The admin group must keep at least one member.", []},
    last_active_human_admin:
      {:conflict, "The installation must keep one active human administrator.", []},
    not_human: {:conflict, "Only active human users can join the admin group.", []},
    principal_disabled: {:conflict, "Disabled users cannot join the admin group.", []}
  }

  def administrator_recovery_required? do
    admin_group_name = Root.admin_group_name()

    members =
      Ash.Query.filter(Membership, group.name == ^admin_group_name and group.built_in == true)

    Ankole.Ash.exists?(members) and
      not Ankole.Ash.exists?(
        Ash.Query.filter(members, principal.type == :human and principal.status == :active)
      )
  end

  @doc false
  def recover_admin_in_tx(uid) do
    case Store.lock_built_in_admin_group_for_update(Root.admin_group_name()) do
      %Group{} = group ->
        active_admin_exists =
          Membership
          |> Ash.Query.filter(
            group_id == ^group.id and principal.type == :human and principal.status == :active
          )
          |> Ankole.Ash.exists?()

        with false <- active_admin_exists,
             {:ok, principal} <- Store.fetch_principal_for_update(uid),
             :ok <- Store.ensure_active_human(principal),
             {:ok, _} <- Store.insert_membership(group.id, principal.uid) do
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
    Store.fetch_group(id_or_name)
  end

  @doc """
  Resolves a Principal group selector (UUID or name) to its canonical lowercase name.
  """
  @spec resolve_group_name(String.t()) :: String.t()
  def resolve_group_name(id_or_name) when is_binary(id_or_name) do
    case Store.fetch_group(id_or_name) do
      {:ok, %Group{name: name}} -> name
      {:error, :not_found} -> id_or_name |> String.trim() |> String.downcase()
    end
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
  Lists static members of a Principal group with their Principal display fields.

  Members are ordered by Principal display name. Computed groups derive
  membership at authorization time and have no stored rows to list.
  """
  @spec list_group_members(String.t()) ::
          {:ok, [%{membership: Membership.t(), principal: Principal.t()}]}
          | {:error, :not_found | :computed_group}
  def list_group_members(id_or_name) do
    with {:ok, group} <- Store.fetch_group(id_or_name),
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
  Lists the effective members of one Principal group as Console member rows.

  A static group gives its stored members and the time each one joined. A
  computed group gives the active Principals that its condition matches now.
  """
  @spec effective_group_members(String.t()) :: {:ok, [map()]} | {:error, term()}
  def effective_group_members(id_or_name) do
    with {:ok, group} <- Store.fetch_group(id_or_name),
         do: effective_members_for_group(group)
  end

  @doc false
  @spec effective_group_members_by_name(String.t()) :: {:ok, [map()]} | {:error, term()}
  def effective_group_members_by_name(name) do
    with {:ok, group} <- Store.fetch_exact_group_by_name(name),
         do: effective_members_for_group(group)
  end

  defp effective_members_for_group(%Group{kind: :static, id: group_id}) do
    with {:ok, members} <- list_group_members(group_id),
         do: {:ok, Enum.map(members, &member_row(&1.principal, &1.membership.inserted_at))}
  end

  defp effective_members_for_group(%Group{kind: :computed, computed_condition: condition}),
    do: preview_members(condition)

  @doc """
  Gives the Console member rows of the active Principals that a computed group
  condition matches. A condition that is not valid gives an error on the
  `condition` argument.
  """
  @spec preview_members(String.t()) :: {:ok, [map()]} | {:error, term()}
  def preview_members(condition) do
    case preview_computed_group_members(condition) do
      {:ok, principals} ->
        {:ok, Enum.map(principals, &member_row(&1, nil))}

      {:error, message} when is_binary(message) ->
        {:error, Ash.Error.Changes.InvalidArgument.exception(field: :condition, message: message)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp member_row(%Principal{} = principal, member_since) do
    principal
    |> Map.take([:uid, :type, :status, :display_name, :avatar_url])
    |> Map.put(:member_since, member_since)
  end

  @doc false
  # The operator text of a refused group or membership change. A refusal that
  # conflicts with the current group or membership state is a conflict.
  def describe_group_refusal(reason), do: Map.get(@group_conflicts, reason)

  @doc """
  Lists permission grants owned by a Principal group ordered by pattern and action.
  """
  @spec list_group_grants(String.t()) :: {:ok, [Grant.t()]} | {:error, :not_found}
  def list_group_grants(id_or_name) do
    with {:ok, group} <- Store.fetch_group(id_or_name) do
      {:ok, list_ordered_grants(group_id: group.id)}
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
        |> Ankole.Ash.exists?()

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
        |> Ankole.Ash.count!()

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
  Looks up one permission grant by id.
  """
  @spec get_permission_grant(String.t()) :: {:ok, Grant.t()} | {:error, :not_found}
  def get_permission_grant(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Grant{} = grant <- Grant |> Ash.Query.filter(id == ^uuid) |> Ankole.Ash.read_one!() do
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
    Repo.transact_top_level(fn ->
      Store.add_principal_to_group(
        principal_uid,
        group_id_or_name,
        Root.admin_group_name()
      )
    end)
  end

  @doc """
  Adds a Principal to a synced static group of the expected domain
  (`:directory`, `:im_group`, or `:signal_source`).
  """
  @spec add_synced_group_member(term(), atom(), String.t()) ::
          {:ok, Membership.t()} | {:error, term()}
  def add_synced_group_member(group_id, domain, principal_uid) do
    Repo.transact_top_level(fn ->
      Store.add_synced_group_member(group_id, domain, principal_uid)
    end)
  end

  @doc """
  Removes a Principal from a synced static group of the expected domain.

  A missing membership gives `{:error, :not_found}`.
  """
  @spec remove_synced_group_member(term(), atom(), String.t()) ::
          {:ok, :deleted} | {:error, term()}
  def remove_synced_group_member(group_id, domain, principal_uid) do
    Repo.transact_top_level(fn ->
      Store.remove_synced_group_member(group_id, domain, principal_uid)
    end)
  end

  @doc """
  Removes a Principal from a static group.
  """
  @spec remove_principal_from_group(String.t(), String.t()) :: {:ok, :deleted} | {:error, term()}
  def remove_principal_from_group(principal_uid, group_id_or_name) do
    Repo.transact_top_level(fn ->
      Store.remove_principal_from_group(
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
    Repo.transact_top_level(fn -> Store.upsert_external_binding(attrs) end)
  end

  @doc """
  Returns group ids bound to a provider-scoped external group of a specific kind.
  """
  @spec external_group_ids(String.t(), atom() | String.t(), String.t()) :: [String.t()]
  def external_group_ids(provider, external_kind, external_id) do
    Store.external_group_ids(provider, external_kind, external_id)
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
    Repo.transact_top_level(fn ->
      Store.sync_external_directory_group_memberships(
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
    Store.external_directory_group_index(provider)
  end

  @doc false
  @spec replace_static_group_members(String.t(), :directory | :im_group | :signal_source, [
          String.t()
        ]) ::
          {:ok, %{synced_principal_uids: [String.t()], removed_memberships: non_neg_integer()}}
          | {:error, term()}
  def replace_static_group_members(group_id, expected_domain, principal_uids)
      when is_binary(group_id) and is_list(principal_uids) do
    Repo.transact_top_level(fn ->
      Store.replace_static_group_members(group_id, expected_domain, principal_uids)
    end)
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
    Repo.transact_top_level(fn ->
      Store.apply_static_group_member_delta(
        group_id,
        expected_domain,
        added_uids,
        removed_uids
      )
    end)
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
          Repo.transact_top_level(fn ->
            ensure_synced_group_member_in_tx(group_attrs, uid)
          end)
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
    |> Ankole.Ash.exists?()
  end

  @doc false
  def ensure_synced_group_member_in_tx(group_attrs, principal_uid) do
    with {:ok, uid} <- Principals.normalize_uid(principal_uid) do
      if synced_member?(group_attrs, uid) do
        :ok
      else
        with {:ok, group} <- Store.ensure_synced_group(group_attrs),
             {:ok, _membership} <-
               Store.add_synced_group_member(
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
  def create_permission_grant(attrs) when is_map(attrs),
    do: Repo.transact_top_level(fn -> Ankole.AuthZ.Grants.create_permission_grant(attrs) end)

  @doc """
  Inserts or updates a permission grant by its natural owner/resource/action/condition key.
  """
  @spec upsert_permission_grant(map()) :: {:ok, Grant.t()} | {:error, term()}
  def upsert_permission_grant(attrs) when is_map(attrs) do
    Repo.transact_top_level(fn -> Ankole.AuthZ.Grants.upsert_permission_grant(attrs) end)
  end

  @doc """
  Updates a permission grant by id.
  """
  @spec update_permission_grant(String.t() | Grant.t(), map()) ::
          {:ok, Grant.t()} | {:error, term()}
  def update_permission_grant(%Grant{} = grant, attrs) when is_map(attrs) do
    Repo.transact_top_level(fn ->
      Ankole.AuthZ.Grants.update_permission_grant(grant, attrs)
    end)
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
    Repo.transact_top_level(fn -> Ankole.AuthZ.Grants.delete_permission_grant(id) end)
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
  @spec root_init_admin(String.t()) :: {:ok, map()} | {:error, term()}
  def root_init_admin(principal_uid) do
    Root.root_init_admin(principal_uid)
  end

  @doc false
  @spec ensure_can_disable_principal(String.t()) :: :ok | {:error, term()}
  def ensure_can_disable_principal(principal_uid) do
    Store.ensure_can_disable_principal(principal_uid, Root.admin_group_name())
  end

  defp list_ordered_grants(owner_filter) do
    Grant
    |> Ash.Query.do_filter(owner_filter)
    |> Ash.Query.sort(resource_pattern: :asc, action: :asc)
    |> Ankole.Ash.read!()
  end
end
