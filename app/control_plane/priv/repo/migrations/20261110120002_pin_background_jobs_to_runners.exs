defmodule Ankole.Repo.Migrations.PinBackgroundJobsToRunners do
  use Ecto.Migration

  def change do
    alter table(:background_agent_jobs) do
      add :runner_id, :uuid
    end

    create index(:background_agent_jobs, [:tenant_id, :runner_id],
             where: "runner_id IS NOT NULL AND status = 'running'",
             name: :background_agent_jobs_running_runner_index
           )
  end
end
