defmodule Ankole.Schedule.Schemas.ScheduledEvent.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Schedule.Schemas.ScheduledEvent`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:console_cancel_checkback, input, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Checkbacks.console_cancel_in_tx(input.arguments)
    |> Ankole.Errors.wrap()
  end

  defp action(:create_check_back_later, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Checkbacks.create_check_back_later_in_tx(args.attrs, args.opts)
    |> Ankole.Errors.wrap()
  end

  defp action(:update_checkback, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Checkbacks.update_checkback_in_tx(
      args.scheduled_event_id,
      args.attrs,
      args.opts
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:cancel_checkback, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Checkbacks.cancel_checkback_in_tx(args.scheduled_event_id, args.opts)
    |> Ankole.Errors.wrap()
  end

  defp action(:fire_due_event, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Fire.fire_due_event_in_tx(args.scheduled_event_id, args.opts)
    |> Ankole.Errors.wrap()
  end

  defp action(:record_fire_error, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Schedule.Fire.record_fire_error_in_tx(
      args.scheduled_event_id,
      args.reason,
      args.terminal
    )
    |> Ankole.Errors.wrap()
  end
end
