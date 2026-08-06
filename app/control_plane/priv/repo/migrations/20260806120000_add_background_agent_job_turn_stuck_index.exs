defmodule Ankole.Repo.Migrations.AddBackgroundAgentJobTurnStuckIndex do
  use Ecto.Migration

  def up do
    create index(:background_agent_job_turns, [:status, :updated_at],
             name: :background_agent_job_turns_stuck_deadline_index,
             where: "status = 'in_progress'"
           )
  end

  def down do
    drop_if_exists index(:background_agent_job_turns, [:status, :updated_at],
                     name: :background_agent_job_turns_stuck_deadline_index
                   )
  end
end
