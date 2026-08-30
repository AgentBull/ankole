defmodule Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobTurn do
  @moduledoc false

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.BackgroundAgentJobs.RuntimeProjection
  alias Ankole.BackgroundAgentJobs.Schemas.Job

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
end
