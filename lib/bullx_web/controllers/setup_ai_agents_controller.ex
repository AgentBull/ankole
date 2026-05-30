defmodule BullXWeb.SetupAIAgentsController do
  @moduledoc false

  use BullXWeb, :controller

  alias BullX.Setup.AIAgents

  def show(conn, _params) do
    case BullXWeb.SetupAuth.require_step(conn, :ai_agents) do
      {:ok, conn, projection} -> render_step(conn, projection, nil)
      {:halt, conn} -> conn
    end
  end

  def save(conn, params) do
    case BullXWeb.SetupAuth.require_step(conn, :ai_agents) do
      {:ok, conn, _projection} ->
        session = BullXWeb.SetupAuth.session_input(conn)

        case AIAgents.save(params["agent"] || params, session) do
          {:ok, %{agent: %{principal_uid: principal_uid}}} ->
            conn
            |> BullXWeb.SetupAuth.put_setup_agent(principal_uid)
            |> BullXWeb.SetupAuth.put_setup_step(:event_routing)
            |> redirect(to: ~p"/setup")

          {:error, error} ->
            conn |> put_status(:unprocessable_entity) |> render_step(%{}, error)
        end

      {:halt, conn} ->
        conn
    end
  end

  defp render_step(conn, projection, error) do
    status = ai_agents_status(projection, conn)
    llm_providers = llm_providers_status(projection)

    conn
    |> assign(:page_title, "Setup AIAgent")
    |> BullXWeb.SetupAuth.assign_props(%{
      app_name: "BullX",
      step: "ai_agents",
      setup: projection,
      agents: status.agents,
      selected_agent: status.selected_agent,
      default_soul: AIAgents.default_soul(),
      groups: status.groups,
      acl_preview: status.acl_preview,
      llm_providers: llm_providers.providers,
      provider_models: BullX.LLM.ModelRegistry.public_provider_models(),
      models_path: ~p"/setup/llm/models",
      reasoning_efforts: BullX.AIAgent.Profile.reasoning_efforts() |> Enum.map(&Atom.to_string/1),
      form_action: ~p"/setup/ai-agents",
      back_path: ~p"/setup/channel-sources",
      error: error
    })
    |> render_inertia("setup/ai-agents/App")
  end

  defp ai_agents_status(%{ai_agents: status}, _conn), do: status

  defp ai_agents_status(_projection, conn) do
    AIAgents.status(BullXWeb.SetupAuth.session_input(conn))
  end

  defp llm_providers_status(%{llm_providers: status}), do: status
  defp llm_providers_status(_projection), do: BullX.Setup.LLMProviders.status()
end
