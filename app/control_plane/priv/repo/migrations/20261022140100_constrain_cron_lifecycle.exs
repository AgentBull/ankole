defmodule Ankole.Repo.Migrations.ConstrainCronLifecycle do
  use Ecto.Migration

  def up do
    create(
      constraint(:cron_schedules, :cron_schedules_live_deadline_check,
        check: "status = 'active' OR next_fire_at IS NULL"
      )
    )
  end

  def down do
    drop(constraint(:cron_schedules, :cron_schedules_live_deadline_check))
  end
end
