defmodule Ankole.AIAgent.Library.RuntimeCapabilityChanges do
  @moduledoc """
  Sends effective Skill disable events to active BackgroundAgentJob turns.

  PostgreSQL capability state changes first. This module then sends a best-effort
  runtime hint. The hint does not replace credential revocation or a Job stop.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Library
  alias Ankole.BackgroundAgentJobs
  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.SignalsGateway.ActorRuntime.TurnEnvelope
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

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
        |> dispatch(
          repo,
          agent_uid,
          Keyword.get(opts, :send, &Broker.send_mandatory/2)
        )

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

  defp dispatch([], _repo, _agent_uid, _send), do: :ok

  defp dispatch(skill_names, repo, agent_uid, send) do
    repo
    |> active_deliveries(agent_uid)
    |> Enum.uniq_by(fn delivery ->
      {delivery.transport_route || delivery.worker_id, delivery.activation_uid,
       delivery.actor_event_id_fence}
    end)
    |> Enum.each(fn delivery ->
      route = delivery.transport_route || delivery.worker_id

      envelope =
        TurnEnvelope.turn_control(TurnRef.from_delivery(delivery), "skill_disabled", %{
          "skill_names" => skill_names
        })

      case send.(route, envelope) do
        {:ok, :sent_or_queued} ->
          :ok

        {:error, reason} ->
          Logging.warning(
            "agent_library.skill_disable_send_failed",
            "active Job Skill disable event failed",
            %{agent_uid: agent_uid, route: route, reason: inspect(reason)}
          )
      end
    end)
  end

  defp active_deliveries(repo, agent_uid) do
    ActorEventDelivery
    |> where([delivery], delivery.agent_uid == ^agent_uid)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> where(
      [delivery],
      like(delivery.session_id, ^"#{BackgroundAgentJobs.job_session_prefix()}%")
    )
    |> where(
      [delivery],
      not is_nil(delivery.transport_route) or not is_nil(delivery.worker_id)
    )
    |> order_by([delivery], desc: delivery.attempt_no, desc: delivery.inserted_at)
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
