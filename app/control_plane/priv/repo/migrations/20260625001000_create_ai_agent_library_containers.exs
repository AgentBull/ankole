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
  end
end
