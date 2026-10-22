defmodule Ankole.Repo.Migrations.AddAutomationWorkerWaitStartedAt do
  use Ecto.Migration

  def change do
    alter table(:automation_job_runs) do
      add :worker_wait_started_at, :utc_datetime_usec
    end
  end
end
