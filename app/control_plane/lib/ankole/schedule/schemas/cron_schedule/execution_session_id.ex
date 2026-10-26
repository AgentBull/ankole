defmodule Ankole.Schedule.Schemas.CronSchedule.ExecutionSessionId do
  @moduledoc """
  Calculates the Session ID in which a cron schedule runs.
  """
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _context),
    do: Enum.map(records, &Ankole.Schedule.Cron.execution_session_id(&1.id))
end
