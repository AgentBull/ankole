defmodule Ankole.Repo.Migrations.ReconcileScheduleRecurrenceInvariants do
  use Ecto.Migration

  @scheduled_trigger "COALESCE(wake_payload->>'trigger', 'scheduled') = 'scheduled'"

  def up do
    execute("""
    UPDATE actor_cron_schedules
    SET status = 'paused',
        next_fire_at = NULL,
        updated_at = NOW()
    WHERE status = 'failed'
    """)

    execute("""
    UPDATE actor_scheduled_events AS event
    SET status = 'cancelled',
        cancelled_at = NOW(),
        last_fire_error = '{"reason":"cron_schedule_not_active"}'::jsonb,
        updated_at = NOW()
    FROM actor_cron_schedules AS schedule
    WHERE event.cron_schedule_id = schedule.id
      AND event.kind = 'cron_fire'
      AND #{@scheduled_trigger}
      AND event.status IN ('scheduled', 'firing')
      AND schedule.status IN ('paused', 'deleted')
    """)

    execute("""
    WITH ranked AS (
      SELECT event.id,
             row_number() OVER (
               PARTITION BY event.cron_schedule_id
               ORDER BY
                 (event.cron_fire_slot_at = schedule.next_fire_at) DESC,
                 event.cron_fire_slot_at ASC,
                 event.id ASC
             ) AS position
      FROM actor_scheduled_events AS event
      JOIN actor_cron_schedules AS schedule
        ON schedule.id = event.cron_schedule_id
      WHERE event.kind = 'cron_fire'
        AND #{@scheduled_trigger}
        AND event.status IN ('scheduled', 'firing')
        AND schedule.status = 'active'
    )
    UPDATE actor_scheduled_events AS event
    SET status = 'cancelled',
        cancelled_at = NOW(),
        last_fire_error = '{"reason":"duplicate_recurring_event_reconciled"}'::jsonb,
        updated_at = NOW()
    FROM ranked
    WHERE event.id = ranked.id
      AND ranked.position > 1
    """)

    execute("""
    UPDATE actor_cron_schedules AS schedule
    SET next_fire_at = live.cron_fire_slot_at,
        updated_at = NOW()
    FROM (
      SELECT cron_schedule_id, cron_fire_slot_at
      FROM actor_scheduled_events
      WHERE kind = 'cron_fire'
        AND #{@scheduled_trigger}
        AND status IN ('scheduled', 'firing')
    ) AS live
    WHERE schedule.id = live.cron_schedule_id
      AND schedule.status = 'active'
      AND schedule.next_fire_at IS DISTINCT FROM live.cron_fire_slot_at
    """)

    drop index(:actor_scheduled_events, [:cron_schedule_id, :cron_fire_slot_at],
           name: :actor_scheduled_events_cron_slot_index
         )

    create unique_index(:actor_scheduled_events, [:cron_schedule_id, :cron_fire_slot_at],
             name: :actor_scheduled_events_cron_slot_index,
             where:
               "cron_schedule_id IS NOT NULL AND kind = 'cron_fire' AND #{@scheduled_trigger} AND status <> 'cancelled'"
           )

    create unique_index(:actor_scheduled_events, [:cron_schedule_id],
             name: :actor_scheduled_events_one_live_recurring_index,
             where:
               "cron_schedule_id IS NOT NULL AND kind = 'cron_fire' AND #{@scheduled_trigger} AND status IN ('scheduled', 'firing')"
           )

    execute("""
    UPDATE actor_cron_schedules
    SET schedule = schedule - 'stagger_ms',
        updated_at = NOW()
    WHERE schedule ? 'stagger_ms'
    """)

    drop constraint(:actor_cron_schedules, :actor_cron_schedules_failure_policy_object)

    alter table(:actor_cron_schedules) do
      remove :failure_policy
    end

    drop constraint(:actor_cron_schedules, :actor_cron_schedules_status_check)

    create constraint(:actor_cron_schedules, :actor_cron_schedules_status_check,
             check: "status IN ('active', 'paused', 'deleted')"
           )
  end

  def down do
    drop constraint(:actor_cron_schedules, :actor_cron_schedules_status_check)

    create constraint(:actor_cron_schedules, :actor_cron_schedules_status_check,
             check: "status IN ('active', 'paused', 'deleted', 'failed')"
           )

    alter table(:actor_cron_schedules) do
      add :failure_policy, :map, null: false, default: %{}
    end

    create constraint(:actor_cron_schedules, :actor_cron_schedules_failure_policy_object,
             check: "jsonb_typeof(failure_policy) = 'object'"
           )

    drop index(:actor_scheduled_events, [:cron_schedule_id],
           name: :actor_scheduled_events_one_live_recurring_index
         )

    drop index(:actor_scheduled_events, [:cron_schedule_id, :cron_fire_slot_at],
           name: :actor_scheduled_events_cron_slot_index
         )

    create unique_index(:actor_scheduled_events, [:cron_schedule_id, :cron_fire_slot_at],
             name: :actor_scheduled_events_cron_slot_index,
             where: "cron_schedule_id IS NOT NULL"
           )
  end
end
