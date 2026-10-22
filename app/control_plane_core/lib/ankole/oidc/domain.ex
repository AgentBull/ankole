defmodule Ankole.OIDC.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.OIDC.Client do
      define(:get_client, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_clients, action: :read)
      define(:create_client, action: :create_in_tx)
      define(:configure_client, action: :configure_in_tx)
      define(:rotate_secret_client, action: :rotate_secret_in_tx)
      define(:delete_client, action: :delete_in_tx)
    end

    resource Ankole.OIDC.ClientGroup do
      define(:get_client_group,
        action: :read,
        get_by: [:client_id, :group_id],
        not_found_error?: false
      )

      define(:list_client_groups, action: :read)
      define(:link_client_group, action: :link_in_tx)
      define(:unlink_client_group, action: :unlink_in_tx)
    end

    resource Ankole.OIDC.SigningKeyRecord do
      define(:get_signing_key_record, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_signing_key_records, action: :read)
      define(:initialize_signing_key_record, action: :initialize_in_tx)
    end

    resource Ankole.OIDC.AuthorizationCode do
      define(:get_authorization_code, action: :read, get_by: [:digest], not_found_error?: false)
      define(:list_authorization_codes, action: :read)
      define(:issue_authorization_code, action: :issue_in_tx)
      define(:consume_authorization_code, action: :consume_in_tx)
      define(:finalize_authorization_code, action: :finalize_in_tx)
      define(:expire_authorization_code, action: :expire_in_tx)
    end

    resource Ankole.OIDC.RefreshToken do
      define(:get_refresh_token, action: :read, get_by: [:digest], not_found_error?: false)
      define(:list_refresh_tokens, action: :read)
      define(:issue_refresh_token, action: :issue_in_tx)
      define(:consume_refresh_token, action: :consume_in_tx)
      define(:redact_successor_refresh_token, action: :redact_successor_in_tx)
      define(:remove_refresh_token, action: :remove_in_tx)
    end

    resource Ankole.OIDC.RefreshTokenFamily do
      define(:get_refresh_token_family, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_refresh_token_families, action: :read)
      define(:issue_refresh_token_family, action: :issue_in_tx)
      define(:revoke_refresh_token_family, action: :revoke_in_tx)
    end

    resource Ankole.OIDC.Session do
      define(:get_session, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_sessions, action: :read)
      define(:authorize_session, action: :authorize_in_tx)
      define(:extend_session, action: :extend_in_tx)
      define(:revoke_session, action: :revoke_in_tx)
      define(:end_session, action: :end_in_tx)
      define(:revoke_and_end_session, action: :revoke_and_end_in_tx)
      define(:expire_session, action: :expire_in_tx)
    end

    resource Ankole.OIDC.LogoutRequest do
      define(:get_logout_request, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_logout_requests, action: :read)
      define(:prepare_logout_request, action: :prepare_in_tx)
      define(:confirm_logout_request, action: :confirm_in_tx)
      define(:cancel_logout_request, action: :cancel_in_tx)
      define(:expire_logout_request, action: :expire_in_tx)
    end

    resource Ankole.OIDC.LogoutDelivery do
      define(:get_logout_delivery, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_logout_deliveries, action: :read)
      define(:enqueue_logout_delivery, action: :enqueue_in_tx)
    end
  end
end
