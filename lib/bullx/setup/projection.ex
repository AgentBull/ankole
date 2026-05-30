defmodule BullX.Setup.Projection do
  @moduledoc false

  alias BullX.Principals
  alias BullX.Setup
  alias BullX.Setup.{AIAgents, ChannelSources, EventRouting, LLMProviders, Plugins}

  @setup_steps [:plugins, :llm_providers, :channel_sources, :ai_agents, :event_routing]
  @step_paths %{
    plugins: "/setup/plugins",
    llm_providers: "/setup/llm/providers",
    channel_sources: "/setup/channel-sources",
    ai_agents: "/setup/ai-agents",
    event_routing: "/setup/event-routing-rules",
    activate_admin: "/setup/activate-admin"
  }

  @spec state_for_session(map()) ::
          {:missing_session | :pending | :activation_pending | :completed, map()}
  def state_for_session(session) when is_map(session) do
    cond do
      not Principals.setup_required?() ->
        {:completed, completed_projection(session)}

      valid_session?(session) ->
        projection = pending_projection(session)

        case projection.earliest_incomplete_step do
          :activate_admin -> {:activation_pending, activation_projection(projection)}
          _step -> {:pending, projection}
        end

      true ->
        {:missing_session, %{redirect_to: "/setup/sessions/new"}}
    end
  end

  @spec step_path(atom()) :: String.t()
  def step_path(step), do: Map.fetch!(@step_paths, step)

  @spec reachable_step?(map(), atom()) :: boolean()
  def reachable_step?(%{earliest_incomplete_step: earliest}, step) do
    step_index(step) <= step_index(earliest)
  end

  def reachable_step?(_projection, _step), do: false

  @spec activation_status_for_session(map()) :: :not_activated | :complete | :invalid
  def activation_status_for_session(session) do
    cond do
      not Principals.setup_required?() -> :complete
      valid_session?(session) -> :not_activated
      true -> :invalid
    end
  end

  defp valid_session?(%{bootstrap_activation_code_hash: code_hash}) do
    Principals.bootstrap_activation_code_valid_for_hash?(code_hash)
  end

  defp valid_session?(_session), do: false

  defp pending_projection(session) do
    steps = step_statuses(session)
    earliest = earliest_incomplete_step(steps)
    requested = Setup.normalize_step(session[:setup_step])
    current = current_step(requested, earliest)

    %{
      status: :pending,
      current_step: current,
      current_path: step_path(current),
      earliest_incomplete_step: earliest,
      steps: steps,
      plugins: steps.plugins,
      llm_providers: steps.llm_providers,
      channel_sources: steps.channel_sources,
      ai_agents: steps.ai_agents,
      event_routing: steps.event_routing
    }
  end

  defp activation_projection(projection) do
    Map.merge(projection, %{
      status: :activation_pending,
      current_step: :activate_admin,
      current_path: step_path(:activate_admin),
      earliest_incomplete_step: :activate_admin
    })
  end

  defp completed_projection(session) do
    session
    |> pending_projection()
    |> Map.put(:status, :completed)
  end

  defp step_statuses(session) do
    %{
      plugins: Plugins.status(),
      llm_providers: LLMProviders.status(),
      channel_sources: ChannelSources.status(),
      ai_agents: AIAgents.status(session),
      event_routing: EventRouting.status(session)
    }
  end

  defp earliest_incomplete_step(steps) do
    Enum.find(@setup_steps, :activate_admin, fn step ->
      not get_in(steps, [step, :complete?])
    end)
  end

  defp current_step(nil, earliest), do: earliest

  defp current_step(requested, earliest) do
    case step_index(requested) <= step_index(earliest) do
      true -> requested
      false -> earliest
    end
  end

  defp step_index(step), do: Enum.find_index(Setup.steps(), &(&1 == step)) || 999
end
