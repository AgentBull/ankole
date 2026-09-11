defmodule AnkoleWeb.AuthController do
  @moduledoc """
  Console and OAuth login through durable, purpose-bound browser transactions.
  """
  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Ankole.AdminAuth
  alias Ankole.BrowserSessions
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.{LocalPassword, Login}
  alias Ankole.OIDC.LoginPolicy
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
    summary: "End authentication in the current browser",
    responses: [ok: {"Deleted session", "application/json", AuthSessionDeleteResponse}]
  )

  def session(conn, _params) do
    case WebSession.admin_session(conn) do
      %{"principal_uid" => uid} = session ->
        if AdminAuth.active_human_admin?(uid) do
          json(conn, %{authenticated: true, principalUID: uid, providerID: session["provider_id"]})
        else
          conn |> put_status(401) |> json(%{authenticated: false})
        end

      _ ->
        conn |> put_status(401) |> json(%{authenticated: false})
    end
  end

  def delete_session(conn, _params) do
    conn |> WebSession.clear_admin_session() |> json(%{ok: true})
  end

  def identity_providers(conn, params) do
    with {:ok, providers} <- providers_for_flow(conn, params["flow"]) do
      json(conn, %{
        identity: current_identity(conn),
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

  defp current_identity(conn) do
    case WebSession.oauth_session(conn) || WebSession.admin_session(conn) do
      %{"principal_uid" => uid, "provider_id" => provider} ->
        {:ok, principal} = Ankole.Principals.get_principal(uid)
        %{displayName: principal.display_name || uid, providerID: provider}

      _ ->
        nil
    end
  end

  defp providers_for_flow(_conn, flow) when flow in [nil, ""], do: Login.list_login_providers()

  defp providers_for_flow(conn, flow) do
    with {:ok, transaction} <- WebSession.login_transaction(conn, flow) do
      case transaction.purpose do
        :console ->
          Login.list_login_providers()

        :oauth ->
          with {:ok, client} <- Ankole.OIDC.get_active_client(transaction.request["client_id"]),
               do: LoginPolicy.providers(client, transaction.request)
      end
    end
  end

  def local_password_login(conn, params) do
    with {:ok, true} <- SetupConfig.completed?(),
         {:ok, %{status: :pending} = transaction} <-
           WebSession.login_transaction(conn, params["flow"]),
         {:ok, provider} <- LocalPassword.fetch_enabled_provider(),
         :ok <- LoginPolicy.authorize_login(transaction, provider["provider_id"]),
         {:ok, _} <-
           BrowserSessions.bind_provider(
             WebSession.browser_reference(conn),
             transaction.id,
             provider["provider_id"]
           ),
         {:ok, email} <- required_param(params, "email"),
         {:ok, password} <- required_param(params, "password"),
         {:ok, login} <- LocalPassword.authenticate(email, password) do
      complete_local_login(conn, transaction, login)
    else
      {:ok, false} -> error(conn, 409, "setup is not complete")
      {:ok, _} -> error(conn, 401, "login_expired")
      {:error, reason} -> login_error(conn, reason)
    end
  end

  defp complete_local_login(conn, transaction, login) do
    auth = %{
      "principal_uid" => login.principal_uid,
      "provider_id" => login.provider_id,
      "external_id" => login.email,
      "access_version" => login.access_version,
      "auth_time" => login.auth_time
    }

    cond do
      transaction.purpose == :console and not AdminAuth.active_human_admin?(login.principal_uid) ->
        error(conn, 403, "not_an_admin")

      login.must_change_password ->
        ticket = Map.put(auth, "credential_version", login.credential_version)

        case BrowserSessions.put_password_ticket(
               WebSession.browser_reference(conn),
               transaction.id,
               ticket
             ) do
          {:ok, _} -> json(conn, %{status: "password_change_required"})
          {:error, reason} -> login_error(conn, reason)
        end

      true ->
        finish_json_login(conn, transaction.id, auth)
    end
  end

  def local_password_change(conn, params) do
    with {:ok, %{status: :pending, password_ticket: %{} = ticket} = transaction} <-
           WebSession.login_transaction(conn, params["flow"]),
         {:ok, password} <- required_param(params, "newPassword") do
      finish_json_login(conn, transaction.id, ticket, fn ->
        case LocalPassword.complete_forced_password_change(
               ticket["principal_uid"],
               password,
               ticket["credential_version"]
             ) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end
      end)
    else
      {:ok, _} -> error(conn, 401, "change_ticket_expired")
      {:error, :login_expired} -> error(conn, 401, "change_ticket_expired")
      {:error, reason} -> login_error(conn, reason)
    end
  end

  defp finish_json_login(conn, id, auth, before_commit \\ fn -> :ok end) do
    result =
      with {:ok, transaction} <- WebSession.login_transaction(conn, id),
           :ok <- LoginPolicy.authorize_login(transaction, auth["provider_id"]),
           :ok <- LoginPolicy.completed_authentication_allowed?(auth, transaction.request),
           do: WebSession.complete_login(conn, id, auth, before_commit)

    case result do
      {:ok, conn, transaction} ->
        json(conn, %{status: "ok", returnTo: return_to(transaction)})

      {:error, reason} ->
        login_error(conn, reason)
    end
  end

  def oidc_authorization(conn, %{"provider_id" => provider_id} = params) do
    with {:ok, true} <- SetupConfig.completed?(),
         {:ok, %{status: :pending} = transaction} <-
           WebSession.login_transaction(conn, params["flow"]),
         {:ok, provider_id} <- IdentityProviders.normalize_provider_id(provider_id),
         :ok <- LoginPolicy.authorize_login(transaction, provider_id),
         state <- WebSession.opaque_token(),
         redirect_uri <- Login.oidc_redirect_uri(public_base_url(conn), provider_id),
         {:ok, authorization_url} <-
           Login.authorization_url(provider_id, redirect_uri: redirect_uri, state: state),
         {:ok, _} <-
           BrowserSessions.bind_provider(
             WebSession.browser_reference(conn),
             transaction.id,
             provider_id,
             state,
             redirect_uri
           ) do
      redirect(conn, external: authorization_url)
    else
      {:ok, false} -> error(conn, 409, "setup is not complete")
      {:ok, _} -> error(conn, 401, "login_expired")
      {:error, reason} -> login_error(conn, reason)
    end
  end

  def oidc_callback(conn, %{"provider_id" => provider_id} = params) do
    code = params["code"]
    state = params["state"]

    cond do
      not is_binary(code) or not is_binary(state) ->
        error(conn, 400, "invalid OIDC callback")

      setup_state_matches?(conn, provider_id, state) ->
        complete_setup_oidc(conn, provider_id, code)

      true ->
        complete_browser_oidc(conn, provider_id, code, state)
    end
  end

  defp complete_browser_oidc(conn, provider_id, code, state) do
    with {:ok, transaction} <-
           BrowserSessions.callback(WebSession.browser_reference(conn), provider_id, state),
         :ok <- LoginPolicy.authorize_login(transaction, provider_id),
         {:ok, login} <-
           Login.complete_oidc_login(provider_id, code, redirect_uri: transaction.redirect_uri),
         auth <- %{
           "principal_uid" => login.principal_uid,
           "provider_id" => login.provider_id,
           "external_id" => login.external_id,
           "access_version" => login.access_version,
           "auth_time" => login.auth_time
         },
         :ok <- LoginPolicy.completed_authentication_allowed?(auth, transaction.request),
         {:ok, conn, transaction} <- WebSession.complete_login(conn, transaction.id, auth) do
      redirect(conn, to: return_to(transaction))
    else
      {:error, reason} -> login_error(conn, reason)
    end
  end

  defp complete_setup_oidc(conn, provider_id, code) do
    oidc_state = WebSession.setup_oidc_state(conn)

    with {:ok, false} <- SetupConfig.completed?(),
         {:ok, login} <-
           Login.complete_oidc_login(provider_id, code, redirect_uri: oidc_state["redirect_uri"]),
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
        external_id: login.external_id,
        auth_time: login.auth_time
      })
      |> redirect(to: ~p"/console")
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

  defp return_to(%{purpose: :oauth, id: id}), do: "/oauth/authorize/resume?flow=" <> id
  defp return_to(transaction), do: WebSession.safe_return_to(transaction.request["return_to"])

  defp required_param(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp login_error(conn, {:retry_locked, seconds}),
    do: conn |> put_status(429) |> json(%{error: "retry_locked", retryAfterSeconds: seconds})

  defp login_error(conn, {:missing, key}), do: error(conn, 422, "#{key} is required")
  defp login_error(conn, :invalid_credentials), do: error(conn, 401, "invalid_credentials")
  defp login_error(conn, :no_local_provider), do: error(conn, 404, "no_local_provider")

  defp login_error(conn, reason) when reason in [:account_disabled, :human_access_revoked],
    do: error(conn, 403, "account_disabled")

  defp login_error(conn, :not_an_admin), do: error(conn, 403, "not_an_admin")

  defp login_error(conn, reason) when reason in [:login_expired, :browser_session_expired],
    do: error(conn, 401, "login_expired")

  defp login_error(conn, :password_change_not_required),
    do: error(conn, 401, "change_ticket_expired")

  defp login_error(conn, :password_too_short), do: error(conn, 422, "password_too_short")
  defp login_error(conn, reason), do: error(conn, 400, reason)

  defp public_base_url(conn) do
    URI.to_string(%URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port})
  end

  defp error(conn, status, reason) do
    conn
    |> put_status(status)
    |> json(%{error: if(is_binary(reason), do: reason, else: inspect(reason))})
  end
end
