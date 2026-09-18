defmodule Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobTurn do
  @moduledoc false

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.RuntimeProjection
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.SignalsGateway.ActorEvent

  @spec opts(ActorEvent.t(), Job.t(), keyword()) :: keyword()
  def opts(%ActorEvent{}, %Job{} = job, opts) do
    opts =
      Keyword.merge(opts,
        kind: "background_agent_job",
        conversation: :none,
        profile: job.model_profile
      )

    case job.runtime_projection do
      %{} = projection when map_size(projection) > 0 ->
        Keyword.put(
          opts,
          :turn_start_overrides,
          RuntimeProjection.turn_start_overrides(projection, agent_uid: job.agent_uid)
        )

      _missing ->
        opts
    end
  end

  @doc "Adds the persisted delivery authorization to a background-job wakeup turn."
  @spec wakeup_opts(ActorEvent.t(), keyword()) :: keyword()
  def wakeup_opts(%ActorEvent{} = event, opts) when is_list(opts) do
    request_context = Keyword.get(opts, :request_context, %{})

    Keyword.put(
      opts,
      :request_context,
      Map.put(
        request_context,
        "background_job_silent_success_allowed",
        BackgroundAgentJobs.silent_success_allowed?(event)
      )
    )
  end
end
