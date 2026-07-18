defmodule Ankole.Repo.Migrations.ReplaceSubagentEventsWithTurns do
  use Ecto.Migration

  def up do
    execute(live_job_guard_sql())

    create table(:subagent_delegation_turns, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :delegation_id,
          references(:subagent_delegations, type: :uuid, on_delete: :delete_all),
          null: false

      add :attempt, :integer, null: false
      add :runtime_thread_id, :text, null: false
      add :runtime_turn_id, :text, null: false
      add :kind, :text, null: false, default: "agent"
      add :status, :text, null: false
      add :revision, :bigint, null: false
      add :trajectory, :map, null: false
      add :usage, :map, null: false, default: %{}
      add :error, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec, null: false
      add :last_activity_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:subagent_delegation_turns, [:delegation_id, :runtime_turn_id],
             name: :subagent_delegation_turns_runtime_turn_index
           )

    create index(:subagent_delegation_turns, [:delegation_id, :attempt, :started_at, :id],
             name: :subagent_delegation_turns_timeline_index
           )

    create constraint(:subagent_delegation_turns, :subagent_delegation_turns_attempt_positive,
             check: "attempt > 0"
           )

    create constraint(:subagent_delegation_turns, :subagent_delegation_turns_revision_nonnegative,
             check: "revision >= 0"
           )

    create constraint(:subagent_delegation_turns, :subagent_delegation_turns_kind_check,
             check: "kind IN ('agent', 'compaction')"
           )

    create constraint(:subagent_delegation_turns, :subagent_delegation_turns_status_check,
             check: "status IN ('in_progress', 'completed', 'failed', 'interrupted')"
           )

    create constraint(:subagent_delegation_turns, :subagent_delegation_turns_trajectory_check,
             check: """
             jsonb_typeof(trajectory) = 'object' AND
             trajectory @> '{"format":"ankole_chatml","version":1}'::jsonb AND
             jsonb_typeof(trajectory->'messages') = 'array' AND
             jsonb_array_length(jsonb_path_query_array(trajectory, '$.messages[*].role')) =
               jsonb_array_length(trajectory->'messages') AND
             jsonb_path_query_array(trajectory, '$.messages[*].role') <@
               '["user","developer","assistant","tool"]'::jsonb
             """
           )

    create constraint(:subagent_delegation_turns, :subagent_delegation_turns_trajectory_bytes,
             check: "octet_length(trajectory::text) <= 524288"
           )

    create constraint(:subagent_delegation_turns, :subagent_delegation_turns_usage_object,
             check: "jsonb_typeof(usage) = 'object'"
           )

    create constraint(:subagent_delegation_turns, :subagent_delegation_turns_error_object,
             check: "jsonb_typeof(error) = 'object'"
           )

    create constraint(:subagent_delegation_turns, :subagent_delegation_turns_completion_check,
             check: """
             (status = 'in_progress' AND completed_at IS NULL) OR
             (status IN ('completed', 'failed', 'interrupted') AND completed_at IS NOT NULL)
             """
           )

    # Raw runtime events do not have a lossless one-to-one mapping to semantic
    # Turns. Keep them as a control-plane-owned archive instead of inventing a
    # backfill or discarding production history. A later explicit retention or
    # export migration may remove the archive after proving it is no longer
    # operationally useful.
    execute(
      "ALTER TABLE subagent_delegation_events DROP CONSTRAINT subagent_delegation_events_delegation_id_fkey"
    )

    execute("""
    ALTER TABLE subagent_delegation_events
    ADD CONSTRAINT subagent_delegation_events_delegation_id_fkey
    FOREIGN KEY (delegation_id) REFERENCES subagent_delegations(id) ON DELETE RESTRICT
    """)

    execute(
      "ALTER TABLE subagent_delegation_events DROP CONSTRAINT subagent_delegation_events_agent_uid_fkey"
    )

    execute("""
    ALTER TABLE subagent_delegation_events
    ADD CONSTRAINT subagent_delegation_events_agent_uid_fkey
    FOREIGN KEY (agent_uid) REFERENCES principals(uid) ON DELETE RESTRICT
    """)

    execute("ALTER TABLE subagent_delegation_events RENAME TO subagent_delegation_legacy_events")

    execute("""
    COMMENT ON TABLE subagent_delegation_legacy_events IS
      'Control-plane-owned immutable archive of pre-Turn SubagentDelegation runtime events. No runtime reader or writer owns this table; retain it until an explicit export or retention migration proves the history is no longer operationally useful.'
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM subagent_delegation_turns) THEN
        RAISE EXCEPTION
          'Cannot restore raw SubagentDelegation events after semantic Turns have been recorded'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$
    """)

    execute("ALTER TABLE subagent_delegation_legacy_events RENAME TO subagent_delegation_events")

    execute("COMMENT ON TABLE subagent_delegation_events IS NULL")

    execute(
      "ALTER TABLE subagent_delegation_events DROP CONSTRAINT subagent_delegation_events_delegation_id_fkey"
    )

    execute("""
    ALTER TABLE subagent_delegation_events
    ADD CONSTRAINT subagent_delegation_events_delegation_id_fkey
    FOREIGN KEY (delegation_id) REFERENCES subagent_delegations(id) ON DELETE CASCADE
    """)

    execute(
      "ALTER TABLE subagent_delegation_events DROP CONSTRAINT subagent_delegation_events_agent_uid_fkey"
    )

    execute("""
    ALTER TABLE subagent_delegation_events
    ADD CONSTRAINT subagent_delegation_events_agent_uid_fkey
    FOREIGN KEY (agent_uid) REFERENCES principals(uid) ON DELETE CASCADE
    """)

    drop table(:subagent_delegation_turns)
  end

  @doc false
  def live_job_guard_sql(table \\ "subagent_delegations") do
    table = validate_table!(table)

    """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM #{table}
        WHERE status IN ('queued', 'running', 'waiting_on_user')
      ) THEN
        RAISE EXCEPTION
          'BackgroundAgentJob Turn migration requires zero non-terminal V1 jobs'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$
    """
  end

  defp validate_table!(table) do
    if is_binary(table) and Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, table) do
      table
    else
      raise ArgumentError, "invalid migration table name"
    end
  end
end
