defmodule Ankole.Repo.Migrations.ImplementBrainV2Storage do
  @moduledoc false

  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("""
    TRUNCATE TABLE
      brain_audit_log,
      brain_block_citations,
      brain_entry_blocks,
      brain_entry_relations,
      brain_entries,
      brain_episodes,
      brain_retained_sources,
      brain_cursors
    """)

    execute("ALTER TYPE principal_type ADD VALUE IF NOT EXISTS 'system'")

    execute("""
    INSERT INTO principals (uid, type, status, display_name, inserted_at, updated_at)
    VALUES ('brain-shared', 'system', 'active', 'Shared long-term memory', now(), now())
    ON CONFLICT (uid) DO UPDATE
    SET type = 'system', status = 'active', display_name = EXCLUDED.display_name, updated_at = now()
    """)

    replace_store_constraints()
    replace_unique_indexes()
    replace_relation_guard()
    add_episode_source_index()
    add_source_sync_fields()
    add_vector_indexes()

    alter table(:signal_gateway_bindings) do
      add :confidential_memory, :boolean, null: false, default: false
    end
  end

  def down do
    raise "Brain V2 storage cannot be downgraded because its ownership and vector contracts replace V1"
  end

  defp replace_store_constraints do
    for table <-
          ~w(brain_entries brain_entry_blocks brain_entry_relations brain_audit_log brain_retained_sources) do
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{table}_store_key_check")

      execute("""
      ALTER TABLE #{table}
      ADD CONSTRAINT #{table}_store_key_check CHECK (
        store_key IN ('shared', 'self') OR
        (store_key LIKE 'dm:%' AND length(store_key) > 3) OR
        (store_key LIKE 'channel:%' AND length(store_key) > 8)
      )
      """)
    end
  end

  defp replace_unique_indexes do
    execute("DROP INDEX brain_entries_public_pinned_memo_index")
    execute("DROP INDEX brain_entries_public_curation_guide_index")

    execute("""
    CREATE UNIQUE INDEX brain_entries_self_pinned_memo_index
    ON brain_entries (owner_uid)
    WHERE store_key = 'self' AND type = 'agent_system_pinned_memo'
    """)

    execute("""
    CREATE UNIQUE INDEX brain_entries_self_curation_guide_index
    ON brain_entries (owner_uid)
    WHERE store_key = 'self' AND type = 'brain_curation_guide'
    """)
  end

  defp replace_relation_guard do
    execute("DROP TRIGGER brain_entry_relations_scope_guard ON brain_entry_relations")
    execute("DROP FUNCTION brain_validate_entry_relation_scope()")

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
      SELECT owner_uid, store_key INTO source_owner, source_store
      FROM brain_entries WHERE id = NEW.source_entry_id;

      SELECT owner_uid, store_key INTO target_owner, target_store
      FROM brain_entries WHERE id = NEW.target_entry_id;

      IF source_owner IS NULL OR target_owner IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'foreign_key_violation',
          MESSAGE = 'long-term memory relation endpoint does not exist';
      END IF;

      IF NEW.owner_uid <> source_owner OR NEW.store_key <> source_store THEN
        RAISE EXCEPTION USING ERRCODE = 'check_violation',
          MESSAGE = 'long-term memory relation scope must match its source entry';
      END IF;

      IF source_store = 'shared' AND
         (source_owner <> 'brain-shared' OR target_owner <> 'brain-shared' OR target_store <> 'shared') THEN
        RAISE EXCEPTION USING ERRCODE = 'check_violation',
          MESSAGE = 'shared entries can reference only shared entries';
      END IF;

      IF source_store <> 'shared' AND NOT (
        (target_owner = source_owner AND target_store = source_store) OR
        (target_owner = 'brain-shared' AND target_store = 'shared')
      ) THEN
        RAISE EXCEPTION USING ERRCODE = 'check_violation',
          MESSAGE = 'private entries can reference only their own store or shared entries';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER brain_entry_relations_scope_guard
    BEFORE INSERT OR UPDATE ON brain_entry_relations
    FOR EACH ROW EXECUTE FUNCTION brain_validate_entry_relation_scope()
    """)
  end

  defp add_episode_source_index do
    create index(:brain_episodes, [:source_entry_ids],
             using: :gin,
             name: :brain_episodes_source_entry_ids_gin_index
           )
  end

  defp add_source_sync_fields do
    execute("DROP TRIGGER brain_retained_sources_immutable ON brain_retained_sources")
    execute("DROP FUNCTION reject_brain_retained_source_update()")

    execute(
      "ALTER TABLE brain_retained_sources DROP CONSTRAINT brain_retained_sources_capture_method_check"
    )

    alter table(:brain_retained_sources) do
      add :connector_id, :text
      add :revision, :text
      add :source_url, :text

      add :learning_agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :nilify_all)

      add :sync_state, :text, null: false, default: "current"
      add :last_synced_at, :utc_datetime_usec
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:brain_retained_sources, :brain_retained_sources_capture_method_check,
             check: "capture_method ~ '^[a-z][a-z0-9_]{0,63}$'"
           )

    create constraint(:brain_retained_sources, :brain_retained_sources_sync_state_check,
             check: "sync_state IN ('current', 'deleted', 'access_lost', 'failed')"
           )

    create constraint(:brain_retained_sources, :brain_retained_sources_connector_check,
             check:
               "(capture_method <> 'file') = (connector_id IS NOT NULL AND revision IS NOT NULL) AND (capture_method = 'file' OR capture_method = connector_id)"
           )

    create constraint(:brain_retained_sources, :brain_retained_sources_learning_agent_check,
             check: "capture_method <> 'file' OR learning_agent_uid IS NOT NULL"
           )

    create unique_index(:brain_retained_sources, [:connector_id, :origin_locator],
             name: :brain_retained_sources_connector_locator_index,
             where: "capture_method <> 'file'"
           )

    execute("""
    CREATE UNIQUE INDEX brain_entries_source_mirror_document_index
    ON brain_entries ((properties->>'source_document_id'))
    WHERE properties->>'source_mirror' = 'true'
    """)

    execute("""
    CREATE FUNCTION guard_brain_retained_source_update()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.capture_method = 'file' OR
         NEW.id <> OLD.id OR NEW.document_id <> OLD.document_id OR
         NEW.owner_uid <> OLD.owner_uid OR NEW.store_key <> OLD.store_key OR
         NEW.capture_method <> OLD.capture_method OR NEW.connector_id <> OLD.connector_id OR
         NEW.origin_locator IS DISTINCT FROM OLD.origin_locator OR
         NEW.learning_agent_uid IS DISTINCT FROM OLD.learning_agent_uid OR
         NEW.captured_by_uid IS DISTINCT FROM OLD.captured_by_uid OR
         NEW.inserted_at <> OLD.inserted_at THEN
        RAISE EXCEPTION 'retained source identity and manual source bytes are immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER brain_retained_sources_update_guard
    BEFORE UPDATE ON brain_retained_sources
    FOR EACH ROW EXECUTE FUNCTION guard_brain_retained_source_update()
    """)
  end

  defp add_vector_indexes do
    execute("ALTER TABLE brain_entry_blocks ALTER COLUMN embedding TYPE vector(4096) USING NULL")

    execute("ALTER TABLE brain_episodes ALTER COLUMN embedding TYPE vector(4096) USING NULL")

    alter table(:brain_entry_blocks) do
      add :embedding_model_agent_uid, :text
    end

    alter table(:brain_episodes) do
      add :embedding_model_agent_uid, :text
    end

    execute(
      "ALTER TABLE brain_entry_blocks DROP CONSTRAINT brain_entry_blocks_embedding_state_consistent"
    )

    execute(
      "ALTER TABLE brain_episodes DROP CONSTRAINT brain_episodes_embedding_state_consistent"
    )

    create constraint(:brain_entry_blocks, :brain_entry_blocks_embedding_state_consistent,
             check: """
             (embedding_state = 'pending' AND embedding IS NULL AND embedding_dimensions IS NULL AND embedding_model_agent_uid IS NULL AND embedding_error IS NULL) OR
             (embedding_state = 'synced' AND embedding IS NOT NULL AND embedding_dimensions IS NOT NULL AND embedding_model_agent_uid IS NOT NULL AND embedding_error IS NULL) OR
             (embedding_state = 'failed' AND embedding IS NULL AND embedding_dimensions IS NULL AND embedding_model_agent_uid IS NULL AND length(btrim(embedding_error)) > 0)
             """
           )

    create constraint(:brain_episodes, :brain_episodes_embedding_state_consistent,
             check: """
             (embedding_state = 'pending' AND embedding IS NULL AND embedding_dimensions IS NULL AND embedding_model_agent_uid IS NULL AND embedding_error IS NULL) OR
             (embedding_state = 'synced' AND embedding IS NOT NULL AND embedding_dimensions IS NOT NULL AND embedding_model_agent_uid IS NOT NULL AND embedding_error IS NULL) OR
             (embedding_state = 'failed' AND embedding IS NULL AND embedding_dimensions IS NULL AND embedding_model_agent_uid IS NULL AND length(btrim(embedding_error)) > 0)
             """
           )

    execute("""
    CREATE INDEX brain_entry_blocks_embedding_hnsw_index
    ON brain_entry_blocks USING hnsw
      ((subvector(embedding, 1, 4000)::halfvec(4000)) halfvec_cosine_ops)
    """)

    execute("""
    CREATE INDEX brain_episodes_embedding_hnsw_index
    ON brain_episodes USING hnsw
      ((subvector(embedding, 1, 4000)::halfvec(4000)) halfvec_cosine_ops)
    """)
  end
end
