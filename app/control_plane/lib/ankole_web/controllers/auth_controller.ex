defmodule AnkoleWeb.AuthController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  JSON and callback endpoints for Console and OAuth Human authentication.

  Setup, Console, and OAuth login share the external provider callback shape.
  Separate session state prevents one flow from being replayed as another.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AdminAuth
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.IdentityProviders.Login
  alias Ankole.Setup.Completion, as: SetupCompletion
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Schemas.ConsoleAPI.AuthSessionDeleteResponse
  alias AnkoleWeb.Session, as: WebSession

  tags(["Auth"])

  operation(:session, false)
  operation(:identity_providers, false)
  operation(:oidc_authorization, false)
  operation(:oidc_callback, false)
  operation(:local_password_login, false)
  operation(:local_password_change, false)

  operation(:delete_session,
    summary: "Clear the current browser admin session",
    responses: [
      ok: {"Deleted session", "application/json", AuthSessionDeleteResponse}
    ]
  )

  @doc """
  Introspects the current admin session.
  """
  def session(conn, _params) do
    case active_admin_session(conn) do
      {:ok, session} ->
        json(conn, %{
          authenticated: true,
          principalUID: session["principal_uid"],
          providerID: session["provider_id"]
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
  Lists configured login providers.
  """
  def identity_providers(conn, _params) do
    with {:ok, providers} <- Login.list_login_providers() do
      json(conn, %{
        providers:
          Enum.map(providers, fn provider ->
            %{
              providerID: provider["provider_id"],
              adapterID: provider["adapter_id"],
              pluginID: provider["plugin_id"],
              kind: provider["kind"]
            }
          end)
      })
    else
      {:error, reason} -> error(conn, 500, reason)
    end
  end

  @doc """
  Verifies a local email and password and opens the requested browser session.

  A verified account that must still change its password gets a short-lived
  change ticket instead of a session; `local_password_change/2` completes it.
  """
  def local_password_login(conn, params) do
    with {:ok, true} <- SetupConfig.completed?(),
         {:ok, purpose, return_to} <- login_context(conn, params),
         {:ok, email} <- required_param(params, "email"),
         {:ok, password} <- required_param(params, "password"),
         {:ok, login} <- LocalPassword.authenticate(email, password) do
      complete_local_password_login(conn, login, purpose, return_to)
    else
      {:ok, false} ->
        error(conn, 409, "setup is not complete")

      {:error, {:missing, key}} ->
        error(conn, 422, "#{key} is required")

      {:error, :oauth_authorization_expired} ->
        local_password_error(conn, 401, "oauth_authorization_expired")

      {:error, :no_local_provider} ->
        local_password_error(conn, 404, "no_local_provider")

      {:error, :invalid_credentials} ->
        local_password_error(conn, 401, "invalid_credentials")

      {:error, :account_disabled} ->
        local_password_error(conn, 403, "account_disabled")

      {:error, {:retry_locked, retry_after_seconds}} ->
        conn
        |> put_status(429)
        |> json(%{error: "retry_locked", retryAfterSeconds: retry_after_seconds})

      {:error, reason} ->
        error(conn, 400, reason)
    end
  end

  @doc """
  Completes a forced password change and opens the requested browser session.

  The admin check runs before the password write. The write locks the credential
  and accepts only the version that the ticket verified while a change is still
  required.
  """
  def local_password_change(conn, params) do
    with %{
           "principal_uid" => principal_uid,
           "credential_version" => credential_version
         } = ticket
         when is_integer(credential_version) <- WebSession.local_password_change(conn),
         {:ok, new_password} <- required_param(params, "newPassword"),
         :ok <- authorize_password_change(conn, ticket),
         {:ok, _credential} <-
           LocalPassword.complete_forced_password_change(
             principal_uid,
             new_password,
             credential_version
           ) do
      complete_password_change(conn, ticket)
    else
      nil ->
        local_password_error(conn, 401, "change_ticket_expired")

      %{} ->
        local_password_error(conn, 401, "change_ticket_expired")

      {:error, :not_an_admin} ->
        local_password_error(conn, 403, "not_an_admin")

      {:error, :oauth_authorization_expired} ->
        local_password_error(conn, 401, "oauth_authorization_expired")

      {:error, {:missing, key}} ->
        error(conn, 422, "#{key} is required")

      {:error, :password_too_short} ->
        local_password_error(conn, 422, "password_too_short")

      {:error, :password_change_not_required} ->
        local_password_error(conn, 401, "change_ticket_expired")

      {:error, reason} ->
        error(conn, 400, reason)
    end
  end

  defp complete_local_password_login(conn, login, purpose, return_to) do
    cond do
      purpose == :console and not AdminAuth.active_human_admin?(login.principal_uid) ->
        local_password_error(conn, 403, "not_an_admin")

      login.must_change_password ->
        conn
        |> WebSession.put_local_password_change(%{
          principal_uid: login.principal_uid,
          provider_id: login.provider_id,
          external_id: login.email,
          credential_version: login.credential_version,
          purpose: Atom.to_string(purpose),
          return_to: return_to
        })
        |> json(%{status: "password_change_required"})

      purpose == :oauth ->
        conn
        |> WebSession.clear_local_password_change()
        |> WebSession.put_oauth_session(%{
          principal_uid: login.principal_uid,
          provider_id: login.provider_id,
          external_id: login.email
        })
        |> json(%{status: "ok", returnTo: return_to})

      true ->
        conn
        |> WebSession.clear_local_password_change()
        |> WebSession.put_admin_session(%{
          principal_uid: login.principal_uid,
          provider_id: login.provider_id,
          external_id: login.email
        })
        |> json(%{status: "ok", returnTo: return_to})
    end
  end

  defp complete_password_change(conn, %{"purpose" => "oauth"} = ticket) do
    conn
    |> WebSession.clear_local_password_change()
    |> WebSession.put_oauth_session(%{
      principal_uid: ticket["principal_uid"],
      provider_id: ticket["provider_id"],
      external_id: ticket["external_id"]
    })
    |> json(%{returnTo: "/oauth/authorize/resume"})
  end

  defp complete_password_change(conn, ticket) do
    conn
    |> WebSession.clear_local_password_change()
    |> WebSession.put_admin_session(%{
      principal_uid: ticket["principal_uid"],
      provider_id: ticket["provider_id"],
      external_id: ticket["external_id"]
    })
    |> json(%{returnTo: WebSession.safe_return_to(ticket["return_to"])})
  end

  defp authorize_password_change(conn, %{"purpose" => "oauth"}) do
    if is_map(WebSession.oauth_authorization(conn)),
      do: :ok,
      else: {:error, :oauth_authorization_expired}
  end

  defp authorize_password_change(_conn, ticket) do
    if AdminAuth.active_human_admin?(ticket["principal_uid"]),
      do: :ok,
      else: {:error, :not_an_admin}
  end

  defp login_context(conn, params) do
    if params["oauth"] in [true, "true"] do
      if is_map(WebSession.oauth_authorization(conn)),
        do: {:ok, :oauth, "/oauth/authorize/resume"},
        else: {:error, :oauth_authorization_expired}
    else
      {:ok, :console, WebSession.safe_return_to(params["returnTo"])}
    end
  end

  defp required_param(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:missing, key}}
    end
  end

  defp local_password_error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{error: code})
  end

  @doc """
  Starts a normal admin OIDC login as one browser navigation.

  The response stores the pending state and redirects to the provider. This
  avoids the earlier fetch-then-navigate gap. One browser supports one pending
  admin login; a later login replaces an earlier one.
  """
  def oidc_authorization(conn, %{"provider_id" => provider_id} = params) do
    with {:ok, true} <- SetupConfig.completed?(),
         {:ok, flow, return_to} <- oidc_login_context(conn, params),
         {:ok, provider_id} <- IdentityProviders.normalize_provider_id(provider_id),
         state <- WebSession.opaque_token(),
         redirect_uri <- Login.oidc_redirect_uri(public_base_url(conn), provider_id),
         {:ok, authorization_url} <-
           Login.authorization_url(provider_id,
             redirect_uri: redirect_uri,
             state: state
           ) do
      put_oidc_login_state(conn, flow, %{
        provider_id: provider_id,
        state: state,
        redirect_uri: redirect_uri,
        return_to: return_to
      })
      |> redirect(external: authorization_url)
    else
      {:ok, false} ->
        error(conn, 409, "setup is not complete")

      {:error, :oauth_authorization_expired} ->
        error(conn, 401, "OAuth authorization expired; start again")

      {:error, reason} ->
        error(conn, 400, reason)
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

      oauth_state_matches?(conn, provider_id, state) ->
        complete_oauth_oidc(conn, provider_id, code, state)

      admin_state_matches?(conn, provider_id, state) ->
        complete_admin_oidc(conn, provider_id, code, state)

      true ->
        error(conn, 400, "OIDC login expired or was replaced; start sign-in again")
    end
  end

  defp complete_setup_oidc(conn, provider_id, code, _state) do
    oidc_state = WebSession.setup_oidc_state(conn)

    with {:ok, false} <- SetupConfig.completed?(),
         {:ok, login} <-
           Login.complete_oidc_login(provider_id, code, redirect_uri: oidc_state["redirect_uri"]),
         # The first OIDC user becomes the root admin only inside the setup flow.
         # Normal admin login below must pass the already-created AuthZ check.
         {:ok, _root} <-
           SetupCompletion.complete_with_root_admin(
             login.principal_uid,
             WebSession.setup_brain_packs(conn)
           ) do
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
           Login.complete_oidc_login(provider_id, code, redirect_uri: oidc_state["redirect_uri"]),
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

  defp complete_oauth_oidc(conn, provider_id, code, _state) do
    oidc_state = WebSession.oauth_oidc_state(conn)

    with authorization when is_map(authorization) <- WebSession.oauth_authorization(conn),
         {:ok, login} <-
           Login.complete_oidc_login(provider_id, code, redirect_uri: oidc_state["redirect_uri"]) do
      conn
      |> WebSession.clear_oauth_oidc_state()
      |> WebSession.put_oauth_session(%{
        principal_uid: login.principal_uid,
        provider_id: login.provider_id,
        external_id: login.external_id
      })
      |> redirect(to: "/oauth/authorize/resume")
    else
      nil -> error(conn, 401, "OAuth authorization expired; start again")
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

  defp oauth_state_matches?(conn, provider_id, state) do
    case WebSession.oauth_oidc_state(conn) do
      %{"provider_id" => ^provider_id, "state" => ^state} -> true
      _state -> false
    end
  end

  defp oidc_login_context(conn, params) do
    if params["oauth"] in ["1", "true"] do
      if is_map(WebSession.oauth_authorization(conn)),
        do: {:ok, :oauth, "/oauth/authorize/resume"},
        else: {:error, :oauth_authorization_expired}
    else
      {:ok, :admin, WebSession.safe_return_to(params["return_to"])}
    end
  end

  defp put_oidc_login_state(conn, :oauth, attrs),
    do: WebSession.put_oauth_oidc_state(conn, attrs)

  defp put_oidc_login_state(conn, :admin, attrs),
    do: WebSession.put_admin_oidc_state(conn, attrs)

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

  defp message(value) when is_binary(value), do: value
  defp message(value), do: inspect(value)
end
