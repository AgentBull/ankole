defmodule Ankole.Repo.Migrations.CreateSignalsGateway do
  # SignalsGateway owns provider ingress normalization, source mirrors, actor handoff,
  # and durable provider-visible outbox intents.
  #
  # Durable actor_events are never consumed away; queue_sequence orders each actor session;
  # signal_gateway_entries.ai_message_id and outbox provenance columns connect provider mirrors to AI output.
  #
  # Identity layers:
  #   source_event_id: provider event idempotency key
  #   source_entry_id: provider entry/message id
  #   actor_event_id: Ankole durable work item id
  #   ai_message_id: stored AIGateway message id
  use Ecto.Migration

  def change do
    # Provider-facing enum values stay constrained in PostgreSQL for replay and recovery.
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

    # Bindings are the per-agent bridge between provider adapters and runtime policy.
    create table(:signal_gateway_bindings, primary_key: false) do
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

    create index(:signal_gateway_bindings, [:adapter])

    create constraint(:signal_gateway_bindings, :signal_gateway_bindings_name_present,
             check: "length(btrim(name)) > 0"
           )

    create constraint(:signal_gateway_bindings, :signal_gateway_bindings_adapter_present,
             check: "length(btrim(adapter)) > 0"
           )

    create constraint(:signal_gateway_bindings, :signal_gateway_bindings_config_ref_present,
             check: "length(btrim(config_ref)) > 0"
           )

    create constraint(:signal_gateway_bindings, :signal_gateway_bindings_filters_object,
             check: "jsonb_typeof(filters) = 'object'"
           )

    comment_table(
      :signal_gateway_bindings,
      "Per-agent SignalsGateway bindings to external input and output adapters."
    )

    comment_columns(:signal_gateway_bindings, %{
      agent_uid: "Agent principal that owns the binding.",
      name: "Agent-local binding name used in actor event and outbox keys.",
      adapter: "SignalsGateway adapter that knows how to read and write the provider.",
      config_ref: "Configuration reference used by the adapter at runtime.",
      filters: "Adapter-neutral binding filters applied before actor delivery.",
      unaddressed_group_message_policy:
        "Policy for group messages that do not directly address the agent.",
      enabled: "Whether this binding may accept or dispatch provider traffic.",
      unavailable_reason: "Operator-visible reason why an enabled binding cannot currently run."
    })

    # Channels are provider locations observed by ingress or outbound recovery.
    create table(:signal_gateway_channels, primary_key: false) do
      add :id, :text, primary_key: true
      add :kind, :signal_channel_kind, null: false, default: "unknown"
      add :reply_mode, :signal_reply_mode, null: false, default: "none"
      add :name, :text
      add :visibility, :text

      add :principal_group_id,
          references(:principal_groups, type: :uuid, on_delete: :nilify_all)

      add :metadata, :map, null: false, default: %{}
      add :raw_payload, :map, null: false, default: %{}
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:signal_gateway_channels, :signal_gateway_channels_id_present,
             check: "length(btrim(id)) > 0"
           )

    create constraint(:signal_gateway_channels, :signal_gateway_channels_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create constraint(:signal_gateway_channels, :signal_gateway_channels_raw_payload_object,
             check: "jsonb_typeof(raw_payload) = 'object'"
           )

    create constraint(:signal_gateway_channels, :signal_gateway_channels_principal_group_kind,
             check: "principal_group_id IS NULL OR kind = 'im_group'"
           )

    create index(:signal_gateway_channels, [:principal_group_id],
             where: "principal_group_id IS NOT NULL"
           )

    comment_table(:signal_gateway_channels, "Provider channels observed by SignalsGateway.")

    comment_columns(:signal_gateway_channels, %{
      id: "Stable Ankole channel id derived from provider channel identity.",
      kind: "Channel category used for policy and rendering.",
      reply_mode: "Whether replies target the whole channel or a specific entry.",
      name: "Provider or operator supplied channel name.",
      visibility: "Provider visibility hint such as private, public, or shared.",
      principal_group_id:
        "Principal group that represents IM group membership when this channel is an IM group.",
      metadata: "Normalized provider channel facts outside the stable contract.",
      raw_payload: "Last provider payload kept for recovery and adapter diagnostics.",
      first_seen_at: "Time this channel was first observed by the gateway.",
      last_seen_at: "Time this channel was most recently observed by the gateway."
    })

    # signal_gateway_entries is the provider source mirror. ai_message_id is set only after an
    # outbound final AI reply is sent, so recovery can distinguish mirrored terminal
    # messages from terminal messages that still need provider reconciliation.
    create table(:signal_gateway_entries, primary_key: false) do
      add :document_id, :text, primary_key: true

      add :signal_channel_id,
          references(:signal_gateway_channels, column: :id, type: :text, on_delete: :delete_all)

      add :source_entry_id, :text, null: false
      add :provider_thread_id, :text
      add :text, :text
      add :rich_content, :map
      add :attachments, {:array, :map}, null: false, default: []
      add :links, {:array, :map}, null: false, default: []
      add :author, :map, null: false, default: %{}
      add :mentions, {:array, :map}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      add :raw_payload, :map, null: false, default: %{}
      add :provider_time, :utc_datetime_usec
      add :reactions, :map, null: false, default: %{}
      add :raw_reaction_keys, :map, null: false, default: %{}
      add :content_hash, :text
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      # SignalsGateway mirror pointer only; it does not backfill the AIGateway message row.
      add :ai_message_id, :uuid

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:signal_gateway_entries, [:signal_channel_id, :source_entry_id],
             name: :signal_gateway_entries_source_identity_index
           )

    create index(:signal_gateway_entries, [:last_seen_at])
    # Recovery scans use ai_message_id to prove a final reply already has a provider mirror.
    create index(:signal_gateway_entries, [:ai_message_id],
             name: :signal_gateway_entries_ai_message_id_index,
             where: "ai_message_id IS NOT NULL"
           )

    create constraint(:signal_gateway_entries, :signal_gateway_entries_source_entry_id_present,
             check: "length(btrim(source_entry_id)) > 0"
           )

    create constraint(:signal_gateway_entries, :signal_gateway_entries_document_id_present,
             check: "length(btrim(document_id)) > 0"
           )

    comment_table(
      :signal_gateway_entries,
      "Provider entries mirrored for gateway policy, recall, and reply targeting."
    )

    comment_columns(:signal_gateway_entries, %{
      signal_channel_id: "Channel that contains this provider entry.",
      source_entry_id: "Provider supplied entry or message identifier within the channel.",
      provider_thread_id: "Provider thread that contains this entry, when applicable.",
      text: "Plain text extracted from the provider entry when available.",
      rich_content: "Structured content that carries information beyond plain text.",
      attachments: "Provider attachments normalized for storage and worker handoff.",
      links: "Links extracted or normalized from the entry.",
      author: "Provider author facts for the entry.",
      mentions: "Mention facts normalized from the entry.",
      metadata: "Gateway-owned metadata outside the durable content contract.",
      raw_payload: "Provider payload kept for adapter diagnostics and recovery.",
      provider_time: "Timestamp assigned by the provider for the entry.",
      reactions: "Normalized reaction counts and actors.",
      raw_reaction_keys: "Provider reaction keys retained before normalization.",
      document_id: "Search and recall document id for this entry.",
      content_hash: "Hash of the durable content projection.",
      first_seen_at: "Time this entry was first observed by the gateway.",
      last_seen_at: "Time this entry was most recently observed by the gateway.",
      ai_message_id:
        "Stored ai_gateway_messages.id when this entry mirrors an outbound final AI reply."
    })

    # Receive-side tombstones suppress provider entries that should not reopen work.
    create table(:signal_gateway_input_tombstones, primary_key: false) do
      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :binding_name, :text, primary_key: true

      add :signal_channel_id,
          references(:signal_gateway_channels, column: :id, type: :text, on_delete: :delete_all),
          primary_key: true

      add :source_entry_id, :text, primary_key: true
      add :tombstoned_until, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:signal_gateway_input_tombstones, [:tombstoned_until])

    comment_table(
      :signal_gateway_input_tombstones,
      "Temporary receive-side tombstones that suppress already-handled or deleted provider entries."
    )

    comment_columns(:signal_gateway_input_tombstones, %{
      agent_uid: "Agent principal protected by the tombstone.",
      binding_name: "Binding where the provider entry was observed.",
      signal_channel_id: "Channel containing the tombstoned provider entry.",
      source_entry_id: "Provider entry suppressed until the tombstone expires.",
      tombstoned_until: "Time after which this tombstone can be removed."
    })

    # Actor events are durable worker-facing facts. Normal completion sets completed_at;
    # unrecoverable events remain with input_state = 'dead_letter'.
    create table(:actor_events, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :binding_name, :text, null: false
      add :session_id, :text, null: false
      add :source_event_id, :text, null: false
      add :signal_channel_id, :text
      add :provider_thread_id, :text
      add :source_entry_id, :text
      add :reply_preview_source_entry_id, :text
      add :type, :text, null: false
      add :available_at, :utc_datetime_usec, null: false
      # Per-session ordering lives here because delivery is ordered within one actor session.
      add :queue_sequence, :bigint, null: false
      # input_state tracks queue eligibility only; normal completion lives in completed_at.
      add :input_state, :text, null: false, default: "open"
      add :completed_at, :utc_datetime_usec
      add :sender_key, :text
      add :payload, :map, null: false
      add :dead_letter_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # Source idempotency keeps one provider source event from enqueueing duplicate actor events.
    create unique_index(
             :actor_events,
             [:agent_uid, :binding_name, :source_event_id],
             name: :actor_events_signal_idempotency_index
           )

    create unique_index(:actor_events, [:agent_uid, :session_id, :queue_sequence],
             name: :actor_events_queue_sequence_index
           )

    create index(
             :actor_events,
             [:agent_uid, :session_id, :available_at, :queue_sequence],
             name: :actor_events_ready_index,
             where: "input_state = 'open' AND completed_at IS NULL"
           )

    create index(
             :actor_events,
             [:agent_uid, :binding_name, :signal_channel_id, :source_entry_id],
             name: :actor_events_signal_entry_index
           )

    create constraint(:actor_events, :actor_events_payload_object,
             check: "jsonb_typeof(payload) = 'object'"
           )

    create constraint(:actor_events, :actor_events_input_state_check,
             check: "input_state IN ('open', 'dead_letter')"
           )

    comment_table(:actor_events, "Durable actor-facing events waiting for one agent session.")

    comment_columns(:actor_events, %{
      agent_uid: "Agent principal that should process the event.",
      binding_name: "Ingress binding or internal source that produced the event.",
      session_id: "Actor session queue that owns ordering for this event.",
      source_event_id: "Idempotency key for the source event (layer-1 identity).",
      signal_channel_id: "Provider channel tied to this event when it came from SignalsGateway.",
      provider_thread_id: "Provider thread key used for batching and reply context.",
      source_entry_id:
        "Provider entry that produced this event when applicable (layer-2 identity).",
      reply_preview_source_entry_id:
        "Provider entry created for the live AI reply preview; SignalsGateway uses it as the final edit target.",
      type: "Actor event type such as command, signal entry, or session lifecycle.",
      available_at: "Earliest time this event may be delivered to the actor runtime.",
      queue_sequence: "Per-session sequence for ordering currently open actor events.",
      input_state: "Queue state for open or dead-lettered events.",
      completed_at: "Time this event finished normal processing.",
      sender_key: "Provider sender key used by same-sender batching policy.",
      payload: "CloudEvents-style actor event envelope consumed by the worker.",
      dead_letter_at: "Time this event was marked undeliverable."
    })

    # The outbox stores non-streamed provider-visible side effects. Streamed final AI
    # replies are sent as live chunk process events and mirrored after provider success.
    create table(:signal_gateway_outbox_entries, primary_key: false) do
      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :binding_name, :text, primary_key: true
      add :outbound_key, :text, primary_key: true
      add :operation, :signal_gateway_outbox_operation, null: false
      add :status, :signal_gateway_outbox_status, null: false, default: "created"
      add :signal_channel_id, :text
      add :provider_thread_id, :text
      add :reply_to_source_entry_id, :text
      add :target_source_entry_id, :text
      add :created_source_entry_id, :text
      add :source_actor_event_id, :uuid
      # References ai_gateway_messages.id as the layer-4 identity for deterministic provenance.
      add :ai_message_id, :uuid
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

    create index(:signal_gateway_outbox_entries, [:status, :next_attempt_at])

    create index(:signal_gateway_outbox_entries, [:signal_channel_id, :created_source_entry_id],
             name: :signal_gateway_outbox_entries_channel_created_entry_index
           )

    create index(:signal_gateway_outbox_entries, [:source_actor_event_id],
             name: :signal_gateway_outbox_entries_source_actor_event_id_index
           )

    create index(:signal_gateway_outbox_entries, [:ai_message_id],
             name: :signal_gateway_outbox_entries_ai_message_id_index
           )

    create constraint(
             :signal_gateway_outbox_entries,
             :signal_gateway_outbox_entries_payload_object,
             check: "jsonb_typeof(payload) = 'object'"
           )

    create constraint(
             :signal_gateway_outbox_entries,
             :signal_gateway_outbox_entries_last_error_object,
             check: "jsonb_typeof(last_error) = 'object'"
           )

    create constraint(
             :signal_gateway_outbox_entries,
             :signal_gateway_outbox_entries_recovery_state_object,
             check: "jsonb_typeof(recovery_state) = 'object'"
           )

    create constraint(
             :signal_gateway_outbox_entries,
             :signal_gateway_outbox_entries_attempts_non_negative,
             check: "attempt_count >= 0 AND max_attempts > 0"
           )

    comment_table(
      :signal_gateway_outbox_entries,
      "Durable provider-visible side-effect intents committed by actor events."
    )

    comment_columns(:signal_gateway_outbox_entries, %{
      agent_uid: "Agent principal that owns the outbound side effect.",
      binding_name: "Output binding that should dispatch the side effect.",
      outbound_key: "Agent-provided idempotency key for the side effect.",
      operation: "Provider-visible operation requested by the actor.",
      status: "Dispatch state for retry and recovery.",
      signal_channel_id: "Provider channel targeted by the side effect.",
      provider_thread_id: "Provider thread targeted by the side effect.",
      reply_to_source_entry_id: "Provider entry that the side effect replies from.",
      target_source_entry_id: "Provider entry targeted by edit, delete, or reaction operations.",
      created_source_entry_id: "Provider id assigned to a successfully created outbound entry.",
      source_actor_event_id: "Actor event that caused this side effect.",
      ai_message_id: "Stored ai_gateway_messages.id represented by this side effect.",
      payload: "Operation-specific payload to send through the adapter.",
      fallback_visible_text: "Plain text rendering used when rich content needs a fallback.",
      idempotency_key: "Provider-facing idempotency token when the adapter supports one.",
      attempt_count: "Number of dispatch attempts already made.",
      max_attempts: "Retry ceiling before the row stops scheduling attempts.",
      last_attempted_at: "Time of the most recent dispatch attempt.",
      last_error: "Last adapter or provider error captured for operators.",
      platform_send_started_at: "Time the provider send call started for in-flight recovery.",
      next_attempt_at: "Next time the dispatcher may retry a failed send.",
      recovery_state: "Adapter breadcrumbs used to reconcile unknown send outcomes."
    })
  end

  # PostgreSQL comment helpers keep schema documentation attached after a clean reset.
  defp comment_table(table, comment) do
    execute(
      "COMMENT ON TABLE #{identifier(table)} IS #{literal(comment)}",
      "COMMENT ON TABLE #{identifier(table)} IS NULL"
    )
  end

  defp comment_columns(table, comments) do
    Enum.each(comments, fn {column, comment} -> comment_column(table, column, comment) end)
  end

  defp comment_column(table, column, comment) do
    execute(
      "COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS #{literal(comment)}",
      "COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS NULL"
    )
  end

  defp identifier(value), do: "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
