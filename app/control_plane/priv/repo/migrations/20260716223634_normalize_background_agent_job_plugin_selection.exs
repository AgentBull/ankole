defmodule Ankole.Repo.Migrations.NormalizeBackgroundAgentJobPluginSelection do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE background_agent_jobs
    ADD COLUMN IF NOT EXISTS agent_plugin_ids text[] NOT NULL DEFAULT ARRAY[]::text[]
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'background_agent_jobs'
          AND column_name = 'agent_plugins'
      ) THEN
        UPDATE background_agent_jobs AS job
        SET agent_plugin_ids = ARRAY(
          SELECT CASE jsonb_typeof(member)
            WHEN 'string' THEN member #>> '{}'
            WHEN 'object' THEN COALESCE(
              member ->> 'id',
              member ->> 'agent_plugin_id',
              member ->> 'name'
            )
            ELSE NULL
          END
          FROM jsonb_array_elements(job.agent_plugins) WITH ORDINALITY AS members(member, position)
          ORDER BY position
        );

        IF EXISTS (
          SELECT 1
          FROM background_agent_jobs
          WHERE array_position(agent_plugin_ids, NULL) IS NOT NULL
        ) THEN
          RAISE EXCEPTION 'cannot normalize legacy BackgroundAgentJob Agent Plugin selection'
            USING ERRCODE = 'check_violation';
        END IF;

        ALTER TABLE background_agent_jobs
          DROP CONSTRAINT IF EXISTS background_agent_jobs_agent_plugins_array;

        ALTER TABLE background_agent_jobs DROP COLUMN agent_plugins;
      END IF;
    END
    $$
    """)

    execute("""
    ALTER TABLE background_agent_jobs
      DROP CONSTRAINT IF EXISTS background_agent_jobs_agent_plugin_ids_valid
    """)

    execute("""
    ALTER TABLE background_agent_jobs
      ADD CONSTRAINT background_agent_jobs_agent_plugin_ids_valid
      CHECK (
        array_position(agent_plugin_ids, NULL) IS NULL
        AND cardinality(agent_plugin_ids) <= 16
      )
    """)
  end

  def down do
    raise "legacy Agent Plugin package snapshots cannot be reconstructed from selected IDs"
  end
end
