defmodule Ankole.Repo.Migrations.BackfillCronFireAuthorization do
  use Ecto.Migration

  def up do
    execute """
    UPDATE actor_scheduled_events AS event
    SET authorization_kind = schedule.authorization_kind,
        human_uid = schedule.human_uid,
        human_access_version = schedule.human_access_version
    FROM actor_cron_schedules AS schedule
    WHERE event.cron_schedule_id = schedule.id
      AND event.agent_uid = schedule.agent_uid
      AND event.kind = 'cron_fire'
      AND event.status IN ('scheduled', 'failed')
      AND event.source_actor_event_id IS NULL
      AND event.authorization_kind = 'review_required'
      AND schedule.authorization_kind IN ('human', 'service')
    """
  end

  def down do
    raise Ecto.MigrationError, message: "retain the recovered cron fire authorization"
  end
end
