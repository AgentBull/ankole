defmodule Ankole.Repo.Migrations.ConstrainCronStates do
  use Ecto.Migration

  def up, do: replace_constraint("'active', 'paused', 'deleted', 'completed'")

  def down, do: replace_constraint("'active', 'paused', 'deleted', 'failed', 'completed'")

  defp replace_constraint(states) do
    drop(constraint(:cron_schedules, :cron_schedules_status_check))

    create(
      constraint(:cron_schedules, :cron_schedules_status_check, check: "status IN (#{states})")
    )
  end
end
