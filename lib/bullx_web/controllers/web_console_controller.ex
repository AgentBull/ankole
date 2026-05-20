defmodule BullXWeb.WebConsoleController do
  @moduledoc """
  Serves the authenticated web console.

  `index/2` renders the SPA shell for `/console` and every nested client route
  (deep links and reloads land here too). `session/2` is the single bootstrap
  endpoint the SPA calls to learn who the signed-in principal is; all other
  data is fetched by the client from dedicated JSON endpoints.
  """

  use BullXWeb, :controller

  def index(conn, _params) do
    render(conn, :index)
  end

  def session(conn, _params) do
    json(conn, %{principal: principal_view(conn.assigns.current_principal)})
  end

  defp principal_view(principal) do
    %{
      id: principal.id,
      uid: principal.uid,
      display_name: principal.display_name,
      type: principal.type,
      status: principal.status,
      avatar_url: principal.avatar_url
    }
  end
end
