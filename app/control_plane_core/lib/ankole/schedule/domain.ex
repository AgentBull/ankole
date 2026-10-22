defmodule Ankole.Schedule.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(Ankole.Schedule.Schemas.ScheduledEvent)
    resource(Ankole.Schedule.Schemas.CronSchedule)
  end
end
