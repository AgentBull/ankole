defmodule Ankole.BackgroundAgentJobs.Schemas.Turn.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.BackgroundAgentJobs.Schemas.Turn`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:record_from_worker, input, _context) do
    Ankole.Errors.wrap(
      Ankole.BackgroundAgentJobs.Lifecycle.upsert_turn_from_worker_in_tx(
        Ankole.Repo,
        input.arguments.job_id,
        input.arguments.agent_uid,
        input.arguments.attrs,
        input.arguments.turn_ref,
        input.arguments.worker_id
      )
    )
  end
end
