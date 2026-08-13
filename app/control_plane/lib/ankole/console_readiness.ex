defmodule Ankole.ConsoleReadiness do
  @moduledoc """
  Builds the console readiness snapshot from deployment instance facts.

  The snapshot keeps readiness rules in the control plane, so each console
  client shows the same result without reconstructing provider, Agent, profile,
  Worker, and signal state.
  """

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.Principals
  alias Ankole.SignalsGateway

  @required_profiles ~w(primary light heavy)
  @total_core_steps 5

  @doc """
  Returns the current deployment instance readiness snapshot.
  """
  @spec snapshot() :: map()
  def snapshot do
    ready_providers = Enum.filter(ProviderConfigs.list_providers(), &ready_llm_provider?/1)
    ready_provider_ids = MapSet.new(ready_providers, &Map.fetch!(&1, "provider_id"))
    active_agents = Principals.list_active_agents()
    target = select_target_agent(active_agents, ready_provider_ids)
    missing_profiles = missing_profiles(target, ready_provider_ids)
    agent_complete = valid_agent?(target)
    profiles_complete = agent_complete and missing_profiles == []
    ready_worker_count = Enum.count(SignalsGateway.list_workers(), &(&1.status == "ready"))
    agent_uid = agent_uid(target)
    # An Agent with no bound channel receives nothing, so a Signal Binding is
    # part of a working deployment instance rather than an optional extra. The
    # question is whether the deployment instance can receive at all, not
    # whether the Agent that exemplifies the model-profile step is the bound
    # one. Those can be different Agents in a deployment instance that runs a
    # background-only Agent.
    signal_route_complete = signal_route_complete?(active_agents)

    core_steps = [
      ready_providers != [],
      agent_complete,
      profiles_complete,
      ready_worker_count > 0,
      signal_route_complete
    ]

    completed_core_steps = Enum.count(core_steps, & &1)

    %{
      ready: completed_core_steps == @total_core_steps,
      completed_core_steps: completed_core_steps,
      total_core_steps: @total_core_steps,
      provider: %{
        complete: ready_providers != [],
        provider_id: ready_providers |> List.first() |> provider_id()
      },
      agent: %{
        complete: agent_complete,
        uid: agent_uid,
        display_name: display_name(target)
      },
      model_profiles: %{
        complete: profiles_complete,
        agent_uid: agent_uid,
        missing_profiles: missing_profiles
      },
      worker: %{
        complete: ready_worker_count > 0,
        ready_count: ready_worker_count
      },
      signal_route: %{
        complete: signal_route_complete
      }
    }
  end

  defp select_target_agent(agents, ready_provider_ids) do
    Enum.find(agents, fn agent ->
      valid_agent?(agent) and missing_profiles(agent, ready_provider_ids) == []
    end) || Enum.find(agents, &valid_agent?/1) || List.first(agents)
  end

  defp ready_llm_provider?(provider) do
    is_nil(Map.get(provider, "disabled_at")) and
      "llm" in (get_in(provider, ["provider_metadata", "capabilities"]) || []) and
      Enum.any?(get_in(provider, ["credential_pool", "entries"]) || [], &ready_credential?/1)
  end

  defp ready_credential?(credential) do
    Map.get(credential, "credential_present") == true and
      is_nil(Map.get(credential, "disabled_at")) and
      Map.get(credential, "reauth_required") != true and
      Map.get(credential, "status") != "dead"
  end

  defp valid_agent?(%{principal: principal, agent: agent}) do
    present?(principal.display_name) and present?(agent.role)
  end

  defp valid_agent?(_agent), do: false

  defp missing_profiles(%{agent: agent}, ready_provider_ids) do
    models = get_in(agent.options || %{}, ["ai_agent", "models"]) || %{}

    Enum.reject(@required_profiles, fn profile ->
      case Map.get(models, profile) do
        %{} = value ->
          present?(Map.get(value, "model")) and
            present?(Map.get(value, "provider_id")) and
            MapSet.member?(ready_provider_ids, Map.get(value, "provider_id"))

        _value ->
          false
      end
    end)
  end

  defp missing_profiles(_agent, _ready_provider_ids), do: @required_profiles

  defp signal_route_complete?(active_agents) do
    active_agent_uids = MapSet.new(active_agents, & &1.principal.uid)
    {:ok, bindings} = SignalsGateway.list_bindings()

    Enum.any?(bindings, fn binding ->
      binding.enabled and is_nil(binding.unavailable_reason) and
        MapSet.member?(active_agent_uids, binding.agent_uid)
    end)
  end

  defp agent_uid(%{principal: principal}), do: principal.uid
  defp agent_uid(_agent), do: nil

  defp display_name(%{principal: principal}), do: principal.display_name
  defp display_name(_agent), do: nil

  defp provider_id(nil), do: nil
  defp provider_id(provider), do: Map.get(provider, "provider_id")

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
