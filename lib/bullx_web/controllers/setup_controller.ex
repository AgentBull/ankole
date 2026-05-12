defmodule BullXWeb.SetupController do
  use BullXWeb, :controller

  def show(conn, _params), do: render_setup(conn)
  def activate_owner(conn, _params), do: render_setup(conn)

  defp render_setup(conn) do
    conn
    |> assign(:page_title, "Setup")
    |> assign_prop(:app_name, "BullX")
    |> render_inertia("setup/App")
  end
end
