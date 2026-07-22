defmodule Ankole.Repo.Migrations.RemoveBackgroundAgentJobExecutionSelection do
  use Ecto.Migration

  def up do
    drop(constraint(:background_agent_jobs, :background_agent_jobs_skill_names_valid))

    drop(constraint(:background_agent_jobs, :background_agent_jobs_model_present))

    drop(constraint(:background_agent_jobs, :background_agent_jobs_reasoning_effort_check))

    alter table(:background_agent_jobs) do
      remove(:background)
      remove(:notes)
      remove(:skill_names)
      remove(:model)
      remove(:reasoning_effort)
    end
  end

  def down do
    raise "discarded BackgroundAgentJob execution selections cannot be reconstructed"
  end
end
