defmodule Ankole.Repo.Migrations.CreateSignalsGateway do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TYPE signal_channel_kind AS ENUM (
        'im_dm',
        'im_group',
        'webhook_endpoint',
        'issue',
        'alert_stream',
        'unknown'
      )
      """,
      "DROP TYPE signal_channel_kind"
    )

    execute(
      "CREATE TYPE signal_reply_mode AS ENUM ('none', 'channel', 'entry')",
      "DROP TYPE signal_reply_mode"
    )

    execute(
      "CREATE TYPE signal_group_message_policy AS ENUM ('ignore', 'record_only', 'may_intervene')",
      "DROP TYPE signal_group_message_policy"
    )

    execute(
      """
      CREATE TYPE signal_gateway_outbox_operation AS ENUM (
        'post',
        'reply',
        'edit',
        'delete',
        'reaction_add',
        'reaction_remove',
        'divider',
        'card'
      )
      """,
      "DROP TYPE signal_gateway_outbox_operation"
    )

    execute(
      """
      CREATE TYPE signal_gateway_outbox_status AS ENUM (
        'created',
        'unsupported',
        'sending',
        'succeeded',
        'failed',
        'unknown_after_send'
      )
      """,
      "DROP TYPE signal_gateway_outbox_status"
    )

    create table(:signal_bindings, primary_key: false) do
      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :name, :text, primary_key: true
      add :adapter, :text, null: false
      add :config_ref, :text, null: false
      add :filters, :map, null: false, default: %{}

      add :unaddressed_group_message_policy,
          :signal_group_message_policy,
          null: false,
          default: "ignore"

      add :enabled, :boolean, null: false, default: true
      add :unavailable_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:signal_bindings, [:adapter])

    create constraint(:signal_bindings, :signal_bindings_name_present,
             check: "length(btrim(name)) > 0"
           )

    create constraint(:signal_bindings, :signal_bindings_adapter_present,
             check: "length(btrim(adapter)) > 0"
           )

    create constraint(:signal_bindings, :signal_bindings_config_ref_present,
             check: "length(btrim(config_ref)) > 0"
           )

    create constraint(:signal_bindings, :signal_bindings_filters_object,
             check: "jsonb_typeof(filters) = 'object'"
           )

    create table(:signal_channels, primary_key: false) do
      add :id, :text, primary_key: true
      add :kind, :signal_channel_kind, null: false, default: "unknown"
      add :reply_mode, :signal_reply_mode, null: false, default: "none"
      add :name, :text
      add :title, :text
      add :visibility, :text
      add :metadata, :map, null: false, default: %{}
      add :raw_payload, :map, null: false, default: %{}
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:signal_channels, :signal_channels_id_present,
             check: "length(btrim(id)) > 0"
           )

    create constraint(:signal_channels, :signal_channels_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create constraint(:signal_channels, :signal_channels_raw_payload_object,
             check: "jsonb_typeof(raw_payload) = 'object'"
           )

    create table(:signal_entries, primary_key: false) do
      add :signal_channel_id,
          references(:signal_channels, column: :id, type: :text, on_delete: :delete_all),
          primary_key: true

      add :provider_entry_id, :text, primary_key: true
      add :text, :text
      add :formatted_content, :map, null: false, default: %{}
      add :attachments, {:array, :map}, null: false, default: []
      add :links, {:array, :map}, null: false, default: []
      add :author, :map, null: false, default: %{}
      add :mentions, {:array, :map}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      add :raw_payload, :map, null: false, default: %{}
      add :provider_time, :utc_datetime_usec
      add :fallback_visible_text, :text
      add :reactions, :map, null: false, default: %{}
      add :raw_reaction_keys, :map, null: false, default: %{}
      add :document_id, :text, null: false
      add :search_text, :text
      add :metadata_text, :text
      add :content_hash, :text
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:signal_entries, [:document_id])
    create index(:signal_entries, [:last_seen_at])

    create constraint(:signal_entries, :signal_entries_provider_entry_id_present,
             check: "length(btrim(provider_entry_id)) > 0"
           )

    create constraint(:signal_entries, :signal_entries_document_id_present,
             check: "length(btrim(document_id)) > 0"
           )

    create table(:signal_gateway_input_tombstones, primary_key: false) do
      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :binding_name, :text, primary_key: true

      add :signal_channel_id,
          references(:signal_channels, column: :id, type: :text, on_delete: :delete_all),
          primary_key: true

      add :provider_entry_id, :text, primary_key: true
      add :tombstoned_until, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:signal_gateway_input_tombstones, [:tombstoned_until])

    create table(:actor_mailbox, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :binding_name, :text, null: false
      add :session_id, :text, null: false
      add :ingress_event_id, :text, null: false
      add :signal_channel_id, :text
      add :provider_thread_id, :text
      add :provider_entry_id, :text
      add :type, :text, null: false
      add :available_at, :utc_datetime_usec, null: false
      add :batch_scope, :map
      add :sender_key, :text
      add :payload, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :actor_mailbox,
             [:agent_uid, :binding_name, :ingress_event_id],
             name: :actor_mailbox_signal_idempotency_index
           )

    create index(:actor_mailbox, [:agent_uid, :session_id, :available_at],
             name: :actor_mailbox_ready_index
           )

    create index(
             :actor_mailbox,
             [:agent_uid, :binding_name, :signal_channel_id, :provider_entry_id],
             name: :actor_mailbox_signal_entry_index
           )

    create index(
             :actor_mailbox,
             [:agent_uid, :binding_name, :signal_channel_id, :provider_thread_id],
             name: :actor_mailbox_batch_scope_index
           )

    create constraint(:actor_mailbox, :actor_mailbox_payload_object,
             check: "jsonb_typeof(payload) = 'object'"
           )

    create table(:actor_consumed_inputs, primary_key: false) do
      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :binding_name, :text, primary_key: true
      add :ingress_event_id, :text, primary_key: true
      add :session_id, :text, null: false
      add :signal_channel_id, :text
      add :provider_thread_id, :text
      add :provider_entry_id, :text
      add :type, :text, null: false
      add :consumed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(
             :actor_consumed_inputs,
             [:agent_uid, :binding_name, :signal_channel_id, :provider_entry_id],
             name: :actor_consumed_inputs_signal_entry_index
           )

    create table(:signal_gateway_outbox, primary_key: false) do
      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :binding_name, :text, primary_key: true
      add :outbound_key, :text, primary_key: true
      add :operation, :signal_gateway_outbox_operation, null: false
      add :status, :signal_gateway_outbox_status, null: false, default: "created"
      add :signal_channel_id, :text
      add :provider_thread_id, :text
      add :source_provider_entry_id, :text
      add :target_provider_entry_id, :text
      add :provider_entry_id, :text
      add :payload, :map, null: false, default: %{}
      add :fallback_visible_text, :text
      add :idempotency_key, :text
      add :attempt_count, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 10
      add :last_attempted_at, :utc_datetime_usec
      add :last_error, :map, null: false, default: %{}
      add :platform_send_started_at, :utc_datetime_usec
      add :next_attempt_at, :utc_datetime_usec
      add :recovery_state, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:signal_gateway_outbox, [:status, :next_attempt_at])
    create index(:signal_gateway_outbox, [:signal_channel_id, :provider_entry_id])

    create constraint(:signal_gateway_outbox, :signal_gateway_outbox_payload_object,
             check: "jsonb_typeof(payload) = 'object'"
           )

    create constraint(:signal_gateway_outbox, :signal_gateway_outbox_last_error_object,
             check: "jsonb_typeof(last_error) = 'object'"
           )

    create constraint(:signal_gateway_outbox, :signal_gateway_outbox_recovery_state_object,
             check: "jsonb_typeof(recovery_state) = 'object'"
           )

    create constraint(:signal_gateway_outbox, :signal_gateway_outbox_attempts_non_negative,
             check: "attempt_count >= 0 AND max_attempts > 0"
           )
  end
end
