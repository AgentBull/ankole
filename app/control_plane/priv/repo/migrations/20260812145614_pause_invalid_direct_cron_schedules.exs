defmodule Ankole.Repo.Migrations.PauseInvalidDirectCronSchedules do
  use Ecto.Migration

  @invalid_direct_schedule """
  schedule.automation_job_id IS NULL
    AND (
      jsonb_typeof(schedule.payload->'task') IS DISTINCT FROM 'string'
      OR COALESCE(schedule.payload->>'task', '') !~ '[^[:space:]]'
    )
  """

  def up do
    Enum.each(up_sqls(), &execute/1)
  end

  def down, do: :ok

  @doc false
  def up_sqls do
    [
      """
      UPDATE actor_cron_schedules AS schedule
      SET status = 'paused',
          next_fire_at = NULL,
          updated_at = NOW()
      WHERE schedule.status = 'active'
        AND #{@invalid_direct_schedule}
      """,
      """
      UPDATE actor_scheduled_events AS event
      SET status = 'cancelled',
          cancelled_at = NOW(),
          last_fire_error = '{"reason":"cron_task_required"}'::jsonb,
          updated_at = NOW()
      FROM actor_cron_schedules AS schedule
      WHERE event.cron_schedule_id = schedule.id
        AND event.kind = 'cron_fire'
        AND event.status IN ('scheduled', 'firing')
        AND #{@invalid_direct_schedule}
      """
    ]
  end
end
