defmodule Ankole.Repo.Migrations.AddBackgroundAgentJobWorkspaceTemplate do
  use Ecto.Migration

  def change do
    alter table(:background_agent_jobs) do
      add(:workspace_template_id, :text)
    end

    create(
      constraint(:background_agent_jobs, :background_agent_jobs_workspace_template_id_valid,
        check:
          "workspace_template_id IS NULL OR workspace_template_id ~ '^[a-z][a-z0-9_-]{0,63}$'"
      )
    )
  end
end
