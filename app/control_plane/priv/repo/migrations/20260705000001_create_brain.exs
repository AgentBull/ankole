defmodule Ankole.Repo.Migrations.CreateBrain do
  @moduledoc false

  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_search")
    execute("CREATE EXTENSION IF NOT EXISTS vector")

    create_enum_types()
    rebuild_signal_entry_search()
    create_entries()
    create_entry_blocks()
    create_entry_relations()
    create_audit_log()
    create_episodes()
    create_cursors()
    create_relation_guard()
    create_brain_search_indexes()
  end

  def down do
    execute("DROP INDEX IF EXISTS signal_gateway_entries_brain_bm25_index")

    execute("DROP TRIGGER IF EXISTS brain_entry_relations_scope_guard ON brain_entry_relations")
    execute("DROP FUNCTION IF EXISTS brain_validate_entry_relation_scope()")

    drop table(:brain_cursors)
    drop table(:brain_episodes)
    drop table(:brain_audit_log)
    drop table(:brain_entry_relations)
    drop table(:brain_entry_blocks)
    drop table(:brain_entries)

    execute("DROP TYPE IF EXISTS brain_cursor_scope_kind")
    execute("DROP TYPE IF EXISTS brain_embedding_state")
    execute("DROP TYPE IF EXISTS brain_author_kind")

    drop_if_exists index(:signal_gateway_entries, [:document_id],
                     name: :signal_gateway_entries_document_id_unique_index
                   )

    create index(:signal_gateway_entries, [:document_id],
             name: :signal_gateway_entries_document_id_index
           )
  end

  defp create_enum_types do
    execute("CREATE TYPE brain_author_kind AS ENUM ('human', 'agent', 'dreaming')")
    execute("CREATE TYPE brain_embedding_state AS ENUM ('pending', 'synced', 'failed')")
    execute("CREATE TYPE brain_cursor_scope_kind AS ENUM ('channel', 'principal')")
  end

  defp rebuild_signal_entry_search do
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

    execute("""
    CREATE INDEX signal_gateway_entries_brain_bm25_index
    ON signal_gateway_entries
    USING bm25 (
      document_id,
      (search_text::pdb.jieba),
      (metadata_text::pdb.jieba)
    )
    WITH (key_field='document_id')
    """)
  end

  defp create_entries do
    create table(:brain_entries, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :owner_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :store_key, :text, null: false
      add :name, :text, null: false
      add :type, :text, null: false
      add :summary, :text, null: false, default: ""
      add :aliases, {:array, :text}, null: false, default: []
      add :properties, :map, null: false, default: %{}
      add :search_text, :text, null: false
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:brain_entries, [:owner_uid, :store_key, :name],
             name: :brain_entries_owner_store_name_index
           )

    create unique_index(:brain_entries, [:id, :owner_uid, :store_key],
             name: :brain_entries_scope_identity_index
           )

    create index(:brain_entries, [:owner_uid, :store_key, :type],
             name: :brain_entries_owner_store_type_index
           )

    create unique_index(:brain_entries, [:owner_uid],
             name: :brain_entries_public_pinned_memo_index,
             where: "store_key = 'public' AND type = 'agent_system_pinned_memo'"
           )

    execute("""
    CREATE UNIQUE INDEX brain_entries_channel_identity_index
    ON brain_entries (owner_uid, store_key, (properties->>'channel_id'))
    WHERE properties ? 'channel_id' AND length(btrim(properties->>'channel_id')) > 0
    """)

    create_store_key_constraint(:brain_entries)
    create_positive_lock_version_constraint(:brain_entries)

    create constraint(:brain_entries, :brain_entries_name_present,
             check: "length(btrim(name)) > 0"
           )

    create constraint(:brain_entries, :brain_entries_type_present,
             check: "length(btrim(type)) > 0"
           )

    create constraint(:brain_entries, :brain_entries_search_text_present,
             check: "length(btrim(search_text)) > 0"
           )

    create constraint(:brain_entries, :brain_entries_properties_object,
             check: "jsonb_typeof(properties) = 'object'"
           )
  end

  defp create_entry_blocks do
    create table(:brain_entry_blocks, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :entry_id, :uuid, null: false

      add :owner_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :store_key, :text, null: false
      add :position, :integer, null: false
      add :body, :text, null: false
      add :author_kind, :brain_author_kind, null: false

      add :author_uid,
          references(:principals, column: :uid, type: :text, on_delete: :nilify_all)

      add :embedding, :text
      add :embedding_dimensions, :integer
      add :embedding_state, :brain_embedding_state, null: false, default: "pending"
      add :embedding_error, :text
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    execute("""
    ALTER TABLE brain_entry_blocks
    ADD CONSTRAINT brain_entry_blocks_entry_scope_fkey
    FOREIGN KEY (entry_id, owner_uid, store_key)
    REFERENCES brain_entries (id, owner_uid, store_key)
    ON DELETE CASCADE
    """)

    create unique_index(:brain_entry_blocks, [:entry_id, :position],
             name: :brain_entry_blocks_entry_position_index
           )

    create index(:brain_entry_blocks, [:owner_uid, :store_key],
             name: :brain_entry_blocks_owner_store_index
           )

    create index(:brain_entry_blocks, [:author_kind], name: :brain_entry_blocks_author_kind_index)

    create index(:brain_entry_blocks, [:embedding_state],
             name: :brain_entry_blocks_embedding_state_index
           )

    create_store_key_constraint(:brain_entry_blocks)
    create_positive_lock_version_constraint(:brain_entry_blocks)

    create constraint(:brain_entry_blocks, :brain_entry_blocks_position_nonnegative,
             check: "position >= 0"
           )

    create constraint(:brain_entry_blocks, :brain_entry_blocks_body_present,
             check: "length(btrim(body)) > 0"
           )

    create constraint(:brain_entry_blocks, :brain_entry_blocks_embedding_dimensions_positive,
             check: "embedding_dimensions IS NULL OR embedding_dimensions > 0"
           )

    create constraint(:brain_entry_blocks, :brain_entry_blocks_embedding_state_consistent,
             check: """
             (embedding_state = 'pending' AND embedding IS NULL AND embedding_dimensions IS NULL) OR
             (embedding_state = 'synced' AND embedding IS NOT NULL AND embedding_dimensions IS NOT NULL AND embedding_error IS NULL) OR
             (embedding_state = 'failed' AND embedding IS NULL AND embedding_dimensions IS NULL AND length(btrim(embedding_error)) > 0)
             """
           )
  end

  defp create_entry_relations do
    create table(:brain_entry_relations, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :owner_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :store_key, :text, null: false

      add :source_entry_id,
          references(:brain_entries, type: :uuid, on_delete: :delete_all),
          null: false

      add :predicate, :text, null: false

      add :target_entry_id,
          references(:brain_entries, type: :uuid, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :brain_entry_relations,
             [
               :source_entry_id,
               :predicate,
               :target_entry_id
             ],
             name: :brain_entry_relations_unique_edge_index
           )

    create index(:brain_entry_relations, [:target_entry_id],
             name: :brain_entry_relations_target_index
           )

    create index(:brain_entry_relations, [:owner_uid, :store_key],
             name: :brain_entry_relations_owner_store_index
           )

    create_store_key_constraint(:brain_entry_relations)

    create constraint(:brain_entry_relations, :brain_entry_relations_predicate_present,
             check: "length(btrim(predicate)) > 0"
           )

    create constraint(:brain_entry_relations, :brain_entry_relations_no_self_edge,
             check: "source_entry_id <> target_entry_id"
           )
  end

  defp create_audit_log do
    create table(:brain_audit_log, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :owner_uid,
          references(:principals, column: :uid, type: :text),
          null: false

      add :store_key, :text, null: false
      add :actor_kind, :brain_author_kind

      add :actor_uid,
          references(:principals, column: :uid, type: :text, on_delete: :nilify_all)

      add :action, :text, null: false
      add :entry_id, :uuid
      add :block_id, :uuid
      add :relation_id, :uuid
      add :before, :map
      add :after, :map
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:brain_audit_log, [:owner_uid, :store_key, :inserted_at],
             name: :brain_audit_log_owner_store_time_index
           )

    create index(:brain_audit_log, [:entry_id, :inserted_at],
             name: :brain_audit_log_entry_time_index
           )

    create index(:brain_audit_log, [:actor_kind, :actor_uid, :inserted_at],
             name: :brain_audit_log_actor_time_index
           )

    create_store_key_constraint(:brain_audit_log)

    create constraint(:brain_audit_log, :brain_audit_log_action_present,
             check: "length(btrim(action)) > 0"
           )

    create constraint(:brain_audit_log, :brain_audit_log_before_object,
             check: "before IS NULL OR jsonb_typeof(before) = 'object'"
           )

    create constraint(:brain_audit_log, :brain_audit_log_after_object,
             check: "after IS NULL OR jsonb_typeof(after) = 'object'"
           )

    create constraint(:brain_audit_log, :brain_audit_log_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )
  end

  defp create_episodes do
    create table(:brain_episodes, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :signal_channel_id,
          references(:signal_gateway_channels, column: :id, type: :text, on_delete: :delete_all),
          null: false

      add :topic, :text, null: false
      add :summary, :text, null: false
      add :source_entry_ids, {:array, :text}, null: false, default: []
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec, null: false
      add :embedding, :text
      add :embedding_dimensions, :integer
      add :embedding_state, :brain_embedding_state, null: false, default: "pending"
      add :embedding_error, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:brain_episodes, [:signal_channel_id, :ended_at],
             name: :brain_episodes_channel_ended_at_index
           )

    create index(:brain_episodes, [:embedding_state], name: :brain_episodes_embedding_state_index)

    create constraint(:brain_episodes, :brain_episodes_topic_present,
             check: "length(btrim(topic)) > 0"
           )

    create constraint(:brain_episodes, :brain_episodes_summary_present,
             check: "length(btrim(summary)) > 0"
           )

    create constraint(:brain_episodes, :brain_episodes_embedding_dimensions_positive,
             check: "embedding_dimensions IS NULL OR embedding_dimensions > 0"
           )

    create constraint(:brain_episodes, :brain_episodes_embedding_state_consistent,
             check: """
             (embedding_state = 'pending' AND embedding IS NULL AND embedding_dimensions IS NULL) OR
             (embedding_state = 'synced' AND embedding IS NOT NULL AND embedding_dimensions IS NOT NULL AND embedding_error IS NULL) OR
             (embedding_state = 'failed' AND embedding IS NULL AND embedding_dimensions IS NULL AND length(btrim(embedding_error)) > 0)
             """
           )

    create constraint(:brain_episodes, :brain_episodes_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )
  end

  defp create_cursors do
    create table(:brain_cursors, primary_key: false) do
      add :scope_kind, :brain_cursor_scope_kind, primary_key: true
      add :scope_key, :text, primary_key: true
      add :cursor_provider_time, :utc_datetime_usec
      add :cursor_source_entry_id, :text
      add :cursor_entry_observed_at, :utc_datetime_usec
      add :unavailable_reason, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:brain_cursors, :brain_cursors_scope_key_present,
             check: "length(btrim(scope_key)) > 0"
           )

    create constraint(:brain_cursors, :brain_cursors_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )
  end

  defp create_relation_guard do
    execute("""
    CREATE FUNCTION brain_validate_entry_relation_scope()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      source_owner text;
      source_store text;
      target_owner text;
      target_store text;
    BEGIN
      SELECT owner_uid, store_key
      INTO source_owner, source_store
      FROM brain_entries
      WHERE id = NEW.source_entry_id;

      SELECT owner_uid, store_key
      INTO target_owner, target_store
      FROM brain_entries
      WHERE id = NEW.target_entry_id;

      IF source_owner IS NULL OR target_owner IS NULL THEN
        RAISE EXCEPTION USING
          ERRCODE = 'foreign_key_violation',
          MESSAGE = 'brain relation endpoint does not exist';
      END IF;

      IF NEW.owner_uid <> source_owner OR NEW.store_key <> source_store THEN
        RAISE EXCEPTION USING
          ERRCODE = 'check_violation',
          MESSAGE = 'brain relation scope must match its source entry';
      END IF;

      IF target_owner <> source_owner THEN
        RAISE EXCEPTION USING
          ERRCODE = 'check_violation',
          MESSAGE = 'brain relation endpoints must have the same owner';
      END IF;

      IF source_store = 'public' AND target_store <> 'public' THEN
        RAISE EXCEPTION USING
          ERRCODE = 'check_violation',
          MESSAGE = 'public brain entries cannot reference DM entries';
      END IF;

      IF source_store <> 'public' AND target_store NOT IN ('public', source_store) THEN
        RAISE EXCEPTION USING
          ERRCODE = 'check_violation',
          MESSAGE = 'DM brain entries can reference only their own DM store or public';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER brain_entry_relations_scope_guard
    BEFORE INSERT OR UPDATE ON brain_entry_relations
    FOR EACH ROW
    EXECUTE FUNCTION brain_validate_entry_relation_scope()
    """)
  end

  defp create_brain_search_indexes do
    execute("""
    CREATE INDEX brain_entries_bm25_index
    ON brain_entries
    USING bm25 (id, (search_text::pdb.jieba))
    WITH (key_field='id')
    """)

    execute("""
    CREATE INDEX brain_entry_blocks_bm25_index
    ON brain_entry_blocks
    USING bm25 (id, (body::pdb.jieba))
    WITH (key_field='id')
    """)
  end

  defp create_store_key_constraint(table) do
    create constraint(table, String.to_atom("#{table}_store_key_check"),
             check: "store_key = 'public' OR store_key ~ '^dm:.+$'"
           )
  end

  defp create_positive_lock_version_constraint(table) do
    create constraint(table, String.to_atom("#{table}_lock_version_positive"),
             check: "lock_version > 0"
           )
  end
end
