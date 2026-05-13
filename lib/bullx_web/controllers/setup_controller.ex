defmodule BullXWeb.SetupController do
  use BullXWeb, :controller

  def show(conn, _params) do
    conn
    |> assign(:page_title, "Setup Placeholder")
    |> assign_prop(:app_name, "BullX")
    |> render_inertia("setup/App")
  end
end
