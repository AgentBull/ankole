defmodule Ankole.Repo.Migrations.CreateAiGatewayCompactionArtifacts do
  use Ecto.Migration

  def up do
    create table(:ai_gateway_compaction_artifacts, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :conversation_id,
          references(:ai_gateway_conversations, type: :uuid, on_delete: :delete_all)

      add :content, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ai_gateway_compaction_artifacts, [:agent_uid, :conversation_id],
             name: :ai_gateway_compaction_artifacts_owner_index
           )

    create constraint(
             :ai_gateway_compaction_artifacts,
             :ai_gateway_compaction_artifacts_content_object,
             check: "jsonb_typeof(content) = 'object'"
           )

    execute(
      "ALTER TABLE ai_gateway_messages DROP CONSTRAINT IF EXISTS ai_gateway_messages_type_check"
    )

    migrate_compaction_rows_to_artifacts()

    execute("""
    UPDATE ai_gateway_messages
    SET type = 'checkpoint',
        content = jsonb_build_array(
          jsonb_build_object(
            'id', 'cmp_' || id::text,
            'type', 'compaction_artifact'
          )
        )
    WHERE type = 'compaction'
    """)

    create constraint(:ai_gateway_messages, :ai_gateway_messages_type_check,
             check: "type IN ('message', 'checkpoint')"
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

    alter table(:ai_gateway_messages) do
      remove :covers_until_message_id
    end

    comment_table(
      :ai_gateway_compaction_artifacts,
      "Canonical AIGateway compaction artifacts. Message checkpoints only reference these rows."
    )

    comment_columns(:ai_gateway_compaction_artifacts, %{
      agent_uid: "Agent principal that owns the compaction artifact.",
      conversation_id: "Optional conversation associated with stateful/checkpoint compaction.",
      content:
        "Versioned compaction artifact JSON body including summary, output, retention, and usage."
    })

    execute(
      "COMMENT ON COLUMN ai_gateway_messages.type IS 'Row-level semantic: message (normal) or checkpoint (compaction continuation).'"
    )

    execute(
      "COMMENT ON COLUMN ai_gateway_messages.content IS 'OpenResponses ResponseItem[] for message rows, or one compaction_artifact ref for checkpoint rows.'"
    )
  end

  def down do
    alter table(:ai_gateway_messages) do
      add :covers_until_message_id, :uuid
    end

    execute(
      "ALTER TABLE ai_gateway_messages DROP CONSTRAINT IF EXISTS ai_gateway_messages_checkpoint_content_ref"
    )

    execute(
      "ALTER TABLE ai_gateway_messages DROP CONSTRAINT IF EXISTS ai_gateway_messages_message_content_no_compaction_refs"
    )

    execute(
      "ALTER TABLE ai_gateway_messages DROP CONSTRAINT IF EXISTS ai_gateway_messages_type_check"
    )

    execute("""
    UPDATE ai_gateway_messages AS message
    SET type = 'compaction',
        content = jsonb_build_array(
          jsonb_build_object(
            'id', 'cmp_' || message.id::text,
            'type', 'compaction',
            'summary', COALESCE(artifact.content->'summary'->>'text', '')
          )
        )
    FROM ai_gateway_compaction_artifacts AS artifact
    WHERE message.type = 'checkpoint'
      AND artifact.id = message.id
    """)

    create constraint(:ai_gateway_messages, :ai_gateway_messages_type_check,
             check: "type IN ('message', 'compaction')"
           )

    drop table(:ai_gateway_compaction_artifacts)
  end

  defp migrate_compaction_rows_to_artifacts do
    execute("""
    WITH RECURSIVE compaction_rows AS (
      SELECT id,
             agent_uid,
             conversation_id,
             previous_message_id,
             covers_until_message_id,
             content,
             metadata,
             inserted_at,
             updated_at
      FROM ai_gateway_messages
      WHERE type = 'compaction'
    ),
    old_summary AS (
      SELECT row.id,
             COALESCE(
               (
                 SELECT item->>'summary'
                 FROM jsonb_array_elements(row.content) AS item
                 WHERE item->>'type' = 'compaction' AND item ? 'summary'
                 LIMIT 1
               ),
               (
                 SELECT item->>'encrypted_content'
                 FROM jsonb_array_elements(row.content) AS item
                 WHERE item->>'type' = 'compaction' AND item ? 'encrypted_content'
                 LIMIT 1
               ),
               ''
             ) AS text
      FROM compaction_rows AS row
    ),
    tail_chain AS (
      SELECT row.id AS compaction_id,
             message.id,
             message.previous_message_id,
             message.content,
             1 AS depth
      FROM compaction_rows AS row
      JOIN ai_gateway_messages AS message
        ON message.id = row.previous_message_id
      WHERE row.previous_message_id IS NOT NULL
        AND (
          row.covers_until_message_id IS NULL
          OR row.previous_message_id <> row.covers_until_message_id
        )

      UNION ALL

      SELECT tail.compaction_id,
             message.id,
             message.previous_message_id,
             message.content,
             tail.depth + 1
      FROM tail_chain AS tail
      JOIN compaction_rows AS row
        ON row.id = tail.compaction_id
      JOIN ai_gateway_messages AS message
        ON message.id = tail.previous_message_id
      WHERE tail.previous_message_id IS NOT NULL
        AND (
          row.covers_until_message_id IS NULL
          OR tail.previous_message_id <> row.covers_until_message_id
        )
        AND tail.depth < 10000
    ),
    tail_items AS (
      SELECT tail.compaction_id,
             jsonb_agg(item.value ORDER BY tail.depth DESC, item.ordinality) AS items
      FROM tail_chain AS tail
      CROSS JOIN LATERAL jsonb_array_elements(tail.content) WITH ORDINALITY AS item(value, ordinality)
      GROUP BY tail.compaction_id
    )
    INSERT INTO ai_gateway_compaction_artifacts (
      id,
      agent_uid,
      conversation_id,
      content,
      inserted_at,
      updated_at
    )
    SELECT row.id,
           row.agent_uid,
           row.conversation_id,
           jsonb_build_object(
             'version', 1,
             'summary', jsonb_build_object('text', summary.text),
             'output',
               jsonb_build_array(
                 jsonb_build_object(
                   'id', 'cmp_' || row.id::text,
                   'type', 'compaction',
                   'encrypted_content', 'ankole:compact:v1:cmp_' || row.id::text,
                   'created_by', 'ankole-aigateway'
                 )
               ) || COALESCE(tail_items.items, '[]'::jsonb),
             'retention',
               jsonb_build_object(
                 'strategy', 'tail_rows',
                 'requested', NULL,
                 'actual', COALESCE(jsonb_array_length(tail_items.items), 0)
               ),
             'usage', COALESCE(row.metadata->'summarizer'->'usage', '{}'::jsonb)
           ),
           row.inserted_at,
           row.updated_at
    FROM compaction_rows AS row
    JOIN old_summary AS summary ON summary.id = row.id
    LEFT JOIN tail_items ON tail_items.compaction_id = row.id
    ON CONFLICT (id) DO NOTHING
    """)
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
