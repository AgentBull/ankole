defmodule Ankole.Schedule.Schemas.CronSchedule.Actions do
  @moduledoc """
  Runs the JSON:API generic actions of `Ankole.Schedule.Schemas.CronSchedule`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:console_create, input, context) do
    Ankole.Schedule.Cron.console_create_in_tx(input.arguments, context.actor.principal)
    |> Ankole.Errors.wrap()
  end

  defp action(:console_update, input, _context) do
    Ankole.Schedule.Cron.console_update_in_tx(input.arguments)
    |> Ankole.Errors.wrap()
  end

  defp action(:console_pause, input, _context) do
    Ankole.Schedule.Cron.console_pause_in_tx(input.arguments)
    |> Ankole.Errors.wrap()
  end

  defp action(:console_resume, input, _context) do
    Ankole.Schedule.Cron.console_resume_in_tx(input.arguments)
    |> Ankole.Errors.wrap()
  end

  defp action(:console_remove, input, _context) do
    Ankole.Schedule.Cron.console_remove_in_tx(input.arguments)
    |> Ankole.Errors.wrap()
  end

  defp action(:console_run, input, _context) do
    Ankole.Schedule.Cron.console_run_in_tx(input.arguments)
    |> Ankole.Errors.wrap()
  end
end
