defmodule Ankole.Repo.Migrations.SplitCronOwnerFromExecutionSession do
  use Ecto.Migration

  @moduledoc """
  A cron schedule's stored session was both its management scope and the
  session its fires executed in. Execution now derives `cron:<schedule_id>`
  per schedule, so the stored column keeps only management ownership and is
  renamed `owner_session_id`. Pending fire rows move to the derived execution
  session; fired history keeps the session it really executed in.
  """

  def up do
    rename table(:actor_cron_schedules), :session_id, to: :owner_session_id

    execute """
    UPDATE actor_scheduled_events
    SET session_id = 'cron:' || cron_schedule_id::text
    WHERE kind = 'cron_fire'
      AND status IN ('scheduled', 'firing')
      AND cron_schedule_id IS NOT NULL
    """
  end

  def down do
    execute """
    UPDATE actor_scheduled_events AS event
    SET session_id = schedule.owner_session_id
    FROM actor_cron_schedules AS schedule
    WHERE event.kind = 'cron_fire'
      AND event.status IN ('scheduled', 'firing')
      AND event.cron_schedule_id = schedule.id
    """

    rename table(:actor_cron_schedules), :owner_session_id, to: :session_id
  end
end
