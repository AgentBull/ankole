defmodule Ankole.Repo.Migrations.CreateCodexDelegations do
  use Ecto.Migration

  def up do
    create table(:codex_delegations, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :session_id, :text, null: false
      add :actor_event_id, references(:actor_events, type: :uuid, on_delete: :nilify_all)
      add :tool_call_id, :text
      add :codex_thread_id, :text
      add :workdir, :text
      add :status, :text, null: false
      add :queued_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :result, :map, null: false, default: %{}
      add :error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:codex_delegations, [:agent_uid, :session_id],
             name: :codex_delegations_agent_session_index
           )

    create index(:codex_delegations, [:agent_uid, :status],
             name: :codex_delegations_agent_status_index
           )

    create constraint(:codex_delegations, :codex_delegations_status_check,
             check:
               "status IN ('queued', 'running', 'waiting_on_user', 'succeeded', 'failed', 'stopped')"
           )

    create constraint(:codex_delegations, :codex_delegations_result_object,
             check: "jsonb_typeof(result) = 'object'"
           )

    create constraint(:codex_delegations, :codex_delegations_error_object,
             check: "jsonb_typeof(error) = 'object'"
           )

    create constraint(:codex_delegations, :codex_delegations_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create table(:codex_delegation_events, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :delegation_id, references(:codex_delegations, type: :uuid, on_delete: :delete_all),
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

    create unique_index(:codex_delegation_events, [:delegation_id, :seq],
             name: :codex_delegation_events_delegation_seq_index
           )

    create index(:codex_delegation_events, [:agent_uid, :inserted_at],
             name: :codex_delegation_events_agent_inserted_index
           )

    create constraint(:codex_delegation_events, :codex_delegation_events_direction_check,
             check:
               "direction IN ('client_to_server', 'server_to_client', 'server_request', 'client_response', 'process', 'queue', 'audit', 'tool')"
           )

    create constraint(:codex_delegation_events, :codex_delegation_events_payload_object,
             check: "jsonb_typeof(payload) = 'object'"
           )

    create constraint(:codex_delegation_events, :codex_delegation_events_redaction_object,
             check: "jsonb_typeof(redaction) = 'object'"
           )
  end

  def down do
    drop table(:codex_delegation_events)
    drop table(:codex_delegations)
  end
end
