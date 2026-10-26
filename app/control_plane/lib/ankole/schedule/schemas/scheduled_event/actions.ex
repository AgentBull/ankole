defmodule Ankole.Schedule.Schemas.ScheduledEvent.Actions do
  @moduledoc """
  Runs the JSON:API generic actions of `Ankole.Schedule.Schemas.ScheduledEvent`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(%{action: %{name: :console_cancel_checkback}} = input, _opts, _context) do
    Ankole.Schedule.Checkbacks.console_cancel_in_tx(input.arguments)
    |> Ankole.Errors.wrap()
  end
end
