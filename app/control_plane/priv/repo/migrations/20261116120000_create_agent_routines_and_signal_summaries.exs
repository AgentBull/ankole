defmodule Ankole.Repo.Migrations.CreateAgentRoutinesAndSignalSummaries do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE signals
      ADD COLUMN turn_summary text,
      ADD CONSTRAINT signals_turn_summary_length_check
        CHECK (turn_summary IS NULL OR length(turn_summary) <= 500)
    """)

    execute("""
    CREATE TABLE agent_routines (
      id uuid NOT NULL,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      status text NOT NULL,
      agent_uid text NOT NULL,
      owner_session_id text NOT NULL,
      binding_name text,
      name text NOT NULL,
      task text NOT NULL,
      delivery jsonb NOT NULL,
      definition_version bigint DEFAULT 1 NOT NULL,
      idempotency_key text NOT NULL,
      created_by jsonb DEFAULT '{}'::jsonb NOT NULL,
      authorization_kind text DEFAULT 'review_required'::text NOT NULL,
      human_uid text,
      human_access_version bigint,
      inserted_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL,
      CONSTRAINT agent_routines_pkey PRIMARY KEY (id),
      CONSTRAINT agent_routines_status_check
        CHECK (status = ANY (ARRAY['active'::text, 'paused'::text, 'deleted'::text, 'completed'::text])),
      CONSTRAINT agent_routines_name_present
        CHECK (length(btrim(name)) > 0),
      CONSTRAINT agent_routines_task_present
        CHECK (length(btrim(task)) > 0),
      CONSTRAINT agent_routines_owner_session_present
        CHECK (length(btrim(owner_session_id)) > 0),
      CONSTRAINT agent_routines_idempotency_key_present
        CHECK (length(btrim(idempotency_key)) > 0),
      CONSTRAINT agent_routines_definition_version_positive
        CHECK (definition_version >= 1),
      CONSTRAINT agent_routines_delivery_object
        CHECK (jsonb_typeof(delivery) = 'object'::text),
      CONSTRAINT agent_routines_created_by_object
        CHECK (jsonb_typeof(created_by) = 'object'::text),
      CONSTRAINT agent_routines_work_authorization_check
        CHECK (
          ((authorization_kind = 'human'::text) AND (human_uid IS NOT NULL) AND (human_access_version IS NOT NULL) AND (human_access_version > 0))
          OR ((authorization_kind = ANY (ARRAY['service'::text, 'review_required'::text])) AND (human_uid IS NULL) AND (human_access_version IS NULL))
        ),
      CONSTRAINT agent_routines_agent_uid_fkey
        FOREIGN KEY (tenant_id, agent_uid)
        REFERENCES principals(tenant_id, uid) ON UPDATE CASCADE ON DELETE CASCADE
    )
    """)

    execute(
      "COMMENT ON TABLE agent_routines IS 'Standing Agent routines triggered by Cron schedules and external Signal bindings.'"
    )

    execute(
      "CREATE UNIQUE INDEX agent_routines_tenant_id_id_index ON agent_routines (tenant_id, id)"
    )

    execute(
      "CREATE UNIQUE INDEX agent_routines_session_owner_index ON agent_routines (tenant_id, agent_uid, id)"
    )

    execute(
      "CREATE INDEX agent_routines_actor_status_index ON agent_routines (tenant_id, agent_uid, owner_session_id, status)"
    )

    execute("""
    CREATE UNIQUE INDEX agent_routines_agent_name_index
      ON agent_routines (tenant_id, agent_uid, owner_session_id, name)
      WHERE status <> 'deleted'::text
    """)

    execute("""
    CREATE UNIQUE INDEX agent_routines_idempotency_index
      ON agent_routines (tenant_id, agent_uid, owner_session_id, idempotency_key)
    """)

    execute(
      "CREATE INDEX agent_routines_human_uid_index ON agent_routines (tenant_id, human_uid)"
    )

    execute("""
    CREATE INDEX agent_routines_pod_board_idx
      ON agent_routines (tenant_id, updated_at DESC)
      WHERE status IN ('active', 'paused')
    """)

    execute("""
    INSERT INTO agent_routines (
      id, tenant_id, status, agent_uid, owner_session_id, binding_name,
      name, task, delivery, definition_version, idempotency_key, created_by,
      authorization_kind, human_uid, human_access_version, inserted_at, updated_at
    )
    SELECT
      cs.id,
      cs.tenant_id,
      cs.status,
      cs.agent_uid,
      cs.owner_session_id,
      cs.binding_name,
      cs.name,
      COALESCE(NULLIF(btrim(cs.payload->>'task'), ''), cs.name),
      cs.delivery,
      1,
      cs.idempotency_key,
      cs.created_by,
      cs.authorization_kind,
      cs.human_uid,
      cs.human_access_version,
      cs.inserted_at,
      cs.updated_at
    FROM cron_schedules cs
    WHERE cs.owner_job_id IS NULL
      AND (
        NOT EXISTS (
          SELECT 1 FROM signal_bindings sb
          WHERE sb.tenant_id = cs.tenant_id
            AND sb.config_ref = 'schedule://' || cs.id::text
            AND sb.name = 'source:schedule://' || cs.id::text
            AND sb.routing_mode = 'action'
        )
        OR EXISTS (
          SELECT 1 FROM sessions s
          WHERE s.tenant_id = cs.tenant_id
            AND s.cron_schedule_id = cs.id
        )
      )
    """)

    execute("""
    ALTER TABLE cron_schedules
      ADD COLUMN owner_routine_id uuid,
      ADD CONSTRAINT cron_schedules_owner_routine_fkey
        FOREIGN KEY (tenant_id, owner_routine_id)
        REFERENCES agent_routines(tenant_id, id) ON DELETE CASCADE,
      ADD CONSTRAINT cron_schedules_routine_exclusive_check
        CHECK (NOT (owner_job_id IS NOT NULL AND owner_routine_id IS NOT NULL))
    """)

    execute("""
    CREATE INDEX cron_schedules_owner_routine_index
      ON cron_schedules (tenant_id, owner_routine_id)
      WHERE owner_routine_id IS NOT NULL
    """)

    execute("""
    UPDATE cron_schedules cs
    SET owner_routine_id = ar.id
    FROM agent_routines ar
    WHERE cs.tenant_id = ar.tenant_id AND cs.id = ar.id
    """)

    execute("""
    ALTER TABLE signal_bindings
      ADD COLUMN agent_routine_id uuid,
      ADD COLUMN coalesce jsonb,
      ADD CONSTRAINT signal_bindings_routine_fkey
        FOREIGN KEY (tenant_id, agent_uid, agent_routine_id)
        REFERENCES agent_routines(tenant_id, agent_uid, id) ON DELETE CASCADE,
      ADD CONSTRAINT signal_bindings_routine_mode_check
        CHECK (agent_routine_id IS NULL OR (routing_mode = 'ai_colleague'::text AND automation_job_id IS NULL)),
      ADD CONSTRAINT signal_bindings_coalesce_object
        CHECK (coalesce IS NULL OR jsonb_typeof(coalesce) = 'object'::text)
    """)

    execute("""
    CREATE INDEX signal_bindings_routine_index
      ON signal_bindings (tenant_id, agent_routine_id)
      WHERE agent_routine_id IS NOT NULL
    """)

    execute("""
    UPDATE signal_bindings sb
    SET agent_routine_id = ar.id
    FROM agent_routines ar
    WHERE sb.tenant_id = ar.tenant_id
      AND sb.config_ref = 'schedule://' || ar.id::text
      AND sb.name = 'source:schedule://' || ar.id::text
      AND sb.routing_mode = 'ai_colleague'
    """)

    execute("DROP INDEX sessions_session_index")
    execute("DROP INDEX sessions_tenant_id_cron_schedule_id_index")
    execute("ALTER TABLE sessions DROP CONSTRAINT sessions_owner_check")
    execute("ALTER TABLE sessions DROP CONSTRAINT sessions_session_id_present")
    execute("ALTER TABLE sessions DROP CONSTRAINT sessions_cron_schedule_owner_fkey")
    execute("ALTER TABLE sessions DROP COLUMN session_id")
    execute("ALTER TABLE sessions RENAME COLUMN cron_schedule_id TO agent_routine_id")
    execute("UPDATE sessions SET kind = 'routine' WHERE kind = 'cron'")

    execute("""
    ALTER TABLE sessions
      ADD COLUMN session_id text GENERATED ALWAYS AS (
        CASE kind
          WHEN 'named'::text THEN name
          WHEN 'conversation'::text THEN ('conversation:'::text || (conversation_id)::text)
          WHEN 'background_job'::text THEN ('job:'::text || (background_job_id)::text)
          WHEN 'workflow_task'::text THEN ('wf_task:'::text || (workflow_agent_call_id)::text)
          WHEN 'routine'::text THEN ('routine:'::text || (agent_routine_id)::text)
          ELSE NULL::text
        END
      ) STORED NOT NULL,
      ADD CONSTRAINT sessions_agent_routine_owner_fkey
        FOREIGN KEY (tenant_id, agent_uid, agent_routine_id)
        REFERENCES agent_routines(tenant_id, agent_uid, id) ON DELETE CASCADE,
      ADD CONSTRAINT sessions_owner_check
        CHECK (
          (num_nonnulls(name, conversation_id, background_job_id, workflow_agent_call_id, agent_routine_id) = 1)
          AND CASE kind
            WHEN 'named'::text THEN ((name IS NOT NULL) AND (btrim(name) <> ''::text) AND (name !~ '^(conversation|job|wf_task|routine):'::text))
            WHEN 'conversation'::text THEN (conversation_id IS NOT NULL)
            WHEN 'background_job'::text THEN (background_job_id IS NOT NULL)
            WHEN 'workflow_task'::text THEN (workflow_agent_call_id IS NOT NULL)
            WHEN 'routine'::text THEN (agent_routine_id IS NOT NULL)
            ELSE false
          END
        ),
      ADD CONSTRAINT sessions_session_id_present CHECK (btrim(session_id) <> ''::text)
    """)

    execute(
      "CREATE INDEX sessions_tenant_id_agent_routine_id_index ON sessions (tenant_id, agent_routine_id)"
    )

    execute(
      "CREATE UNIQUE INDEX sessions_session_index ON sessions (tenant_id, agent_uid, session_id)"
    )

    execute("""
    UPDATE signal_bindings
    SET target = jsonb_set(target, '{session_id}', to_jsonb('routine:' || substr(target->>'session_id', 6)))
    WHERE target->>'session_id' LIKE 'cron:%'
    """)

    for {table, column} <- [
          {"signals", "session_id"},
          {"scheduled_events", "session_id"},
          {"ai_gateway_conversations", "conversation_key"},
          {"ai_gateway_usage_records", "session_id"},
          {"background_agent_jobs", "owner_session_id"},
          {"workflow_runs", "owner_session_id"},
          {"conversation_messages", "session_id"},
          {"conversation_action_cards", "session_id"},
          {"session_tool_receipts", "session_id"},
          {"signal_webhook_endpoints", "session_id"},
          {"brain_claims", "provenance_session"}
        ] do
      execute("""
      UPDATE #{table}
      SET #{column} = 'routine:' || substr(#{column}, 6)
      WHERE #{column} LIKE 'cron:%'
      """)
    end
  end

  def down do
    for {table, column} <- [
          {"brain_claims", "provenance_session"},
          {"signal_webhook_endpoints", "session_id"},
          {"session_tool_receipts", "session_id"},
          {"conversation_action_cards", "session_id"},
          {"conversation_messages", "session_id"},
          {"workflow_runs", "owner_session_id"},
          {"background_agent_jobs", "owner_session_id"},
          {"ai_gateway_usage_records", "session_id"},
          {"ai_gateway_conversations", "conversation_key"},
          {"scheduled_events", "session_id"},
          {"signals", "session_id"}
        ] do
      execute("""
      UPDATE #{table}
      SET #{column} = 'cron:' || substr(#{column}, 9)
      WHERE #{column} LIKE 'routine:%'
      """)
    end

    execute("""
    UPDATE signal_bindings
    SET target = jsonb_set(target, '{session_id}', to_jsonb('cron:' || substr(target->>'session_id', 9)))
    WHERE target->>'session_id' LIKE 'routine:%'
    """)

    execute("""
    DELETE FROM sessions
    WHERE kind = 'routine'
      AND NOT EXISTS (
        SELECT 1 FROM cron_schedules cs
        WHERE cs.tenant_id = sessions.tenant_id
          AND cs.agent_uid = sessions.agent_uid
          AND cs.id = sessions.agent_routine_id
      )
    """)

    execute("DROP INDEX sessions_session_index")
    execute("DROP INDEX sessions_tenant_id_agent_routine_id_index")
    execute("ALTER TABLE sessions DROP CONSTRAINT sessions_owner_check")
    execute("ALTER TABLE sessions DROP CONSTRAINT sessions_session_id_present")
    execute("ALTER TABLE sessions DROP CONSTRAINT sessions_agent_routine_owner_fkey")
    execute("ALTER TABLE sessions DROP COLUMN session_id")
    execute("ALTER TABLE sessions RENAME COLUMN agent_routine_id TO cron_schedule_id")
    execute("UPDATE sessions SET kind = 'cron' WHERE kind = 'routine'")

    execute("""
    ALTER TABLE sessions
      ADD COLUMN session_id text GENERATED ALWAYS AS (
        CASE kind
          WHEN 'named'::text THEN name
          WHEN 'conversation'::text THEN ('conversation:'::text || (conversation_id)::text)
          WHEN 'background_job'::text THEN ('job:'::text || (background_job_id)::text)
          WHEN 'workflow_task'::text THEN ('wf_task:'::text || (workflow_agent_call_id)::text)
          WHEN 'cron'::text THEN ('cron:'::text || (cron_schedule_id)::text)
          ELSE NULL::text
        END
      ) STORED NOT NULL,
      ADD CONSTRAINT sessions_cron_schedule_owner_fkey
        FOREIGN KEY (tenant_id, agent_uid, cron_schedule_id)
        REFERENCES cron_schedules(tenant_id, agent_uid, id) ON DELETE CASCADE,
      ADD CONSTRAINT sessions_owner_check
        CHECK (
          (num_nonnulls(name, conversation_id, background_job_id, workflow_agent_call_id, cron_schedule_id) = 1)
          AND CASE kind
            WHEN 'named'::text THEN ((name IS NOT NULL) AND (btrim(name) <> ''::text) AND (name !~ '^(conversation|job|wf_task|cron):'::text))
            WHEN 'conversation'::text THEN (conversation_id IS NOT NULL)
            WHEN 'background_job'::text THEN (background_job_id IS NOT NULL)
            WHEN 'workflow_task'::text THEN (workflow_agent_call_id IS NOT NULL)
            WHEN 'cron'::text THEN (cron_schedule_id IS NOT NULL)
            ELSE false
          END
        ),
      ADD CONSTRAINT sessions_session_id_present CHECK (btrim(session_id) <> ''::text)
    """)

    execute(
      "CREATE INDEX sessions_tenant_id_cron_schedule_id_index ON sessions (tenant_id, cron_schedule_id)"
    )

    execute(
      "CREATE UNIQUE INDEX sessions_session_index ON sessions (tenant_id, agent_uid, session_id)"
    )

    execute("DROP INDEX signal_bindings_routine_index")

    execute("""
    ALTER TABLE signal_bindings
      DROP CONSTRAINT signal_bindings_coalesce_object,
      DROP CONSTRAINT signal_bindings_routine_mode_check,
      DROP CONSTRAINT signal_bindings_routine_fkey,
      DROP COLUMN coalesce,
      DROP COLUMN agent_routine_id
    """)

    execute("DROP INDEX cron_schedules_owner_routine_index")

    execute("""
    ALTER TABLE cron_schedules
      DROP CONSTRAINT cron_schedules_routine_exclusive_check,
      DROP CONSTRAINT cron_schedules_owner_routine_fkey,
      DROP COLUMN owner_routine_id
    """)

    execute("DROP TABLE agent_routines")

    execute("""
    ALTER TABLE signals
      DROP CONSTRAINT signals_turn_summary_length_check,
      DROP COLUMN turn_summary
    """)
  end
end
