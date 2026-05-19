defmodule BullXWeb.SetupLLMController do
  @moduledoc false

  use BullXWeb, :controller

  alias BullX.Setup.LLMProviders

  def show(conn, _params) do
    case BullXWeb.SetupAuth.require_step(conn, :llm_providers) do
      {:ok, conn, projection} -> render_step(conn, projection, nil)
      {:halt, conn} -> conn
    end
  end

  def save(conn, %{"providers" => providers}) do
    case BullXWeb.SetupAuth.require_step(conn, :llm_providers) do
      {:ok, conn, _projection} ->
        case LLMProviders.save_many(providers) do
          {:ok, _providers} ->
            conn
            |> BullXWeb.SetupAuth.put_setup_step(:channel_sources)
            |> redirect(to: ~p"/setup")

          {:error, error} ->
            conn |> put_status(:unprocessable_entity) |> render_step(%{}, error)
        end

      {:halt, conn} ->
        conn
    end
  end

  def save(conn, params), do: save(conn, %{"providers" => [params]})

  def check(conn, params) do
    case BullXWeb.SetupAuth.require_json_step(conn, :llm_providers) do
      {:ok, conn, _projection} ->
        case LLMProviders.check(params["provider"] || params) do
          {:ok, result} ->
            json(conn, %{ok: true, result: result})

          {:error, error} ->
            conn |> put_status(:unprocessable_entity) |> json(%{ok: false, errors: [error]})
        end

      {:halt, conn} ->
        conn
    end
  end

  defp render_step(conn, projection, error) do
    status = LLMProviders.status()

    conn
    |> assign(:page_title, "Setup LLM Providers")
    |> BullXWeb.SetupAuth.assign_props(%{
      app_name: "BullX",
      step: "llm_providers",
      setup: projection,
      providers: status.providers,
      req_llm_providers: status.req_llm_providers,
      form_action: ~p"/setup/llm/providers",
      check_path: ~p"/setup/llm/providers/check",
      error: error
    })
    |> render_inertia("setup/llm/App")
  end
end
