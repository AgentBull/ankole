defmodule BullXWeb.PageController do
  use BullXWeb, :controller

  alias BullXAccounts.User

  def home(conn, _params) do
    cond do
      BullXAccounts.setup_required?() and BullXAccounts.bootstrap_activation_code_pending?() ->
        redirect(conn, to: ~p"/setup")

      match?(%User{}, conn.assigns[:current_user]) ->
        render_authorized_home(conn, conn.assigns.current_user)

      true ->
        redirect(conn, to: ~p"/sessions/new")
    end
  end

  defp render_authorized_home(conn, %User{} = user) do
    case BullXAccounts.authorize(user, "web_console:overview", "write") do
      :ok ->
        render_control_panel(conn, user)

      {:error, :forbidden} ->
        render_no_access(conn, user)

      {:error, _reason} ->
        conn
        |> delete_session(:user_id)
        |> redirect(to: ~p"/sessions/new")
    end
  end

  defp render_control_panel(conn, user) do
    conn
    |> assign(:page_title, "Control Panel")
    |> assign_prop(:app_name, "BullX")
    |> assign_prop(:current_user, user_props(user))
    |> assign_prop(:swagger_ui_path, swagger_ui_path())
    |> render_inertia("control-panel/App")
  end

  defp render_no_access(conn, user) do
    conn
    |> assign(:page_title, "No Control Panel Access")
    |> assign_prop(:app_name, "BullX")
    |> assign_prop(:current_user, user_props(user))
    |> render_inertia("control-panel/NoAccess")
  end

  defp swagger_ui_path do
    case Application.get_env(:bullx, :dev_routes, false) do
      true -> "/dev/swaggerui"
      false -> nil
    end
  end

  defp user_props(%User{} = user) do
    %{
      id: user.id,
      display_name: user.display_name,
      email: user.email
    }
  end
end
