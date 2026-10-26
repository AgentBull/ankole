defmodule Ankole.BackgroundAgentJobs.Schemas.Job.Actions do
  @moduledoc """
  Runs the JSON:API generic actions of `Ankole.BackgroundAgentJobs.Schemas.Job`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:console_cancel, input, context) do
    Ankole.Errors.wrap(
      Ankole.BackgroundAgentJobs.Control.console_cancel_in_tx(
        input.arguments.id,
        context.actor.principal
      ),
      &Ankole.BackgroundAgentJobs.Control.console_rejection/1
    )
  end

  defp action(:console_complete, input, context) do
    Ankole.Errors.wrap(
      Ankole.BackgroundAgentJobs.Control.console_complete_in_tx(
        input.arguments.id,
        input.arguments.result_summary,
        context.actor.principal
      ),
      &Ankole.BackgroundAgentJobs.Control.console_rejection/1
    )
  end
end
