defmodule AnkoleWeb.AuthController do
  @moduledoc """
  Browser authentication through durable, purpose-bound login transactions.
  """
  use AnkoleWeb, :controller

  alias Ankole.BrowserSessions
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Login
  alias Ankole.OIDC.LoginPolicy
  alias Ankole.Setup.Completion, as: SetupCompletion
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  plug :put_login_tenant when action == :oidc_authorization

  defp put_login_tenant(conn, _opts) do
    case conn.params["flow"] do
      flow when is_binary(flow) and flow != "" ->
        transaction = WebSession.login_transaction(conn, flow)

        case transaction do
          {:ok, %{tenant_id: tenant_id}} when is_binary(tenant_id) ->
            :ok = Ankole.Repo.put_tenant_id(tenant_id)

          {:ok, _} ->
            :ok

          {:error, _} ->
            :ok
        end

        assign(conn, :login_transaction, transaction)

      _ ->
        case WebSession.put_privileged_tenant() do
          :ok -> assign(conn, :login_transaction, {:error, :login_expired})
          {:error, reason} -> conn |> login_error(reason) |> halt()
        end
    end
  end

  defp login_transaction(conn), do: conn.assigns.login_transaction

  def oidc_authorization(conn, %{"provider_id" => provider_id}) do
    with {:ok, true} <- SetupConfig.completed?(),
         {:ok, %{status: :pending} = transaction} <-
           login_transaction(conn),
         {:ok, provider_id} <- IdentityProviders.normalize_provider_id(provider_id),
         :ok <- LoginPolicy.authorize_login(transaction, provider_id),
         state <- WebSession.opaque_token(),
         redirect_uri <-
           Login.oidc_redirect_uri(AnkoleWeb.Plugs.RequestHost.origin(conn), provider_id),
         {:ok, authorization_url} <-
           Login.authorization_url(
             provider_id,
             Keyword.merge(LoginPolicy.upstream_options(%{transaction | upstream_state: state}),
               redirect_uri: redirect_uri,
               state: state
             )
           ),
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
        :ok = WebSession.put_privileged_tenant()
        complete_setup_oidc(conn, provider_id, code)

      true ->
        complete_browser_oidc(conn, provider_id, code, state)
    end
  end

  defp complete_browser_oidc(conn, provider_id, code, state) do
    with {:ok, transaction} <-
           BrowserSessions.callback(WebSession.browser_reference(conn), provider_id, state),
         :ok <- Ankole.Repo.put_tenant_id(transaction.tenant_id),
         :ok <- LoginPolicy.authorize_login(transaction, provider_id),
         {:ok, login} <-
           Login.complete_oidc_login(
             provider_id,
             code,
             Keyword.put(
               LoginPolicy.upstream_options(transaction),
               :redirect_uri,
               transaction.redirect_uri
             )
           ),
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
           Login.complete_oidc_login(provider_id, code,
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

  def return_to(%{purpose: :oauth, id: id} = transaction) do
    if LoginPolicy.authorization_ready?(transaction),
      do: "/oauth/authorize/resume?flow=" <> id,
      else: "/sessions/new?oauth=1&flow=" <> id
  end

  def return_to(transaction), do: WebSession.safe_return_to(transaction.request["return_to"])

  defp login_error(conn, {:retry_locked, seconds}),
    do: conn |> put_status(429) |> json(%{error: "retry_locked", retryAfterSeconds: seconds})

  defp login_error(conn, {:retry_busy, seconds}),
    do:
      conn
      |> put_resp_header("retry-after", Integer.to_string(seconds))
      |> put_status(429)
      |> json(%{error: "retry_busy", retryAfterSeconds: seconds})

  defp login_error(conn, {:missing, key}), do: error(conn, 422, "#{key} is required")
  defp login_error(conn, :invalid_credentials), do: error(conn, 401, "invalid_credentials")
  defp login_error(conn, :no_local_provider), do: error(conn, 404, "no_local_provider")

  defp login_error(conn, reason) when reason in [:account_disabled, :human_access_revoked],
    do: error(conn, 403, "account_disabled")

  defp login_error(conn, :tenant_suspended), do: error(conn, 403, "tenant_suspended")

  defp login_error(conn, :not_an_admin), do: error(conn, 403, "not_an_admin")

  defp login_error(conn, reason) when reason in [:login_expired, :browser_session_expired],
    do: error(conn, 401, "login_expired")

  defp login_error(conn, :password_change_not_required),
    do: error(conn, 401, "change_ticket_expired")

  defp login_error(conn, :password_too_short), do: error(conn, 422, "password_too_short")
  defp login_error(conn, reason), do: error(conn, 400, reason)

  defp error(conn, status, reason) do
    conn
    |> put_status(status)
    |> json(%{error: if(is_binary(reason), do: reason, else: inspect(reason))})
  end
end
