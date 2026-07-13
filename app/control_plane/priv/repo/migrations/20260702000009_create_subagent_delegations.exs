defmodule Ankole.Repo.Migrations.CreateSubagentDelegations do
  use Ecto.Migration

  def up do
    create table(:subagent_delegations, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :session_id, :text, null: false
      add :actor_event_id, references(:actor_events, type: :uuid, on_delete: :nilify_all)
      add :tool_call_id, :text
      add :runtime_thread_id, :text
      add :workdir, :text
      add :status, :text, null: false
      add :queued_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :result, :map, null: false, default: %{}
      add :error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :runtime, :text, null: false, default: "task_worker"
      add :title, :text, null: false
      add :task, :text, null: false
      add :background, :text
      add :notes, :text
      add :reply_route, :map, null: false, default: %{}
      add :attempts, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:subagent_delegations, [:agent_uid, :session_id],
             name: :subagent_delegations_agent_session_index
           )

    create index(:subagent_delegations, [:agent_uid, :status],
             name: :subagent_delegations_agent_status_index
           )

    execute("""
    CREATE INDEX subagent_delegations_agent_status_queued_index
    ON subagent_delegations (agent_uid, status, queued_at DESC)
    """)

    execute("""
    CREATE INDEX subagent_delegations_agent_channel_queued_index
    ON subagent_delegations (agent_uid, (reply_route->>'signal_channel_id'), queued_at DESC)
    """)

    create unique_index(:subagent_delegations, [:agent_uid, :session_id, :tool_call_id],
             name: :subagent_delegations_parent_tool_call_index,
             where: "tool_call_id IS NOT NULL"
           )

    create constraint(:subagent_delegations, :subagent_delegations_status_check,
             check:
               "status IN ('queued', 'running', 'waiting_on_user', 'succeeded', 'failed', 'stopped')"
           )

    create constraint(:subagent_delegations, :subagent_delegations_result_object,
             check: "jsonb_typeof(result) = 'object'"
           )

    create constraint(:subagent_delegations, :subagent_delegations_error_object,
             check: "jsonb_typeof(error) = 'object'"
           )

    create constraint(:subagent_delegations, :subagent_delegations_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create constraint(:subagent_delegations, :subagent_delegations_runtime_check,
             check: "runtime IN ('task_worker')"
           )

    create constraint(:subagent_delegations, :subagent_delegations_reply_route_object,
             check: "jsonb_typeof(reply_route) = 'object'"
           )

    create constraint(:subagent_delegations, :subagent_delegations_attempts_nonnegative,
             check: "attempts >= 0"
           )

    create table(:subagent_delegation_events, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :delegation_id,
          references(:subagent_delegations, type: :uuid, on_delete: :delete_all),
          null: false

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
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

    create constraint(
             :subagent_delegation_events,
             :subagent_delegation_events_direction_check,
             check:
               "direction IN ('client_to_server', 'server_to_client', 'server_request', 'client_response', 'process', 'queue', 'audit', 'tool')"
           )

    create constraint(
             :subagent_delegation_events,
             :subagent_delegation_events_payload_object,
             check: "jsonb_typeof(payload) = 'object'"
           )

    create constraint(
             :subagent_delegation_events,
             :subagent_delegation_events_redaction_object,
             check: "jsonb_typeof(redaction) = 'object'"
           )
  end

  def down do
    drop table(:subagent_delegation_events)
    drop table(:subagent_delegations)
  end
end
