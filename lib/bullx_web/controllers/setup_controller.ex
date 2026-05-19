defmodule BullXWeb.SetupController do
  use BullXWeb, :controller

  def show(conn, _params) do
    conn = BullXWeb.SetupAuth.put_no_store(conn)

    case BullXWeb.SetupAuth.setup_state(conn) do
      {:pending, projection} ->
        redirect(conn, to: projection.current_path)

      {:activation_pending, _projection} ->
        redirect(conn, to: ~p"/setup/activate-admin")

      {:completed, _projection} ->
        conn
        |> BullXWeb.SetupAuth.clear_setup_session()
        |> redirect(to: ~p"/")

      {:missing_session, _projection} ->
        conn
        |> BullXWeb.SetupAuth.clear_setup_session()
        |> redirect(to: ~p"/setup/sessions/new")
    end
  end
end
