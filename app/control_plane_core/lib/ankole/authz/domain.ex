defmodule Ankole.AuthZ.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.AuthZ.Group do
      define(:get_group, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_groups, action: :read)
      define(:create_group, action: :create_in_tx)
      define(:ensure_group, action: :ensure_in_tx)
      define(:profile_group, action: :profile_in_tx)
      define(:delete_group, action: :delete_in_tx)
    end

    resource Ankole.AuthZ.Membership do
      define(:get_membership,
        action: :read,
        get_by: [:group_id, :principal_uid],
        not_found_error?: false
      )

      define(:list_memberships, action: :read)
      define(:add_membership, action: :add_in_tx)
      define(:remove_membership, action: :remove_in_tx)
    end

    resource Ankole.AuthZ.Grant do
      define(:get_grant, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_grants, action: :read)
      define(:create_grant, action: :create_in_tx)
      define(:upsert_grant, action: :upsert_in_tx)
      define(:update_grant, action: :update_in_tx)
      define(:delete_grant, action: :delete_in_tx)
    end

    resource Ankole.AuthZ.ExternalBinding do
      define(:get_external_binding,
        action: :read,
        get_by: [:provider, :external_kind, :external_id],
        not_found_error?: false
      )

      define(:list_external_bindings, action: :read)
      define(:bind_external_binding, action: :bind_in_tx)
    end
  end
end
