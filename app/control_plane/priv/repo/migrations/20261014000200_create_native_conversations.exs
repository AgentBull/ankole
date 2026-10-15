defmodule Ankole.Repo.Migrations.CreateNativeConversations do
  use Ecto.Migration

  def change do
    create unique_index(:principals, [:tenant_id, :uid])
    create unique_index(:actor_events, [:tenant_id, :id])

    create table(:conversations, primary_key: false) do
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), primary_key: true
      add :id, :uuid, primary_key: true
      add :kind, :text, null: false, default: "native"
      add :title, :text, null: false

      add :created_by,
          references(:principals,
            column: :uid,
            type: :text,
            with: [tenant_id: :tenant_id],
            on_delete: :delete_all
          ),
          null: false

      add :last_activity_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversations, [:tenant_id, :last_activity_at])
    create constraint(:conversations, :conversations_kind_check, check: "kind = 'native'")
    create constraint(:conversations, :conversations_title_present, check: "btrim(title) <> ''")

    create table(:conversation_participants, primary_key: false) do
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), primary_key: true

      add :conversation_id,
          references(:conversations,
            type: :uuid,
            with: [tenant_id: :tenant_id],
            on_delete: :delete_all
          ),
          primary_key: true

      add :principal_uid,
          references(:principals,
            column: :uid,
            type: :text,
            with: [tenant_id: :tenant_id],
            on_delete: :delete_all
          ),
          primary_key: true

      add :role, :text, null: false
    end

    create index(:conversation_participants, [:tenant_id, :principal_uid])

    create unique_index(:conversation_participants, [:tenant_id, :conversation_id],
             name: :conversation_participants_one_agent_index,
             where: "role = 'agent'"
           )

    create constraint(:conversation_participants, :conversation_participants_role_check,
             check: "role IN ('owner', 'member', 'agent')"
           )

    create table(:conversation_messages, primary_key: false) do
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), primary_key: true
      add :id, :uuid, primary_key: true

      add :conversation_id,
          references(:conversations,
            type: :uuid,
            with: [tenant_id: :tenant_id],
            on_delete: :delete_all
          ),
          null: false

      add :seq, :bigint, null: false
      add :author_type, :text, null: false

      add :author_uid,
          references(:principals,
            column: :uid,
            type: :text,
            with: [tenant_id: :tenant_id],
            on_delete: :delete_all
          ),
          null: false

      add :kind, :text, null: false, default: "message"
      add :text, :text, null: false
      add :reply_to_message_id, :uuid
      add :origin, :text, null: false, default: "native"
      add :session_id, :text

      add :signal_id,
          references(:actor_events,
            type: :uuid,
            with: [tenant_id: :tenant_id],
            on_delete: :restrict
          )

      add :created_at, :utc_datetime_usec, null: false
    end

    create unique_index(:conversation_messages, [:tenant_id, :conversation_id, :seq],
             name: :conversation_messages_sequence_index
           )

    create unique_index(:conversation_messages, [:tenant_id, :signal_id],
             name: :conversation_messages_signal_index,
             where: "signal_id IS NOT NULL"
           )

    create unique_index(:conversation_messages, [:tenant_id, :conversation_id, :id])

    execute(
      "ALTER TABLE conversation_messages ADD CONSTRAINT conversation_messages_reply_to_message_id_fkey " <>
        "FOREIGN KEY (tenant_id, conversation_id, reply_to_message_id) " <>
        "REFERENCES conversation_messages (tenant_id, conversation_id, id) " <>
        "ON DELETE SET NULL (reply_to_message_id)",
      "ALTER TABLE conversation_messages DROP CONSTRAINT conversation_messages_reply_to_message_id_fkey"
    )

    create constraint(:conversation_messages, :conversation_messages_sequence_positive,
             check: "seq > 0"
           )

    create constraint(:conversation_messages, :conversation_messages_author_type_check,
             check: "author_type IN ('human', 'agent')"
           )

    create constraint(:conversation_messages, :conversation_messages_kind_check,
             check: "kind IN ('message', 'notice')"
           )

    create constraint(:conversation_messages, :conversation_messages_text_present,
             check: "btrim(text) <> ''"
           )

    create constraint(:conversation_messages, :conversation_messages_origin_check,
             check: "origin = 'native'"
           )

    create constraint(:conversation_messages, :conversation_messages_provenance_check,
             check:
               "(author_type = 'human' AND signal_id IS NULL AND session_id IS NULL) OR " <>
                 "(author_type = 'agent' AND signal_id IS NOT NULL AND session_id IS NOT NULL " <>
                 "AND session_id = 'conversation:' || conversation_id::text)"
           )
  end
end
