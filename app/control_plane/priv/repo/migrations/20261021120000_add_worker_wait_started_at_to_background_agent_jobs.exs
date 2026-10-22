defmodule Ankole.Repo.Migrations.AddWorkerWaitStartedAtToBackgroundAgentJobs do
  use Ecto.Migration

  def change do
    alter table(:background_agent_jobs) do
      add :worker_wait_started_at, :utc_datetime_usec
    end
  end
end
