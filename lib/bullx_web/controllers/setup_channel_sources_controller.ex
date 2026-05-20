defmodule BullXWeb.SetupChannelSourcesController do
  @moduledoc false

  use BullXWeb, :controller

  alias BullX.Setup.ChannelSources

  def show(conn, _params) do
    case BullXWeb.SetupAuth.require_step(conn, :channel_sources) do
      {:ok, conn, projection} -> render_step(conn, projection, nil)
      {:halt, conn} -> conn
    end
  end

  def save(conn, %{"adapter_id" => adapter_id} = params) do
    case BullXWeb.SetupAuth.require_step(conn, :channel_sources) do
      {:ok, conn, _projection} ->
        case ChannelSources.save(adapter_id, params) do
          {:ok, _result} ->
            conn
            |> BullXWeb.SetupAuth.put_setup_step(:ai_agents)
            |> redirect(to: ~p"/setup")

          {:error, error} ->
            conn |> put_status(:unprocessable_entity) |> render_step(%{}, error)
        end

      {:halt, conn} ->
        conn
    end
  end

  def check(conn, %{"adapter_id" => adapter_id} = params) do
    case BullXWeb.SetupAuth.require_json_step(conn, :channel_sources) do
      {:ok, conn, _projection} ->
        case ChannelSources.check(adapter_id, params) do
          {:ok, result} ->
            json(conn, %{ok: true, result: result})

          {:error, error} ->
            conn |> put_status(:unprocessable_entity) |> json(%{ok: false, errors: [error]})
        end

      {:halt, conn} ->
        conn
    end
  end

  def generated_secret(conn, %{"adapter_id" => adapter_id, "path" => path}) do
    case BullXWeb.SetupAuth.require_json_step(conn, :channel_sources) do
      {:ok, conn, _projection} ->
        case ChannelSources.generated_secret(adapter_id, path) do
          {:ok, result} ->
            json(conn, Map.put(result, :ok, true))

          {:error, error} ->
            conn |> put_status(:unprocessable_entity) |> json(%{ok: false, errors: [error]})
        end

      {:halt, conn} ->
        conn
    end
  end

  def generated_secret(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{ok: false, errors: [%{message: "adapter_id and path are required"}]})
  end

  defp render_step(conn, projection, error) do
    status = ChannelSources.status()

    conn
    |> assign(:page_title, "Setup Channel Sources")
    |> BullXWeb.SetupAuth.assign_props(%{
      app_name: "BullX",
      step: "channel_sources",
      setup: projection,
      adapters: status.adapters,
      ready_sources: status.ready_sources,
      oidc_callback_url_template: url(~p"/sessions/oidc/__source_id__/callback"),
      form_action: ~p"/setup/channel-sources",
      check_path: ~p"/setup/channel-sources/check",
      generated_secret_path: ~p"/setup/channel-sources/generated-secret",
      back_path: ~p"/setup/llm/providers",
      error: error
    })
    |> render_inertia("setup/channel-sources/App")
  end
end
