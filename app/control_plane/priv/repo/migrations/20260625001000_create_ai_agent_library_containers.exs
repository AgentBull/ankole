defmodule Ankole.Repo.Migrations.CreateAiAgentLibraryContainers do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto", "")

    create table(:agent_library_container_entries, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :path, :text, null: false
      add :source_kind, :text, null: false
      add :content, :text
      add :content_hash, :text
      add :metadata, :map, null: false, default: %{}
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_library_container_entries, [:agent_uid, :path],
             name: :agent_library_container_entries_active_path_index,
             where: "deleted_at IS NULL"
           )

    create index(:agent_library_container_entries, [:agent_uid, :source_kind],
             name: :agent_library_container_entries_source_kind_index
           )

    create constraint(
             :agent_library_container_entries,
             :agent_library_container_entries_path_present,
             check: "length(btrim(path)) > 0"
           )

    create constraint(
             :agent_library_container_entries,
             :agent_library_container_entries_source_kind_check,
             check:
               "source_kind IN ('soul', 'mission', 'setting', 'memory', 'system', 'user', 'computer')"
           )

    create constraint(
             :agent_library_container_entries,
             :agent_library_container_entries_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create table(:library_builtin_sync_state, primary_key: false) do
      add :name, :text, primary_key: true
      add :content_hash, :text, null: false
      add :synced_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:library_builtin_sync_state, :library_builtin_sync_state_name_present,
             check: "length(btrim(name)) > 0"
           )

    create constraint(
             :library_builtin_sync_state,
             :library_builtin_sync_state_content_hash_present,
             check: "length(btrim(content_hash)) > 0"
           )

    create constraint(:library_builtin_sync_state, :library_builtin_sync_state_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(
      :agent_library_container_entries,
      "Per-agent library container entries materialized for worker-visible files."
    )

    comment_columns(:agent_library_container_entries, %{
      agent_uid: "Agent principal that owns the library entry.",
      path: "Agent-local library path exposed to the worker.",
      source_kind: "Library source bucket such as mission, memory, system, or computer.",
      content: "Text content stored for file-backed library entries.",
      content_hash: "Hash of the stored content projection.",
      metadata: "Library entry metadata outside the file content contract.",
      deleted_at: "Soft-delete marker that removes the path from the active library view."
    })

    comment_table(:library_builtin_sync_state, "Sync checkpoints for built-in library content.")

    comment_columns(:library_builtin_sync_state, %{
      name: "Built-in content bundle or source name.",
      content_hash: "Hash last observed for the built-in content source.",
      synced_at: "Time the built-in content source was last synchronized.",
      metadata: "Sync metadata outside the content hash contract."
    })
  end

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
