defmodule BullXWeb.SetupEventRoutingController do
  @moduledoc false

  use BullXWeb, :controller

  alias BullX.Setup.EventRouting

  def show(conn, _params) do
    case BullXWeb.SetupAuth.require_step(conn, :event_routing) do
      {:ok, conn, projection} -> render_step(conn, projection, nil)
      {:halt, conn} -> conn
    end
  end

  def save(conn, _params) do
    case BullXWeb.SetupAuth.require_step(conn, :event_routing) do
      {:ok, conn, _projection} ->
        case EventRouting.save(BullXWeb.SetupAuth.session_input(conn)) do
          {:ok, _result} ->
            conn
            |> BullXWeb.SetupAuth.put_setup_step(:activate_admin)
            |> redirect(to: ~p"/setup")

          {:error, error} ->
            conn |> put_status(:unprocessable_entity) |> render_step(%{}, error)
        end

      {:halt, conn} ->
        conn
    end
  end

  defp render_step(conn, projection, error) do
    status = event_routing_status(projection, conn)

    conn
    |> assign(:page_title, "Setup Event Routing")
    |> BullXWeb.SetupAuth.assign_props(%{
      app_name: "BullX",
      step: "event_routing",
      setup: projection,
      routing: status,
      form_action: ~p"/setup/event-routing-rules",
      back_path: ~p"/setup/ai-agents",
      error: error
    })
    |> render_inertia("setup/event-routing/App")
  end

  defp event_routing_status(%{event_routing: status}, _conn), do: status

  defp event_routing_status(_projection, conn) do
    EventRouting.status(BullXWeb.SetupAuth.session_input(conn))
  end
end
