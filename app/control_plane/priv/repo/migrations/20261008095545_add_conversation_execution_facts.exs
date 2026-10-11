defmodule Ankole.Repo.Migrations.AddConversationExecutionFacts do
  use Ecto.Migration

  def change do
    alter table(:actor_events) do
      add :attempt_count, :integer, null: false, default: 0
      add :provider_capacity_attempt_count, :integer, null: false, default: 0
      add :last_attempt_at, :utc_datetime_usec
    end

    create constraint(:actor_events, :actor_events_attempt_count_non_negative,
             check: "attempt_count >= 0"
           )

    create constraint(:actor_events, :actor_events_capacity_attempt_count_check,
             check:
               "provider_capacity_attempt_count >= 0 AND provider_capacity_attempt_count <= attempt_count"
           )

    alter table(:actor_session_workspaces) do
      add :epoch, :bigint, null: false, default: 0
    end

    create constraint(:actor_session_workspaces, :actor_session_workspaces_epoch_non_negative,
             check: "epoch >= 0"
           )

    create table(:conversation_tool_receipts, primary_key: false) do
      add :response_id, :text, primary_key: true
      add :call_id, :text, primary_key: true

      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :session_id, :text, null: false
      add :result, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:conversation_tool_receipts, [:agent_uid, :session_id])

    create constraint(:conversation_tool_receipts, :conversation_tool_receipts_result_object,
             check: "jsonb_typeof(result) = 'object'"
           )
  end
end
