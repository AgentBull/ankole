defmodule AnkoleWeb.OIDCLogoutController do
  @moduledoc false
  use AnkoleWeb, :controller

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

  def confirm(conn, %{"request" => id, "action" => "cancel"}) do
    case RPLogout.cancel(WebSession.browser_reference(conn), id) do
      {:ok, _} -> redirect(conn, to: "/sessions/logged-out?cancelled=1")
      {:error, _} -> conn |> put_status(409) |> AnkoleWeb.SpaController.logout_error(%{})
    end
  end

  def confirm(conn, %{"request" => id, "action" => "confirm"}) do
    case RPLogout.confirm(WebSession.browser_reference(conn), id) do
      {:ok, %{redirect_uri: redirect_uri, browser: browser}} ->
        Logout.deliver_browser(browser.id)
        conn = WebSession.clear_authentication_cookies(conn)

        case redirect_uri do
          nil -> redirect(conn, to: "/sessions/logged-out")
          uri -> redirect(conn, external: uri)
        end

      {:error, _} ->
        conn |> put_status(409) |> AnkoleWeb.SpaController.logout_error(%{})
    end
  end

  def confirm(conn, _), do: conn |> put_status(400) |> AnkoleWeb.SpaController.logout_error(%{})
end
