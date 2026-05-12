defmodule BullXWeb.PageController do
  use BullXWeb, :controller

  def home(conn, _params) do
    conn
    |> assign(:page_title, "BullX")
    |> assign_prop(:app_name, "BullX")
    |> render_inertia("setup/App")
  end
end
