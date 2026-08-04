defmodule Ankole.Repo.Migrations.AddModelProfileToBackgroundAgentJobs do
  use Ecto.Migration

  def change do
    alter table(:background_agent_jobs) do
      add(:model_profile, :text, null: false, default: "coding")
    end

    create(
      constraint(:background_agent_jobs, :background_agent_jobs_model_profile_valid,
        check: "model_profile ~ '^[a-z][a-z0-9_-]{0,63}$'"
      )
    )
  end
end
