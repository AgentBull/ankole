defmodule Ankole.Repo.Migrations.ReplacePendingCronEventsWithFireCronJobs do
  use Ecto.Migration

  def up do
    execute """
    DO $$
    DECLARE invalid_id uuid;
    BEGIN
      SELECT id INTO invalid_id FROM actor_cron_schedules
      WHERE status = 'active' AND next_fire_at IS NULL LIMIT 1;
      IF invalid_id IS NOT NULL THEN
        RAISE EXCEPTION 'active cron rule % has no next_fire_at', invalid_id;
      END IF;
    END $$;
    """

    execute """
    INSERT INTO oban_jobs (worker, queue, args, scheduled_at, state, max_attempts)
    SELECT 'Ankole.Schedule.Jobs.FireCron', 'default',
           jsonb_build_object('cron_schedule_id', id::text, 'tenant_id', tenant_id::text),
           next_fire_at,
           CASE WHEN next_fire_at > timezone('UTC', now()) THEN 'scheduled' ELSE 'available' END::oban_job_state,
           10
    FROM actor_cron_schedules WHERE status = 'active';
    """

    execute """
    DELETE FROM oban_jobs WHERE worker = 'Ankole.SignalsGateway.ActorRuntime.Jobs.FireScheduledEvent'
      AND state IN ('available', 'scheduled', 'retryable')
      AND args->>'scheduled_event_id' IN (
        SELECT id::text FROM actor_scheduled_events
        WHERE kind = 'cron_fire' AND status = 'scheduled'
          AND COALESCE(wake_payload->>'trigger', 'scheduled') = 'scheduled'
      );
    """

    execute """
    DELETE FROM actor_scheduled_events WHERE kind = 'cron_fire' AND status = 'scheduled'
      AND COALESCE(wake_payload->>'trigger', 'scheduled') = 'scheduled';
    """

    execute """
    DO $$
    DECLARE invalid_id uuid;
    BEGIN
      SELECT rules.id INTO invalid_id FROM actor_cron_schedules AS rules
      WHERE rules.status = 'active' AND (
        SELECT count(*) FROM oban_jobs AS jobs
        WHERE jobs.worker = 'Ankole.Schedule.Jobs.FireCron'
          AND jobs.args->>'cron_schedule_id' = rules.id::text
          AND jobs.args->>'tenant_id' = rules.tenant_id::text
          AND jobs.state IN ('available', 'scheduled', 'retryable')
          AND jobs.scheduled_at = rules.next_fire_at
      ) <> 1 LIMIT 1;
      IF invalid_id IS NOT NULL THEN
        RAISE EXCEPTION 'active cron rule % does not have exactly one matching FireCron job', invalid_id;
      END IF;
    END $$;
    """

    execute "DROP INDEX actor_scheduled_events_one_live_recurring_index"

    execute "ALTER TABLE actor_scheduled_events DROP COLUMN fire_attempts, DROP COLUMN fire_claimed_at"
  end

  def down do
    raise Ecto.MigrationError,
          "Pending cron events cannot be restored. Restore the database backup."
  end
end
