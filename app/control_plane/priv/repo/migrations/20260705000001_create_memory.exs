defmodule Ankole.Repo.Migrations.CreateMemory do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_search")
    execute("CREATE EXTENSION IF NOT EXISTS vector")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM signal_gateway_entries
        GROUP BY document_id
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'signal_gateway_entries.document_id contains duplicates; cannot use as pg_search key_field';
      END IF;
    END $$;
    """)

    drop_if_exists index(:signal_gateway_entries, [:document_id],
                     name: :signal_gateway_entries_document_id_index
                   )

    create unique_index(:signal_gateway_entries, [:document_id],
             name: :signal_gateway_entries_document_id_unique_index
           )

    execute(
      """
      CREATE INDEX signal_gateway_entries_memory_bm25_index
      ON signal_gateway_entries
      USING bm25 (document_id, search_text, metadata_text)
      WITH (key_field='document_id')
      """,
      "DROP INDEX IF EXISTS signal_gateway_entries_memory_bm25_index"
    )

    create table(:memory_notes, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :signal_channel_id,
          references(:signal_gateway_channels, column: :id, type: :text, on_delete: :delete_all),
          null: false

      add :content, :text, null: false
      add :source, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:memory_notes, [:agent_uid, :signal_channel_id],
             name: :memory_notes_agent_channel_index
           )

    create constraint(:memory_notes, :memory_notes_content_present,
             check: "length(btrim(content)) > 0"
           )

    create constraint(:memory_notes, :memory_notes_content_length,
             check: "char_length(content) <= 500"
           )

    create constraint(:memory_notes, :memory_notes_source_object,
             check: "jsonb_typeof(source) = 'object'"
           )

    create table(:memory_episodes, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :signal_channel_id,
          references(:signal_gateway_channels, column: :id, type: :text, on_delete: :delete_all),
          null: false

      add :topic, :text, null: false
      add :summary, :text, null: false
      add :source_entry_ids, {:array, :text}, null: false, default: []
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec, null: false
      add :embedding, :vector
      add :embedding_dimensions, :integer
      add :embedding_state, :text, null: false, default: "pending"
      add :embedding_error, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:memory_episodes, [:signal_channel_id, :ended_at],
             name: :memory_episodes_channel_ended_at_index
           )

    create index(:memory_episodes, [:embedding_state],
             name: :memory_episodes_embedding_state_index
           )

    create constraint(:memory_episodes, :memory_episodes_topic_present,
             check: "length(btrim(topic)) > 0"
           )

    create constraint(:memory_episodes, :memory_episodes_summary_present,
             check: "length(btrim(summary)) > 0"
           )

    create constraint(:memory_episodes, :memory_episodes_embedding_state_check,
             check: "embedding_state IN ('pending', 'synced', 'failed')"
           )

    create constraint(:memory_episodes, :memory_episodes_embedding_dimensions_positive,
             check: "embedding_dimensions IS NULL OR embedding_dimensions > 0"
           )

    create constraint(:memory_episodes, :memory_episodes_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create table(:memory_channel_cursors, primary_key: false) do
      add :signal_channel_id,
          references(:signal_gateway_channels, column: :id, type: :text, on_delete: :delete_all),
          primary_key: true

      add :cursor_provider_time, :utc_datetime_usec
      add :cursor_source_entry_id, :text
      add :cursor_entry_observed_at, :utc_datetime_usec
      add :unavailable_reason, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:memory_channel_cursors, :memory_channel_cursors_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(:memory_notes, "Curated per-agent channel memory notes managed by tools.")
    comment_table(:memory_episodes, "Channel-level historical memory episodes for recall.")
    comment_table(:memory_channel_cursors, "Per-channel Memory Layer B scanner cursors.")
  end

  def down do
    drop table(:memory_channel_cursors)
    drop table(:memory_episodes)
    drop table(:memory_notes)

    execute("DROP INDEX IF EXISTS signal_gateway_entries_memory_bm25_index")

    drop_if_exists index(:signal_gateway_entries, [:document_id],
                     name: :signal_gateway_entries_document_id_unique_index
                   )

    create index(:signal_gateway_entries, [:document_id],
             name: :signal_gateway_entries_document_id_index
           )
  end

  defp comment_table(table, comment) do
    execute(
      "COMMENT ON TABLE #{table} IS #{quote_literal(comment)}",
      "COMMENT ON TABLE #{table} IS NULL"
    )
  end

  defp quote_literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
