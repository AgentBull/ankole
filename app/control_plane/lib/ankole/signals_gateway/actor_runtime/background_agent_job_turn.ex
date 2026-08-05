defmodule Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobTurn do
  @moduledoc false

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.BackgroundAgentJobs.RuntimeProjection
  alias Ankole.BackgroundAgentJobs.Schemas.Job

  def opts(%ActorEvent{} = input, %Job{} = job, opts) do
    base_context = Keyword.get(opts, :request_context, %{})

    context = %{
      "turn_mode" => "background_agent_job",
      "job_id" => job.id,
      "owner_session_id" => job.owner_session_id,
      "attempts" => job.attempts,
      "actor_event_type" => input.type,
      "silent_success_allowed" => true
    }

    opts =
      Keyword.merge(opts,
        kind: "background_agent_job",
        conversation: :none,
        profile: job.model_profile,
        request_context: Map.merge(base_context, context)
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
