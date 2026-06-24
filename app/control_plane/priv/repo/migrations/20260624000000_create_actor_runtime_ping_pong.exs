defmodule Ankole.Repo.Migrations.CreateActorRuntimePingPong do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto", "")

    rename table(:actor_mailbox), to: table(:actor_inputs)
    rename table(:actor_consumed_inputs), to: table(:actor_input_consumptions)

    execute(
      "ALTER INDEX actor_mailbox_signal_idempotency_index RENAME TO actor_inputs_signal_idempotency_index",
      "ALTER INDEX actor_inputs_signal_idempotency_index RENAME TO actor_mailbox_signal_idempotency_index"
    )

    execute(
      "ALTER INDEX actor_mailbox_ready_index RENAME TO actor_inputs_ready_index_legacy",
      "ALTER INDEX actor_inputs_ready_index_legacy RENAME TO actor_mailbox_ready_index"
    )

    execute(
      "ALTER INDEX actor_mailbox_signal_entry_index RENAME TO actor_inputs_signal_entry_index",
      "ALTER INDEX actor_inputs_signal_entry_index RENAME TO actor_mailbox_signal_entry_index"
    )

    execute(
      "ALTER INDEX actor_mailbox_batch_scope_index RENAME TO actor_inputs_batch_scope_index",
      "ALTER INDEX actor_inputs_batch_scope_index RENAME TO actor_mailbox_batch_scope_index"
    )

    execute(
      "ALTER TABLE actor_inputs RENAME CONSTRAINT actor_mailbox_payload_object TO actor_inputs_payload_object",
      "ALTER TABLE actor_inputs RENAME CONSTRAINT actor_inputs_payload_object TO actor_mailbox_payload_object"
    )

    alter table(:actor_inputs) do
      add :broker_sequence, :bigint
      add :input_state, :text, null: false, default: "open"
      add :dead_letter_at, :utc_datetime_usec
    end

    execute("""
    WITH numbered AS (
      SELECT id,
             row_number() OVER (
               PARTITION BY agent_uid, session_id
               ORDER BY inserted_at, id
             ) AS seq
      FROM actor_inputs
    )
    UPDATE actor_inputs
    SET broker_sequence = numbered.seq
    FROM numbered
    WHERE actor_inputs.id = numbered.id
    """)

    alter table(:actor_inputs) do
      modify :broker_sequence, :bigint, null: false
    end

    create unique_index(:actor_inputs, [:agent_uid, :session_id, :broker_sequence],
             name: :actor_inputs_actor_sequence_index
           )

    create index(
             :actor_inputs,
             [:agent_uid, :session_id, :input_state, :available_at, :broker_sequence],
             name: :actor_inputs_ready_index
           )

    create constraint(:actor_inputs, :actor_inputs_input_state_check,
             check: "input_state IN ('open', 'dead_letter')"
           )

    execute("ALTER TABLE actor_input_consumptions DROP CONSTRAINT actor_consumed_inputs_pkey")

    alter table(:actor_input_consumptions) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()")
      add :actor_input_id, :uuid
      add :conversation_id, :uuid
      add :user_message_id, :uuid
      add :llm_turn_id, :uuid
      add :activation_uid, :text
      add :actor_epoch, :bigint
      add :revision, :integer
    end

    execute(
      "ALTER TABLE actor_input_consumptions ADD PRIMARY KEY (id)",
      "ALTER TABLE actor_input_consumptions DROP CONSTRAINT actor_input_consumptions_pkey"
    )

    create unique_index(:actor_input_consumptions, [:agent_uid, :binding_name, :ingress_event_id],
             name: :actor_input_consumptions_signal_idempotency_index
           )

    create unique_index(:actor_input_consumptions, [:actor_input_id],
             name: :actor_input_consumptions_actor_input_id_index
           )

    create index(:actor_input_consumptions, [:llm_turn_id],
             name: :actor_input_consumptions_llm_turn_id_index
           )

    create index(
             :actor_input_consumptions,
             [:agent_uid, :binding_name, :signal_channel_id, :provider_entry_id],
             name: :actor_input_consumptions_signal_entry_index
           )

    create table(:ai_agent_conversations, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :conversation_key, :text, null: false
      add :ended_at, :utc_datetime_usec
      add :generation, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ai_agent_conversations, [:agent_uid, :conversation_key],
             name: :ai_agent_conversations_active_key_index,
             where: "ended_at IS NULL"
           )

    create constraint(:ai_agent_conversations, :ai_agent_conversations_generation_object,
             check: "jsonb_typeof(generation) = 'object'"
           )

    create constraint(:ai_agent_conversations, :ai_agent_conversations_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create table(:ai_agent_messages, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :conversation_id,
          references(:ai_agent_conversations, type: :uuid, on_delete: :delete_all), null: false

      add :role, :text, null: false
      add :kind, :text, null: false
      add :status, :text, null: false
      add :content, :map, null: false, default: fragment("'[]'::jsonb")
      add :agent_message, :map
      add :covers_range, :map
      add :event_source, :text
      add :event_id, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ai_agent_messages, [:conversation_id, :event_source, :event_id],
             name: :ai_agent_messages_inbound_event_index,
             where:
               "role IN ('user', 'im_ambient') AND kind = 'normal' AND event_source IS NOT NULL AND event_id IS NOT NULL"
           )

    create index(:ai_agent_messages, [:agent_uid, :conversation_id],
             name: :ai_agent_messages_conversation_index
           )

    create constraint(:ai_agent_messages, :ai_agent_messages_role_check,
             check: "role IN ('user', 'assistant', 'tool', 'im_ambient')"
           )

    create constraint(:ai_agent_messages, :ai_agent_messages_kind_check,
             check: "kind IN ('normal', 'summary', 'introspection', 'error')"
           )

    create constraint(:ai_agent_messages, :ai_agent_messages_status_check,
             check: "status IN ('generating', 'complete')"
           )

    create constraint(:ai_agent_messages, :ai_agent_messages_content_array,
             check: "jsonb_typeof(content) = 'array'"
           )

    create constraint(:ai_agent_messages, :ai_agent_messages_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create table(:ai_agent_llm_turns, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :conversation_id,
          references(:ai_agent_conversations, type: :uuid, on_delete: :delete_all), null: false

      add :kind, :text, null: false
      add :status, :text, null: false
      add :profile, :text, null: false
      add :provider, :text, null: false
      add :model, :text, null: false
      add :lease_id, :text
      add :call_index, :integer
      add :branch_id, :text
      add :parent_branch_id, :text
      add :trigger_message_id, :uuid
      add :trigger_event_id, :text
      add :input_message_ids, :map, null: false, default: fragment("'[]'::jsonb")
      add :request_context, :map, null: false, default: %{}
      add :request_refs, :map, null: false, default: fragment("'[]'::jsonb")
      add :request_patches, :map, null: false, default: fragment("'[]'::jsonb")
      add :response, :map, null: false, default: %{}
      add :tool_results, :map, null: false, default: fragment("'[]'::jsonb")
      add :usage, :map, null: false, default: %{}
      add :provider_metadata, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ai_agent_llm_turns, [:conversation_id, :lease_id, :call_index],
             name: :ai_agent_llm_turns_generation_call_index,
             where: "lease_id IS NOT NULL AND call_index IS NOT NULL"
           )

    create index(:ai_agent_llm_turns, [:agent_uid, :conversation_id, :status],
             name: :ai_agent_llm_turns_conversation_status_index
           )

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_kind_check,
             check:
               "kind IN ('generation', 'retry_generation', 'scheduled_task', 'checkback_generation', 'compression', 'ambient_recognizer', 'overflow_retry')"
           )

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_status_check,
             check: "status IN ('started', 'succeeded', 'failed', 'cancelled')"
           )

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_profile_check,
             check: "profile IN ('primary', 'light', 'heavy')"
           )

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_input_message_ids_array,
             check: "jsonb_typeof(input_message_ids) = 'array'"
           )

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_request_context_object,
             check: "jsonb_typeof(request_context) = 'object'"
           )

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_request_refs_array,
             check: "jsonb_typeof(request_refs) = 'array'"
           )

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_request_patches_array,
             check: "jsonb_typeof(request_patches) = 'array'"
           )

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_response_object,
             check: "jsonb_typeof(response) = 'object'"
           )

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_tool_results_array,
             check: "jsonb_typeof(tool_results) = 'array'"
           )

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_usage_object,
             check: "jsonb_typeof(usage) = 'object'"
           )

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_provider_metadata_object,
             check: "jsonb_typeof(provider_metadata) = 'object'"
           )

    create_unlogged_actor_runtime_tables()

    alter table(:signal_gateway_outbox) do
      add :source_actor_input_id, :uuid
      add :llm_turn_id, :uuid
      add :assistant_message_id, :uuid
    end

    create index(:signal_gateway_outbox, [:llm_turn_id],
             name: :signal_gateway_outbox_llm_turn_id_index
           )

    create index(:signal_gateway_outbox, [:source_actor_input_id],
             name: :signal_gateway_outbox_actor_input_id_index
           )
  end

  def down do
    drop index(:signal_gateway_outbox, [:source_actor_input_id],
           name: :signal_gateway_outbox_actor_input_id_index
         )

    drop index(:signal_gateway_outbox, [:llm_turn_id],
           name: :signal_gateway_outbox_llm_turn_id_index
         )

    alter table(:signal_gateway_outbox) do
      remove :assistant_message_id
      remove :llm_turn_id
      remove :source_actor_input_id
    end

    execute("DROP TABLE IF EXISTS actor_session_activations")
    execute("DROP TABLE IF EXISTS actor_session_worker_assignments")
    execute("DROP TABLE IF EXISTS agent_computer_workers")
    execute("DROP TABLE IF EXISTS actor_input_deliveries")

    drop table(:ai_agent_llm_turns)
    drop table(:ai_agent_messages)
    drop table(:ai_agent_conversations)

    drop index(:actor_input_consumptions, [:llm_turn_id],
           name: :actor_input_consumptions_llm_turn_id_index
         )

    drop index(:actor_input_consumptions, [:actor_input_id],
           name: :actor_input_consumptions_actor_input_id_index
         )

    drop index(:actor_input_consumptions, [:agent_uid, :binding_name, :ingress_event_id],
           name: :actor_input_consumptions_signal_idempotency_index
         )

    execute("ALTER TABLE actor_input_consumptions DROP CONSTRAINT actor_input_consumptions_pkey")

    alter table(:actor_input_consumptions) do
      remove :revision
      remove :actor_epoch
      remove :activation_uid
      remove :llm_turn_id
      remove :user_message_id
      remove :conversation_id
      remove :actor_input_id
      remove :id
    end

    execute(
      "ALTER TABLE actor_input_consumptions ADD PRIMARY KEY (agent_uid, binding_name, ingress_event_id)",
      "ALTER TABLE actor_input_consumptions DROP CONSTRAINT actor_consumed_inputs_pkey"
    )

    drop constraint(:actor_inputs, :actor_inputs_input_state_check)

    drop index(
           :actor_inputs,
           [:agent_uid, :session_id, :input_state, :available_at, :broker_sequence],
           name: :actor_inputs_ready_index
         )

    drop index(:actor_inputs, [:agent_uid, :session_id, :broker_sequence],
           name: :actor_inputs_actor_sequence_index
         )

    alter table(:actor_inputs) do
      remove :dead_letter_at
      remove :input_state
      remove :broker_sequence
    end

    rename table(:actor_input_consumptions), to: table(:actor_consumed_inputs)
    rename table(:actor_inputs), to: table(:actor_mailbox)
  end

  defp create_unlogged_actor_runtime_tables do
    execute("""
    CREATE UNLOGGED TABLE actor_input_deliveries (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      actor_input_id uuid NOT NULL,
      agent_uid text NOT NULL,
      session_id text NOT NULL,
      broker_sequence bigint NOT NULL,
      attempt_no integer NOT NULL,
      delivery_batch_id uuid NOT NULL,
      actor_bus_message_id text NOT NULL,
      correlation_id text,
      activation_uid text NOT NULL,
      actor_epoch bigint NOT NULL,
      llm_turn_id uuid NOT NULL,
      revision integer NOT NULL,
      worker_id text,
      worker_instance_id text,
      transport_route text,
      state text NOT NULL DEFAULT 'created',
      send_outcome text,
      sent_at timestamptz,
      accepted_at timestamptz,
      failed_at timestamptz,
      superseded_at timestamptz,
      error jsonb NOT NULL DEFAULT '{}',
      inserted_at timestamp(6) NOT NULL,
      updated_at timestamp(6) NOT NULL,
      CONSTRAINT actor_input_deliveries_attempt_positive CHECK (attempt_no > 0),
      CONSTRAINT actor_input_deliveries_state_check CHECK (
        state IN ('created', 'sent', 'send_failed', 'accepted', 'superseded')
      ),
      CONSTRAINT actor_input_deliveries_send_outcome_check CHECK (
        send_outcome IS NULL OR send_outcome IN (
          'sent_or_queued',
          'unknown_route',
          'backpressure',
          'timeout',
          'socket_closed'
        )
      ),
      CONSTRAINT actor_input_deliveries_error_object CHECK (jsonb_typeof(error) = 'object')
    )
    """)

    execute(
      "CREATE UNIQUE INDEX actor_input_deliveries_actor_input_attempt_index ON actor_input_deliveries (actor_input_id, attempt_no)"
    )

    execute(
      "CREATE UNIQUE INDEX actor_input_deliveries_live_actor_input_index ON actor_input_deliveries (actor_input_id) WHERE state IN ('created', 'sent', 'accepted')"
    )

    execute(
      "CREATE INDEX actor_input_deliveries_actor_state_index ON actor_input_deliveries (agent_uid, session_id, state, broker_sequence)"
    )

    execute(
      "CREATE INDEX actor_input_deliveries_llm_turn_id_index ON actor_input_deliveries (llm_turn_id)"
    )

    execute(
      "CREATE INDEX actor_input_deliveries_worker_state_index ON actor_input_deliveries (worker_id, worker_instance_id, state)"
    )

    execute("""
    CREATE UNLOGGED TABLE agent_computer_workers (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      worker_id text NOT NULL,
      worker_instance_id text NOT NULL,
      status text NOT NULL,
      version text,
      capacity jsonb NOT NULL DEFAULT '{}',
      load jsonb NOT NULL DEFAULT '{}',
      transport_route text,
      last_worker_heartbeat_at timestamptz,
      started_at timestamptz,
      stopped_at timestamptz,
      stop_reason text,
      metadata jsonb NOT NULL DEFAULT '{}',
      inserted_at timestamp(6) NOT NULL,
      updated_at timestamp(6) NOT NULL,
      CONSTRAINT agent_computer_workers_status_check CHECK (
        status IN ('ready', 'stale', 'draining', 'stopped')
      ),
      CONSTRAINT agent_computer_workers_capacity_object CHECK (jsonb_typeof(capacity) = 'object'),
      CONSTRAINT agent_computer_workers_load_object CHECK (jsonb_typeof(load) = 'object'),
      CONSTRAINT agent_computer_workers_metadata_object CHECK (jsonb_typeof(metadata) = 'object')
    )
    """)

    execute(
      "CREATE UNIQUE INDEX agent_computer_workers_worker_id_index ON agent_computer_workers (worker_id)"
    )

    execute(
      "CREATE UNIQUE INDEX agent_computer_workers_instance_id_index ON agent_computer_workers (worker_instance_id)"
    )

    execute(
      "CREATE UNIQUE INDEX agent_computer_workers_transport_route_index ON agent_computer_workers (transport_route) WHERE transport_route IS NOT NULL"
    )

    execute("""
    CREATE UNLOGGED TABLE actor_session_worker_assignments (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      agent_uid text NOT NULL,
      session_id text NOT NULL,
      worker_id text NOT NULL,
      worker_instance_id text,
      transport_route text,
      status text NOT NULL,
      workspace_mount text,
      assigned_at timestamptz NOT NULL,
      last_used_at timestamptz,
      metadata jsonb NOT NULL DEFAULT '{}',
      inserted_at timestamp(6) NOT NULL,
      updated_at timestamp(6) NOT NULL,
      CONSTRAINT actor_session_worker_assignments_status_check CHECK (
        status IN ('assigned', 'draining', 'released')
      ),
      CONSTRAINT actor_session_worker_assignments_metadata_object CHECK (jsonb_typeof(metadata) = 'object')
    )
    """)

    execute(
      "CREATE UNIQUE INDEX actor_session_worker_assignments_live_actor_index ON actor_session_worker_assignments (agent_uid, session_id) WHERE status IN ('assigned', 'draining')"
    )

    execute(
      "CREATE INDEX actor_session_worker_assignments_worker_index ON actor_session_worker_assignments (worker_id, worker_instance_id, status)"
    )

    execute("""
    CREATE UNLOGGED TABLE actor_session_activations (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      activation_uid text NOT NULL,
      agent_uid text NOT NULL,
      session_id text NOT NULL,
      actor_epoch bigint NOT NULL,
      status text NOT NULL,
      controller_node text,
      lease_id text NOT NULL,
      lease_expires_at timestamptz NOT NULL,
      last_actor_heartbeat_at timestamptz,
      assigned_worker_id text,
      assigned_worker_instance_id text,
      current_llm_turn_id uuid,
      revision integer NOT NULL DEFAULT 0,
      started_at timestamptz NOT NULL,
      stopped_at timestamptz,
      stop_reason text,
      metadata jsonb NOT NULL DEFAULT '{}',
      inserted_at timestamp(6) NOT NULL,
      updated_at timestamp(6) NOT NULL,
      CONSTRAINT actor_session_activations_status_check CHECK (
        status IN ('starting', 'active', 'draining', 'stopped', 'failed')
      ),
      CONSTRAINT actor_session_activations_metadata_object CHECK (jsonb_typeof(metadata) = 'object')
    )
    """)

    execute(
      "CREATE UNIQUE INDEX actor_session_activations_activation_uid_index ON actor_session_activations (activation_uid)"
    )

    execute(
      "CREATE UNIQUE INDEX actor_session_activations_live_actor_index ON actor_session_activations (agent_uid, session_id) WHERE status IN ('starting', 'active', 'draining')"
    )
  end
end
