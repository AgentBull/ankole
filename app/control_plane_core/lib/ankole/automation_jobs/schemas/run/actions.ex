defmodule Ankole.AutomationJobs.Schemas.Run.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AutomationJobs.Schemas.Run`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:start_attempt, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.AutomationJobs.start_attempt_in_tx(args.run_id, args.now, args.ready_timeout_ms)
    |> Ankole.Errors.wrap()
  end

  defp action(:finish_attempt, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.AutomationJobs.finish_attempt_in_tx(
      args.run_id,
      args.attempt_id,
      args.result,
      args.now
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:infrastructure_failure, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.AutomationJobs.infrastructure_failure_in_tx(
      args.run_id,
      args.attempt_id,
      args.error,
      args.disposition,
      args.now
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:emit_event, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.AutomationJobs.emit_event_in_tx(
      args.agent_uid,
      args.run_id,
      args.attempt_id,
      args.payload,
      args.now
    )
    |> Ankole.Errors.wrap()
  end
end
