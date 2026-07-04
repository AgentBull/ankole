defmodule Ankole.Repo.Migrations.CreateAiGateway do
  # AIGateway 拥有的 durable state 表：ai_gateway_conversations 与 ai_gateway_messages。
  #
  # Phase 1 关键重构（见 new-plan.md §3.6 / §3.7）：
  #   - ai_agent_conversations → ai_gateway_conversations
  #   - ai_agent_messages → ai_gateway_messages
  #   - kind → type（normal→message, summary→compaction, introspection→retracted, error→message+status=error）
  #   - 新增 previous_message_id（自引用，历史续接链）
  #   - 新增 content_version（同一 row durable content snapshot 版本）
  #   - 新增 metadata.actor_event_id 的 partial unique index（每个 actor event 至多一条 generating row）
  #   - 删除 ai_agent_llm_turns（不再需要，状态分布到 actor_events + messages metadata）
  use Ecto.Migration

  def up do
    # ── ai_gateway_conversations ─────────────────────────────
    # 只保存 conversation 身份、scope、metadata、active generation lease。
    # 不保存派生续接指针——续接位置从 message graph 推导（见 §3.6）。
    create table(:ai_gateway_conversations, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :conversation_key, :text, null: false
      add :ended_at, :utc_datetime_usec
      # generation jsonb 只记录当前 active actor event 的最小 liveness/scope：
      # actor_event_id、model/profile/provider ref、lease id/expiry、activation uid/epoch/revision。
      # 不记录任何续接指针（见 §3.6）。
      add :generation, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # 同一 agent 下，同一 conversation_key 只能有一个 active（未 ended）conversation。
    create unique_index(:ai_gateway_conversations, [:agent_uid, :conversation_key],
             name: :ai_gateway_conversations_active_key_index,
             where: "ended_at IS NULL"
           )

    create constraint(:ai_gateway_conversations, :ai_gateway_conversations_generation_object,
             check: "jsonb_typeof(generation) = 'object'"
           )

    create constraint(:ai_gateway_conversations, :ai_gateway_conversations_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(:ai_gateway_conversations, "Durable AI-gateway conversation threads per agent.")

    comment_columns(:ai_gateway_conversations, %{
      agent_uid: "Agent principal that owns the conversation.",
      conversation_key: "Agent-local key used to identify the active conversation lane.",
      ended_at: "Time the conversation was closed and excluded from active-key uniqueness.",
      generation:
        "Active generation lease: actor_event_id, model ref, lease id/expiry, activation scope.",
      metadata: "Conversation metadata outside the stable message contract."
    })

    # ── ai_gateway_messages：stored message-log fact 表 ───────
    # 一条 row = 一次 stateful Responses run、一次 stateful compaction、
    # 或一条内部 AI gateway message fact。
    # 旧 kind 字段拆为 type(row 语义)+status(生命周期)。
    create table(:ai_gateway_messages, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :conversation_id,
          references(:ai_gateway_conversations, type: :uuid, on_delete: :delete_all), null: false

      # type 是 row-level 语义（见 §3.7）：
      #   message    - 普通 response/message fact
      #   compaction - 压缩 fact（content 必须含 compaction item）
      add :type, :text, null: false

      # role 只是 legacy transcript/UI projection hint，不是权威角色。
      # 允许 null——function_call 等 item 不带 role。
      add :role, :text

      # status 生命周期（见 §3.8）：
      #   generating - row 在 active actor event 的 Responses loop 中，尚未收敛
      #   complete   - 可进入普通 model-chain projection
      #   error      - 终态失败，保留可审计失败事实
      #   retracted  - 审计保留但不进入普通历史/anchor
      add :status, :text, null: false

      # previous_message_id：自引用续接链。API 边界渲染为 previous_response_id。
      # resp_#{id} 永远等于 resp_#{ai_gateway_messages.id}（见 §1.4）。
      add :previous_message_id, :uuid

      # content 是 OpenResponses ResponseItem[] 子集（见 §3.7）。
      # 一次 response.create 如果产生多个 items，存为同一条 row 的数组元素。
      add :content, :map, null: false, default: fragment("'[]'::jsonb")
      # content_version 是同一 row 内 durable content snapshot 版本号，
      # 不是 live chunk sequence，不参与 previous_message_id 链。
      add :content_version, :integer, null: false, default: 0
      add :covers_range, :map
      # metadata 只保存辅助事实：model/provider、usage、provider raw ids、
      # renderer hints、actor_event_id、request refs、compaction refs。
      # 特别地，metadata.actor_event_id 是 AIGateway/ActorRuntime correlation key。
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # 自引用外键：previous_message_id 指向同表 id。
    # 用 execute 而非 references()，因为 Ecto 的 references 不支持自引用表的同表 FK。
    execute(
      """
      ALTER TABLE ai_gateway_messages
      ADD CONSTRAINT ai_gateway_messages_previous_message_id_fkey
      FOREIGN KEY (previous_message_id) REFERENCES ai_gateway_messages(id) ON DELETE SET NULL
      """,
      """
      ALTER TABLE ai_gateway_messages
      DROP CONSTRAINT IF EXISTS ai_gateway_messages_previous_message_id_fkey
      """
    )

    create index(:ai_gateway_messages, [:agent_uid, :conversation_id],
             name: :ai_gateway_messages_conversation_index
           )

    # 续接链查询：按 previous_message_id 反查「谁续接了这条」。
    create index(:ai_gateway_messages, [:previous_message_id],
             name: :ai_gateway_messages_previous_message_id_index,
             where: "previous_message_id IS NOT NULL"
           )

    # 每个 actor event 同一时刻至多一条在飞（generating）的 message row。
    # 这是当前那次 response.create。loop 里之前的 row 已是 complete。
    # reconnect 用它确定性定位当前在飞调用的 row 与已累积 content（见 §3.7）。
    execute(
      """
      CREATE UNIQUE INDEX ai_gateway_messages_generating_actor_event_index
      ON ai_gateway_messages ((metadata->>'actor_event_id'))
      WHERE status = 'generating' AND type = 'message'
      """,
      "DROP INDEX IF EXISTS ai_gateway_messages_generating_actor_event_index"
    )

    create constraint(:ai_gateway_messages, :ai_gateway_messages_role_check,
             check: "role IS NULL OR role IN ('user', 'assistant', 'tool', 'im_ambient')"
           )

    create constraint(:ai_gateway_messages, :ai_gateway_messages_type_check,
             check: "type IN ('message', 'compaction')"
           )

    create constraint(:ai_gateway_messages, :ai_gateway_messages_status_check,
             check: "status IN ('generating', 'complete', 'error', 'retracted')"
           )

    create constraint(:ai_gateway_messages, :ai_gateway_messages_content_array,
             check: "jsonb_typeof(content) = 'array'"
           )

    create constraint(:ai_gateway_messages, :ai_gateway_messages_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(
      :ai_gateway_messages,
      "Stored AI-gateway message-log facts: response runs, compactions, and message facts."
    )

    comment_columns(:ai_gateway_messages, %{
      agent_uid: "Agent principal that owns the message.",
      conversation_id: "Conversation containing the message.",
      type: "Row-level semantic: message (normal) or compaction (summary).",
      role: "Legacy transcript/UI role hint; not the authoritative Response item role.",
      status: "Lifecycle: generating, complete, error, or retracted.",
      previous_message_id:
        "Self-reference continuation anchor; renders as previous_response_id on the API.",
      content: "OpenResponses ResponseItem[] subset stored for this row.",
      content_version: "Durable content snapshot version within this row (not a live sequence).",
      covers_range: "Compaction coverage: covered message ids/ranges.",
      metadata: "Auxiliary facts: model/provider, usage, actor_event_id, request refs."
    })
  end

  def down do
    drop table(:ai_gateway_messages)
    drop table(:ai_gateway_conversations)
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
end
