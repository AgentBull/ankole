defmodule Ankole.Repo.Migrations.ReplaceSubagentEventsWithTurns do
  use Ecto.Migration

  def up do
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

    # Deep Research briefly used a separate raw Codex rollout archive while
    # this unreleased migration series was in flight. It is not a trajectory
    # model and must not survive databases that applied that earlier draft.
    drop_if_exists table(:subagent_trajectory_archives)
    drop table(:subagent_delegation_events)
  end

  def down do
    create table(:subagent_delegation_events, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :delegation_id,
          references(:subagent_delegations, type: :uuid, on_delete: :delete_all),
          null: false

      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :seq, :bigint, null: false
      add :direction, :text, null: false
      add :event_type, :text, null: false
      add :payload, :map, null: false
      add :redaction, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:subagent_delegation_events, [:delegation_id, :seq],
             name: :subagent_delegation_events_delegation_seq_index
           )

    create index(:subagent_delegation_events, [:agent_uid, :inserted_at],
             name: :subagent_delegation_events_agent_inserted_index
           )

    create constraint(:subagent_delegation_events, :subagent_delegation_events_direction_check,
             check:
               "direction IN ('client_to_server', 'server_to_client', 'server_request', 'client_response', 'process', 'queue', 'audit', 'tool')"
           )

    create constraint(:subagent_delegation_events, :subagent_delegation_events_payload_object,
             check: "jsonb_typeof(payload) = 'object'"
           )

    create constraint(:subagent_delegation_events, :subagent_delegation_events_redaction_object,
             check: "jsonb_typeof(redaction) = 'object'"
           )

    drop table(:subagent_delegation_turns)
  end
end
