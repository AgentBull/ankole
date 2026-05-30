defmodule BullXWeb.SetupPluginsController do
  @moduledoc false

  use BullXWeb, :controller

  alias BullX.Setup.Plugins

  def show(conn, _params) do
    case BullXWeb.SetupAuth.require_step(conn, :plugins) do
      {:ok, conn, projection} -> render_step(conn, projection)
      {:halt, conn} -> conn
    end
  end

  def update(conn, %{"plugins" => plugin_ids}) do
    case BullXWeb.SetupAuth.require_step(conn, :plugins) do
      {:ok, conn, _projection} ->
        case Plugins.save_enabled(plugin_ids) do
          :ok ->
            conn
            |> maybe_advance()
            |> redirect(to: ~p"/setup")

          {:error, error} ->
            conn |> put_status(:unprocessable_entity) |> render_step(error)
        end

      {:halt, conn} ->
        conn
    end
  end

  def update(conn, _params), do: update(conn, %{"plugins" => []})

  defp maybe_advance(conn) do
    case Plugins.status().complete? do
      true -> BullXWeb.SetupAuth.put_setup_step(conn, :llm_providers)
      false -> conn
    end
  end

  defp render_step(conn, projection_or_error) do
    status = plugins_status(projection_or_error)

    conn
    |> assign(:page_title, "Setup Plugins")
    |> BullXWeb.SetupAuth.assign_props(%{
      app_name: "BullX",
      step: "plugins",
      setup: projection_or_error,
      plugins: status.discovered,
      persisted_enabled_ids: status.persisted_enabled_ids,
      runtime_enabled_ids: status.runtime_enabled_ids,
      pending_restart: status.pending_restart?,
      diff: status.diff,
      form_action: ~p"/setup/plugins"
    })
    |> render_inertia("setup/plugins/App")
  end

  defp plugins_status(%{plugins: status}), do: status
  defp plugins_status(_projection_or_error), do: Plugins.status()
end
