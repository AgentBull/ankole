defmodule Ankole.Repo.Migrations.AddSubagentWorkspaceCleanup do
  use Ecto.Migration

  def change do
    alter table(:subagent_delegations) do
      add(:workspace_retention_days, :integer)
      add(:workspace_cleaned_at, :utc_datetime_usec)
    end

    create(
      constraint(:subagent_delegations, :subagent_delegations_workspace_retention_check,
        check:
          "(runtime = 'task_worker' AND workspace_retention_days IS NULL) OR (runtime = 'deep_research' AND workspace_retention_days BETWEEN 1 AND 3650)"
      )
    )

    create(
      index(:subagent_delegations, [:completed_at],
        name: :subagent_delegations_research_workspace_cleanup_index,
        where:
          "runtime = 'deep_research' AND workspace_cleaned_at IS NULL AND completed_at IS NOT NULL"
      )
    )
  end
end
