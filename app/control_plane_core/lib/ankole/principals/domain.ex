defmodule Ankole.Principals.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.Principals.Principal do
      define(:get_principal, action: :read, get_by: [:uid], not_found_error?: false)
      define(:list_principals, action: :read)
      define(:create_principal, action: :create_in_tx)
      define(:profile_principal, action: :profile_in_tx)
      define(:enable_principal, action: :enable_in_tx)
      define(:disable_principal, action: :disable_in_tx)
      define(:revoke_human_principal, action: :revoke_human_in_tx)
      define(:delete_principal, action: :delete_in_tx)
    end

    resource Ankole.Principals.Agent do
      define(:get_agent, action: :read, get_by: [:uid], not_found_error?: false)
      define(:list_agents, action: :read)
      define(:create_agent, action: :create_in_tx)
      define(:profile_agent, action: :profile_in_tx)
      define(:options_agent, action: :options_in_tx)
    end

    resource Ankole.Principals.HumanUser do
      define(:get_human_user, action: :read, get_by: [:principal_uid], not_found_error?: false)
      define(:list_human_users, action: :read)
      define(:create_human_user, action: :create_in_tx)
      define(:profile_human_user, action: :profile_in_tx)
    end

    resource Ankole.Principals.ExternalIdentity do
      define(:get_external_identity, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_external_identities, action: :read)
      define(:bind_external_identity, action: :bind_in_tx)
      define(:observe_external_identity, action: :observe_in_tx)
    end

    resource Ankole.Principals.LocalCredential do
      define(:get_local_credential,
        action: :read,
        get_by: [:principal_uid],
        not_found_error?: false
      )

      define(:list_local_credentials, action: :read)
      define(:create_local_credential, action: :create_in_tx)
      define(:set_password_local_credential, action: :set_password_in_tx)
    end

    resource Ankole.Principals.AccessRestriction do
      define(:get_access_restriction, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_access_restrictions, action: :read)
      define(:restrict_access_restriction, action: :restrict_in_tx)
      define(:repeat_restriction_access_restriction, action: :repeat_restriction_in_tx)
      define(:verify_recovery_access_restriction, action: :verify_recovery_in_tx)
      define(:clear_access_restriction, action: :clear_in_tx)
    end

    resource Ankole.Principals.AccessEvent do
      define(:get_access_event, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_access_events, action: :read)
      define(:record_access_event, action: :record_in_tx)
      define(:record_once_access_event, action: :record_once_in_tx)
    end

    resource Ankole.Principals.MappingRequest do
      define(:get_mapping_request, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_mapping_requests, action: :read)
      define(:observe_mapping_request, action: :observe_in_tx)
      define(:delete_mapping_request, action: :delete_in_tx)
    end
  end
end
