defmodule BullX.Repo.Migrations.CreateImGatewayMailboxTables do
  use Ecto.Migration

  def change do
    create_im_gateway_types()
    create_mailbox_types()
    create_im_rooms()
    create_im_messages()
    create_mailboxes()
    create_mailbox_delivery_rules()
    create_mailbox_sessions()
    create_mailbox_entries()
  end

  defp create_im_gateway_types do
    execute(
      "CREATE TYPE im_room_kind AS ENUM ('direct', 'group', 'channel', 'thread', 'unknown')",
      "DROP TYPE im_room_kind"
    )

    execute(
      "CREATE TYPE im_message_direction AS ENUM ('inbound', 'outbound')",
      "DROP TYPE im_message_direction"
    )

    execute(
      "CREATE TYPE im_message_status AS ENUM ('pending', 'received', 'sent', 'edited', 'recalled', 'deleted', 'failed')",
      "DROP TYPE im_message_status"
    )
  end

  defp create_mailbox_types do
    execute(
      "CREATE TYPE mailbox_entry_status AS ENUM ('pending', 'leased', 'processed', 'discarded', 'failed')",
      "DROP TYPE mailbox_entry_status"
    )

    execute(
      "CREATE TYPE mailbox_session_status AS ENUM ('active', 'closed', 'failed')",
      "DROP TYPE mailbox_session_status"
    )

    execute(
      "CREATE TYPE mailbox_attention AS ENUM ('addressed', 'ambient', 'command', 'action', 'lifecycle', 'system')",
      "DROP TYPE mailbox_attention"
    )
  end

  defp create_im_rooms do
    create table(:im_rooms, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :provider, :text, null: false
      add :source_id, :text, null: false
      add :provider_realm_id, :text
      add :provider_room_id, :text, null: false
      add :kind, :im_room_kind, null: false, default: "unknown"
      add :title, :text
      add :parent_room_id, references(:im_rooms, type: :uuid, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:im_rooms, [:provider, :source_id, :provider_room_id])
    create index(:im_rooms, [:parent_room_id])

    create constraint(:im_rooms, :im_rooms_provider_present, check: "provider <> ''")
    create constraint(:im_rooms, :im_rooms_source_id_present, check: "source_id <> ''")

    create constraint(:im_rooms, :im_rooms_provider_room_id_present,
             check: "provider_room_id <> ''"
           )

    create constraint(:im_rooms, :im_rooms_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )
  end

  defp create_im_messages do
    create table(:im_messages, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :room_id, references(:im_rooms, type: :uuid, on_delete: :delete_all), null: false
      add :direction, :im_message_direction, null: false
      add :status, :im_message_status, null: false
      add :provider_message_id, :text
      add :provider_occurrence_id, :text
      add :actor_kind, :text, null: false, default: "unknown"
      add :actor_principal_id, references(:principals, type: :uuid, on_delete: :nilify_all)

      add :actor_external_identity_id,
          references(:principal_external_identities, type: :uuid, on_delete: :nilify_all)

      add :actor_provider_id, :text
      add :actor, :map, null: false, default: %{}
      add :message_kind, :text, null: false
      add :text, :text
      add :content, :map, null: false, default: %{}
      add :attachments, :map, null: false, default: fragment("'[]'::jsonb")
      add :mentions, :map, null: false, default: fragment("'[]'::jsonb")
      add :reply_address, :map
      add :provider_created_at, :utc_datetime_usec
      add :provider_updated_at, :utc_datetime_usec
      add :received_at, :utc_datetime_usec, null: false
      add :sent_at, :utc_datetime_usec
      add :safe_error, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:im_messages, [:room_id, :provider_message_id],
             where: "provider_message_id IS NOT NULL",
             name: :im_messages_provider_message_unique_idx
           )

    create unique_index(:im_messages, [:room_id, :provider_occurrence_id],
             where: "provider_occurrence_id IS NOT NULL",
             name: :im_messages_provider_occurrence_unique_idx
           )

    create index(:im_messages, [:room_id, :provider_created_at, :id],
             name: :im_messages_room_time_idx
           )

    create index(:im_messages, [:actor_principal_id], where: "actor_principal_id IS NOT NULL")

    create constraint(:im_messages, :im_messages_message_kind_present,
             check: "message_kind <> ''"
           )

    create constraint(:im_messages, :im_messages_actor_kind_present, check: "actor_kind <> ''")

    create constraint(:im_messages, :im_messages_human_actor_has_principal,
             check: "actor_kind <> 'human' OR actor_principal_id IS NOT NULL"
           )

    create constraint(:im_messages, :im_messages_actor_object,
             check: "jsonb_typeof(actor) = 'object'"
           )

    create constraint(:im_messages, :im_messages_content_object,
             check: "jsonb_typeof(content) = 'object'"
           )

    create constraint(:im_messages, :im_messages_attachments_array,
             check: "jsonb_typeof(attachments) = 'array'"
           )

    create constraint(:im_messages, :im_messages_mentions_array,
             check: "jsonb_typeof(mentions) = 'array'"
           )

    create constraint(:im_messages, :im_messages_reply_address_object,
             check: "reply_address IS NULL OR jsonb_typeof(reply_address) = 'object'"
           )

    create constraint(:im_messages, :im_messages_safe_error_object,
             check: "safe_error IS NULL OR jsonb_typeof(safe_error) = 'object'"
           )
  end

  defp create_mailboxes do
    create table(:mailboxes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :receiver_type, :text, null: false
      add :receiver_ref, :text, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mailboxes, [:receiver_type, :receiver_ref])
    create constraint(:mailboxes, :mailboxes_receiver_type_present, check: "receiver_type <> ''")
    create constraint(:mailboxes, :mailboxes_receiver_ref_present, check: "receiver_ref <> ''")

    create constraint(:mailboxes, :mailboxes_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )
  end

  defp create_mailbox_delivery_rules do
    create table(:mailbox_delivery_rules, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :active, :boolean, null: false, default: true
      add :priority, :integer, null: false
      add :match_expr, :text, null: false
      add :receiver_type, :text, null: false
      add :receiver_ref, :text, null: false
      add :attention, :mailbox_attention, null: false
      add :session_key_template, :text
      add :available_delay_ms, :integer, null: false, default: 0
      add :coalesce_key_template, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mailbox_delivery_rules, [:name])
    create index(:mailbox_delivery_rules, [:priority, :id], where: "active = true")

    create constraint(:mailbox_delivery_rules, :mailbox_delivery_rules_name_present,
             check: "name = btrim(name) AND name <> ''"
           )

    create constraint(:mailbox_delivery_rules, :mailbox_delivery_rules_priority_positive,
             check: "priority > 0"
           )

    create constraint(:mailbox_delivery_rules, :mailbox_delivery_rules_match_expr_present,
             check: "match_expr <> ''"
           )

    create constraint(:mailbox_delivery_rules, :mailbox_delivery_rules_receiver_type_present,
             check: "receiver_type <> ''"
           )

    create constraint(:mailbox_delivery_rules, :mailbox_delivery_rules_receiver_ref_present,
             check: "receiver_ref <> ''"
           )

    create constraint(
             :mailbox_delivery_rules,
             :mailbox_delivery_rules_available_delay_ms_nonnegative,
             check: "available_delay_ms >= 0"
           )

    create constraint(:mailbox_delivery_rules, :mailbox_delivery_rules_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )
  end

  defp create_mailbox_sessions do
    create table(:mailbox_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :mailbox_id, references(:mailboxes, type: :uuid, on_delete: :delete_all), null: false
      add :session_key, :text, null: false
      add :status, :mailbox_session_status, null: false, default: "active"
      add :last_entry_at, :utc_datetime_usec, null: false
      add :lease_holder, :text
      add :lease_expires_at, :utc_datetime_usec
      add :closed_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      "ALTER TABLE mailbox_sessions SET UNLOGGED",
      "ALTER TABLE mailbox_sessions SET LOGGED"
    )

    create unique_index(:mailbox_sessions, [:mailbox_id, :session_key])
    create index(:mailbox_sessions, [:mailbox_id, :last_entry_at], where: "status = 'active'")

    create constraint(:mailbox_sessions, :mailbox_sessions_session_key_present,
             check: "session_key <> ''"
           )

    create constraint(:mailbox_sessions, :mailbox_sessions_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )
  end

  defp create_mailbox_entries do
    create table(:mailbox_entries, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :entry_seq, :bigserial, null: false
      add :mailbox_id, references(:mailboxes, type: :uuid, on_delete: :delete_all), null: false

      add :mailbox_session_id, :uuid

      add :status, :mailbox_entry_status, null: false, default: "pending"
      add :attention, :mailbox_attention, null: false
      add :cloud_event, :map, null: false
      add :reply_address, :map
      add :available_at, :utc_datetime_usec, null: false
      add :dedupe_hash, :binary, null: false
      add :coalesce_key, :text
      add :lease_holder, :text
      add :lease_expires_at, :utc_datetime_usec
      add :attempts, :integer, null: false, default: 0
      add :safe_error, :map

      timestamps(type: :utc_datetime_usec)
    end

    execute("ALTER TABLE mailbox_entries SET UNLOGGED", "ALTER TABLE mailbox_entries SET LOGGED")

    execute(
      """
      ALTER TABLE mailbox_entries
      ADD CONSTRAINT mailbox_entries_mailbox_session_id_fkey
      FOREIGN KEY (mailbox_session_id)
      REFERENCES mailbox_sessions(id)
      ON DELETE SET NULL
      """,
      "ALTER TABLE mailbox_entries DROP CONSTRAINT mailbox_entries_mailbox_session_id_fkey"
    )

    create unique_index(:mailbox_entries, [:mailbox_id, :dedupe_hash])

    create index(:mailbox_entries, [:available_at, :lease_expires_at, :entry_seq],
             where: "status IN ('pending', 'leased')",
             name: :mailbox_entries_ready_idx
           )

    create index(:mailbox_entries, [:mailbox_session_id, :entry_seq])

    create constraint(:mailbox_entries, :mailbox_entries_cloud_event_object,
             check: "jsonb_typeof(cloud_event) = 'object'"
           )

    create constraint(:mailbox_entries, :mailbox_entries_reply_address_object,
             check: "reply_address IS NULL OR jsonb_typeof(reply_address) = 'object'"
           )

    create constraint(:mailbox_entries, :mailbox_entries_safe_error_object,
             check: "safe_error IS NULL OR jsonb_typeof(safe_error) = 'object'"
           )

    create constraint(:mailbox_entries, :mailbox_entries_attempts_nonnegative,
             check: "attempts >= 0"
           )
  end
end
