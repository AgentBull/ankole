defmodule AnkoleWeb.AuthController do
  @moduledoc """
  Browser outbound upstream OIDC authorization redirects and callbacks.
  """
  use AnkoleWeb, :controller

  alias Ankole.BrowserSessions
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Login
  alias Ankole.OIDC.{AuthorizationRequests, LoginPolicy}
  alias Ankole.Setup.Completion, as: SetupCompletion
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  def oidc_authorization(conn, %{"provider_id" => provider_id} = params) do
    now = DateTime.utc_now()

    with {:ok, true} <- SetupConfig.completed?(),
         {:ok, target} <- AnkoleWeb.BrowserAuth.resolve_login_target(conn, params),
         :ok <- ensure_upstream_target(target),
         conn = WebSession.ensure_browser(conn),
         {:ok, provider_id} <- IdentityProviders.normalize_provider_id(provider_id),
         :ok <- LoginPolicy.authorize_login(target.oauth_request || target.purpose, provider_id),
         state <- WebSession.opaque_token(),
         redirect_uri <-
           Login.oidc_redirect_uri(AnkoleWeb.Plugs.RequestHost.origin(conn), provider_id),
         upstream_opts = LoginPolicy.upstream_options(state, target.request_params, now),
         {:ok, authorization_url} <-
           Ankole.Authn.Info.run(
             Ankole.Principals.ExternalIdentity,
             :enterprise,
             :authorize,
             %{provider_id: provider_id},
             Keyword.merge(upstream_opts, redirect_uri: redirect_uri, state: state)
           ),
         {:ok, _} <-
           BrowserSessions.begin_oidc_state(WebSession.browser_reference(conn), %{
             state: state,
             provider_id: provider_id,
             purpose: target.purpose,
             mode: target.mode,
             started_revision: target.started_revision,
             redirect_uri: redirect_uri,
             return_to: target.return_to,
             prompt: target.request_params["prompt"] || [],
             invitation_id: target.invitation_id,
             expected_authentication_id: target.expected_authentication_id,
             reauthentication_principal_uid: target.reauthentication_principal_uid,
             oauth_request_id: target.oauth_request_id
           }) do
      redirect(conn, external: authorization_url)
    else
      {:ok, false} -> error(conn, 409, "setup is not complete")
      {:error, reason} -> login_error(conn, reason)
    end
  end

  defp ensure_upstream_target(%{purpose: :oauth, oauth_request: %{status: :pending}}), do: :ok
  defp ensure_upstream_target(%{purpose: :oauth}), do: {:error, :login_expired}
  defp ensure_upstream_target(%{purpose: purpose}) when purpose in [:pod, :console], do: :ok
  defp ensure_upstream_target(_), do: {:error, :identity_provider_not_allowed}

  def oidc_callback(conn, %{"provider_id" => provider_id} = params) do
    code = params["code"]
    state = params["state"]

    cond do
      not is_binary(code) or not is_binary(state) ->
        error(conn, 400, "invalid OIDC callback")

      setup_state_matches?(conn, provider_id, state) ->
        :ok = WebSession.put_privileged_tenant()
        complete_setup_oidc(conn, provider_id, code)

      true ->
        complete_browser_oidc(conn, provider_id, code, state)
    end
  end

  defp complete_browser_oidc(conn, provider_id, code, state) do
    browser_ref = WebSession.browser_reference(conn)

    with {:ok, oidc_state} <- BrowserSessions.oidc_callback(browser_ref, provider_id, state),
         :ok <- verify_callback_host(conn, oidc_state.tenant_id),
         :ok <- Ankole.Repo.put_tenant_id(oidc_state.tenant_id),
         {:ok, policy_subject, request_params} <- oidc_callback_policy(browser_ref, oidc_state),
         :ok <- LoginPolicy.authorize_login(policy_subject, provider_id),
         {:ok,
          %{
            browser: browser,
            authentication: authentication,
            oauth_request: oauth_request,
            oidc_state: consumed
          }} <-
           Ankole.Authn.Info.run(
             Ankole.Principals.ExternalIdentity,
             :enterprise,
             :callback,
             %{provider_id: provider_id, code: code},
             LoginPolicy.upstream_options(
               oidc_state.state,
               request_params,
               oidc_state.inserted_at
             )
             |> Keyword.put(:redirect_uri, oidc_state.redirect_uri)
             |> Keyword.put(:invitation_id, oidc_state.invitation_id)
             |> Keyword.put(:browser_reference, browser_ref)
             |> Keyword.put(:complete, fn login ->
               auth = %{
                 "principal_uid" => login.principal_uid,
                 "provider_id" => login.provider_id,
                 "external_id" => login.external_id,
                 "access_version" => login.access_version,
                 "auth_time" => login.auth_time
               }

               with :ok <- LoginPolicy.completed_authentication_allowed?(auth, request_params),
                    do: BrowserSessions.consume_oidc_state_in_tx(browser_ref, oidc_state.id, auth)
             end)
           ) do
      conn = WebSession.put_authentication(conn, browser, authentication)
      redirect(conn, to: callback_return_to(consumed, oauth_request))
    else
      {:error, reason} -> login_error(conn, reason)
    end
  end

  defp verify_callback_host(%{assigns: %{host_context: {:pod, host_tenant_id}}}, tenant_id)
       when host_tenant_id != tenant_id,
       do: {:error, :login_expired}

  defp verify_callback_host(_conn, _tenant_id), do: :ok

  defp oidc_callback_policy(browser_ref, %{purpose: :oauth, oauth_request_id: id}) do
    case AuthorizationRequests.get(browser_ref, id) do
      {:ok, %{status: :pending} = request} -> {:ok, request, request.request}
      {:ok, _} -> {:error, :login_expired}
      error -> error
    end
  end

  defp oidc_callback_policy(_browser_ref, oidc_state) do
    {:ok, oidc_state.purpose,
     %{
       "prompt" => oidc_state.prompt,
       "reauthenticate" => not is_nil(oidc_state.expected_authentication_id)
     }}
  end

  defp complete_setup_oidc(conn, provider_id, code) do
    oidc_state = WebSession.setup_oidc_state(conn)

    with {:ok, false} <- SetupConfig.completed?(),
         {:ok, login} <-
           Ankole.Authn.Info.run(
             Ankole.Principals.ExternalIdentity,
             :enterprise,
             :callback,
             %{provider_id: provider_id, code: code},
             redirect_uri: oidc_state["redirect_uri"],
             nonce: oidc_state["state"]
           ),
         {:ok, _root} <-
           SetupCompletion.complete_with_first_site_admin(
             login.principal_uid,
             WebSession.setup_brain_packs(conn)
           ) do
      conn
      |> WebSession.clear_setup_session()
      |> WebSession.put_admin_session(%{
        principal_uid: login.principal_uid,
        provider_id: login.provider_id,
        external_id: login.external_id,
        auth_time: login.auth_time
      })
      |> redirect(to: AnkoleWeb.SiteAdminConsole.path())
    else
      {:ok, true} -> error(conn, 409, "setup already completed")
      {:error, reason} -> login_error(conn, reason)
    end
  end

  defp setup_state_matches?(conn, provider_id, state) do
    case WebSession.setup_oidc_state(conn) do
      %{"provider_id" => ^provider_id, "state" => ^state} -> true
      _ -> false
    end
  end

  def oauth_return_to(%{id: id} = request) do
    if LoginPolicy.authorization_ready?(request),
      do: "/oauth/authorize/resume?oauth_request=" <> id,
      else: "/sessions/new?oauth_request=" <> id
  end

  defp callback_return_to(%{purpose: :oauth}, oauth_request), do: oauth_return_to(oauth_request)

  defp callback_return_to(oidc_state, _oauth_request),
    do: WebSession.safe_return_to(oidc_state.return_to)

  defp login_error(conn, {:missing, key}), do: error(conn, 422, "#{key} is required")
  defp login_error(conn, :invalid_credentials), do: error(conn, 401, "invalid_credentials")

  defp login_error(conn, reason) when reason in [:account_disabled, :human_access_revoked],
    do: error(conn, 403, "account_disabled")

  defp login_error(conn, :tenant_suspended), do: error(conn, 403, "tenant_suspended")

  defp login_error(conn, :not_an_admin), do: error(conn, 403, "not_an_admin")

  defp login_error(conn, :login_subject_mismatch), do: error(conn, 400, "login_subject_mismatch")

  defp login_error(conn, reason) when reason in [:login_expired, :browser_session_expired],
    do: error(conn, 401, "login_expired")

  defp login_error(conn, reason), do: error(conn, 400, reason)

  defp error(conn, status, reason) do
    conn
    |> put_status(status)
    |> json(%{error: if(is_binary(reason), do: reason, else: inspect(reason))})
  end
end
