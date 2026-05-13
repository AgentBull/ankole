defmodule BullX.Repo.Migrations.CreateAgentConversationTables do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE agent_message_role AS ENUM ('system', 'user', 'assistant', 'tool')",
      "DROP TYPE agent_message_role"
    )

    execute(
      "CREATE TYPE agent_message_kind AS ENUM ('normal', 'summary', 'command', 'error')",
      "DROP TYPE agent_message_kind"
    )

    execute(
      "CREATE TYPE agent_message_status AS ENUM ('complete', 'generating')",
      "DROP TYPE agent_message_status"
    )

    create table(:agent_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_principal_id, references(:agents, column: :principal_id, type: :uuid),
        null: false

      add :conversation_key, :text, null: false
      add :current_leaf_message_id, :uuid
      add :ended_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_sessions, [:agent_principal_id])
    create index(:agent_sessions, [:conversation_key])

    create unique_index(:agent_sessions, [:agent_principal_id, :conversation_key],
             name: :agent_sessions_one_active_per_conversation,
             where: "ended_at IS NULL"
           )

    create constraint(:agent_sessions, :agent_sessions_conversation_key_present,
             check: "conversation_key <> ''"
           )

    create constraint(:agent_sessions, :agent_sessions_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create table(:agent_messages, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :session_id, references(:agent_sessions, type: :uuid, on_delete: :delete_all),
        null: false

      add :parent_id, :uuid
      add :role, :agent_message_role, null: false
      add :kind, :agent_message_kind, null: false
      add :status, :agent_message_status, null: false, default: "complete"
      add :content, :map, null: false
      add :covers_range, :map
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_messages, [:session_id, :inserted_at])
    create index(:agent_messages, [:parent_id])

    create unique_index(:agent_messages, [:session_id, :id],
             name: :agent_messages_session_id_id_index
           )

    execute(
      """
      CREATE UNIQUE INDEX agent_messages_route_decision_user_index
      ON agent_messages ((metadata ->> 'route_decision_id'))
      WHERE role = 'user'
        AND metadata ? 'route_decision_id'
      """,
      "DROP INDEX agent_messages_route_decision_user_index"
    )

    create constraint(:agent_messages, :agent_messages_content_array,
             check: "jsonb_typeof(content) = 'array'"
           )

    create constraint(:agent_messages, :agent_messages_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create constraint(:agent_messages, :agent_messages_covers_range_object,
             check: "covers_range IS NULL OR jsonb_typeof(covers_range) = 'object'"
           )

    create constraint(:agent_messages, :agent_messages_summary_covers_range,
             check:
               "(kind = 'summary' AND covers_range IS NOT NULL) OR (kind <> 'summary' AND covers_range IS NULL)"
           )

    create constraint(:agent_messages, :agent_messages_no_self_parent,
             check: "parent_id IS NULL OR id <> parent_id"
           )

    execute(
      """
      ALTER TABLE agent_messages
      ADD CONSTRAINT agent_messages_parent_session_fk
      FOREIGN KEY (session_id, parent_id)
      REFERENCES agent_messages(session_id, id)
      DEFERRABLE INITIALLY DEFERRED
      """,
      "ALTER TABLE agent_messages DROP CONSTRAINT agent_messages_parent_session_fk"
    )

    execute(
      """
      ALTER TABLE agent_sessions
      ADD CONSTRAINT agent_sessions_current_leaf_session_fk
      FOREIGN KEY (id, current_leaf_message_id)
      REFERENCES agent_messages(session_id, id)
      DEFERRABLE INITIALLY DEFERRED
      """,
      "ALTER TABLE agent_sessions DROP CONSTRAINT agent_sessions_current_leaf_session_fk"
    )
  end
end
