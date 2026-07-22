defmodule Ankole.Repo.Migrations.RelaxLegacyBackgroundAgentJobWorkspaceMounts do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE background_agent_jobs
      DROP CONSTRAINT IF EXISTS background_agent_jobs_workspace_mounts_array,
      ALTER COLUMN workspace_mounts SET DEFAULT '[]'::jsonb
    """)

    execute("""
    ALTER TABLE agents
      ADD CONSTRAINT agents_uid_agent_home_safe
      CHECK (uid ~ '^[a-z0-9][a-z0-9._-]{0,95}$') NOT VALID
    """)
  end

  def down do
    execute("ALTER TABLE agents DROP CONSTRAINT IF EXISTS agents_uid_agent_home_safe")

    execute("""
    ALTER TABLE background_agent_jobs
      ALTER COLUMN workspace_mounts DROP DEFAULT,
      ADD CONSTRAINT background_agent_jobs_workspace_mounts_array
      CHECK (
        jsonb_typeof(workspace_mounts) = 'array'
        AND jsonb_array_length(workspace_mounts) BETWEEN 1 AND 16
      ) NOT VALID
    """)
  end
end
