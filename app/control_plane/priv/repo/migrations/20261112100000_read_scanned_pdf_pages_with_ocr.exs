defmodule Ankole.Repo.Migrations.ReadScannedPdfPagesWithOcr do
  use Ecto.Migration

  def up do
    # The text that OCR read from a file's scanned pages is paid for, and the
    # kernel cannot rebuild it from the file. It stays with the file's cache,
    # so a later extraction of the same file reuses it.
    alter table(:pod_file_caches) do
      add(:ocr, :map, null: false, default: %{})
    end

    # AIGateway records the pages that file extraction sends to OCR. Dropping
    # and adding the check take a brief exclusive lock on the table, and
    # PostgreSQL validates the new check against every row while it holds it.
    drop(constraint(:ai_gateway_usage_records, :ai_gateway_usage_records_origin_check))

    create(
      constraint(:ai_gateway_usage_records, :ai_gateway_usage_records_origin_check,
        check:
          "origin IN ('agent', 'codex', 'applet', 'brain', 'oidc_human', 'compaction', 'pod_files')"
      )
    )

    # A file's content version follows its bytes: the object's SHA-256, the
    # extractor version, and the number of pages that OCR read. An Agent's
    # `drive put` or a sync client commits an unchanged file as a new object,
    # and the version must not change with it, or Brain would learn the same
    # content again. An OCR run adds text without replacing the bytes or the
    # extractor, so the version also counts the pages OCR read. An object
    # stored before Ankole recorded digests has no SHA-256 and keeps its id.
    execute("""
    CREATE OR REPLACE VIEW brain_page_nodes AS
    WITH RECURSIVE paths AS (
      SELECT tenant_id,id,system_key,''::text AS path FROM pages WHERE parent_id IS NULL
      UNION ALL SELECT n.tenant_id,n.id,n.system_key,
        CASE WHEN p.path='' OR p.system_key='ankole_brain' THEN n.name ELSE p.path||'/'||n.name END
        FROM pages n JOIN paths p ON n.tenant_id=p.tenant_id AND n.parent_id=p.id
    )
    SELECT p.tenant_id,p.id,paths.path AS slug,
      COALESCE(p.metadata->>'entity_type',p.type) AS type,p.metadata->>'subtype' AS subtype,
      p.title,
      CASE WHEN p.type='file' THEN COALESCE(psd.body_text,'') ELSE COALESCE(c.plain_text,'') END AS body,
      COALESCE(c.content,'<page />') AS xml,
      p.metadata AS meta,p.upstream_state,p.revision,p.parent_id,p.acl_anchor_id,p.is_acl_anchor,p.type AS kind,
      CASE WHEN p.metadata->>'effective_date' ~ '^\\d{4}-\\d{2}-\\d{2}$'
        AND pg_input_is_valid(p.metadata->>'effective_date','date')
        THEN (p.metadata->>'effective_date')::date END AS effective_date,
      CASE WHEN fc.page_id IS NOT NULL
        THEN COALESCE(encode(fo.sha256,'hex'),fc.object_id::text)||':v'||fc.extractor_version::text||
          COALESCE(':ocr'||NULLIF(jsonb_array_length(fc.metadata->'ocr_pages'),0)::text,'')
        ELSE p.revision::text END AS content_hash,
      (p.upstream_state->>'source_id')::uuid AS managed_by_source_id,
      p.deleted_at,p.created_at,p.updated_at,
      CASE WHEN fc.page_id IS NOT NULL
        THEN jsonb_build_object('format',fc.format,'extract_status',fc.extract_status,'metadata',fc.metadata)
        END AS file
    FROM pages p JOIN paths ON paths.tenant_id=p.tenant_id AND paths.id=p.id
      LEFT JOIN page_contents c ON c.tenant_id=p.tenant_id AND c.page_id=p.id
      LEFT JOIN page_search_documents psd
        ON p.type='file' AND psd.tenant_id=p.tenant_id AND psd.page_id=p.id
      LEFT JOIN pod_file_caches fc
        ON p.type='file' AND fc.tenant_id=p.tenant_id AND fc.page_id=p.id
      LEFT JOIN file_objects fo
        ON fo.tenant_id=fc.tenant_id AND fo.id=fc.object_id
    WHERE p.parent_id IS NOT NULL AND p.type IN ('knowledge','doc','base','applet','file')
    """)

    rename_file_versions()
  end

  # What Brain learned from a file, and the learning jobs still waiting, name
  # the file's content version by its object id. Renaming them to the digest
  # keeps the files that are learned from being learned again, and keeps a
  # waiting job from being rejected as stale.
  defp rename_file_versions do
    execute("""
    UPDATE pages p SET upstream_state =
      replace(p.upstream_state::text, fc.object_id::text||':v', encode(fo.sha256,'hex')||':v')::jsonb
    FROM pod_file_caches fc
      JOIN file_objects fo ON fo.tenant_id=fc.tenant_id AND fo.id=fc.object_id
    WHERE p.tenant_id=fc.tenant_id AND p.id=fc.page_id AND p.type='file'
      AND fo.sha256 IS NOT NULL
      AND p.upstream_state::text LIKE '%'||fc.object_id::text||':v%'
    """)

    execute("""
    UPDATE oban_jobs j SET args = jsonb_set(j.args, '{content_version}', to_jsonb(
      replace(j.args->>'content_version', fc.object_id::text||':v', encode(fo.sha256,'hex')||':v')))
    FROM pod_file_caches fc
      JOIN file_objects fo ON fo.tenant_id=fc.tenant_id AND fo.id=fc.object_id
    WHERE j.worker='Ankole.Brain.Jobs.LearnSource'
      AND j.state IN ('available','scheduled','retryable')
      AND j.args->>'page_id'=fc.page_id::text
      AND fo.sha256 IS NOT NULL
      AND j.args->>'content_version' LIKE fc.object_id::text||':v%'
    """)
  end

  def down do
    raise Ecto.MigrationError,
          "Restore a database backup to reverse OCR for scanned PDF pages"
  end
end
