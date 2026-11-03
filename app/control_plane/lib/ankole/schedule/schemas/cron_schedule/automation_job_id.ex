defmodule Ankole.Schedule.Schemas.CronSchedule.AutomationJobId do
  @moduledoc "Projects the schedule's default Job binding for Console consumers."
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _context),
    do: Ankole.Signals.source_automation_job_ids(records)
end
