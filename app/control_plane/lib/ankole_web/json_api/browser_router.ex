defmodule AnkoleWeb.JSONAPI.BrowserRouter do
  @moduledoc "Setup and login actions use the browser cookie and CSRF boundary, without an administrator gate."
  use AnkoleWeb.JSONAPI.Router,
    scope: :browser,
    domains: [AnkoleWeb.BrowserAPI],
    prefix: "/api/v2/browser",
    before_dispatch: {__MODULE__, :context, []}

  def context(conn, :open_api), do: Plug.Conn.put_resp_content_type(conn, "application/json")

  def context(conn, :not_found), do: conn

  def context(conn, route) do
    if route.resource == AnkoleWeb.BrowserSetup,
      do: :ok = AnkoleWeb.Session.put_privileged_tenant()

    # Re-authentication replaces setup authority, including on a rejected attempt.
    conn =
      if route.resource == AnkoleWeb.BrowserSetup and route.route.action == :create_session,
        do: AnkoleWeb.Session.clear_setup_session(conn),
        else: conn

    Ash.PlugHelpers.set_context(conn, %{conn: conn})
  end
end
