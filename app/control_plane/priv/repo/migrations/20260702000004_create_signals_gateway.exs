defmodule Ankole.Repo.Migrations.CreateSignalsGateway do
  # SignalsGateway：provider 入口规范化 + source mirror + actor event 投递。
  #
  # Phase 1 重构后的关键变化：
  #   - actor_inputs        → actor_events（durable 事件，处理完不删除）
  #   - 删除 actor_input_consumptions（不再需要 consumed tombstone）
  #   - live_queue_sequence → queue_sequence
  #   - signal_entries 新增 ai_message_id（引用 ai_gateway_messages.id）
  #   - outbox: llm_turn_id 删除, source_actor_input_id → source_actor_event_id,
  #     assistant_message_id → ai_message_id
  #
  # 四层身份（见 new-plan.md §2.2）：
  #   source_event_id  来源事件幂等键
  #   source_entry_id  来源平台消息 id
  #   actor_event_id   Ankole 内部 work item id
  #   ai_message_id    stored AI gateway message id
  use Ecto.Migration

  def change do
    # ── 枚举类型 ──────────────────────────────────────────────
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

    # ── signal_bindings：agent ↔ adapter 绑定 ────────────────
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

    comment_table(
      :signal_bindings,
      "Per-agent SignalsGateway bindings to external input and output adapters."
    )

    comment_columns(:signal_bindings, %{
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

    # ── signal_channels：观察到的 provider 频道 ──────────────
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

    comment_table(:signal_channels, "Provider channels observed by SignalsGateway.")

    comment_columns(:signal_channels, %{
      id: "Stable Ankole channel id derived from provider channel identity.",
      kind: "Channel category used for policy and rendering.",
      reply_mode: "Whether replies target the whole channel or a specific entry.",
      name: "Provider or operator supplied short channel name.",
      title: "Provider or operator supplied channel title.",
      visibility: "Provider visibility hint such as private, public, or shared.",
      metadata: "Normalized provider channel facts outside the stable contract.",
      raw_payload: "Last provider payload kept for recovery and adapter diagnostics.",
      first_seen_at: "Time this channel was first observed by the gateway.",
      last_seen_at: "Time this channel was most recently observed by the gateway."
    })

    # ── signal_entries：provider 消息镜像 ─────────────────────
    # Phase 1 新增 ai_message_id：当 outbound final AI reply 成功发送后，
    # 在此记录它对应的 ai_gateway_messages.id，供后续 edit/delete/reconcile
    # 以及 recovery catch-up scan 判断「终态 message 是否已成功镜像」。
    create table(:signal_entries, primary_key: false) do
      add :signal_channel_id,
          references(:signal_channels, column: :id, type: :text, on_delete: :delete_all),
          primary_key: true

      add :source_entry_id, :text, primary_key: true
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
      # Phase 1：outbound final AI reply 镜像时记录对应的 stored AI message id。
      # 只属于 SignalsGateway 的 source mirror，不反向写入 ai_gateway_messages。
      add :ai_message_id, :uuid

      timestamps(type: :utc_datetime_usec)
    end

    create index(:signal_entries, [:document_id])
    create index(:signal_entries, [:last_seen_at])
    # recovery scan 按 ai_message_id 查「final reply 是否已镜像」。
    create index(:signal_entries, [:ai_message_id],
             name: :signal_entries_ai_message_id_index,
             where: "ai_message_id IS NOT NULL"
           )

    create constraint(:signal_entries, :signal_entries_source_entry_id_present,
             check: "length(btrim(source_entry_id)) > 0"
           )

    create constraint(:signal_entries, :signal_entries_document_id_present,
             check: "length(btrim(document_id)) > 0"
           )

    comment_table(
      :signal_entries,
      "Provider entries mirrored for gateway policy, recall, and reply targeting."
    )

    comment_columns(:signal_entries, %{
      signal_channel_id: "Channel that contains this provider entry.",
      source_entry_id: "Provider supplied entry or message identifier within the channel.",
      text: "Plain text extracted from the provider entry when available.",
      formatted_content: "Structured rich content normalized from the provider entry.",
      attachments: "Provider attachments normalized for storage and worker handoff.",
      links: "Links extracted or normalized from the entry.",
      author: "Provider author facts for the entry.",
      mentions: "Mention facts normalized from the entry.",
      metadata: "Gateway-owned metadata outside the durable content contract.",
      raw_payload: "Provider payload kept for adapter diagnostics and recovery.",
      provider_time: "Timestamp assigned by the provider for the entry.",
      fallback_visible_text: "Best effort text shown when structured content cannot be rendered.",
      reactions: "Normalized reaction counts and actors.",
      raw_reaction_keys: "Provider reaction keys retained before normalization.",
      document_id: "Search and recall document id for this entry.",
      search_text: "Text projection used for search and recall.",
      metadata_text: "Metadata projection used for search and recall.",
      content_hash: "Hash of the durable content projection.",
      first_seen_at: "Time this entry was first observed by the gateway.",
      last_seen_at: "Time this entry was most recently observed by the gateway.",
      ai_message_id:
        "Stored ai_gateway_messages.id when this entry mirrors an outbound final AI reply."
    })

    # ── signal_gateway_input_tombstones：接收侧去重墓碑 ─────
    create table(:signal_gateway_input_tombstones, primary_key: false) do
      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :binding_name, :text, primary_key: true

      add :signal_channel_id,
          references(:signal_channels, column: :id, type: :text, on_delete: :delete_all),
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

    # ── actor_events：durable actor-facing work item ─────────
    # 旧名 actor_inputs。Phase 1 重构后这是 durable lifecycle row：
    # 处理完成后不删除，也不写 consumption marker（已删 actor_input_consumptions 表）。
    # 是否仍在运行/完成由 delivery row + ai_gateway_conversations.generation lease +
    # ai_gateway_messages.status 推导，不落独立状态字段（见 new-plan.md §2.3）。
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
      add :type, :text, null: false
      add :available_at, :utc_datetime_usec, null: false
      # 旧名 live_queue_sequence → queue_sequence。Per-session 顺序号。
      add :queue_sequence, :bigint, null: false
      # input_state 只约束 open | dead_letter（见 §2.3）。
      # 完成态不在这里表达。
      add :input_state, :text, null: false, default: "open"
      add :sender_key, :text
      add :payload, :map, null: false
      add :dead_letter_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # source 幂等：同一 (agent, binding, source_event_id) 只产生一个 actor event。
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
             [:agent_uid, :session_id, :input_state, :available_at, :queue_sequence],
             name: :actor_events_ready_index
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
      source_entry_id: "Provider entry that produced this event when applicable (layer-2 identity).",
      type: "Actor event type such as command, signal entry, or session lifecycle.",
      available_at: "Earliest time this event may be delivered to the actor runtime.",
      queue_sequence: "Per-session sequence for ordering currently open actor events.",
      input_state: "Queue state for open or dead-lettered events.",
      sender_key: "Provider sender key used by same-sender batching policy.",
      payload: "CloudEvents-style actor event envelope consumed by the worker.",
      dead_letter_at: "Time this event was marked undeliverable."
    })

    # ── signal_gateway_outbox：provider 可见 side-effect ─────
    # Phase 1：streamed AI reply 不再走 outbox（改走进程消息 live chunk events）。
    # outbox 只保留其他显式 provider-visible side effect。
    # 字段改名：source_actor_input_id → source_actor_event_id,
    #          assistant_message_id → ai_message_id, 删除 llm_turn_id。
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
      add :reply_to_source_entry_id, :text
      add :target_source_entry_id, :text
      add :created_source_entry_id, :text
      # 旧名 source_actor_input_id → source_actor_event_id。
      add :source_actor_event_id, :uuid
      # 旧名 assistant_message_id → ai_message_id。
      # 引用 ai_gateway_messages.id（layer-4 identity），可确定性追溯。
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

    create index(:signal_gateway_outbox, [:status, :next_attempt_at])

    create index(:signal_gateway_outbox, [:signal_channel_id, :created_source_entry_id],
             name: :signal_gateway_outbox_channel_created_entry_index
           )

    create index(:signal_gateway_outbox, [:source_actor_event_id],
             name: :signal_gateway_outbox_source_actor_event_id_index
           )

    create index(:signal_gateway_outbox, [:ai_message_id],
             name: :signal_gateway_outbox_ai_message_id_index
           )

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

    comment_table(
      :signal_gateway_outbox,
      "Durable provider-visible side-effect intents committed by actor events."
    )

    comment_columns(:signal_gateway_outbox, %{
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

  # ── COMMENT 辅助函数 ───────────────────────────────────────
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
