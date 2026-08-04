defmodule Ankole.Repo.Migrations.AddRuntimeProjectionToBackgroundAgentJobs do
  use Ecto.Migration

  def change do
    alter table(:background_agent_jobs) do
      add(:runtime_projection, :map)
    end

    create(
      constraint(:background_agent_jobs, :background_agent_jobs_runtime_projection_object,
        check: "runtime_projection IS NULL OR jsonb_typeof(runtime_projection) = 'object'"
      )
    )
  end
end
