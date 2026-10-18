defmodule AnkoleWeb.OIDCLogoutController do
  @moduledoc false
  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias AnkoleWeb.Schemas.InternalAPI

  operation(:request, false)
  operation(:confirm, false)
  alias Ankole.OIDC.Logout
  alias Ankole.OIDC.RPLogout
  alias AnkoleWeb.Session, as: WebSession

  @request_fields ~w(id_token_hint client_id post_logout_redirect_uri state)

  def request(%{method: "POST"} = conn, params) do
    # A top-level GET recovers the SameSite cookie before confirmation. A
    # cross-site form POST must not replace an existing browser reference.
    params = Map.take(params, @request_fields)

    if Enum.all?(params, fn {_field, value} -> is_binary(value) end) do
      query = URI.encode_query(params)
      conn |> put_status(303) |> redirect(to: "/oauth/logout?" <> query)
    else
      conn |> put_status(400) |> AnkoleWeb.SpaController.logout_error(%{})
    end
  end

  def request(conn, params) do
    conn = WebSession.ensure_browser(conn)

    case RPLogout.prepare(WebSession.browser_reference(conn), params) do
      {:ok, request} -> redirect(conn, to: "/oauth/logout/confirm?request=" <> request.id)
      {:error, _} -> conn |> put_status(400) |> AnkoleWeb.SpaController.logout_error(%{})
    end
  end

  operation(:confirmation,
    operation_id: "logoutConfirmation",
    summary: "logoutConfirmation",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Success", "application/json", InternalAPI.LogoutConfirmation},
      401 => {"Error", "application/json", InternalAPI.InternalError}
    }
  )

  def confirmation(conn, %{"id" => id}) do
    with {:ok, request} <-
           Ankole.Repo.across_tenants(fn ->
             RPLogout.confirmation(WebSession.browser_reference(conn), id)
           end),
         :ok <- Ankole.Repo.put_tenant_id(request.tenant_id) do
      auth = WebSession.oauth_session(conn) || WebSession.admin_session(conn)

      identity =
        case auth do
          %{"principal_uid" => uid} ->
            identity =
              with {:ok, tenant_id} <- Ankole.Principals.resolve_tenant(uid),
                   do:
                     Ankole.Repo.with_tenant(tenant_id, fn ->
                       Ankole.Principals.get_principal(uid)
                     end)

            case identity do
              {:ok, principal} ->
                %{
                  principalUID: uid,
                  displayName: principal.display_name || uid,
                  providerID: auth["provider_id"]
                }

              {:error, :not_found} ->
                nil
            end

          nil ->
            nil
        end

      client_name =
        if request.client_id do
          case Ankole.OIDC.get_active_client(request.client_id) do
            {:ok, client} -> client.name
            _ -> nil
          end
        end

      json(conn, %{identity: identity, clientName: client_name})
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "logout_request_expired"})
    end
  end

  def confirm(conn, %{"request" => id, "action" => "cancel"}) do
    case RPLogout.cancel(WebSession.browser_reference(conn), id) do
      {:ok, _} -> redirect(conn, to: "/sessions/logged-out?cancelled=1")
      {:error, _} -> conn |> put_status(409) |> AnkoleWeb.SpaController.logout_error(%{})
    end
  end

  def confirm(conn, %{"request" => id, "action" => "confirm"}) do
    case RPLogout.confirm(WebSession.browser_reference(conn), id) do
      {:ok, %{request: request, browser: browser}} ->
        Logout.deliver_browser(browser.id)
        conn = WebSession.clear_authentication_cookies(conn)

        case RPLogout.redirect_uri(request) do
          nil -> redirect(conn, to: "/sessions/logged-out")
          uri -> redirect(conn, external: uri)
        end

      {:error, _} ->
        conn |> put_status(409) |> AnkoleWeb.SpaController.logout_error(%{})
    end
  end

  def confirm(conn, _), do: conn |> put_status(400) |> AnkoleWeb.SpaController.logout_error(%{})
end
