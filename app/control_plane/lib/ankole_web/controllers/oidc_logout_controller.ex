defmodule AnkoleWeb.OIDCLogoutController do
  @moduledoc false
  use AnkoleWeb, :controller
  alias Ankole.OIDC.{Logout, RPLogout}
  alias AnkoleWeb.Session, as: WebSession

  @request_fields ~w(id_token_hint client_id post_logout_redirect_uri state)

  def request(%{method: "POST"} = conn, params) do
    # A top-level GET recovers the SameSite cookie before confirmation. A
    # cross-site form POST must not replace an existing browser reference.
    query = URI.encode_query(Map.take(params, @request_fields))
    conn |> put_status(303) |> redirect(to: "/oauth/logout?" <> query)
  end

  def request(conn, params) do
    conn = WebSession.ensure_browser(conn)

    case RPLogout.prepare(WebSession.browser_reference(conn), params) do
      {:ok, request} -> redirect(conn, to: "/oauth/logout/confirm?request=" <> request.id)
      {:error, _} -> conn |> put_status(400) |> AnkoleWeb.SpaController.logout_error(%{})
    end
  end

  def confirmation(conn, %{"id" => id}) do
    with {:ok, request} <- RPLogout.confirmation(WebSession.browser_reference(conn), id) do
      auth = WebSession.oauth_session(conn) || WebSession.admin_session(conn)

      identity =
        case auth do
          %{"principal_uid" => uid} ->
            {:ok, principal} = Ankole.Principals.get_principal(uid)

            %{
              principalUID: uid,
              displayName: principal.display_name || uid,
              providerID: auth["provider_id"]
            }

          nil ->
            nil
        end

      client_name =
        case Ankole.OIDC.get_active_client(request.client_id) do
          {:ok, client} -> client.name
          _ -> nil
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
        conn = WebSession.clear_admin_session(conn)

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
