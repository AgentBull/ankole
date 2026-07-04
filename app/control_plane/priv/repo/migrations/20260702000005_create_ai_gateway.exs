defmodule Ankole.Repo.Migrations.CreateAiGateway do
  # AIGateway owns durable conversation and message-log state.
  #
  # The continuation chain is previous_message_id, durable content is written only at
  # terminal state, and metadata.actor_event_id has a partial unique index so one actor
  # event can have at most one generating message row.
  use Ecto.Migration

  def up do
    # Conversations store identity and metadata only; continuation position is derived
    # from the message graph instead of cached on the conversation row.
    create table(:ai_gateway_conversations, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :conversation_key, :text, null: false
      add :ended_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # One agent/conversation_key may have only one active conversation at a time.
    create unique_index(:ai_gateway_conversations, [:agent_uid, :conversation_key],
             name: :ai_gateway_conversations_active_key_index,
             where: "ended_at IS NULL"
           )

    create constraint(:ai_gateway_conversations, :ai_gateway_conversations_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(:ai_gateway_conversations, "Durable AI-gateway conversation threads per agent.")

    comment_columns(:ai_gateway_conversations, %{
      agent_uid: "Agent principal that owns the conversation.",
      conversation_key: "Agent-local key used to identify the active conversation lane.",
      ended_at: "Time the conversation was closed and excluded from active-key uniqueness.",
      metadata: "Conversation metadata outside the stable message contract."
    })

    # Each row is a stored message-log fact: a stateful Responses run, a compaction,
    # or an internal AIGateway message fact. type is semantics; status is lifecycle.
    create table(:ai_gateway_messages, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :conversation_id,
          references(:ai_gateway_conversations, type: :uuid, on_delete: :delete_all), null: false

      # Row-level semantic:
      #   message - ordinary response/message fact
      #   compaction - summary fact whose content must contain a compaction item
      add :type, :text, null: false

      # role is a legacy transcript/UI projection hint, not the authoritative item role.
      # It may be null because function_call-style items do not carry a role.
      add :role, :text

      # Lifecycle:
      #   generating - active actor event is still running its Responses loop
      #   complete - eligible for normal model-chain projection
      #   error - terminal failure preserved as an auditable fact
      #   retracted - audit-retained row excluded from normal history and anchors
      add :status, :text, null: false

      # Self-reference continuation anchor; the API renders it as previous_response_id.
      # The API id resp_<id> is derived from ai_gateway_messages.id.
      add :previous_message_id, :uuid

      # content is the stored OpenResponses ResponseItem[] subset for one response.create.
      # Multiple items from the same create call remain array elements in one row.
      add :content, :map, null: false, default: fragment("'[]'::jsonb")
      add :covers_until_message_id, :uuid
      # metadata stores auxiliary facts: model/provider, usage, provider raw ids,
      # render hints, actor_event_id, request refs, and compaction refs. actor_event_id
      # is the AIGateway/ActorRuntime correlation key.
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # Self-referential FK for previous_message_id; execute is used because Ecto's
    # references helper cannot express this same-table FK in the create block.
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

    # Continuation lookup: find rows that directly continue a given message row.
    create index(:ai_gateway_messages, [:previous_message_id],
             name: :ai_gateway_messages_previous_message_id_index,
             where: "previous_message_id IS NOT NULL"
           )

    # Each actor event may have only one in-flight message row. Reconnect uses this
    # index to locate the active response.create row without persisting partial streams.
    execute(
      """
      CREATE UNIQUE INDEX ai_gateway_messages_generating_actor_event_index
      ON ai_gateway_messages ((metadata->>'actor_event_id'))
      WHERE status = 'generating' AND type = 'message'
      """,
      "DROP INDEX IF EXISTS ai_gateway_messages_generating_actor_event_index"
    )

    execute(
      """
      CREATE UNIQUE INDEX ai_gateway_messages_tool_result_journal_key_index
      ON ai_gateway_messages ((metadata->>'tool_result_idempotency_key'))
      WHERE metadata ? 'tool_result_idempotency_key'
      """,
      "DROP INDEX IF EXISTS ai_gateway_messages_tool_result_journal_key_index"
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
      covers_until_message_id:
        "Compaction coverage boundary interpreted only on this row's ancestor chain.",
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
