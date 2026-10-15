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
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Signals.Signal
  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.Sessions.TurnControl

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
    repo.all(from j in Job, where: j.status == "running", select: j.agent_uid, distinct: true)
  end

  defp dispatch([], _repo, _agent_uid), do: :ok

  defp dispatch(skill_names, repo, agent_uid) do
    repo.all(from j in Job, where: j.agent_uid == ^agent_uid and j.status == "running")
    |> Enum.flat_map(fn job ->
      session = Ankole.Sessions.Key.job(job.id)

      case repo.one(
             from e in Signal,
               where:
                 e.agent_uid == ^agent_uid and e.session_id == ^session and
                   e.input_state == "open" and is_nil(e.completed_at),
               order_by: e.queue_sequence,
               limit: 1
           ) do
        nil ->
          []

        event ->
          [
            %{
              turn_ref: %JobTurnRef{
                agent_uid: agent_uid,
                session_id: session,
                signal_id: event.id,
                job_id: job.id,
                attempt: job.attempts
              },
              verb: :skill_disabled,
              reason: nil,
              payload: %{"skill_names" => skill_names}
            }
          ]
      end
    end)
    |> TurnControl.dispatch()

    :ok
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
