defmodule Ankole.Repo.Migrations.RestorePageOwnership do
  use Ecto.Migration

  def up do
    # Rename the identity table in place so references, object ownership and ACL
    # edges keep their original Page IDs throughout this transaction.
    execute("DROP VIEW brain_page_nodes")
    execute("DROP VIEW pod_page_nodes")
    execute("ALTER TABLE pages DROP CONSTRAINT pages_node_fkey")
    execute("ALTER TABLE pages RENAME TO page_properties_migration")
    execute("ALTER TABLE drive_nodes RENAME TO pages")
    execute("ALTER TABLE pages RENAME COLUMN kind TO type")
    execute("ALTER TABLE pages DROP CONSTRAINT drive_nodes_kind")
    execute("ALTER TABLE pages DROP CONSTRAINT drive_nodes_root_shape")

    execute("""
    ALTER TABLE pages
      ADD COLUMN title text NOT NULL DEFAULT '',
      ADD COLUMN icon text,
      ADD COLUMN position text COLLATE "C",
      ADD COLUMN revision bigint NOT NULL DEFAULT 0,
      ADD COLUMN saved_from_message_id uuid,
      ADD COLUMN children_view jsonb NOT NULL DEFAULT '{}',
      ADD COLUMN metadata jsonb NOT NULL DEFAULT '{}',
      ADD COLUMN upstream_state jsonb NOT NULL DEFAULT '{}',
      ADD COLUMN vfs_md_size bigint,
      ADD COLUMN vfs_md_blake3 text,
      ADD COLUMN vfs_content_empty boolean,
      ADD COLUMN is_root boolean GENERATED ALWAYS AS (parent_id IS NULL) STORED
    """)

    execute("UPDATE pages SET title=name")

    execute("""
    UPDATE pages p SET
      title=CASE WHEN p.type IN ('folder','file') THEN p.name ELSE a.title END,
      icon=a.icon,position=a.position,revision=a.revision,
      saved_from_message_id=a.saved_from_message_id,children_view=a.children_view,
      metadata=a.metadata,upstream_state=a.upstream_state,
      vfs_md_size=a.vfs_md_size,vfs_md_blake3=a.vfs_md_blake3,
      updated_at=GREATEST(p.updated_at,a.updated_at)
    FROM page_properties_migration a WHERE a.tenant_id=p.tenant_id AND a.id=p.id
    """)

    execute("""
    WITH RECURSIVE knowledge_tree AS (
      SELECT tenant_id,id FROM pages WHERE system_key='ankole_brain'
      UNION ALL
      SELECT p.tenant_id,p.id FROM pages p JOIN knowledge_tree k
        ON p.tenant_id=k.tenant_id AND p.parent_id=k.id
    )
    UPDATE pages p SET type='knowledge' FROM knowledge_tree k
    WHERE p.tenant_id=k.tenant_id AND p.id=k.id AND p.type='folder'
    """)

    execute("UPDATE pages SET type='doc' WHERE type='folder'")

    execute("ALTER TABLE brain_chunks ADD COLUMN subject_page_id uuid")
    execute("UPDATE brain_chunks SET subject_page_id=page_id WHERE content_kind='body'")

    execute(
      "ALTER TABLE brain_chunks ADD CONSTRAINT brain_chunks_subject_page CHECK (subject_page_id IS NULL OR subject_page_id=page_id)"
    )

    # Content/history tables referenced the optional metadata row. Retarget
    # those FKs before dropping it, preserving each FK's original delete rule.
    execute("""
    DO $$ DECLARE fk record; BEGIN
      FOR fk IN SELECT conrelid::regclass AS relation,conname,
        pg_get_constraintdef(oid) AS definition FROM pg_constraint
        WHERE contype='f' AND confrelid='page_properties_migration'::regclass
      LOOP
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',fk.relation,fk.conname);
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s',fk.relation,fk.conname,
          replace(fk.definition,'REFERENCES page_properties_migration(', 'REFERENCES pages('));
      END LOOP;
    END $$
    """)

    execute("DROP TABLE page_properties_migration")

    execute("""
    DO $$ DECLARE item record; BEGIN
      FOR item IN SELECT conname FROM pg_constraint WHERE conrelid='pages'::regclass
        AND conname LIKE 'drive_nodes_%'
      LOOP
        EXECUTE format('ALTER TABLE pages RENAME CONSTRAINT %I TO %I', item.conname,
          replace(item.conname,'drive_nodes_','pages_'));
      END LOOP;
      FOR item IN SELECT indexname FROM pg_indexes WHERE tablename='pages'
        AND indexname LIKE 'drive_nodes_%'
      LOOP
        EXECUTE format('ALTER INDEX %I RENAME TO %I', item.indexname,
          replace(item.indexname,'drive_nodes_','pages_'));
      END LOOP;
    END $$
    """)

    execute("""
    ALTER TABLE pages
      ADD CONSTRAINT pages_type CHECK (type IN ('doc','knowledge','base','applet','file')),
      ADD CONSTRAINT pages_root_shape CHECK (
        (parent_id IS NULL AND type='doc' AND num_nonnulls(private_owner_uid,conversation_id)<=1)
        OR (parent_id IS NOT NULL AND private_owner_uid IS NULL AND conversation_id IS NULL)),
      ADD CONSTRAINT pages_revision_check CHECK (revision>=0),
      ADD CONSTRAINT pages_children_view_object CHECK (jsonb_typeof(children_view)='object'),
      ADD CONSTRAINT pages_metadata_object CHECK (jsonb_typeof(metadata)='object'),
      ADD CONSTRAINT pages_upstream_state_object CHECK (jsonb_typeof(upstream_state)='object')
    """)

    execute("DROP INDEX pages_name_trgm_index")

    execute(
      "CREATE INDEX pages_name_trgm_index ON pages USING gin(name gin_trgm_ops) WHERE deleted_at IS NULL"
    )

    execute("CREATE INDEX pages_title_trgm_gin_index ON pages USING gin(title gin_trgm_ops)")

    execute("""
    INSERT INTO page_contents(tenant_id,page_id,content,plain_text,updated_by,updated_at,contributors)
    SELECT tenant_id,id,'<page />','',COALESCE(created_by,'ankole:'||tenant_id::text||':principal/system'),
      updated_at,ARRAY[]::text[] FROM pages p
    WHERE type IN ('doc','knowledge')
      AND NOT EXISTS (SELECT 1 FROM page_contents c WHERE c.tenant_id=p.tenant_id AND c.page_id=p.id)
    """)

    execute("""
    UPDATE oban_jobs SET worker='Ankole.Pod.Jobs.PurgeTree'
      WHERE worker='Ankole.Files.Jobs.PurgeNode'
    """)

    execute("""
    CREATE VIEW brain_page_nodes AS
    WITH RECURSIVE paths AS (
      SELECT tenant_id,id,system_key,''::text AS path FROM pages WHERE parent_id IS NULL
      UNION ALL SELECT n.tenant_id,n.id,n.system_key,
        CASE WHEN p.path='' OR p.system_key='ankole_brain' THEN n.name ELSE p.path||'/'||n.name END
        FROM pages n JOIN paths p ON n.tenant_id=p.tenant_id AND n.parent_id=p.id
    )
    SELECT p.tenant_id,p.id,paths.path AS slug,
      COALESCE(p.metadata->>'entity_type',p.type) AS type,p.metadata->>'subtype' AS subtype,
      p.title,COALESCE(c.plain_text,'') AS body,COALESCE(c.content,'<page />') AS xml,
      p.metadata AS meta,p.upstream_state,p.revision,p.parent_id,p.acl_anchor_id,p.is_acl_anchor,p.type AS kind,
      CASE WHEN p.metadata->>'effective_date' ~ '^\\d{4}-\\d{2}-\\d{2}$'
        AND pg_input_is_valid(p.metadata->>'effective_date','date')
        THEN (p.metadata->>'effective_date')::date END AS effective_date,
      p.revision::text AS content_hash,(p.upstream_state->>'source_id')::uuid AS managed_by_source_id,
      p.deleted_at,p.created_at,p.updated_at
    FROM pages p JOIN paths ON paths.tenant_id=p.tenant_id AND paths.id=p.id
      LEFT JOIN page_contents c ON c.tenant_id=p.tenant_id AND c.page_id=p.id
    WHERE p.parent_id IS NOT NULL AND p.type IN ('knowledge','doc','base','applet')
    """)

    flush()

    legacy_brain? =
      repo().query!("SELECT to_regclass('agent_library_container_entries')").rows != [[nil]]

    # Timeline chunks copy their explicit subject. A Page becoming readable as
    # knowledge must not turn a source-only timeline into an entity assertion.
    for [tenant_id, page_id] <-
          repo().query!(
            "SELECT DISTINCT tenant_id::text,page_id::text FROM brain_chunks WHERE content_kind='timeline'"
          ).rows do
      Ankole.Repo.with_tenant(tenant_id, fn ->
        chunking =
          Enum.find(Ankole.Brain.Config.definitions(), &(&1.key == "brain.chunking")).default_value

        {:ok, _} = Ankole.Brain.Chunks.reconcile_node_in_tx(page_id, chunking: chunking)
      end)
    end

    for [tenant_id, id, type, xml, metadata] <-
          repo().query!("""
          SELECT p.tenant_id::text,p.id::text,p.type,c.content,p.metadata
          FROM pages p JOIN page_contents c ON c.tenant_id=p.tenant_id AND c.page_id=p.id
          WHERE p.type IN ('doc','knowledge')
          """).rows do
      {:ok, projection} =
        Ankole.Kernel.vfs_projection(String.to_existing_atom(type), xml, metadata)

      repo().query!(
        """
        UPDATE pages SET vfs_content_empty=$3,vfs_md_size=$4,vfs_md_blake3=$5
        WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid
        """,
        [
          tenant_id,
          id,
          projection.vfs_content_empty,
          projection.vfs_md_size,
          projection.vfs_md_blake3
        ]
      )
    end

    if legacy_brain? do
      for [tenant_id] <- repo().query!("SELECT id::text FROM tenants").rows do
        Ankole.Repo.with_tenant(tenant_id, fn ->
          Ankole.Brain.Schemas.Page
          |> Ankole.Ash.read!()
          |> Enum.filter(fn page ->
            repo().query!(
              "SELECT 1 FROM brain_chunks WHERE tenant_id=$1::text::uuid AND page_id=$2::text::uuid LIMIT 1",
              [tenant_id, page.id]
            ).rows == []
          end)
          |> Enum.each(fn page ->
            {:ok, _} =
              Ankole.Brain.Chunks.reconcile_in_tx(page,
                chunking:
                  Enum.find(Ankole.Brain.Config.definitions(), &(&1.key == "brain.chunking")).default_value
              )

            {:ok, _} = Ankole.Brain.Links.reconcile_object_links_in_tx(page.id)
          end)

          chunking =
            Enum.find(Ankole.Brain.Config.definitions(), &(&1.key == "brain.chunking")).default_value

          for [source_id] <-
                repo().query!(
                  "SELECT DISTINCT source_node_id::text FROM brain_timelines WHERE tenant_id=$1::text::uuid AND subject_page_id IS NULL",
                  [tenant_id]
                ).rows do
            {:ok, _} = Ankole.Brain.Chunks.reconcile_node_in_tx(source_id, chunking: chunking)
          end
        end)
      end
    end
  end

  def down do
    raise Ecto.MigrationError, "Restore a database backup to reverse Page ownership migration"
  end
end
