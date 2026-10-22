defmodule Ankole.BrowserSessions.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.BrowserSessions.Session do
      define(:get_session, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_sessions, action: :read)
      define(:create_session, action: :create_in_tx)
      define(:activate_session, action: :activate_in_tx)
      define(:record_login_session, action: :record_login_in_tx)
      define(:revoke_session, action: :revoke_in_tx)
      define(:logout_session, action: :logout_in_tx)
      define(:expire_session, action: :expire_in_tx)
    end

    resource Ankole.BrowserSessions.Authentication do
      define(:get_authentication, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_authentications, action: :read)
      define(:create_authentication, action: :create_in_tx)
      define(:renew_authentication, action: :renew_in_tx)
      define(:revoke_authentication, action: :revoke_in_tx)
    end

    resource Ankole.BrowserSessions.LoginTransaction do
      define(:get_login_transaction, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_login_transactions, action: :read)
      define(:begin_login_transaction, action: :begin_in_tx)
      define(:bind_provider_login_transaction, action: :bind_provider_in_tx)
      define(:password_ticket_login_transaction, action: :password_ticket_in_tx)
      define(:bind_proof_login_transaction, action: :bind_proof_in_tx)
      define(:expire_login_transaction, action: :expire_in_tx)
    end

    resource Ankole.BrowserSessions.PodAuthentication do
      define(:get_pod_authentication,
        action: :read,
        get_by: [:authentication_id],
        not_found_error?: false
      )

      define(:list_pod_authentications, action: :read)
      define(:record_pod_authentication, action: :record_in_tx)
      define(:remove_pod_authentication, action: :remove_in_tx)
    end
  end
end
