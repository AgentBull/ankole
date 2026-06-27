defmodule Ankole.Repo.Migrations.CreateActorRuntimePingPong do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto", "")

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
             check: "status IN ('generating', 'complete', 'retracted')"
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
               "kind IN ('generation', 'retry_generation', 'scheduled_task', 'checkback_generation', 'compression', 'overflow_retry')"
           )

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_status_check,
             check: "status IN ('started', 'succeeded', 'failed', 'cancelled')"
           )

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_profile_check,
             check: "profile IN ('primary', 'light', 'heavy', 'codex')"
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
    comment_actor_runtime_tables()
  end

  def down do
    execute("DROP TABLE IF EXISTS actor_session_activations")
    execute("DROP TABLE IF EXISTS actor_session_worker_assignments")
    execute("DROP TABLE IF EXISTS agent_computer_workers")
    execute("DROP TABLE IF EXISTS actor_input_deliveries")

    drop table(:ai_agent_llm_turns)
    drop table(:ai_agent_messages)
    drop table(:ai_agent_conversations)
  end

  defp comment_actor_runtime_tables do
    comment_table(:ai_agent_conversations, "Durable AI-agent conversation threads per agent.")

    comment_columns(:ai_agent_conversations, %{
      agent_uid: "Agent principal that owns the conversation.",
      conversation_key: "Agent-local key used to identify the active conversation lane.",
      ended_at: "Time the conversation was closed and excluded from active-key uniqueness.",
      generation: "Current generation state used by the actor runtime.",
      metadata: "Conversation metadata outside the stable message contract."
    })

    comment_table(
      :ai_agent_messages,
      "Durable messages and summaries inside AI-agent conversations."
    )

    comment_columns(:ai_agent_messages, %{
      agent_uid: "Agent principal that owns the message.",
      conversation_id: "Conversation containing the message.",
      role: "Conversation role such as user, assistant, tool, or ambient IM.",
      kind: "Message kind such as normal, summary, introspection, or error.",
      status: "Generation state, completion state, or provider-retracted input state.",
      content: "Array-shaped message content consumed by worker and UI surfaces.",
      covers_range: "Summary coverage range when this message compresses earlier messages.",
      event_source: "External or internal event namespace that produced inbound messages.",
      event_id: "Event id used with event_source for inbound idempotency.",
      metadata: "Message metadata outside the stable content contract."
    })

    comment_table(:ai_agent_llm_turns, "Durable records of LLM turns attempted by actor runtime.")

    comment_columns(:ai_agent_llm_turns, %{
      agent_uid: "Agent principal that owns the LLM turn.",
      conversation_id: "Conversation whose context was used for the turn.",
      kind: "Runtime turn kind such as generation, compression, or scheduled task.",
      status: "Terminal or in-flight state of the LLM turn.",
      profile: "Agent model profile selected for the turn.",
      provider: "Resolved LLM provider id used for the turn.",
      model: "Resolved provider model id used for the turn.",
      lease_id: "Runtime lease grouping streamed calls for one turn attempt.",
      call_index: "Provider call sequence within the lease.",
      branch_id: "Conversation branch written by the turn.",
      parent_branch_id: "Parent branch used when retrying or forking generation.",
      trigger_message_id: "Message that triggered the turn when there is one.",
      trigger_event_id: "External or internal trigger event id.",
      input_message_ids: "Ordered message ids supplied to the worker as context.",
      request_context: "Runtime request envelope facts sent to the worker.",
      request_refs: "Reference material requested by the worker for the turn.",
      request_patches: "Patch proposals or request adjustments attached to the turn.",
      response: "Provider or worker response captured for the turn.",
      tool_results: "Tool result payloads produced during the turn.",
      usage: "Token and cost usage reported by the provider or worker.",
      provider_metadata: "Provider-specific metadata outside the stable turn contract.",
      started_at: "Time the turn attempt started.",
      completed_at: "Time the turn reached a terminal state."
    })

    comment_table(
      :actor_input_deliveries,
      "Volatile delivery attempts from actor inputs to workers."
    )

    comment_columns(:actor_input_deliveries, %{
      actor_input_id: "Actor input row being delivered.",
      agent_uid: "Agent principal that owns the input.",
      session_id: "Actor session queue for the delivery.",
      broker_sequence: "Per-session input sequence copied from actor_inputs.",
      attempt_no: "Delivery attempt number for this actor input.",
      delivery_batch_id: "Batch id shared by inputs sent together.",
      actor_lane_message_id: "Transport message id sent over the actor lane.",
      correlation_id: "Optional transport correlation id.",
      activation_uid: "Runtime activation targeted by the delivery.",
      actor_epoch: "Actor epoch fence used by the targeted activation.",
      llm_turn_id: "LLM turn opened for this delivery.",
      revision: "Runtime revision fence used by the targeted activation.",
      worker_id: "Worker selected for the delivery.",
      transport_route: "Actor transport route used for the delivery.",
      state: "Delivery state from creation through send, acceptance, or supersession.",
      send_outcome: "Transport outcome when the send did not cleanly succeed.",
      sent_at: "Time the actor lane send was attempted.",
      accepted_at: "Time the worker accepted the turn.",
      failed_at: "Time the delivery failed before acceptance.",
      superseded_at: "Time a newer delivery replaced this attempt.",
      error: "Structured delivery error for diagnostics."
    })

    comment_table(
      :agent_computer_workers,
      "Volatile registry of connected Agent Computer workers."
    )

    comment_columns(:agent_computer_workers, %{
      worker_id: "Worker process id authenticated by the control plane.",
      status: "Worker availability state used by assignment policy.",
      version: "Worker software version reported at admission.",
      capacity: "Worker capacity advertisement.",
      load: "Current worker load advertisement.",
      transport_route: "Actor transport route proven for this worker connection.",
      last_worker_heartbeat_at: "Most recent heartbeat time observed from the worker.",
      started_at: "Worker-reported start time.",
      stopped_at: "Time the worker was marked stopped.",
      stop_reason: "Operator-visible reason for the stopped state.",
      metadata: "Worker metadata outside the scheduler contract."
    })

    comment_table(
      :actor_session_worker_assignments,
      "Volatile mapping from actor sessions to assigned workers."
    )

    comment_columns(:actor_session_worker_assignments, %{
      agent_uid: "Agent principal that owns the session.",
      session_id: "Actor session assigned to the worker.",
      worker_id: "Worker selected for the session.",
      transport_route: "Actor transport route used for the session.",
      status: "Assignment lifecycle state.",
      workspace_mount: "Worker-visible workspace mount for the session.",
      assigned_at: "Time the assignment was created.",
      last_used_at: "Most recent time the assignment handled work.",
      metadata: "Assignment metadata outside the scheduler contract."
    })

    comment_table(
      :actor_session_activations,
      "Volatile activation leases for live actor sessions."
    )

    comment_columns(:actor_session_activations, %{
      activation_uid: "Stable activation identifier carried across worker messages.",
      agent_uid: "Agent principal that owns the activation.",
      session_id: "Actor session protected by the activation.",
      actor_epoch: "Monotonic actor epoch fence for this session activation.",
      status: "Activation lifecycle state.",
      controller_node: "Control-plane node that owns the activation lease.",
      lease_id: "Lease id proving current activation ownership.",
      lease_expires_at: "Time the activation lease expires without renewal.",
      last_actor_heartbeat_at: "Most recent actor heartbeat observed for the activation.",
      assigned_worker_id: "Worker assigned to the activation.",
      current_llm_turn_id: "LLM turn currently controlled by the activation.",
      revision: "Revision fence advanced by activation state changes.",
      started_at: "Time the activation started.",
      stopped_at: "Time the activation stopped.",
      stop_reason: "Operator-visible reason the activation stopped.",
      metadata: "Activation metadata outside the runtime fencing contract."
    })
  end

  defp comment_table(table, comment) do
    execute("COMMENT ON TABLE #{identifier(table)} IS #{literal(comment)}")
  end

  defp comment_columns(table, comments) do
    Enum.each(comments, fn {column, comment} -> comment_column(table, column, comment) end)
  end

  defp comment_column(table, column, comment) do
    execute("COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS #{literal(comment)}")
  end

  defp identifier(value), do: "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"

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
      actor_lane_message_id text NOT NULL,
      correlation_id text,
      activation_uid text NOT NULL,
      actor_epoch bigint NOT NULL,
      llm_turn_id uuid NOT NULL,
      revision integer NOT NULL,
      worker_id text,
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
      "CREATE INDEX actor_input_deliveries_worker_state_index ON actor_input_deliveries (worker_id, state)"
    )

    execute("""
    CREATE UNLOGGED TABLE agent_computer_workers (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      worker_id text NOT NULL,
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
      "CREATE UNIQUE INDEX agent_computer_workers_transport_route_index ON agent_computer_workers (transport_route) WHERE transport_route IS NOT NULL"
    )

    execute("""
    CREATE UNLOGGED TABLE actor_session_worker_assignments (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      agent_uid text NOT NULL,
      session_id text NOT NULL,
      worker_id text NOT NULL,
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
      "CREATE INDEX actor_session_worker_assignments_worker_index ON actor_session_worker_assignments (worker_id, status)"
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
