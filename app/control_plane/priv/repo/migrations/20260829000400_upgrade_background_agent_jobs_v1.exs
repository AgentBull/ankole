defmodule Ankole.Repo.Migrations.UpgradeBackgroundAgentJobsV1 do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE background_agent_jobs
    SET runtime_projection = runtime_projection - 'codex'
    WHERE runtime_projection IS NOT NULL
      AND runtime_projection ? 'codex'
    """)

    drop table(:background_agent_job_turn_trajectory_groups)
  end

  def down do
    raise Ecto.MigrationError,
      message: "the pre-v1 Background Agent Job state cannot be restored after the v1 upgrade"
  end
end
