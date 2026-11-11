defmodule Ankole.Repo.Migrations.IncludeFilesInBrainPageNodes do
  use Ecto.Migration

  # Brain reads file pages through the same projection as knowledge pages. A
  # file page's body is its extracted search text. Replacing a file names a new
  # object without advancing the page revision, so a file page's content
  # version names the object and the extractor version that produced the text.
  # The `file` column carries the cache's format, status, and structure
  # metadata, apart from the page's own business metadata.
  def up do
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
        THEN fc.object_id::text||':v'||fc.extractor_version::text
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
    WHERE p.parent_id IS NOT NULL AND p.type IN ('knowledge','doc','base','applet','file')
    """)

    # Learning and timeline extraction record the content version they
    # covered. Every page learned so far recorded its integer revision, which
    # equals its content version as text.
    execute("""
    UPDATE pages SET upstream_state =
      (upstream_state - 'facts_revision' - 'timeline_revision') ||
      jsonb_strip_nulls(jsonb_build_object(
        'facts_version',upstream_state->>'facts_revision',
        'timeline_version',upstream_state->>'timeline_revision'))
    WHERE upstream_state ?| ARRAY['facts_revision','timeline_revision']
    """)
  end

  def down do
    raise Ecto.MigrationError, "Restore a database backup to reverse the Brain file projection"
  end
end
