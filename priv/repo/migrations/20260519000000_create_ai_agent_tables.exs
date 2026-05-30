defmodule BullX.Repo.Migrations.CreateAiAgentTables do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE ai_agent_message_role AS ENUM ('user', 'assistant', 'tool', 'im_ambient')",
      "DROP TYPE ai_agent_message_role"
    )

    execute(
      "CREATE TYPE ai_agent_message_kind AS ENUM ('normal', 'summary', 'introspection', 'error')",
      "DROP TYPE ai_agent_message_kind"
    )

    execute(
      "CREATE TYPE ai_agent_message_status AS ENUM ('generating', 'complete')",
      "DROP TYPE ai_agent_message_status"
    )

    create table(:conversations, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid, references(:agents, column: :uid, type: :text, on_delete: :restrict),
        null: false

      add :conversation_key, :text, null: false
      add :ended_at, :utc_datetime_usec
      add :generation, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:conversations, :conversations_generation_object,
             check: "jsonb_typeof(generation) = 'object'"
           )

    create constraint(:conversations, :conversations_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create unique_index(:conversations, [:agent_uid, :conversation_key],
             where: "ended_at IS NULL",
             name: :conversations_active_agent_key_index
           )

    create unique_index(:conversations, [:id, :agent_uid],
             name: :conversations_id_agent_uid_index
           )

    create table(:conversation_messages, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid, references(:agents, column: :uid, type: :text, on_delete: :restrict),
        null: false

      add :conversation_id, references(:conversations, type: :uuid, on_delete: :restrict),
        null: false

      add :role, :ai_agent_message_role, null: false
      add :kind, :ai_agent_message_kind, null: false
      add :status, :ai_agent_message_status, null: false
      add :content, :map, null: false
      add :covers_range, :map
      add :mailbox_session_id, :uuid
      add :event_source, :text
      add :event_id, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversation_messages, [:conversation_id, :inserted_at])
    create index(:conversation_messages, [:mailbox_session_id])

    create index(
             :conversation_messages,
             [:agent_uid, "((metadata->'scene'->>'scene_key'))", :inserted_at, :id],
             where: "role = 'im_ambient' AND kind = 'normal'",
             name: :conversation_messages_ambient_recall_idx
           )

    create index(:conversation_messages, [:conversation_id, :inserted_at, :id],
             where: "kind <> 'summary' AND NOT (metadata ? 'transcript_effect')",
             name: :conversation_messages_visible_transcript_idx
           )

    create index(
             :conversation_messages,
             [
               :conversation_id,
               "((covers_range->>'from_id'))",
               "((covers_range->>'to_id'))",
               :inserted_at,
               :id
             ],
             where:
               "role = 'assistant' AND kind = 'summary' AND status = 'complete' AND NOT (metadata ? 'transcript_effect')",
             name: :conversation_messages_summary_lookup_idx
           )

    create unique_index(:conversation_messages, [:conversation_id, :event_source, :event_id],
             where:
               "event_source IS NOT NULL AND event_id IS NOT NULL AND role IN ('user', 'im_ambient') AND kind = 'normal'",
             name: :conversation_messages_inbound_event_unique_index
           )

    create unique_index(
             :conversation_messages,
             [
               :conversation_id,
               "((metadata->>'ambient_batch_idempotency_key'))"
             ],
             where:
               "role = 'im_ambient' AND kind = 'introspection' AND metadata ? 'ambient_batch_idempotency_key'",
             name: :conversation_messages_ambient_batch_unique_index
           )

    create constraint(:conversation_messages, :conversation_messages_content_array,
             check: "jsonb_typeof(content) = 'array'"
           )

    create constraint(:conversation_messages, :conversation_messages_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create constraint(:conversation_messages, :conversation_messages_covers_range_object,
             check: "covers_range IS NULL OR jsonb_typeof(covers_range) = 'object'"
           )

    create constraint(:conversation_messages, :conversation_messages_valid_role_kind_status,
             check: """
             (role = 'user' AND kind = 'normal' AND status = 'complete') OR
             (role = 'user' AND kind = 'introspection' AND status = 'complete') OR
             (role = 'assistant' AND kind = 'normal' AND status IN ('generating', 'complete')) OR
             (role = 'assistant' AND kind = 'summary' AND status = 'complete') OR
             (role = 'assistant' AND kind = 'error' AND status = 'complete') OR
             (role = 'tool' AND kind = 'normal' AND status = 'complete') OR
             (role = 'im_ambient' AND kind = 'normal' AND status = 'complete') OR
             (role = 'im_ambient' AND kind = 'introspection' AND status = 'complete')
             """
           )

    create constraint(:conversation_messages, :conversation_messages_summary_contract,
             check: """
             NOT (role = 'assistant' AND kind = 'summary') OR (
               covers_range ? 'from_id' AND
               covers_range ? 'to_id' AND
               metadata ? 'original_dialogue_time_range' AND
               metadata ? 'compression' AND
               jsonb_path_exists(content, '$[*] ? (@.type == "summary_text" && @.text.type() == "string")')
             )
             """
           )

    execute(
      """
      ALTER TABLE conversation_messages
      ADD CONSTRAINT conversation_messages_conversation_agent_fkey
      FOREIGN KEY (conversation_id, agent_uid)
      REFERENCES conversations(id, agent_uid)
      DEFERRABLE INITIALLY IMMEDIATE
      """,
      "ALTER TABLE conversation_messages DROP CONSTRAINT conversation_messages_conversation_agent_fkey"
    )
  end
end
