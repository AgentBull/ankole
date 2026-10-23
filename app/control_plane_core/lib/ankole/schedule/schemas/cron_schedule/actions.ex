defmodule Ankole.Schedule.Schemas.CronSchedule.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Schedule.Schemas.CronSchedule`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:console_create, input, context) do
    Ankole.Repo
    |> Ankole.Schedule.Cron.console_create_in_tx(input.arguments, context.actor)
    |> Ankole.Errors.wrap()
  end

  defp action(:console_update, input, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Cron.console_update_in_tx(input.arguments)
    |> Ankole.Errors.wrap()
  end

  defp action(:console_pause, input, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Cron.console_pause_in_tx(input.arguments)
    |> Ankole.Errors.wrap()
  end

  defp action(:console_resume, input, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Cron.console_resume_in_tx(input.arguments)
    |> Ankole.Errors.wrap()
  end

  defp action(:console_remove, input, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Cron.console_remove_in_tx(input.arguments)
    |> Ankole.Errors.wrap()
  end

  defp action(:console_run, input, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Cron.console_run_in_tx(input.arguments)
    |> Ankole.Errors.wrap()
  end

  defp action(:create_cron_schedule, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Cron.create_cron_schedule_in_tx(args.attrs, args.opts)
    |> Ankole.Errors.wrap()
  end

  defp action(:update_cron_schedule, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Cron.update_cron_schedule_in_tx(
      args.cron_schedule_id,
      args.attrs,
      args.opts
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:pause_cron_schedule, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Cron.pause_cron_schedule_in_tx(args.cron_schedule_id, args.opts)
    |> Ankole.Errors.wrap()
  end

  defp action(:resume_cron_schedule, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Cron.resume_cron_schedule_in_tx(args.cron_schedule_id, args.opts)
    |> Ankole.Errors.wrap()
  end

  defp action(:remove_cron_schedule, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Cron.remove_cron_schedule_in_tx(args.cron_schedule_id, args.opts)
    |> Ankole.Errors.wrap()
  end

  defp action(:run_cron_schedule, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Cron.run_cron_schedule_in_tx(args.cron_schedule_id, args.opts)
    |> Ankole.Errors.wrap()
  end

  defp action(:fire_cron, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Fire.fire_cron_in_tx(args.cron_schedule_id, args.now)
    |> Ankole.Errors.wrap()
  end

  defp action(:record_fire_failure, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Fire.record_fire_failure_in_tx(
      args.cron_schedule_id,
      args.slot,
      args.reason,
      args.now
    )
    |> Ankole.Errors.wrap()
  end
end
