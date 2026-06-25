defmodule AnkoleWeb.AuthController do
  @moduledoc """
  JSON and callback endpoints for normal admin authentication.

  Setup OIDC and admin OIDC share the external provider callback shape, but they
  are kept apart by separate session state so bootstrap login cannot be replayed
  as a later admin login.
  """

  use AnkoleWeb, :controller

  alias Ankole.AdminAuth
  alias Ankole.AuthZ
  alias Ankole.IdentityProviders
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.ConsoleTokens
  alias AnkoleWeb.Session, as: WebSession

  @doc """
  Introspects the current admin session.
  """
  def session(conn, _params) do
    case active_admin_session(conn) do
      {:ok, session} ->
        json(conn, %{
          authenticated: true,
          principalUid: session["principal_uid"],
          providerId: session["provider_id"]
        })

      :error ->
        conn
        |> put_status(401)
        |> json(%{authenticated: false})
    end
  end

  @doc """
  Clears the current admin session.
  """
  def delete_session(conn, _params) do
    conn
    |> WebSession.clear_admin_session()
    |> json(%{ok: true})
  end

  @doc """
  Exchanges the browser admin session or refresh token for console bearer tokens.

  This is the bridge from the cookie world to the stateless console API. The
  custom `browser-session` grant lets the already-authenticated SPA trade its
  session cookie for short-lived JWTs (see `AnkoleWeb.ConsoleTokens`), so console
  XHRs can use Bearer auth without re-running OIDC. Multiple `oauth_token/2`
  clauses below dispatch on `grant_type`, mirroring the OAuth token endpoint shape.
  """
  def oauth_token(conn, %{"grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"}) do
    with {:ok, session} <- active_admin_session(conn),
         {:ok, token_set} <- ConsoleTokens.mint_for_session(session) do
      json(conn, token_set)
    else
      :error -> oauth_error(conn, 401, "invalid_grant", "active admin session required")
      {:error, reason} -> oauth_error(conn, 400, "server_error", reason)
    end
  end

  # Refresh still requires a live browser session: console tokens are leashed to
  # the cookie session, so signing out of the browser also kills token refresh.
  def oauth_token(conn, %{"grant_type" => "refresh_token", "refresh_token" => refresh_token})
      when is_binary(refresh_token) do
    with {:ok, session} <- active_admin_session(conn),
         {:ok, token_set} <- ConsoleTokens.refresh_for_session(refresh_token, session) do
      json(conn, token_set)
    else
      :error -> oauth_error(conn, 401, "invalid_grant", "active admin session required")
      {:error, reason} -> oauth_error(conn, 400, "invalid_grant", reason)
    end
  end

  def oauth_token(conn, %{"grant_type" => "refresh_token"}) do
    oauth_error(conn, 400, "invalid_request", "refresh_token is required")
  end

  def oauth_token(conn, %{"grant_type" => _grant_type}) do
    oauth_error(conn, 400, "unsupported_grant_type", "grant_type is not supported")
  end

  def oauth_token(conn, _params) do
    oauth_error(conn, 400, "invalid_request", "grant_type is required")
  end

  @doc """
  Lists configured login providers.
  """
  def identity_providers(conn, _params) do
    with {:ok, providers} <- IdentityProviders.list_login_providers() do
      json(conn, %{
        providers:
          Enum.map(providers, fn provider ->
            %{
              providerId: provider["provider_id"],
              adapterId: provider["adapter_id"],
              pluginId: provider["plugin_id"]
            }
          end)
      })
    else
      {:error, reason} -> error(conn, 500, reason)
    end
  end

  @doc """
  Starts a normal admin OIDC login.
  """
  def oidc_authorization(conn, %{"provider_id" => provider_id} = params) do
    return_to = WebSession.safe_return_to(params["return_to"])

    with {:ok, true} <- SetupConfig.completed?(),
         {:ok, provider_id} <- Ankole.IdentityProviders.Config.normalize_provider_id(provider_id),
         state <- WebSession.opaque_token(),
         redirect_uri <- IdentityProviders.oidc_redirect_uri(public_base_url(conn), provider_id),
         {:ok, authorization_url} <-
           IdentityProviders.authorization_url(provider_id,
             redirect_uri: redirect_uri,
             state: state
           ) do
      conn
      |> WebSession.put_admin_oidc_state(%{
        provider_id: provider_id,
        state: state,
        redirect_uri: redirect_uri,
        return_to: return_to
      })
      |> json(%{authorizationUrl: authorization_url})
    else
      {:ok, false} -> error(conn, 409, "setup is not complete")
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  @doc """
  Completes setup or normal admin OIDC login depending on the session state.

  One callback URL serves both flows. We don't trust the URL to say which flow it
  is; instead the `state` param must match a `state` we previously stashed in the
  session (setup vs admin namespace). That match is the CSRF/replay defense — a
  forged or stale `state`, or one bound to the wrong flow, falls through to the
  final clause and is rejected.
  """
  def oidc_callback(conn, %{"provider_id" => provider_id} = params) do
    code = params["code"]
    state = params["state"]

    cond do
      not is_binary(code) or not is_binary(state) ->
        error(conn, 400, "invalid OIDC callback")

      setup_state_matches?(conn, provider_id, state) ->
        complete_setup_oidc(conn, provider_id, code, state)

      admin_state_matches?(conn, provider_id, state) ->
        complete_admin_oidc(conn, provider_id, code, state)

      true ->
        error(conn, 400, "invalid OIDC state")
    end
  end

  defp complete_setup_oidc(conn, provider_id, code, _state) do
    oidc_state = WebSession.setup_oidc_state(conn)

    with {:ok, false} <- SetupConfig.completed?(),
         {:ok, login} <-
           IdentityProviders.complete_oidc_login(provider_id, code,
             redirect_uri: oidc_state["redirect_uri"]
           ),
         # The first OIDC user becomes the root admin only inside the setup flow.
         # Normal admin login below must pass the already-created AuthZ check.
         {:ok, _root} <- AuthZ.root_init_admin(login.principal_uid),
         {:ok, true} <- SetupConfig.put_completed(true),
         :ok <- SetupConfig.delete_bootstrap_activation_code() do
      conn
      |> WebSession.clear_setup_session()
      |> WebSession.put_admin_session(%{
        principal_uid: login.principal_uid,
        provider_id: login.provider_id,
        external_id: login.external_id
      })
      |> redirect(to: ~p"/console")
    else
      {:ok, true} -> error(conn, 409, "setup already completed")
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  # Unlike setup, this flow never provisions an admin. The OIDC identity must
  # already resolve to an active human admin, otherwise login is refused (403) —
  # a valid external login is not by itself authorization to reach the console.
  defp complete_admin_oidc(conn, provider_id, code, _state) do
    oidc_state = WebSession.admin_oidc_state(conn)

    with {:ok, login} <-
           IdentityProviders.complete_oidc_login(provider_id, code,
             redirect_uri: oidc_state["redirect_uri"]
           ),
         true <- AdminAuth.active_human_admin?(login.principal_uid) do
      conn
      |> WebSession.clear_admin_oidc_state()
      |> WebSession.put_admin_session(%{
        principal_uid: login.principal_uid,
        provider_id: login.provider_id,
        external_id: login.external_id
      })
      |> redirect(to: oidc_state["return_to"] || ~p"/console")
    else
      false -> error(conn, 403, "admin access required")
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  defp active_admin_session(conn) do
    case WebSession.admin_session(conn) do
      %{"principal_uid" => principal_uid} = session ->
        case AdminAuth.active_human_admin?(principal_uid) do
          true -> {:ok, session}
          false -> :error
        end

      _session ->
        :error
    end
  end

  # Both the provider and the opaque state must match what we stored, pinned — the
  # callback is only honored for the exact provider/state pair this session began.
  defp setup_state_matches?(conn, provider_id, state) do
    case WebSession.setup_oidc_state(conn) do
      %{"provider_id" => ^provider_id, "state" => ^state} -> true
      _state -> false
    end
  end

  defp admin_state_matches?(conn, provider_id, state) do
    case WebSession.admin_oidc_state(conn) do
      %{"provider_id" => ^provider_id, "state" => ^state} -> true
      _state -> false
    end
  end

  # OIDC redirect URIs must be absolute, so we rebuild this request's origin from
  # the conn. This trusts the incoming scheme/host/port — fine because the
  # endpoint sits behind a trusted proxy that normalizes them.
  defp public_base_url(conn) do
    uri = %URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port}
    URI.to_string(uri)
  end

  defp error(conn, status, reason) do
    conn
    |> put_status(status)
    |> json(%{error: message(reason)})
  end

  defp oauth_error(conn, status, code, reason) do
    conn
    |> put_status(status)
    |> json(%{error: code, error_description: message(reason)})
  end

  defp message(value) when is_binary(value), do: value
  defp message(value), do: inspect(value)
end
