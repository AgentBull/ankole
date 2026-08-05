defmodule Ankole.Repo.Migrations.AddCronScheduleCompletedStatus do
  use Ecto.Migration

  # A recurring schedule with an occurrence bound ("occurrences" in its schedule
  # JSON) ends as "completed" when the bound is spent. The old constraint list
  # stays, so no existing row can fail the new check.
  def up do
    drop constraint(:actor_cron_schedules, :actor_cron_schedules_status_check)

    create constraint(:actor_cron_schedules, :actor_cron_schedules_status_check,
             check: "status IN ('active', 'paused', 'deleted', 'failed', 'completed')"
           )
  end

  def down do
    drop constraint(:actor_cron_schedules, :actor_cron_schedules_status_check)

    create constraint(:actor_cron_schedules, :actor_cron_schedules_status_check,
             check: "status IN ('active', 'paused', 'deleted', 'failed')"
           )
  end
end
