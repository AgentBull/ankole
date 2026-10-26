defmodule Ankole.BrowserSessions do
  @moduledoc """
  Durable browser authentication, identity selection, and one-use login transactions.

  Each public write owns one top-level transaction (`Ankole.Repo.transact_top_level/1`).
  An `_in_tx` function runs the same step in the caller's transaction. A callback
  that a caller gives to a write runs in that transaction, so it calls only
  `_in_tx` functions.
  """
  use Ankole.Ash.Domain

  alias Ankole.BrowserSessions.{Identity, Logins, PodAccess, Revocation}

  resources do
    resource(Ankole.BrowserSessions.Session)
    resource(Ankole.BrowserSessions.Authentication)

    resource Ankole.BrowserSessions.LoginTransaction do
      define(:get_login_transaction, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_login_transactions, action: :read)
    end

    resource(Ankole.BrowserSessions.PodAuthentication)
  end

  defdelegate create(), to: Identity
  defdelegate reference(record), to: Identity
  defdelegate encode_reference(ref), to: Identity
  defdelegate decode_reference(value), to: Identity
  defdelegate get(ref), to: Identity
  defdelegate lock_browser_in_tx(ref), to: Identity
  defdelegate get_authentication(ref), to: Identity
  defdelegate authentication_evidence(id), to: Identity
  defdelegate current_reference(ref), to: Identity
  defdelegate authentication(ref, purpose), to: Identity
  defdelegate identity(ref, tenant_id), to: Identity
  defdelegate identities(ref), to: Identity
  defdelegate claim_membership(ref, tenant_id), to: PodAccess
  defdelegate accept_invitation(ref, tenant_id, id), to: PodAccess
  defdelegate activate(browser_ref, authentication_ref, tenant_id \\ nil), to: Identity
  defdelegate activate_in_tx(browser_ref, authentication_ref, tenant_id \\ nil), to: Identity
  defdelegate authorize_in_tx(authentication_ref, auth), to: Identity

  defdelegate begin_login(ref, purpose, request, opts \\ []), to: Logins
  defdelegate begin_login_in_tx(ref, purpose, request, opts \\ []), to: Logins
  defdelegate login(ref, id), to: Logins
  defdelegate transaction_csrf(ref, id), to: Logins
  defdelegate callback(ref, provider_id, state), to: Logins
  defdelegate bind_provider(ref, id, provider_id, state \\ nil, redirect_uri \\ nil), to: Logins

  defdelegate bind_provider_in_tx(ref, id, provider_id, state \\ nil, redirect_uri \\ nil),
    to: Logins

  defdelegate complete_login(ref, id, auth, before_commit \\ fn -> :ok end), to: Logins
  defdelegate complete_login_in_tx(ref, id, auth, before_commit), to: Logins
  defdelegate replace_site_credential_in_tx(ref, actor, proof), to: Logins
  defdelegate complete_site_login(ref, id, provider_id, proof), to: Logins
  defdelegate complete_site_login_in_tx(ref, id, provider_id, proof), to: Logins
  defdelegate select_authorization(ref, id, authentication_ref), to: Logins
  defdelegate select_authorization_in_tx(ref, id, authentication_ref), to: Logins
  defdelegate consume_authorization(ref, id, authentication_ref, issue), to: Logins
  defdelegate consume_authorization_in_tx(ref, id, authentication_ref, issue), to: Logins
  defdelegate consume_login(ref, id, purpose, complete), to: Logins
  defdelegate consume_login_in_tx(ref, id, purpose, complete), to: Logins

  defdelegate create_pod_access(authentication_ref, create), to: PodAccess
  defdelegate create_pod_access_in_tx(authentication_ref, create), to: PodAccess

  defdelegate revoke(browser_ref, authentication_ref), to: Revocation
  defdelegate revoke_in_tx(browser_ref, authentication_ref), to: Revocation
  defdelegate logout(ref, expected_revision \\ nil), to: Revocation
  defdelegate logout_in_tx(ref, expected_revision \\ nil), to: Revocation
  defdelegate cleanup_expired(now), to: Revocation
end
