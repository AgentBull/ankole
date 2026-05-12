defmodule BullXWeb.SessionController do
  use BullXWeb, :controller

  def new(conn, _params) do
    conn
    |> assign(:page_title, "Sign In")
    |> assign_prop(:app_name, "BullX")
    |> render_inertia("setup/App")
  end
end
