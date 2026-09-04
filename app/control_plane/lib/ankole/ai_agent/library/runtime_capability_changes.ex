defmodule Ankole.AIAgent.Library.RuntimeCapabilityChanges do
  @moduledoc """
  Sends effective Skill disable events to active BackgroundAgentJob turns.

  PostgreSQL capability state changes first. This module then sends a best-effort
  runtime hint. The hint does not replace credential revocation or a Job stop.
  A route that cannot receive the hint is marked unusable, like any other turn
  control.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Library
  alias Ankole.BackgroundAgentJobs
  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.TurnControl

  @type capability :: {:agent_plugin, String.t()} | {:skill, String.t()}

  @spec notify_global(capability(), keyword()) :: :ok
  def notify_global(capability, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo
    |> active_agent_uids()
    |> Enum.each(&notify_agent(&1, capability, opts))

    :ok
  end

  @spec notify_agent(String.t(), capability(), keyword()) :: :ok
  def notify_agent(agent_uid, capability, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    capabilities =
      case Keyword.get(opts, :capabilities) do
        %{} = current -> {:ok, current}
        _value -> Library.capabilities_for_agent(agent_uid, repo: repo)
      end

    case capabilities do
      {:ok, current} ->
        current
        |> disabled_skill_names(capability)
        |> dispatch(repo, agent_uid)

      {:error, reason} ->
        Logging.warning(
          "agent_library.skill_disable_resolution_failed",
          "active Job Skill disable resolution failed",
          %{agent_uid: agent_uid, reason: inspect(reason)}
        )
    end

    :ok
  end

  @doc false
  def disabled_skill_names(capabilities, {:skill, skill_id}) when is_map(capabilities) do
    capabilities
    |> all_skills()
    |> Enum.find(&(&1["id"] == skill_id))
    |> case do
      %{"effective_enabled" => false, "name" => name} when is_binary(name) -> [name]
      _skill -> []
    end
  end

  def disabled_skill_names(capabilities, {:agent_plugin, agent_plugin_id})
      when is_map(capabilities) do
    capabilities
    |> Map.get("agent_plugins", [])
    |> Enum.find(&(&1["id"] == agent_plugin_id))
    |> case do
      %{"effective_enabled" => false, "skills" => skills} when is_list(skills) ->
        skills
        |> Enum.flat_map(fn
          %{"name" => name} when is_binary(name) and name != "" -> [name]
          _skill -> []
        end)
        |> Enum.uniq()
        |> Enum.sort()

      _agent_plugin ->
        []
    end
  end

  def disabled_skill_names(_capabilities, _capability), do: []

  defp active_agent_uids(repo) do
    ActorEventDelivery
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> where(
      [delivery],
      like(delivery.session_id, ^"#{BackgroundAgentJobs.job_session_prefix()}%")
    )
    |> select([delivery], delivery.agent_uid)
    |> distinct(true)
    |> repo.all()
  end

  defp dispatch([], _repo, _agent_uid), do: :ok

  defp dispatch(skill_names, repo, agent_uid) do
    repo
    |> active_deliveries(agent_uid)
    |> TurnControl.collect(:skill_disabled, nil, payload: %{"skill_names" => skill_names})
    |> TurnControl.dispatch()

    :ok
  end

  defp active_deliveries(repo, agent_uid) do
    ActorEventDelivery
    |> where([delivery], delivery.agent_uid == ^agent_uid)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> where(
      [delivery],
      like(delivery.session_id, ^"#{BackgroundAgentJobs.job_session_prefix()}%")
    )
    |> repo.all()
  end

  defp all_skills(capabilities) do
    standalone = Map.get(capabilities, "skills", [])

    plugin_skills =
      capabilities
      |> Map.get("agent_plugins", [])
      |> Enum.flat_map(&Map.get(&1, "skills", []))

    standalone ++ plugin_skills
  end
end
