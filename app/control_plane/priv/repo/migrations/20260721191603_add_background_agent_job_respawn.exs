defmodule Ankole.Repo.Migrations.AddBackgroundAgentJobRespawn do
  use Ecto.Migration

  def up do
    alter table(:background_agent_jobs) do
      add(
        :continued_from_job_id,
        references(:background_agent_jobs, type: :bigint, on_delete: :restrict)
      )

      add(
        :workspace_owner_job_id,
        references(:background_agent_jobs, type: :bigint, on_delete: :restrict)
      )
    end

    execute("UPDATE background_agent_jobs SET workspace_owner_job_id = id")

    alter table(:background_agent_jobs) do
      modify(:workspace_owner_job_id, :bigint, null: false)
    end

    create(
      unique_index(:background_agent_jobs, [:continued_from_job_id],
        name: :background_agent_jobs_continued_from_job_index,
        where: "continued_from_job_id IS NOT NULL"
      )
    )

    create(
      index(:background_agent_jobs, [:workspace_owner_job_id],
        name: :background_agent_jobs_workspace_owner_index
      )
    )

    create(
      constraint(:background_agent_jobs, :background_agent_jobs_continued_from_not_self,
        check: "continued_from_job_id IS NULL OR continued_from_job_id <> id"
      )
    )
  end

  def down do
    raise "BackgroundAgentJob continuation history cannot be removed"
  end
end
