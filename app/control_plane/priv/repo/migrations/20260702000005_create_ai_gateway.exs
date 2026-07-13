defmodule Ankole.Repo.Migrations.CreateAIGateway do
  # AIGateway owns durable conversation and message-log state.
  #
  # The continuation chain is previous_message_id, durable content is written only at
  # terminal state, and checkpoint rows reference immutable compaction artifacts.
  use Ecto.Migration

  def up do
    # Conversations store identity and metadata only; continuation position is derived
    # from the message graph instead of cached on the conversation row.
    create table(:ai_gateway_conversations, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :subject_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :conversation_key, :text, null: false
      add :ended_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # One subject/conversation_key may have only one active conversation at a time.
    create unique_index(:ai_gateway_conversations, [:subject_uid, :conversation_key],
             name: :ai_gateway_conversations_active_key_index,
             where: "ended_at IS NULL"
           )

    create constraint(:ai_gateway_conversations, :ai_gateway_conversations_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(
      :ai_gateway_conversations,
      "Durable AIGateway conversation threads per Principal subject."
    )

    comment_columns(:ai_gateway_conversations, %{
      subject_uid: "Principal that owns the conversation.",
      conversation_key: "Subject-local key used to identify an active conversation.",
      ended_at: "Time the conversation was closed and excluded from active-key uniqueness.",
      metadata: "Conversation metadata outside the stable message contract."
    })

    # Each row is a stored Response, journal, or checkpoint fact. type is semantics;
    # status is lifecycle.
    create table(:ai_gateway_messages, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :subject_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :conversation_id,
          references(:ai_gateway_conversations, type: :uuid, on_delete: :delete_all), null: false

      # Row-level semantic:
      #   message - ordinary response/message fact
      #   checkpoint - continuation anchor that references one compaction artifact
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
      # metadata stores opaque caller metadata plus AIGateway response facts.
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

    create index(:ai_gateway_messages, [:subject_uid, :conversation_id],
             name: :ai_gateway_messages_conversation_index
           )

    # Continuation lookup: find rows that directly continue a given message row.
    create index(:ai_gateway_messages, [:previous_message_id],
             name: :ai_gateway_messages_previous_message_id_index,
             where: "previous_message_id IS NOT NULL"
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
             check: "type IN ('message', 'checkpoint')"
           )

    create constraint(:ai_gateway_messages, :ai_gateway_messages_status_check,
             check: "status IN ('generating', 'complete', 'error', 'retracted')"
           )

    create constraint(:ai_gateway_messages, :ai_gateway_messages_content_array,
             check: "jsonb_typeof(content) = 'array'"
           )

    create constraint(
             :ai_gateway_messages,
             :ai_gateway_messages_message_content_no_compaction_refs,
             check:
               "type <> 'message' OR NOT jsonb_path_exists(content, '$[*] ? (@.type == \"compaction\" || @.type == \"compaction_artifact\")')"
           )

    create constraint(
             :ai_gateway_messages,
             :ai_gateway_messages_checkpoint_content_ref,
             check:
               "type <> 'checkpoint' OR (jsonb_array_length(content) = 1 AND content->0->>'type' = 'compaction_artifact' AND content->0->>'id' ~ '^cmp_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')"
           )

    create constraint(:ai_gateway_messages, :ai_gateway_messages_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(
      :ai_gateway_messages,
      "Stored Response, journal, and checkpoint facts owned by AIGateway."
    )

    comment_columns(:ai_gateway_messages, %{
      subject_uid: "Principal that owns the response message.",
      conversation_id: "Conversation containing the message.",
      type: "Row-level semantic: message (normal) or checkpoint (compaction continuation).",
      role: "Legacy transcript/UI role hint; not the authoritative Response item role.",
      status: "Lifecycle: generating, complete, error, or retracted.",
      previous_message_id:
        "Self-reference continuation anchor; renders as previous_response_id on the API.",
      content:
        "OpenResponses ResponseItem[] for message rows, or one compaction_artifact ref for checkpoint rows.",
      metadata: "Opaque caller metadata plus AIGateway response facts."
    })

    create table(:ai_gateway_compaction_artifacts, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :subject_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :conversation_id,
          references(:ai_gateway_conversations, type: :uuid, on_delete: :delete_all)

      add :content, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ai_gateway_compaction_artifacts, [:subject_uid, :conversation_id],
             name: :ai_gateway_compaction_artifacts_owner_index
           )

    create constraint(
             :ai_gateway_compaction_artifacts,
             :ai_gateway_compaction_artifacts_content_object,
             check: "jsonb_typeof(content) = 'object'"
           )

    comment_table(
      :ai_gateway_compaction_artifacts,
      "Immutable compaction artifacts owned by an AIGateway subject."
    )

    comment_columns(:ai_gateway_compaction_artifacts, %{
      subject_uid: "Principal that owns the compaction artifact.",
      conversation_id: "Optional conversation associated with stateful/checkpoint compaction.",
      content:
        "Versioned compaction artifact JSON body including summary, output, retention, and usage."
    })
  end

  def down do
    drop table(:ai_gateway_compaction_artifacts)
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
