defmodule BullX.Setup do
  @moduledoc """
  Fresh-install setup orchestration boundary.

  Setup composes existing subsystem facades. It owns wizard projection and
  request normalization; durable facts remain in Config, Principals, AuthZ,
  LLMProvider, plugin-owned source config, AIAgent, and EventBus.
  """

  alias BullX.Setup.Projection

  @steps [:plugins, :llm_providers, :channel_sources, :ai_agents, :event_routing, :activate_admin]

  @spec steps() :: [atom()]
  def steps, do: @steps

  @spec setup_step?(term()) :: boolean()
  def setup_step?(step), do: normalize_step(step) in @steps

  @spec normalize_step(term()) :: atom() | nil
  def normalize_step(step) when step in @steps, do: step

  def normalize_step(step) when is_binary(step) do
    case step do
      "plugins" -> :plugins
      "llm_providers" -> :llm_providers
      "channel_sources" -> :channel_sources
      "ai_agents" -> :ai_agents
      "event_routing" -> :event_routing
      "activate_admin" -> :activate_admin
      _other -> nil
    end
  end

  def normalize_step(_step), do: nil

  @spec state_for_session(map()) ::
          {:missing_session | :pending | :activation_pending | :completed, map()}
  defdelegate state_for_session(session), to: Projection
end
