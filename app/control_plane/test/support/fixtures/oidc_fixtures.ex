defmodule Ankole.OIDCFixtures do
  @moduledoc false
  alias Ankole.{BrowserSessions, IdentityProviders, OIDC}

  def access_token(principal_uid, client_id, scope) do
    with {:ok, session} <- session(principal_uid, client_id, scope),
         do: OIDC.Tokens.mint_access(principal_uid, client_id, scope, session.id)
  end

  def session(principal_uid, client_id, scope) do
    provider_id =
      case IdentityProviders.LocalPassword.fetch_enabled_provider() do
        {:ok, provider} ->
          provider["provider_id"]

        {:error, :no_local_provider} ->
          {:ok, _} = IdentityProviders.save_provider("oidc-fixture", "local", %{}, true)
          "oidc-fixture"
      end

    {:ok, version} = Ankole.Principals.HumanAccess.current_version(principal_uid)
    {:ok, browser} = BrowserSessions.create()
    ref = BrowserSessions.reference(browser)
    {:ok, flow} = BrowserSessions.begin_login(ref, :oauth, %{})
    {:ok, _} = BrowserSessions.bind_provider(ref, flow.id, provider_id)

    {:ok, %{browser: browser}} =
      BrowserSessions.complete_login(ref, flow.id, %{
        "principal_uid" => principal_uid,
        "provider_id" => provider_id,
        "external_id" => principal_uid,
        "access_version" => version,
        "auth_time" => System.system_time(:second)
      })

    authentication = BrowserSessions.authentication(BrowserSessions.reference(browser), :oauth)
    OIDC.Sessions.ensure(client_id, authentication, scope)
  end
end
