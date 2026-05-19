defmodule BullXWeb.SetupActivationController do
  @moduledoc false

  use BullXWeb, :controller

  alias BullX.Setup.ChannelSources
  alias BullX.Setup.Projection

  def show(conn, _params) do
    case BullXWeb.SetupAuth.require_step(conn, :activate_admin) do
      {:ok, conn, projection} ->
        session = BullXWeb.SetupAuth.session_input(conn)

        conn
        |> assign(:page_title, "Activate Admin")
        |> BullXWeb.SetupAuth.assign_props(%{
          app_name: "BullX",
          step: "activate_admin",
          setup: projection,
          activation_code: session.bootstrap_activation_code_plaintext,
          command: activation_command(session.bootstrap_activation_code_plaintext),
          ready_sources: ChannelSources.status().ready_sources,
          status_path: ~p"/setup/activation/status",
          back_path: ~p"/setup/event-routing-rules"
        })
        |> render_inertia("setup/ActivateAdmin")

      {:halt, conn} ->
        conn
    end
  end

  def status(conn, _params) do
    case BullXWeb.SetupAuth.require_json_step(conn, :activate_admin) do
      {:ok, conn, _projection} ->
        session = BullXWeb.SetupAuth.session_input(conn)

        case Projection.activation_status_for_session(session) do
          :complete ->
            conn
            |> BullXWeb.SetupAuth.clear_setup_session()
            |> json(%{activated: true, redirect_to: "/"})

          :handoff_pending ->
            json(conn, %{
              activated: false,
              handoff: "pending",
              message: "admin membership handoff pending"
            })

          :not_activated ->
            json(conn, %{activated: false})

          :invalid ->
            conn
            |> BullXWeb.SetupAuth.clear_setup_session()
            |> put_status(:unauthorized)
            |> json(%{ok: false, redirect_to: "/setup/sessions/new"})
        end

      {:halt, conn} ->
        conn
    end
  end

  defp activation_command(nil), do: nil
  defp activation_command(code), do: "/preauth #{code}"
end
