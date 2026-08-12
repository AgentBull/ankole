defmodule Ankole.Repo.Migrations.AddBackgroundAgentJobExecutionFailures do
  use Ecto.Migration

  def change do
    alter table(:background_agent_jobs) do
      add :execution_failures, :integer, null: false, default: 0
    end

    create constraint(:background_agent_jobs, :background_agent_jobs_execution_failures_nonnegative,
             check: "execution_failures >= 0"
           )
  end
end
