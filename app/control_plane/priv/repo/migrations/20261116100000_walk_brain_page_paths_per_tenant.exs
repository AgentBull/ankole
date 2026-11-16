defmodule Ankole.Repo.Migrations.WalkBrainPagePathsPerTenant do
  use Ecto.Migration

  # Every Brain read selects one tenant. The view walks the Page tree from that
  # tenant's roots, so PostgreSQL derives slugs from the tenant's own pages
  # instead of walking every tenant's tree and discarding the others. `OFFSET 0`
  # keeps a reader's page filters outside the walk: PostgreSQL joins the walk to
  # `pages` once and filters the result, rather than repeating the scan of the
  # walk for every page that matches the filters.
  def up do
    execute("""
    CREATE OR REPLACE VIEW brain_page_nodes AS
    SELECT t.id AS tenant_id,p.id,p.path AS slug,
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
    FROM tenants t
      CROSS JOIN LATERAL (
        WITH RECURSIVE paths AS (
          SELECT id,system_key,''::text AS path FROM pages WHERE tenant_id=t.id AND parent_id IS NULL
          UNION ALL SELECT n.id,n.system_key,
            CASE WHEN parent.path='' OR parent.system_key='ankole_brain' THEN n.name ELSE parent.path||'/'||n.name END
            FROM pages n JOIN paths parent ON n.tenant_id=t.id AND n.parent_id=parent.id
        )
        SELECT page.id,page.parent_id,page.type,page.title,page.metadata,page.upstream_state,
          page.revision,page.acl_anchor_id,page.is_acl_anchor,page.deleted_at,page.created_at,
          page.updated_at,paths.path
        FROM paths JOIN pages page ON page.tenant_id=t.id AND page.id=paths.id
        WHERE page.parent_id IS NOT NULL AND page.type IN ('knowledge','doc','base','applet','file')
        OFFSET 0
      ) p
      LEFT JOIN page_contents c ON c.tenant_id=t.id AND c.page_id=p.id
      LEFT JOIN page_search_documents psd
        ON p.type='file' AND psd.tenant_id=t.id AND psd.page_id=p.id
      LEFT JOIN pod_file_caches fc
        ON p.type='file' AND fc.tenant_id=t.id AND fc.page_id=p.id
      LEFT JOIN file_objects fo
        ON fo.tenant_id=fc.tenant_id AND fo.id=fc.object_id
    """)
  end

  def down do
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
  end
end
