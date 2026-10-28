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

  alias Ankole.AuthZ.Decision
  alias Ankole.AuthZ.ExternalBinding
  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.AuthZ.Root
  alias Ankole.AuthZ.Store

  json_api do
    authorize?(true)
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

  defdelegate administrator_recovery_required?(), to: Ankole.AuthZ.Recovery
  defdelegate recover_admin_in_tx(uid), to: Ankole.AuthZ.Recovery
  defdelegate restoration_review(uid), to: Ankole.AuthZ.Recovery

  defdelegate list_principal_groups(), to: Ankole.AuthZ.Groups
  defdelegate get_principal_group(id_or_name), to: Ankole.AuthZ.Groups
  defdelegate resolve_group_name(id_or_name), to: Ankole.AuthZ.Groups
  defdelegate create_principal_group(attrs), to: Ankole.AuthZ.Groups
  defdelegate update_principal_group(group, attrs), to: Ankole.AuthZ.Groups
  defdelegate list_group_members(id_or_name), to: Ankole.AuthZ.Groups
  defdelegate effective_group_members(id_or_name), to: Ankole.AuthZ.Groups
  defdelegate effective_group_members_by_name(name), to: Ankole.AuthZ.Groups
  defdelegate preview_members(condition), to: Ankole.AuthZ.Groups
  defdelegate describe_group_refusal(reason), to: Ankole.AuthZ.Groups
  defdelegate list_group_grants(id_or_name), to: Ankole.AuthZ.Groups
  defdelegate list_principal_group_memberships(principal_uid), to: Ankole.AuthZ.Groups
  defdelegate list_current_groups_for_principal(principal_uid), to: Ankole.AuthZ.Groups
  defdelegate principal_in_group?(principal_uid, group), to: Ankole.AuthZ.Groups
  defdelegate all_in_group?(principal_uids, group), to: Ankole.AuthZ.Groups
  defdelegate get_permission_grant(id), to: Ankole.AuthZ.Groups
  defdelegate preview_computed_group_members(condition), to: Ankole.AuthZ.Groups
  defdelegate add_principal_to_group(principal_uid, group_id_or_name), to: Ankole.AuthZ.Groups
  defdelegate add_synced_group_member(group_id, domain, principal_uid), to: Ankole.AuthZ.Groups
  defdelegate remove_synced_group_member(group_id, domain, principal_uid), to: Ankole.AuthZ.Groups

  defdelegate remove_principal_from_group(principal_uid, group_id_or_name),
    to: Ankole.AuthZ.Groups

  defdelegate upsert_external_binding(attrs), to: Ankole.AuthZ.Groups
  defdelegate external_group_ids(provider, external_kind, external_id), to: Ankole.AuthZ.Groups

  defdelegate sync_external_directory_group_memberships(
                provider,
                principal_uid,
                external_ids,
                opts \\ []
              ),
              to: Ankole.AuthZ.Groups

  defdelegate external_directory_group_index(provider), to: Ankole.AuthZ.Groups

  defdelegate replace_static_group_members(group_id, expected_domain, principal_uids),
    to: Ankole.AuthZ.Groups

  defdelegate apply_static_group_member_delta(
                group_id,
                expected_domain,
                added_uids,
                removed_uids
              ),
              to: Ankole.AuthZ.Groups

  defdelegate ensure_synced_group_member(group_attrs, principal_uid), to: Ankole.AuthZ.Groups

  defdelegate ensure_synced_group_member_in_tx(group_attrs, principal_uid),
    to: Ankole.AuthZ.Groups

  defdelegate create_permission_grant(attrs), to: Ankole.AuthZ.Grants, as: :create
  defdelegate upsert_permission_grant(attrs), to: Ankole.AuthZ.Grants, as: :upsert
  defdelegate update_permission_grant(id, attrs), to: Ankole.AuthZ.Grants, as: :update
  defdelegate delete_permission_grant(id), to: Ankole.AuthZ.Grants, as: :delete
  defdelegate authorize(principal_uid, resource, action, context \\ %{}), to: Decision
  defdelegate allowed?(principal_uid, resource, action, context \\ %{}), to: Decision
  defdelegate authorize_decision(principal_uid, resource, action, context \\ %{}), to: Decision

  defdelegate authorize_all_decision(principal_uid, resource, actions, context \\ %{}),
    to: Decision

  defdelegate authorize_checks(principal_uid, checks, context \\ %{}), to: Decision
  defdelegate evaluate_pod_context(principal_uid, context), to: Decision

  defdelegate authorize_locked_in_tx(actor, record, action, opts \\ []),
    to: Ankole.AuthZ.LockedAccess,
    as: :authorize_in_tx

  defdelegate site_admin?(uid), to: Root
  defdelegate site_admin_member?(uid), to: Root
  defdelegate root_init_admin(uid), to: Root
  defdelegate ensure_can_disable_principal(uid), to: Store
  defdelegate pod_admin?(uid), to: Root
  defdelegate add_pod_admin_in_tx(uid), to: Root
end
