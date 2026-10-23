defmodule Ankole.AutomationJobs.Schemas.Job.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AutomationJobs.Schemas.Job`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:create_job, input, _context) do
    Ankole.Repo
    |> Ankole.AutomationJobs.create_job_in_tx(input.arguments.attrs)
    |> Ankole.Errors.wrap()
  end

  defp action(:cancel_job, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.AutomationJobs.cancel_job_in_tx(
      args.agent_uid,
      args.owner_session_id,
      args.job_id,
      args.now
    )
    |> Ankole.Errors.wrap()
  end
end
