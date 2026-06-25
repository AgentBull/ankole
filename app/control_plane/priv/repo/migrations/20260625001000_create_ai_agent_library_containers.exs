defmodule Ankole.Repo.Migrations.CreateAiAgentLibraryContainers do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto", "")

    create table(:library_skills, primary_key: false) do
      add :skill_name, :text, primary_key: true
      add :description, :text, null: false
      add :default_enabled, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}
      add :content_hash, :text, null: false
      add :synced_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:library_skills, :library_skills_skill_name_format,
             check: "skill_name ~ '^[a-z][a-z0-9_-]{0,63}$'"
           )

    create constraint(:library_skills, :library_skills_description_present,
             check: "length(btrim(description)) > 0"
           )

    create constraint(:library_skills, :library_skills_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create constraint(:library_skills, :library_skills_content_hash_present,
             check: "length(btrim(content_hash)) > 0"
           )

    create table(:library_skill_files, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :skill_name,
          references(:library_skills,
            column: :skill_name,
            type: :text,
            on_delete: :delete_all
          ),
          null: false

      add :path, :text, null: false
      add :content, :text, null: false
      add :content_hash, :text, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:library_skill_files, [:skill_name, :path],
             name: :library_skill_files_skill_path_index
           )

    create constraint(:library_skill_files, :library_skill_files_path_present,
             check: "length(btrim(path)) > 0"
           )

    create constraint(:library_skill_files, :library_skill_files_content_hash_present,
             check: "length(btrim(content_hash)) > 0"
           )

    create constraint(:library_skill_files, :library_skill_files_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create table(:agent_skill_assignments, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :skill_name,
          references(:library_skills,
            column: :skill_name,
            type: :text,
            on_delete: :delete_all
          ),
          null: false

      add :enabled, :boolean, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_skill_assignments, [:agent_uid, :skill_name],
             name: :agent_skill_assignments_agent_skill_index
           )

    create constraint(:agent_skill_assignments, :agent_skill_assignments_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

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
               "source_kind IN ('soul', 'mission', 'skill_append', 'setting', 'memory', 'system', 'user', 'computer')"
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
