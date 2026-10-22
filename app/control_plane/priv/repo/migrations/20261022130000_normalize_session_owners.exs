defmodule Ankole.Repo.Migrations.NormalizeSessionOwners do
  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add(:kind, :text)
      add(:name, :text)
      add(:background_job_id, :bigint)
      add(:workflow_agent_call_id, :bigint)
      add(:cron_schedule_id, :uuid)
    end

    execute("""
    DELETE FROM sessions
    WHERE (session_id ~ '^conversation:[0-9a-fA-F-]{36}$' AND NOT EXISTS (
            SELECT 1 FROM conversations c
            WHERE c.tenant_id = sessions.tenant_id AND c.id = sessions.conversation_id
          ))
       OR (session_id ~ '^job:[1-9][0-9]*$' AND NOT EXISTS (
            SELECT 1 FROM background_agent_jobs j
            WHERE j.tenant_id = sessions.tenant_id
              AND j.agent_uid = sessions.agent_uid
              AND j.id = substring(session_id FROM 5)::bigint
          ))
       OR (session_id ~ '^wf_task:[1-9][0-9]*$' AND NOT EXISTS (
            SELECT 1 FROM workflow_agent_calls w
            WHERE w.tenant_id = sessions.tenant_id
              AND w.agent_uid = sessions.agent_uid
              AND w.id = substring(session_id FROM 9)::bigint
          ))
       OR (session_id ~ '^cron:[0-9a-fA-F-]{36}$' AND NOT EXISTS (
            SELECT 1 FROM cron_schedules cs
            WHERE cs.tenant_id = sessions.tenant_id
              AND cs.agent_uid = sessions.agent_uid
              AND cs.id = substring(session_id FROM 6)::uuid
          ))
    """)

    execute("""
    UPDATE sessions SET
      kind = CASE
        WHEN starts_with(session_id, 'conversation:') THEN 'conversation'
        WHEN starts_with(session_id, 'job:') THEN 'background_job'
        WHEN starts_with(session_id, 'wf_task:') THEN 'workflow_task'
        WHEN starts_with(session_id, 'cron:') THEN 'cron'
        ELSE 'named'
      END,
      name = CASE WHEN session_id !~ '^(conversation|job|wf_task|cron):' THEN session_id END,
      background_job_id = CASE
        WHEN starts_with(session_id, 'job:') THEN substring(session_id FROM 5)::bigint
      END,
      workflow_agent_call_id = CASE
        WHEN starts_with(session_id, 'wf_task:') THEN substring(session_id FROM 9)::bigint
      END,
      cron_schedule_id = CASE
        WHEN starts_with(session_id, 'cron:') THEN substring(session_id FROM 6)::uuid
      END
    """)

    create(
      unique_index(:background_agent_jobs, [:tenant_id, :agent_uid, :id],
        name: :background_agent_jobs_session_owner_index
      )
    )

    create(
      unique_index(:workflow_agent_calls, [:tenant_id, :agent_uid, :id],
        name: :workflow_agent_calls_session_owner_index
      )
    )

    create(
      unique_index(:cron_schedules, [:tenant_id, :agent_uid, :id],
        name: :cron_schedules_session_owner_index
      )
    )

    execute("""
    ALTER TABLE sessions
      ADD CONSTRAINT sessions_background_job_owner_fkey
        FOREIGN KEY (tenant_id, agent_uid, background_job_id)
        REFERENCES background_agent_jobs (tenant_id, agent_uid, id) ON DELETE CASCADE,
      ADD CONSTRAINT sessions_workflow_call_owner_fkey
        FOREIGN KEY (tenant_id, agent_uid, workflow_agent_call_id)
        REFERENCES workflow_agent_calls (tenant_id, agent_uid, id) ON DELETE CASCADE,
      ADD CONSTRAINT sessions_cron_schedule_owner_fkey
        FOREIGN KEY (tenant_id, agent_uid, cron_schedule_id)
        REFERENCES cron_schedules (tenant_id, agent_uid, id) ON DELETE CASCADE,
      ADD CONSTRAINT sessions_owner_check CHECK (
        num_nonnulls(name, conversation_id, background_job_id,
          workflow_agent_call_id, cron_schedule_id) = 1 AND
        CASE kind
          WHEN 'named' THEN name IS NOT NULL AND btrim(name) <> ''
            AND name !~ '^(conversation|job|wf_task|cron):'
          WHEN 'conversation' THEN conversation_id IS NOT NULL
          WHEN 'background_job' THEN background_job_id IS NOT NULL
          WHEN 'workflow_task' THEN workflow_agent_call_id IS NOT NULL
          WHEN 'cron' THEN cron_schedule_id IS NOT NULL
          ELSE false
        END
      ),
      ALTER COLUMN kind SET NOT NULL
    """)

    # Keep the wire key stable while its owner becomes a typed foreign key.
    execute("""
    ALTER TABLE sessions ADD COLUMN generated_session_id text
      GENERATED ALWAYS AS (#{key_expression()}) STORED
    """)

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM sessions WHERE session_id <> generated_session_id) THEN
        RAISE EXCEPTION 'Session owner normalization changed an existing transport key';
      END IF;
    END $$
    """)

    execute("ALTER TABLE sessions DROP COLUMN session_id")
    execute("ALTER TABLE sessions RENAME COLUMN generated_session_id TO session_id")
    execute("ALTER TABLE sessions ALTER COLUMN session_id SET NOT NULL")

    execute("""
    ALTER TABLE sessions ADD CONSTRAINT sessions_session_id_present
      CHECK (btrim(session_id) <> '')
    """)

    create(unique_index(:sessions, [:agent_uid, :session_id], name: :sessions_session_index))
    create(index(:sessions, [:tenant_id, :background_job_id]))
    create(index(:sessions, [:tenant_id, :workflow_agent_call_id]))
    create(index(:sessions, [:tenant_id, :cron_schedule_id]))
  end

  def down do
    execute("ALTER TABLE sessions ADD COLUMN legacy_session_id text")
    execute("UPDATE sessions SET legacy_session_id = session_id")
    execute("ALTER TABLE sessions DROP COLUMN session_id")
    execute("ALTER TABLE sessions RENAME COLUMN legacy_session_id TO session_id")
    execute("ALTER TABLE sessions ALTER COLUMN session_id SET NOT NULL")

    execute("""
    ALTER TABLE sessions ADD CONSTRAINT sessions_session_id_present
      CHECK (btrim(session_id) <> '')
    """)

    execute("ALTER TABLE sessions DROP CONSTRAINT sessions_owner_check")
    execute("ALTER TABLE sessions DROP CONSTRAINT sessions_background_job_owner_fkey")
    execute("ALTER TABLE sessions DROP CONSTRAINT sessions_workflow_call_owner_fkey")
    execute("ALTER TABLE sessions DROP CONSTRAINT sessions_cron_schedule_owner_fkey")

    alter table(:sessions) do
      remove(:kind)
      remove(:name)
      remove(:background_job_id)
      remove(:workflow_agent_call_id)
      remove(:cron_schedule_id)
    end

    drop(
      index(:background_agent_jobs, [:tenant_id, :agent_uid, :id],
        name: :background_agent_jobs_session_owner_index
      )
    )

    drop(
      index(:workflow_agent_calls, [:tenant_id, :agent_uid, :id],
        name: :workflow_agent_calls_session_owner_index
      )
    )

    drop(
      index(:cron_schedules, [:tenant_id, :agent_uid, :id],
        name: :cron_schedules_session_owner_index
      )
    )

    create(unique_index(:sessions, [:agent_uid, :session_id], name: :sessions_session_index))
  end

  defp key_expression do
    """
    CASE kind
      WHEN 'named' THEN name
      WHEN 'conversation' THEN 'conversation:' || conversation_id::text
      WHEN 'background_job' THEN 'job:' || background_job_id::text
      WHEN 'workflow_task' THEN 'wf_task:' || workflow_agent_call_id::text
      WHEN 'cron' THEN 'cron:' || cron_schedule_id::text
    END
    """
  end
end
