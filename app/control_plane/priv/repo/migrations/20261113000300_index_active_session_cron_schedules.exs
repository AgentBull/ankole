defmodule Ankole.Repo.Migrations.IndexActiveSessionCronSchedules do
  use Ecto.Migration

  def change do
    create_if_not_exists index(:cron_schedules, [:tenant_id, :owner_session_id],
                           where: "status IN ('active', 'paused') AND owner_job_id IS NULL",
                           name: :cron_schedules_tenant_active_owner_session_idx
                         )
  end
end
