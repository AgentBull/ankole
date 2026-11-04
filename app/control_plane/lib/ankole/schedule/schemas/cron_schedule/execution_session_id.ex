defmodule Ankole.Schedule.Schemas.CronSchedule.ExecutionSessionId do
  @moduledoc """
  Calculates the Session ID in which a cron schedule runs.
  """
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _context),
    do:
      Enum.map(records, fn record ->
        if is_nil(record.owner_job_id), do: Ankole.Schedule.Cron.execution_session_id(record.id)
      end)
end
