defmodule Ankole.Schedule.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.Schedule.Schemas.ScheduledEvent do
      define(:get_scheduled_event, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_scheduled_events, action: :read)
      define(:reauthorize_scheduled_event, action: :reauthorize)
      define(:create_event_scheduled_event, action: :create_event)
      define(:schedule_event_scheduled_event, action: :schedule_event)
    end

    resource Ankole.Schedule.Schemas.CronSchedule do
      define(:get_cron_schedule, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_cron_schedules, action: :read)
      define(:create_cron_schedule, action: :create)
      define(:update_definition_cron_schedule, action: :update_definition)
      define(:schedule_fire_cron_schedule, action: :schedule_fire)
      define(:record_fire_cron_schedule, action: :record_fire)
      define(:reauthorize_cron_schedule, action: :reauthorize)
    end
  end
end
