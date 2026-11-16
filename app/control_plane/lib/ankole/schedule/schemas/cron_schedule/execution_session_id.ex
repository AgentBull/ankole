defmodule Ankole.Schedule.Schemas.CronSchedule.ExecutionSessionId do
  @moduledoc """
  Calculates the Session ID in which a cron schedule runs.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:owner_routine_id]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      if is_binary(record.owner_routine_id),
        do: Ankole.Sessions.Key.routine(record.owner_routine_id)
    end)
  end
end
