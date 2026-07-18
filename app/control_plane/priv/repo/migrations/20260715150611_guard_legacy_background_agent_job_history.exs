defmodule Ankole.Repo.Migrations.GuardLegacyBackgroundAgentJobHistory do
  use Ecto.Migration

  @naming_version 20_260_716_120_707
  @destructive_v2_version 20_260_716_124_417

  def up do
    execute(guard_sql())
    execute(repair_empty_archive_sql())
  end

  def down, do: :ok

  @doc false
  def guard_sql do
    """
    DO $$
    DECLARE
      naming_applied boolean;
      destructive_v2_applied boolean;
      expected_archive regclass;
      jobs_table regclass;
      actor_events_table regclass;
      has_job_rows boolean;
      has_job_actor_events boolean;
    BEGIN
      SELECT EXISTS (
        SELECT 1
        FROM schema_migrations
        WHERE version = #{@naming_version}
      ) INTO naming_applied;

      SELECT EXISTS (
        SELECT 1
        FROM schema_migrations
        WHERE version = #{@destructive_v2_version}
      ) INTO destructive_v2_applied;

      expected_archive := CASE
        WHEN naming_applied THEN to_regclass('background_agent_job_legacy_events')
        ELSE to_regclass('subagent_delegation_legacy_events')
      END;

      IF NOT naming_applied AND NOT destructive_v2_applied AND expected_archive IS NOT NULL THEN
        RETURN;
      END IF;

      jobs_table := CASE
        WHEN naming_applied THEN to_regclass('background_agent_jobs')
        ELSE to_regclass('subagent_delegations')
      END;
      actor_events_table := to_regclass('actor_events');

      IF jobs_table IS NULL OR actor_events_table IS NULL THEN
        RAISE EXCEPTION
          'Legacy BackgroundAgentJob history cannot be proven because its durable Job or actor-event evidence table is missing. Restore the database from a backup at or before 20260714000003 and rerun migrations.'
          USING ERRCODE = 'check_violation';
      END IF;

      EXECUTE 'SELECT EXISTS (SELECT 1 FROM ' || jobs_table || ')'
      INTO has_job_rows;

      EXECUTE
        'SELECT EXISTS (
           SELECT 1
           FROM ' || actor_events_table || '
           WHERE type LIKE ''subagent.delegation.%''
              OR type LIKE ''background_agent_job.%''
              OR source_event_id LIKE ''subagent_delegation:%''
              OR source_event_id LIKE ''background_agent_job:%''
              OR session_id LIKE ''subagent:%''
              OR session_id LIKE ''job:%''
         )'
      INTO has_job_actor_events;

      IF has_job_rows OR has_job_actor_events THEN
        RAISE EXCEPTION
          'Legacy BackgroundAgentJob history cannot be reconstructed safely because an older destructive migration ran and durable Job or actor-event evidence survives. Restore the database from a backup at or before 20260714000003 and rerun migrations; Ankole will not fabricate deleted Jobs or events.'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$
    """
  end

  @doc false
  def repair_empty_archive_sql do
    """
    DO $$
    DECLARE
      naming_applied boolean;
    BEGIN
      SELECT EXISTS (
        SELECT 1
        FROM schema_migrations
        WHERE version = #{@naming_version}
      ) INTO naming_applied;

      IF naming_applied THEN
        IF to_regclass('background_agent_job_legacy_events') IS NULL THEN
          CREATE TABLE background_agent_job_legacy_events (
            id uuid NOT NULL,
            job_id uuid NOT NULL,
            agent_uid text NOT NULL,
            seq bigint NOT NULL,
            direction text NOT NULL,
            event_type text NOT NULL,
            payload jsonb NOT NULL,
            redaction jsonb DEFAULT '{}'::jsonb NOT NULL,
            occurred_at timestamp without time zone NOT NULL,
            inserted_at timestamp without time zone NOT NULL,
            updated_at timestamp without time zone NOT NULL,
            CONSTRAINT background_agent_job_legacy_events_pkey PRIMARY KEY (id),
            CONSTRAINT background_agent_job_legacy_events_job_id_fkey
              FOREIGN KEY (job_id) REFERENCES background_agent_jobs(id) ON DELETE RESTRICT,
            CONSTRAINT background_agent_job_legacy_events_agent_uid_fkey
              FOREIGN KEY (agent_uid) REFERENCES principals(uid) ON DELETE RESTRICT,
            CONSTRAINT background_agent_job_legacy_events_direction_check
              CHECK (direction IN (
                'client_to_server', 'server_to_client', 'server_request', 'client_response',
                'process', 'queue', 'audit', 'tool'
              )),
            CONSTRAINT background_agent_job_legacy_events_payload_object
              CHECK (jsonb_typeof(payload) = 'object'),
            CONSTRAINT background_agent_job_legacy_events_redaction_object
              CHECK (jsonb_typeof(redaction) = 'object')
          );

          CREATE UNIQUE INDEX background_agent_job_legacy_events_job_seq_index
          ON background_agent_job_legacy_events (job_id, seq);

          CREATE INDEX background_agent_job_legacy_events_agent_inserted_index
          ON background_agent_job_legacy_events (agent_uid, inserted_at);

          COMMENT ON TABLE background_agent_job_legacy_events IS
            'Control-plane-owned immutable archive of pre-Turn BackgroundAgentJob runtime events. No runtime reader or writer owns this table; retain it until an explicit export or retention migration proves the history is no longer operationally useful.';
        END IF;
      ELSIF to_regclass('subagent_delegation_legacy_events') IS NULL THEN
        CREATE TABLE subagent_delegation_events (
          id uuid NOT NULL,
          delegation_id uuid NOT NULL,
          agent_uid text NOT NULL,
          seq bigint NOT NULL,
          direction text NOT NULL,
          event_type text NOT NULL,
          payload jsonb NOT NULL,
          redaction jsonb DEFAULT '{}'::jsonb NOT NULL,
          occurred_at timestamp without time zone NOT NULL,
          inserted_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL,
          CONSTRAINT subagent_delegation_events_pkey PRIMARY KEY (id),
          CONSTRAINT subagent_delegation_events_delegation_id_fkey
            FOREIGN KEY (delegation_id) REFERENCES subagent_delegations(id) ON DELETE RESTRICT,
          CONSTRAINT subagent_delegation_events_agent_uid_fkey
            FOREIGN KEY (agent_uid) REFERENCES principals(uid) ON DELETE RESTRICT,
          CONSTRAINT subagent_delegation_events_direction_check
            CHECK (direction IN (
              'client_to_server', 'server_to_client', 'server_request', 'client_response',
              'process', 'queue', 'audit', 'tool'
            )),
          CONSTRAINT subagent_delegation_events_payload_object
            CHECK (jsonb_typeof(payload) = 'object'),
          CONSTRAINT subagent_delegation_events_redaction_object
            CHECK (jsonb_typeof(redaction) = 'object')
        );

        CREATE UNIQUE INDEX subagent_delegation_events_delegation_seq_index
        ON subagent_delegation_events (delegation_id, seq);

        CREATE INDEX subagent_delegation_events_agent_inserted_index
        ON subagent_delegation_events (agent_uid, inserted_at);

        ALTER TABLE subagent_delegation_events RENAME TO subagent_delegation_legacy_events;

        COMMENT ON TABLE subagent_delegation_legacy_events IS
          'Control-plane-owned immutable archive of pre-Turn SubagentDelegation runtime events. No runtime reader or writer owns this table; retain it until an explicit export or retention migration proves the history is no longer operationally useful.';
      END IF;
    END
    $$
    """
  end
end
